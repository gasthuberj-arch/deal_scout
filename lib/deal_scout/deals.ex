defmodule DealScout.Deals do
  @moduledoc """
  The Deals context for managing ingested deal records and merchant intelligence.
  """

  import Ecto.Query, warn: false
  alias DealScout.Repo
  alias DealScout.Deals.{Deal, Merchant, MerchantGuard}

  @pubsub DealScout.PubSub
  @topic "deals:feed"

  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  def broadcast_deal({:ok, %Deal{} = deal} = result) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:new_deal, deal})
    result
  end

  def broadcast_deal(error), do: error

  @doc """
  Lists deals with optional filters:
  - :search - text query matching title or clean_text
  - :feed_id - filter by feed
  - :merchant - filter by merchant slug
  - :exclude_dropshippers - boolean to filter out dropshippers
  - :min_temperature - integer threshold
  - :limit - max records (default 60)
  - :offset - pagination offset
  """
  def list_deals(opts \\ []) do
    search = Keyword.get(opts, :search)
    feed_id = Keyword.get(opts, :feed_id)
    merchant_slug = Keyword.get(opts, :merchant)
    exclude_dropshippers = Keyword.get(opts, :exclude_dropshippers, false)
    min_temperature = Keyword.get(opts, :min_temperature)
    limit = Keyword.get(opts, :limit, 60)
    offset = Keyword.get(opts, :offset, 0)

    Deal
    |> join(:inner, [d], f in assoc(d, :feed), as: :feed)
    |> join(:left, [d], m in assoc(d, :merchant), as: :merchant)
    |> preload([d, feed: f, merchant: m], feed: f, merchant: m)
    |> filter_by_search(search)
    |> filter_by_feed(feed_id)
    |> filter_by_merchant(merchant_slug)
    |> filter_by_dropshippers(exclude_dropshippers)
    |> filter_by_min_temperature(min_temperature)
    |> order_by([d], desc: d.published_at, desc: d.id)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  defp filter_by_search(query, nil), do: query
  defp filter_by_search(query, ""), do: query

  defp filter_by_search(query, search_term) do
    term = "%#{search_term}%"

    where(
      query,
      [d, feed: _f, merchant: m],
      like(d.title, ^term) or like(d.clean_text, ^term) or like(m.name, ^term)
    )
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

  def get_deal!(id) do
    Deal
    |> preload([:feed, :merchant])
    |> Repo.get!(id)
  end

  @doc """
  Gets or creates a Merchant record and updates posting frequency and stats.
  """
  def get_or_create_merchant(merchant_name, opts \\ []) do
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
    feed_slug = Keyword.get(opts, :feed_slug)
    temperature = Keyword.get(opts, :temperature)

    trust_level = MerchantGuard.classify(norm_name, url, context_text)
    domain = MerchantGuard.extract_domain(url)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get_by(Merchant, slug: slug) do
      nil ->
        feed_counts = if feed_slug, do: %{feed_slug => 1}, else: %{}
        avg_temp = if temperature, do: temperature * 1.0, else: 0.0

        %Merchant{}
        |> Merchant.changeset(%{
          name: norm_name,
          slug: slug,
          domain: domain,
          trust_level: trust_level,
          deal_count: 1,
          feed_counts: feed_counts,
          avg_temperature: avg_temp,
          last_seen_at: now
        })
        |> Repo.insert(
          on_conflict: [
            inc: [deal_count: 1],
            set: [last_seen_at: now]
          ],
          conflict_target: :slug
        )
        |> case do
          {:ok, merchant} -> merchant
          {:error, _} -> Repo.get_by!(Merchant, slug: slug)
        end

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
          if merchant.trust_level == "verified", do: "verified", else: trust_level

        merchant
        |> Merchant.changeset(%{
          deal_count: new_deal_count,
          feed_counts: updated_feed_counts,
          avg_temperature: updated_avg_temp,
          trust_level: effective_trust_level,
          domain: merchant.domain || domain,
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
  Inserts a single deal, resolving the merchant association, ignoring duplicate guid.
  Returns {:ok, deal} or {:duplicate, guid}
  """
  def insert_deal(attrs) do
    attrs = Map.new(attrs)

    merchant_id =
      cond do
        attrs[:merchant_id] ->
          attrs[:merchant_id]

        attrs["merchant_id"] ->
          attrs["merchant_id"]

        true ->
          name =
            attrs[:merchant_name] || attrs["merchant_name"] || attrs[:merchant] ||
              attrs["merchant"]

          url = attrs[:url] || attrs["url"]
          text = attrs[:clean_text] || attrs["clean_text"]
          feed_id = attrs[:feed_id] || attrs["feed_id"]
          feed_slug = get_feed_slug(feed_id)
          temp = attrs[:temperature] || attrs["temperature"]

          merchant =
            get_or_create_merchant(name,
              url: url,
              text: text,
              feed_slug: feed_slug,
              temperature: temp
            )

          merchant.id
      end

    raw_merchant =
      attrs[:merchant_name] || attrs["merchant_name"] || attrs[:merchant] || attrs["merchant"]

    deal_attrs =
      attrs
      |> Map.put(:merchant_id, merchant_id)
      |> Map.put_new(:raw_merchant, raw_merchant)

    %Deal{}
    |> Deal.changeset(deal_attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: :guid
    )
    |> case do
      {:ok, %Deal{id: nil}} ->
        {:duplicate, attrs[:guid] || attrs["guid"]}

      {:ok, %Deal{} = deal} ->
        deal = Repo.preload(deal, [:feed, :merchant])
        broadcast_deal({:ok, deal})

      error ->
        error
    end
  end

  @doc """
  Bulk inserts a list of parsed deal attribute maps.
  Returns list of newly created %Deal{} structs.
  """
  def insert_new_deals(deal_attrs_list) when is_list(deal_attrs_list) do
    Enum.reduce(deal_attrs_list, [], fn attrs, acc ->
      case insert_deal(attrs) do
        {:ok, deal} -> [deal | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
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

  defp get_feed_slug(nil), do: nil

  defp get_feed_slug(feed_id) do
    case Repo.get(DealScout.Feeds.Feed, feed_id) do
      %{slug: slug} -> slug
      _ -> nil
    end
  end
end
