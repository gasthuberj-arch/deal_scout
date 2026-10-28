defmodule DealScout.Feeds.Ebay.Matcher do
  @moduledoc """
  Filter-first, in-memory matching engine for eBay items.

  Guarantees match-only persistence: eBay items are evaluated completely in RAM
  against active user alert rules. Non-matching items are discarded instantly
  without touching SQLite disk storage. Only items matching $\\ge 1$ alert rule
  are persisted via `DealScout.Deals.Ingestion`.
  """

  require Logger
  alias DealScout.Alerts
  alias DealScout.Alerts.AlertRule
  alias DealScout.Alerts.Matcher, as: RuleMatcher
  alias DealScout.Deals.{Deal, Ingestion, Merchant}
  alias DealScout.Feeds

  @doc """
  Evaluates candidate deal items in memory against alert rules.
  Only matching items are inserted into the database.

  Options:
  - `:rules` - Explicit list of `AlertRule` structs (defaults to `Alerts.list_active_rules()`).

  Returns `{:ok, %{matched_deals: [Deal.t()], discarded_count: integer()}}`.
  """
  def evaluate_and_persist(items, opts \\ []) when is_list(items) do
    rules =
      case Keyword.get(opts, :rules) do
        nil -> Alerts.list_active_rules()
        explicit_rules -> explicit_rules
      end
      |> Enum.filter(&ebay_eligible?/1)

    if rules == [] do
      {:ok, %{matched_deals: [], discarded_count: length(items)}}
    else
      ebay_feed = Feeds.ensure_ebay_feed()

      {matched_deals, discarded_count} =
        Enum.reduce(items, {[], 0}, fn item, {matched_acc, discarded_acc} ->
          deal_struct = build_in_memory_deal(item, ebay_feed)

          matching_rules =
            Enum.filter(rules, fn rule ->
              RuleMatcher.matches?(deal_struct, rule)
            end)

          if matching_rules != [] do
            case persist_matched_deal(item, ebay_feed) do
              {:ok, persisted_deal} ->
                {[persisted_deal | matched_acc], discarded_acc}

              {:duplicate, _guid} ->
                {matched_acc, discarded_acc + 1}

              {:error, reason} ->
                Logger.warning(
                  "[DealScout.Feeds.Ebay.Matcher] Failed to ingest matching deal #{item.guid}: #{inspect(reason)}"
                )

                {matched_acc, discarded_acc + 1}
            end
          else
            # Discard from RAM with zero disk overhead
            {matched_acc, discarded_acc + 1}
          end
        end)

      {:ok, %{matched_deals: Enum.reverse(matched_deals), discarded_count: discarded_count}}
    end
  end

  defp ebay_eligible?(%AlertRule{is_active: false}), do: false

  defp ebay_eligible?(%AlertRule{source_filter: filter}) do
    is_nil(filter) or filter in ["", "all", "ebay"]
  end

  defp build_in_memory_deal(item, ebay_feed) do
    %Deal{
      guid: item.guid,
      title: item.title,
      url: item.url,
      price: item.price,
      description: item.description,
      clean_text: item.clean_text,
      temperature: item[:temperature] || 100,
      raw_merchant: item[:raw_merchant] || "eBay",
      image_url: item[:image_url],
      published_at: item[:published_at] || DateTime.utc_now() |> DateTime.truncate(:second),
      country:
        item[:country] ||
          %{country_code: "DE", is_germany: true, is_eu: true, flags: "🇩🇪", requires_action: false},
      keyboard_warning: item[:keyboard_warning],
      feed_id: ebay_feed.id,
      feed: ebay_feed,
      merchant: %Merchant{name: "eBay"}
    }
  end

  defp persist_matched_deal(item, ebay_feed) do
    attrs =
      item
      |> Map.put(:feed_id, ebay_feed.id)
      |> Map.put(:feed_slug, "ebay")
      |> Map.put(:merchant_name, "eBay")

    Ingestion.ingest_deal(attrs)
  end
end
