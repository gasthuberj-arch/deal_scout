defmodule DealScout.Alerts do
  @moduledoc """
  The Alerts context for managing user keyword alert rules and matches.
  """

  import Ecto.Query, warn: false
  alias DealScout.Repo
  alias DealScout.Alerts.{AlertRule, UserMatch, Matcher}
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

  # ============================================================================
  # Matching & Ingestion Processing
  # ============================================================================

  @doc """
  Matches a list of newly ingested deals against all active alert rules.
  For each match, creates a UserMatch record and dispatches notifications
  with canonical deduplication and polling-cycle batch collapsing.
  """
  def process_new_deals(deals) when is_list(deals) do
    deals = Repo.preload(deals, [:merchant, :feed])
    rules = list_active_rules()

    # Collect matches grouped by rule for batch collapsing
    matches_by_rule =
      for rule <- rules, reduce: %{} do
        acc ->
          matched_for_rule =
            for deal <- deals,
                Matcher.matches?(deal, rule),
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
