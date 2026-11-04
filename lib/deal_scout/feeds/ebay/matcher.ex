defmodule DealScout.Feeds.Ebay.Matcher do
  @moduledoc """
  Filter-first, in-memory matching engine for eBay items.

  Guarantees match-only persistence: eBay items are evaluated completely in RAM
  against active eBay-eligible alert rules. Non-matching items are discarded instantly
  without touching SQLite disk storage. Only items matching >= 1 alert rule
  are persisted via `DealScout.Deals.Ingestion.ingest_ephemeral/3`.
  """

  alias DealScout.Alerts
  alias DealScout.Alerts.AlertRule
  alias DealScout.Deals.Ingestion
  alias DealScout.Feeds

  @doc """
  Evaluates candidate deal items in memory against alert rules.
  Only matching items are inserted into the database.

  Options:
  - `:rules` - Explicit list of `AlertRule` structs (defaults to eBay-eligible `Alerts.list_active_rules()`).

  Returns `{:ok, %{matched_deals: [Deal.t()], discarded_count: integer()}}`.
  """
  def evaluate_and_persist(items, opts \\ []) when is_list(items) do
    ebay_feed = Feeds.ensure_ebay_feed()

    rules =
      case Keyword.get(opts, :rules) do
        nil ->
          Alerts.list_active_rules()
          |> Enum.filter(&AlertRule.ebay_eligible?/1)

        custom_rules ->
          custom_rules
      end

    Ingestion.ingest_ephemeral(items, ebay_feed, Keyword.put(opts, :rules, rules))
  end
end
