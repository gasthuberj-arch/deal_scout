defmodule DealScout.Deals do
  @moduledoc """
  The Deals context for managing ingested deal records and merchant intelligence.
  """

  import Ecto.Query, warn: false
  alias DealScout.Repo
  alias DealScout.Deals.{Deal, Merchant, MerchantGuard, Deduplicator, CrossBorderGuard, Ingestion}

  @pubsub DealScout.PubSub
  @topic "deals:feed"

  alias DealScout.Deals.Cache

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
  Lists deals with optional filters:
  - :search - text query matching title or clean_text
  - :feed_id - filter by feed
  - :merchant - filter by merchant slug
  - :exclude_dropshippers - boolean to filter out dropshippers
  - :min_temperature - integer threshold
  - :group_deals - boolean to consolidate duplicate deals (default true)
  - :limit - max records (default 60)
  - :offset - pagination offset
  """
  def list_deals(opts \\ []) do
    Cache.fetch_deals(opts, fn ->
      fetch_deals_from_db(opts)
    end)
  end

  defp fetch_deals_from_db(opts) do
    search = Keyword.get(opts, :search)
    feed_id = Keyword.get(opts, :feed_id)
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
      |> filter_by_feed(feed_id)
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

    Enum.map(deals, &CrossBorderGuard.enrich/1)
  end

  defp filter_by_search(query, nil), do: query
  defp filter_by_search(query, ""), do: query

  defp filter_by_search(query, search_term) do
    fts_term = sanitize_fts_query(search_term)

    if fts_term != "" do
      where(
        query,
        [d],
        fragment("? IN (SELECT rowid FROM deals_fts WHERE deals_fts MATCH ?)", d.id, ^fts_term)
      )
    else
      query
    end
  end

  defp sanitize_fts_query(term) when is_binary(term) do
    term
    |> String.replace(~r/[^\p{L}\p{N}\s\-]/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&"\"#{&1}\"*")
    |> Enum.join(" AND ")
  end

  defp filter_by_feed(query, nil), do: query
  defp filter_by_feed(query, "all"), do: query

  defp filter_by_feed(query, feed_id) when is_integer(feed_id) do
    where(query, [d], d.feed_id == ^feed_id)
  end

  defp filter_by_feed(query, feed_id_str) when is_binary(feed_id_str) do
    case Integer.parse(feed_id_str) do
      {id, ""} -> where(query, [d], d.feed_id == ^id)
      _ -> query
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

  def get_deal!(id) do
    Deal
    |> preload([:feed, :merchant, duplicates: [:feed, :merchant]])
    |> Repo.get!(id)
    |> CrossBorderGuard.enrich()
  end

  @doc """
  Gets or creates a Merchant record and updates posting frequency and stats.
  """
  def get_or_create_merchant(merchant_name, opts \\ []) do
    merchant = ensure_merchant(merchant_name, opts)
    feed_slug = Keyword.get(opts, :feed_slug)
    temperature = Keyword.get(opts, :temperature)
    record_merchant_deal(merchant.id, feed_slug, temperature)
  end

  @doc """
  Ensures a Merchant record exists for the given name/url without incrementing deal stats.
  """
  def ensure_merchant(merchant_name, opts \\ []) do
    norm_name =
      case merchant_name do
        name when is_binary(name) and name != "" ->
          MerchantGuard.normalize_name(name)

        _ ->
          url = Keyword.get(opts, :url)

          case MerchantGuard.extract_domain(url) do
            domain when is_binary(domain) and domain != "" -> domain
            _ -> "Diverse Händler"
          end
      end

    slug = MerchantGuard.slugify(norm_name)
    url = Keyword.get(opts, :url)
    context_text = Keyword.get(opts, :context_text) || Keyword.get(opts, :text)

    trust_level = MerchantGuard.classify(norm_name, url, context_text)
    domain = MerchantGuard.extract_domain(url)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get_by(Merchant, slug: slug) do
      nil ->
        %Merchant{}
        |> Merchant.changeset(%{
          name: norm_name,
          slug: slug,
          domain: domain,
          trust_level: trust_level,
          deal_count: 0,
          feed_counts: %{},
          avg_temperature: 0.0,
          last_seen_at: now
        })
        |> Repo.insert(
          on_conflict: :nothing,
          conflict_target: :slug
        )
        |> case do
          {:ok, %Merchant{id: id}} when not is_nil(id) ->
            Repo.get!(Merchant, id)

          _ ->
            Repo.get_by!(Merchant, slug: slug)
        end

      %Merchant{} = merchant ->
        merchant
    end
  end

  @doc """
  Updates merchant posting frequency, temperature average, and feed counts for a newly inserted deal.
  """
  def record_merchant_deal(merchant_id, feed_slug \\ nil, temperature \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get(Merchant, merchant_id) do
      nil ->
        {:error, :merchant_not_found}

      %Merchant{} = merchant ->
        new_deal_count = merchant.deal_count + 1
        current_feed_counts = merchant.feed_counts || %{}

        updated_feed_counts =
          if feed_slug do
            count = Map.get(current_feed_counts, feed_slug, 0)
            Map.put(current_feed_counts, feed_slug, count + 1)
          else
            current_feed_counts
          end

        updated_avg_temp =
          if temperature do
            (merchant.avg_temperature * merchant.deal_count + temperature) / new_deal_count
          else
            merchant.avg_temperature
          end

        effective_trust_level =
          if merchant.trust_level == "verified", do: "verified", else: merchant.trust_level

        merchant
        |> Merchant.changeset(%{
          deal_count: new_deal_count,
          feed_counts: updated_feed_counts,
          avg_temperature: updated_avg_temp,
          trust_level: effective_trust_level,
          last_seen_at: now
        })
        |> Repo.update()
        |> case do
          {:ok, updated} -> updated
          {:error, _} -> merchant
        end
    end
  end

  @doc """
  Inserts a single deal using the unified Deal Ingestion pipeline.
  Ensures merchant exists, performs canonical deduplication, enriches
  cross-border origin metadata, evaluates alert rules, and broadcasts via PubSub.
  Returns {:ok, deal} or {:duplicate, guid} or {:error, changeset}.
  """
  def insert_deal(attrs) do
    Ingestion.ingest_deal(attrs)
  end

  @doc """
  Runs through all deals chronologically and assigns canonical_deal_id to duplicates.
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
  Deletes deals older than given number of days.
  """
  def prune_old_deals(days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second)

    from(d in Deal, where: d.published_at < ^cutoff)
    |> Repo.delete_all()
  end
end
