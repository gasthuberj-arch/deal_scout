defmodule DealScout.Alerts do
  @moduledoc """
  The Alerts context for managing user keyword alert rules and matches.
  """

  import Ecto.Query, warn: false
  alias DealScout.Repo
  alias DealScout.Alerts.{AlertRule, ComputeGuard, Matcher, UserMatch}
  alias DealScout.Deals.Deal
  alias DealScout.Notifications.Dispatcher
  alias DealScout.KeywordEngine

  def subscribe_to_user_matches(user_id) do
    Phoenix.PubSub.subscribe(DealScout.PubSub, Dispatcher.user_topic(user_id))
  end

  # ============================================================================
  # Alert Rules
  # ============================================================================

  def list_alert_rules_for_user(user_id) do
    Repo.all(from r in AlertRule, where: r.user_id == ^user_id, order_by: [desc: r.inserted_at])
  end

  def get_alert_rule!(id), do: Repo.get!(AlertRule, id)

  def get_user_alert_rule!(user_id, id) do
    Repo.get_by!(AlertRule, id: id, user_id: user_id)
  end

  def create_alert_rule(user, attrs) do
    result =
      %AlertRule{user_id: user.id}
      |> AlertRule.changeset(attrs)
      |> Repo.insert()

    with {:ok, rule} <- result do
      KeywordEngine.mark_dirty()
      {:ok, rule}
    end
  end

  def update_alert_rule(%AlertRule{} = rule, attrs) do
    result =
      rule
      |> AlertRule.changeset(attrs)
      |> Repo.update()

    with {:ok, updated_rule} <- result do
      KeywordEngine.mark_dirty()
      {:ok, updated_rule}
    end
  end

  def delete_alert_rule(%AlertRule{} = rule) do
    result = Repo.delete(rule)

    with {:ok, deleted_rule} <- result do
      KeywordEngine.mark_dirty()
      {:ok, deleted_rule}
    end
  end

  @doc """
  Runs historical backtesting for an alert rule (or draft parameter map) against past deals.
  """
  defdelegate backtest_rule(rule_or_params, opts \\ []),
    to: DealScout.Alerts.Backtest,
    as: :test_rule

  def change_alert_rule(%AlertRule{} = rule, attrs \\ %{}) do
    AlertRule.changeset(rule, attrs)
  end

  def list_active_rules do
    Repo.all(from r in AlertRule, where: r.is_active == true, preload: [:user])
  end

  @doc """
  Auto-pauses an alert rule when its evaluation duration exceeds the compute budget.
  Records the pause reason and last evaluation duration in microseconds.
  """
  def auto_pause_rule(%AlertRule{} = rule, reason, duration_us) do
    update_alert_rule(rule, %{
      is_active: false,
      pause_reason: reason,
      last_eval_duration_us: duration_us
    })
  end

  @doc """
  Resumes an alert rule, clearing any pause reason and setting is_active to true.
  """
  def resume_rule(%AlertRule{} = rule) do
    update_alert_rule(rule, %{
      is_active: true,
      pause_reason: nil
    })
  end

  @doc """
  Pauses an alert rule manually (e.g. from the admin console).
  """
  def pause_rule(%AlertRule{} = rule, reason \\ "Manually paused by administrator") do
    update_alert_rule(rule, %{
      is_active: false,
      pause_reason: reason
    })
  end

  @doc """
  Lists all alert rules that have been auto-paused (is_active is false and pause_reason is set),
  preloading the associated user.
  """
  def list_auto_paused_rules do
    Repo.all(
      from r in AlertRule,
        where: r.is_active == false and not is_nil(r.pause_reason),
        preload: [:user],
        order_by: [desc: r.updated_at]
    )
  end

  @doc """
  Lists the slowest alert rules ordered by last evaluation duration in microseconds descending,
  preloading the associated user.
  """
  def list_slowest_rules(limit \\ 10) do
    Repo.all(
      from r in AlertRule,
        where: not is_nil(r.last_eval_duration_us),
        preload: [:user],
        order_by: [desc: r.last_eval_duration_us],
        limit: ^limit
    )
  end

  # ============================================================================
  # Matching & Ingestion Processing
  # ============================================================================

  defdelegate auto_pause_enabled?, to: ComputeGuard

  @doc """
  Matches a list of newly ingested deals against all active alert rules.
  For each match, creates a UserMatch record and dispatches notifications
  with canonical deduplication and polling-cycle batch collapsing.
  Evaluation, telemetry, and compute budget circuit breaker are handled
  internally by `Matcher.match_batch/3`.
  """
  def process_new_deals(deals, opts \\ []) when is_list(deals) do
    deals = maybe_preload_deals(deals)
    rules = Keyword.get(opts, :rules) || list_active_rules()

    {:ok, %{matches_by_rule: matches_by_rule}} = Matcher.match_batch(deals, rules, opts)
    record_and_dispatch(matches_by_rule)
  end

  @doc """
  Records newly evaluated matches in the database with set-based canonical deduplication
  and dispatches notifications per rule.
  """
  @spec record_and_dispatch(%{AlertRule.t() => [Deal.t()]}) :: :ok
  def record_and_dispatch(matches_by_rule) when is_map(matches_by_rule) do
    candidates =
      for {rule, deals} <- matches_by_rule,
          deal <- deals do
        %{
          rule: rule,
          deal: deal,
          user_id: rule.user_id,
          rule_id: rule.id,
          deal_id: deal.id,
          canonical_id: deal.canonical_deal_id || deal.id
        }
      end

    if candidates == [] do
      :ok
    else
      persisted_by_rule =
        candidates
        |> filter_canonical_duplicates()
        |> persist_matches()

      for {rule, matches} <- persisted_by_rule do
        Dispatcher.dispatch_batch(rule, matches)
      end

      :ok
    end
  end

  def record_and_dispatch(_), do: :ok

  @doc """
  Filters out deals that match existing canonical deals for the same (user_id, rule_id)
  within the last 24 hours or earlier in the same candidate batch.
  """
  def filter_canonical_duplicates([]), do: []

  def filter_canonical_duplicates(candidates) when is_list(candidates) do
    user_ids = Enum.map(candidates, & &1.user_id) |> Enum.uniq()
    rule_ids = Enum.map(candidates, & &1.rule_id) |> Enum.uniq()
    canonical_ids = Enum.map(candidates, & &1.canonical_id) |> Enum.uniq()

    since = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)

    existing_matches =
      from(m in UserMatch,
        join: d in Deal,
        on: d.id == m.deal_id,
        where: m.user_id in ^user_ids and m.alert_rule_id in ^rule_ids,
        where: m.inserted_at >= ^since,
        where: d.id in ^canonical_ids or d.canonical_deal_id in ^canonical_ids,
        select: {m.user_id, m.alert_rule_id, coalesce(d.canonical_deal_id, d.id)}
      )
      |> Repo.all()
      |> MapSet.new()

    {filtered, _seen} =
      Enum.reduce(candidates, {[], existing_matches}, fn cand, {acc, seen_set} ->
        key = {cand.user_id, cand.rule_id, cand.canonical_id}

        if MapSet.member?(seen_set, key) do
          {acc, seen_set}
        else
          {[cand | acc], MapSet.put(seen_set, key)}
        end
      end)

    Enum.reverse(filtered)
  end

  defp persist_matches(candidates) do
    candidates
    |> Enum.reduce(%{}, fn cand, acc ->
      case insert_match(cand.deal, cand.rule) do
        {:ok, %UserMatch{id: id} = match} when not is_nil(id) ->
          Map.update(acc, cand.rule, [match], &[match | &1])

        _ ->
          acc
      end
    end)
    |> Map.new(fn {rule, matches} -> {rule, Enum.reverse(matches)} end)
  end

  defp insert_match(deal, rule) do
    %UserMatch{
      user_id: rule.user_id,
      deal_id: deal.id,
      alert_rule_id: rule.id,
      is_read: false
    }
    |> Ecto.Changeset.change()
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:user_id, :deal_id, :alert_rule_id]
    )
  end

  defp maybe_preload_deals(deals) do
    needs_preload? =
      Enum.any?(deals, fn deal ->
        not Ecto.assoc_loaded?(deal.merchant) or not Ecto.assoc_loaded?(deal.feed)
      end)

    if needs_preload? do
      Repo.preload(deals, [:merchant, :feed])
    else
      deals
    end
  end

  # ============================================================================
  # User Matches (Inbox)
  # ============================================================================

  def list_user_matches(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    unread_only = Keyword.get(opts, :unread_only, false)

    query =
      from m in UserMatch,
        where: m.user_id == ^user_id,
        join: d in assoc(m, :deal),
        join: f in assoc(d, :feed),
        left_join: me in assoc(d, :merchant),
        join: r in assoc(m, :alert_rule),
        preload: [deal: {d, [feed: f, merchant: me]}, alert_rule: r],
        order_by: [desc: m.inserted_at],
        limit: ^limit

    query =
      if unread_only do
        from m in query, where: m.is_read == false
      else
        query
      end

    query
    |> Repo.all()
  end

  def count_unread_matches(user_id) do
    Repo.one(
      from m in UserMatch,
        where: m.user_id == ^user_id and m.is_read == false,
        select: count(m.id)
    ) || 0
  end

  def mark_match_read(user_id, match_id) do
    from(m in UserMatch, where: m.id == ^match_id and m.user_id == ^user_id)
    |> Repo.update_all(
      set: [is_read: true, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )
  end

  def mark_all_matches_read(user_id) do
    from(m in UserMatch, where: m.user_id == ^user_id and m.is_read == false)
    |> Repo.update_all(
      set: [is_read: true, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )
  end
end
