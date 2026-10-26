defmodule DealScout.Alerts.MatchRecorder do
  @moduledoc """
  The **Match recording** module for DealScout.

  Provides the persistence and batch deduplication seam between
  **Match evaluation** (`DealScout.Alerts.Matcher`) and **Match delivery**
  (`DealScout.Notifications.Dispatcher`).

  Encapsulates:
  - Single set-based query for 24-hour canonical duplicate matches across all rules and deals
  - Intra-batch duplicate suppression for matching canonical deals in the same polling cycle
  - Conflict-safe persistence of `UserMatch` records
  - Clean dispatch handoff to `DealScout.Notifications.Dispatcher`
  """

  import Ecto.Query, warn: false
  alias DealScout.Repo
  alias DealScout.Alerts.{AlertRule, UserMatch}
  alias DealScout.Deals.Deal
  alias DealScout.Notifications.Dispatcher

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
end
