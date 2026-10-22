defmodule DealScout.Alerts do
  @moduledoc """
  The Alerts context for managing user keyword alert rules and matches.
  """

  import Ecto.Query, warn: false
  require Logger
  alias DealScout.Repo
  alias DealScout.Alerts.{AlertRule, UserMatch, Matcher, EvaluationLogger}
  alias DealScout.Notifications.Dispatcher
  alias DealScout.Deals.{Deal, CrossBorderGuard}

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
    %AlertRule{user_id: user.id}
    |> AlertRule.changeset(attrs)
    |> Repo.insert()
  end

  def update_alert_rule(%AlertRule{} = rule, attrs) do
    rule
    |> AlertRule.changeset(attrs)
    |> Repo.update()
  end

  def delete_alert_rule(%AlertRule{} = rule) do
    Repo.delete(rule)
  end

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

  @default_budget_us 30_000

  defp get_budget_us do
    Application.get_env(:deal_scout, :alert_compute_budget_us, @default_budget_us)
  end

  def auto_pause_enabled? do
    Application.get_env(:deal_scout, :alert_auto_pause_enabled, false)
  end

  @doc """
  Matches a list of newly ingested deals against all active alert rules.
  For each match, creates a UserMatch record and dispatches notifications
  with canonical deduplication and polling-cycle batch collapsing.
  Measures query evaluation duration, emits telemetry, and enforces the
  compute budget circuit breaker normalized by batch size (with a 1-deal floor).
  """
  def process_new_deals(deals, opts \\ []) when is_list(deals) do
    deals =
      deals
      |> Repo.preload([:merchant, :feed])
      |> Enum.map(&DealScout.Deals.CrossBorderGuard.enrich/1)

    rules = Keyword.get(opts, :rules) || list_active_rules()
    budget_us = Keyword.get(opts, :budget_us) || get_budget_us()
    auto_pause? = Keyword.get(opts, :auto_pause, auto_pause_enabled?())
    deal_count = max(length(deals), 1)

    # Collect matches grouped by rule for batch collapsing
    matches_by_rule =
      for rule <- rules, reduce: %{} do
        acc ->
          start_time = System.monotonic_time(:microsecond)

          matched_deals =
            Enum.filter(deals, fn deal ->
              Matcher.matches?(deal, rule)
            end)

          duration_us = System.monotonic_time(:microsecond) - start_time
          normalized_duration_us = div(duration_us, deal_count)

          :telemetry.execute(
            [:deal_scout, :alerts, :rule_eval],
            %{
              duration_us: duration_us,
              normalized_duration_us: normalized_duration_us,
              deal_count: length(deals)
            },
            %{rule_id: rule.id, user_id: rule.user_id, rule_name: rule.name}
          )

          # Record slow evaluations to persistent log file (threshold 5ms / 5,000µs)
          EvaluationLogger.log_evaluation(
            rule,
            deals,
            duration_us,
            normalized_duration_us,
            length(matched_deals),
            opts
          )

          if normalized_duration_us > budget_us and auto_pause? do
            budget_ms = Float.round(budget_us / 1000, 1)
            duration_ms = Float.round(normalized_duration_us / 1000, 1)

            reason =
              "Auto-paused: Query evaluation took #{duration_ms}ms/deal (exceeded #{budget_ms}ms compute budget). Simplify keywords or remove broad terms."

            updated_rule =
              case auto_pause_rule(rule, reason, normalized_duration_us) do
                {:ok, updated} -> updated
                _ -> rule
              end

            Phoenix.PubSub.broadcast(
              DealScout.PubSub,
              Dispatcher.user_topic(rule.user_id),
              {:rule_auto_paused, updated_rule, reason}
            )

            Logger.warning(
              "[Compute Guard] Auto-paused slow alert rule #{rule.id} ('#{rule.name}') for user #{rule.user_id} - took #{normalized_duration_us}µs/deal (batch #{duration_us}µs for #{deal_count} deals)"
            )

            acc
          else
            if normalized_duration_us > budget_us do
              Logger.warning(
                "[Compute Guard] Slow alert rule #{rule.id} ('#{rule.name}') took #{normalized_duration_us}µs/deal (batch #{duration_us}µs for #{deal_count} deals), auto-pause is disabled."
              )
            end

            from(r in AlertRule, where: r.id == ^rule.id)
            |> Repo.update_all(set: [last_eval_duration_us: normalized_duration_us])

            matched_for_rule =
              for deal <- matched_deals,
                  not duplicate_canonical_match?(rule.user_id, rule.id, deal) do
                case insert_match(deal, rule) do
                  {:ok, %UserMatch{id: id} = match} when not is_nil(id) ->
                    match

                  _ ->
                    nil
                end
              end
              |> Enum.reject(&is_nil/1)

            if matched_for_rule != [] do
              Map.put(acc, rule, matched_for_rule)
            else
              acc
            end
          end
      end

    # Dispatch notifications per rule
    for {rule, matches} <- matches_by_rule do
      if AlertRule.in_cooldown?(rule) do
        # Broadcast to LiveView inbox for real-time UI, but suppress push/email
        Enum.each(matches, fn m ->
          Phoenix.PubSub.broadcast(
            DealScout.PubSub,
            Dispatcher.user_topic(m.user_id),
            {:new_match, m}
          )
        end)
      else
        Dispatcher.dispatch_batch(rule, matches)
      end
    end
  end

  defp insert_match(deal, rule) do
    attrs = %{
      user_id: rule.user_id,
      deal_id: deal.id,
      alert_rule_id: rule.id,
      is_read: false
    }

    %UserMatch{}
    |> UserMatch.changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:user_id, :deal_id, :alert_rule_id]
    )
  end

  defp duplicate_canonical_match?(user_id, rule_id, deal) do
    canonical_id = deal.canonical_deal_id || deal.id
    since = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)

    query =
      from m in UserMatch,
        join: d in Deal,
        on: d.id == m.deal_id,
        where: m.user_id == ^user_id and m.alert_rule_id == ^rule_id,
        where: m.inserted_at >= ^since,
        where: d.canonical_deal_id == ^canonical_id or d.id == ^canonical_id

    Repo.exists?(query)
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
    |> Enum.map(fn m -> %{m | deal: CrossBorderGuard.enrich(m.deal)} end)
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
