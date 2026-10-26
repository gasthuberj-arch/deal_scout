defmodule DealScout.Deals do
  @moduledoc """
  The Deals context for managing ingested deal records, **Deal stream filter** queries,
  and merchant intelligence.
  """

  import Ecto.Query, warn: false
  alias DealScout.Repo

  alias DealScout.Deals.{
    Cache,
    Deal,
    Deduplicator,
    Ingestion,
    Merchant,
    MerchantGuard
  }

  alias DealScout.KeywordEngine.Query

  @pubsub DealScout.PubSub
  @topic "deals:feed"

  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  def broadcast_deal({:ok, %Deal{} = deal} = result) do
    Cache.invalidate_deals()
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:new_deal, deal})
    result
  end

  def broadcast_deal(%Deal{} = deal) do
    Cache.invalidate_deals()
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:new_deal, deal})
    {:ok, deal}
  end

  def broadcast_deal(error), do: error

  @doc """
  Lists deals with optional **Deal stream filter** options:
  - `:search` - text or boolean **Keyword query** matching title, merchant, or `clean_text`
  - `:feed` / `:feed_id` - filter by feed slug, integer ID, or `"all"`
  - `:merchant` - filter by merchant slug or `"all"`
  - `:exclude_dropshippers` - boolean to filter out dropshippers
  - `:min_temperature` - integer threshold
  - `:group_deals` - boolean to consolidate duplicate deals (default `true`)
  - `:limit` - max records (default `60`)
  - `:offset` - pagination offset
  """
  def list_deals(opts \\ []) do
    Cache.fetch_deals(opts, fn ->
      fetch_deals_from_db(opts)
    end)
  end

  @doc """
  Evaluates whether an in-memory `%Deal{}` matches the active **Deal stream filter**
  options (used when a live `:new_deal` arrives over PubSub so live stream filtering
  and `list_deals/1` share identical semantics).
  """
  def matches_stream?(%Deal{} = deal, filters) when is_list(filters) or is_map(filters) do
    filters = Map.new(filters)

    feed_filter =
      Map.get(filters, :feed) || Map.get(filters, :feed_id) ||
        Map.get(filters, :selected_feed, "all")

    merchant_filter = Map.get(filters, :merchant) || Map.get(filters, :selected_merchant, "all")

    exclude_dropshippers =
      Map.get(filters, :exclude_dropshippers, Map.get(filters, :hide_dropshippers, false))

    min_temperature = Map.get(filters, :min_temperature)
    group_deals = Map.get(filters, :group_deals, true)
    search = Map.get(filters, :search) || Map.get(filters, :search_query, "")

    matches_feed_filter?(deal, feed_filter) and
      matches_merchant_filter?(deal, merchant_filter) and
      (not exclude_dropshippers or not dropshipper_deal?(deal)) and
      matches_min_temp?(deal, min_temperature) and
      (not group_deals or is_nil(deal.canonical_deal_id)) and
      matches_search_query?(deal, search)
  end

  @doc """
  Returns true if the deal's merchant or URL is classified as a dropshipper.
  Shared between **Deal stream filter** and `DealScout.Alerts.Matcher`.
  """
  def dropshipper_deal?(%Deal{} = deal) do
    trust_level =
      case deal.merchant do
        %{trust_level: level} -> level
        _ -> nil
      end

    merchant_name =
      case deal.merchant do
        %{name: name} -> name
        _ -> deal.raw_merchant
      end

    trust_level == "dropshipper" or MerchantGuard.dropshipper?(merchant_name, deal.url)
  end

  @doc """
  Returns the canonical searchable text string for a deal (`title + merchant + clean_text`).
  """
  def searchable_text(%Deal{} = deal) do
    merchant_name =
      case deal.merchant do
        %{name: name} -> name
        _ -> deal.raw_merchant || ""
      end

    "#{deal.title} #{merchant_name} #{deal.clean_text || ""}"
  end

  defp fetch_deals_from_db(opts) do
    search = Keyword.get(opts, :search)
    feed_filter = Keyword.get(opts, :feed) || Keyword.get(opts, :feed_id)
    merchant_slug = Keyword.get(opts, :merchant)
    exclude_dropshippers = Keyword.get(opts, :exclude_dropshippers, false)
    min_temperature = Keyword.get(opts, :min_temperature)
    group_deals = Keyword.get(opts, :group_deals, true)
    limit = Keyword.get(opts, :limit, 60)
    offset = Keyword.get(opts, :offset, 0)

    query =
      Deal
      |> join(:inner, [d], f in assoc(d, :feed), as: :feed)
      |> join(:left, [d], m in assoc(d, :merchant), as: :merchant)
      |> filter_by_search(search)
      |> filter_by_feed(feed_filter)
      |> filter_by_merchant(merchant_slug)
      |> filter_by_dropshippers(exclude_dropshippers)
      |> filter_by_min_temperature(min_temperature)
      |> filter_by_grouping(group_deals)
      |> order_by([d], desc: d.published_at, desc: d.id)
      |> limit(^limit)
      |> offset(^offset)

    deals =
      if group_deals do
        query
        |> preload([d, feed: f, merchant: m],
          feed: f,
          merchant: m,
          duplicates: [:feed, :merchant]
        )
        |> Repo.all()
      else
        query
        |> preload([d, feed: f, merchant: m], feed: f, merchant: m)
        |> Repo.all()
      end

    deals
    |> Enum.filter(fn d -> not exclude_dropshippers or not dropshipper_deal?(d) end)
  end

  defp filter_by_search(query, nil), do: query
  defp filter_by_search(query, ""), do: query

  defp filter_by_search(query, search_term) when is_binary(search_term) do
    case Query.fts_query(search_term) do
      fts_term when is_binary(fts_term) and fts_term != "" ->
        where(
          query,
          [d],
          fragment("? IN (SELECT rowid FROM deals_fts WHERE deals_fts MATCH ?)", d.id, ^fts_term)
        )

      _ ->
        query
    end
  end

  defp filter_by_feed(query, nil), do: query
  defp filter_by_feed(query, ""), do: query
  defp filter_by_feed(query, "all"), do: query

  defp filter_by_feed(query, feed_id) when is_integer(feed_id) do
    where(query, [d], d.feed_id == ^feed_id)
  end

  defp filter_by_feed(query, feed_str) when is_binary(feed_str) do
    case Integer.parse(feed_str) do
      {id, ""} -> where(query, [d], d.feed_id == ^id)
      _ -> where(query, [d, feed: f], f.slug == ^feed_str)
    end
  end

  defp filter_by_merchant(query, nil), do: query
  defp filter_by_merchant(query, ""), do: query
  defp filter_by_merchant(query, "all"), do: query

  defp filter_by_merchant(query, slug) do
    where(query, [d, feed: _f, merchant: m], m.slug == ^slug)
  end

  defp filter_by_dropshippers(query, false), do: query
  defp filter_by_dropshippers(query, nil), do: query

  defp filter_by_dropshippers(query, true) do
    where(
      query,
      [d, feed: _f, merchant: m],
      is_nil(m.trust_level) or m.trust_level != "dropshipper"
    )
  end

  defp filter_by_min_temperature(query, nil), do: query

  defp filter_by_min_temperature(query, min_temp) when is_integer(min_temp) do
    where(query, [d], not is_nil(d.temperature) and d.temperature >= ^min_temp)
  end

  defp filter_by_grouping(query, true) do
    where(query, [d], is_nil(d.canonical_deal_id))
  end

  defp filter_by_grouping(query, false), do: query

  defp matches_feed_filter?(_deal, nil), do: true
  defp matches_feed_filter?(_deal, ""), do: true
  defp matches_feed_filter?(_deal, "all"), do: true

  defp matches_feed_filter?(deal, feed_id) when is_integer(feed_id) do
    deal.feed_id == feed_id
  end

  defp matches_feed_filter?(deal, feed_str) when is_binary(feed_str) do
    case Integer.parse(feed_str) do
      {id, ""} ->
        deal.feed_id == id

      _ ->
        (deal.feed != nil and deal.feed.slug == feed_str) or to_string(deal.feed_id) == feed_str
    end
  end

  defp matches_merchant_filter?(_deal, nil), do: true
  defp matches_merchant_filter?(_deal, ""), do: true
  defp matches_merchant_filter?(_deal, "all"), do: true

  defp matches_merchant_filter?(deal, merchant_slug) do
    deal.merchant != nil and deal.merchant.slug == merchant_slug
  end

  defp matches_min_temp?(_deal, nil), do: true

  defp matches_min_temp?(deal, min_temp) when is_integer(min_temp) do
    not is_nil(deal.temperature) and deal.temperature >= min_temp
  end

  defp matches_search_query?(_deal, nil), do: true
  defp matches_search_query?(_deal, ""), do: true

  defp matches_search_query?(deal, search_query) when is_binary(search_query) do
    trimmed = String.trim(search_query)

    if trimmed == "" do
      true
    else
      text = searchable_text(deal)

      case Query.parse(trimmed) do
        {:ok, ast} ->
          Query.matches?(ast, text) or substring_tokens_match?(text, trimmed)

        _ ->
          substring_tokens_match?(text, trimmed)
      end
    end
  end

  defp substring_tokens_match?(text, query) do
    down_text = String.downcase(text)

    query
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s\-]/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.all?(&String.contains?(down_text, &1))
  end

  def get_deal!(id) do
    Deal
    |> preload([:feed, :merchant, duplicates: [:feed, :merchant]])
    |> Repo.get!(id)
  end

  @doc """
  Inserts a single deal using the unified **Deal ingestion** pipeline.
  Ensures merchant exists, performs canonical deduplication, enriches
  cross-border origin metadata, evaluates alert rules, and broadcasts via PubSub.
  Returns `{:ok, deal}` or `{:duplicate, guid}` or `{:error, changeset}`.
  """
  def insert_deal(attrs) do
    Ingestion.ingest_deal(attrs)
  end

  @doc """
  Runs through all deals chronologically and assigns `canonical_deal_id` to duplicates.
  """
  def deduplicate_all_deals do
    deals =
      Deal
      |> order_by([d], asc: d.published_at, asc: d.id)
      |> Repo.all()

    Enum.reduce(deals, 0, fn deal, count ->
      case Deduplicator.find_canonical_deal(deal) do
        %Deal{id: cid} when cid != deal.id ->
          deal
          |> Deal.changeset(%{canonical_deal_id: cid})
          |> Repo.update!()

          count + 1

        _ ->
          count
      end
    end)
  end

  @doc """
  Lists top merchants by deal count.
  """
  def list_merchants(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Merchant
    |> order_by([m], desc: m.deal_count, desc: m.last_seen_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def get_merchant_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Merchant, slug: slug)
  end

  @doc """
  Deletes deals older than given number of days and invalidates caches.
  """
  def prune_old_deals(days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second)

    {count, _} =
      result =
      from(d in Deal, where: d.published_at < ^cutoff)
      |> Repo.delete_all()

    if count > 0 do
      Cache.invalidate_deals()
    end

    result
  end
end
