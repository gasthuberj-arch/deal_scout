defmodule DealScout.Deals.Ingestion do
  @moduledoc """
  Atomic ingestion pipeline for deal feeds.

  Encapsulates the end-to-end deal ingestion lifecycle:
  - Parses raw feed XML into normalized item structures.
  - Filters out existing deal GUIDs in bulk.
  - Resolves merchants and ensures merchant stats (deal count, average temperature,
    feed frequency) are updated ONLY on genuinely new deals, never on duplicate polls.
  - Deduplicates incoming deals against existing ones using `Deduplicator`.
  - Performs cross-border EU and keyboard layout detection at ingestion time.
  - Dispatches newly inserted deals to `Alerts` and broadcasts via PubSub.
  """

  import Ecto.Query, warn: false
  alias DealScout.Repo
  alias DealScout.Deals
  alias DealScout.Deals.{Deal, Deduplicator, CrossBorderGuard}
  alias DealScout.Feeds.Parser
  alias DealScout.Alerts

  @doc """
  Ingests deals from a feed's raw XML body.
  Returns `{:ok, new_deals}` or `{:error, reason}`.
  """
  def ingest_feed(feed, xml_body) when is_map(feed) and is_binary(xml_body) do
    feed_id = Map.get(feed, :id)
    feed_slug = Map.get(feed, :slug) || get_feed_slug(feed_id)

    case Parser.parse_feed(xml_body, feed_id) do
      items when is_list(items) ->
        new_deals = process_items(items, feed_id, feed_slug)
        {:ok, new_deals}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:parse_failed, other}}
    end
  end

  def ingest_feed(_feed, _xml_body), do: {:error, :invalid_arguments}

  defp process_items([], _feed_id, _feed_slug), do: []

  defp process_items(items, feed_id, feed_slug) do
    # 1. Deduplicate by GUID within the current batch
    unique_items = Enum.uniq_by(items, fn item -> item[:guid] || item["guid"] end)

    guids =
      unique_items
      |> Enum.map(fn item -> item[:guid] || item["guid"] end)
      |> Enum.reject(&is_nil/1)

    # 2. Query DB to filter out already-ingested GUIDs
    existing_guids =
      if guids == [] do
        MapSet.new()
      else
        Deal
        |> where([d], d.guid in ^guids)
        |> select([d], d.guid)
        |> Repo.all()
        |> MapSet.new()
      end

    new_items =
      Enum.reject(unique_items, fn item ->
        guid = item[:guid] || item["guid"]
        is_nil(guid) or MapSet.member?(existing_guids, guid)
      end)

    if new_items == [] do
      []
    else
      # 3. Insert new deals, resolving merchants and stats atomically
      inserted_deals =
        Enum.reduce(new_items, [], fn item, acc ->
          case insert_single_deal(item, feed_id, feed_slug) do
            {:ok, deal} -> [deal | acc]
            _ -> acc
          end
        end)
        |> Enum.reverse()

      # 4. Trigger alert rule matcher on newly inserted deals
      if inserted_deals != [] do
        Alerts.process_new_deals(inserted_deals)
      end

      inserted_deals
    end
  end

  defp insert_single_deal(item, feed_id, feed_slug) do
    guid = item[:guid] || item["guid"]
    name = item[:merchant] || item["merchant"] || item[:merchant_name] || item["merchant_name"]
    url = item[:url] || item["url"]
    text = item[:clean_text] || item["clean_text"]
    temp = item[:temperature] || item["temperature"]

    # Ensure merchant exists without incrementing deal stats yet
    merchant =
      Deals.ensure_merchant(name,
        url: url,
        text: text
      )

    merchant_id = if merchant, do: merchant.id, else: nil

    # Find canonical deal for cross-feed deduplication
    candidate_attrs =
      item
      |> Map.put(:merchant_id, merchant_id)
      |> Map.put(:feed_id, feed_id)
      |> Map.put(:title, item[:title] || item["title"])
      |> Map.put(:price, item[:price] || item["price"])
      |> Map.put(:url, url)
      |> Map.put(:published_at, item[:published_at] || item["published_at"])

    canonical_id =
      case Deduplicator.find_canonical_deal(candidate_attrs) do
        %{id: cid} -> cid
        _ -> nil
      end

    deal_attrs =
      item
      |> Map.put(:feed_id, feed_id)
      |> Map.put(:merchant_id, merchant_id)
      |> Map.put(:canonical_deal_id, canonical_id)
      |> Map.put_new(:raw_merchant, name)

    %Deal{}
    |> Deal.changeset(deal_attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: :guid
    )
    |> case do
      {:ok, %Deal{id: nil}} ->
        {:duplicate, guid}

      {:ok, %Deal{} = deal} ->
        # CRITICAL: Only increment merchant stats on successful insertion
        if merchant do
          Deals.record_merchant_deal(merchant.id, feed_slug, temp)
        end

        deal = Repo.preload(deal, [:feed, :merchant, duplicates: [:feed]])
        deal = enrich_deal_metadata(deal)

        Deals.broadcast_deal({:ok, deal})

        {:ok, deal}

      error ->
        error
    end
  end

  defp enrich_deal_metadata(%Deal{} = deal) do
    country = CrossBorderGuard.detect_country(deal)
    keyboard_warning = CrossBorderGuard.keyboard_warning(deal)

    %{deal | country: country, keyboard_warning: keyboard_warning, cross_border_evaluated: true}
  end

  defp get_feed_slug(nil), do: nil

  defp get_feed_slug(feed_id) do
    case Repo.get(DealScout.Feeds.Feed, feed_id) do
      %{slug: slug} -> slug
      _ -> nil
    end
  end
end
