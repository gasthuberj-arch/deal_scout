defmodule DealScout.Deals.Ingestion do
  @moduledoc """
  Atomic **Deal ingestion** pipeline for DealScout.

  Encapsulates the end-to-end deal ingestion lifecycle:
  - Parses raw feed XML or candidate deal maps into normalized atom-keyed structures.
  - Filters out existing deal GUIDs in bulk.
  - Resolves merchants and enforces the invariant that merchant stats (`deal_count`,
    `avg_temperature`, `feed_counts`) are updated ONLY on genuinely new deal inserts,
    never on duplicate polls.
  - Deduplicates incoming deals against existing ones using `DealScout.Deals.Deduplicator`.
  - Performs cross-border EU and keyboard layout detection at ingestion time.
  - Dispatches newly inserted deals to `DealScout.Alerts` and broadcasts via PubSub.
  """

  import Ecto.Query, warn: false
  require Logger
  alias DealScout.Repo
  alias DealScout.Deals
  alias DealScout.Deals.{CrossBorder, Deal, Deduplicator, Merchant, MerchantGuard}
  alias DealScout.Feeds.Parser
  alias DealScout.Feeds.Feed
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

  @doc """
  Ingests a single deal attribute map using the unified ingestion pipeline.
  Ensures merchant exists, deduplicates against canonical deals,
  enriches cross-border metadata, records merchant deal stats,
  triggers alert rule matcher, and broadcasts to PubSub.

  Returns `{:ok, deal}`, `{:duplicate, guid}`, or `{:error, changeset}`.
  """
  def ingest_deal(attrs) when is_map(attrs) do
    normalized = normalize_candidate_attrs(attrs)
    guid = normalized.guid

    if guid && Repo.exists?(from d in Deal, where: d.guid == ^guid) do
      {:duplicate, guid}
    else
      feed_id = normalized.feed_id
      feed_slug = normalized.feed_slug || get_feed_slug(feed_id)

      case insert_single_deal(normalized, feed_id, feed_slug) do
        {:ok, deal} ->
          Alerts.process_new_deals([deal])
          {:ok, deal}

        other ->
          other
      end
    end
  end

  @doc """
  Evaluates candidate deal items in memory against alert rules, persisting only
  those that match at least one rule (filter-first / match-only ingestion).
  Bypasses secondary rule evaluation by recording matches directly.

  Accepts either `(items, %Feed{} = feed, opts)` or `(items, opts)`.
  Options:
  - `:rules` - List of `AlertRule` structs to match against (defaults to all active rules).
  - `:feed` - Feed struct to associate deals with (defaults to `DealScout.Feeds.ensure_ebay_feed()`).
  - `:feed_slug` - Optional custom slug for merchant statistics (defaults to `feed.slug`).

  Returns `{:ok, %{matched_deals: [Deal.t()], discarded_count: integer()}}`.
  """
  def ingest_ephemeral(items, feed_or_opts \\ [])

  def ingest_ephemeral(items, %Feed{} = feed) when is_list(items) do
    ingest_ephemeral(items, feed, [])
  end

  def ingest_ephemeral(items, opts) when is_list(items) and is_list(opts) do
    feed = Keyword.get_lazy(opts, :feed, &DealScout.Feeds.ensure_ebay_feed/0)
    ingest_ephemeral(items, feed, opts)
  end

  def ingest_ephemeral(items, %Feed{} = feed, opts) when is_list(items) and is_list(opts) do
    rules =
      case Keyword.get(opts, :rules) do
        nil -> Alerts.list_active_rules()
        explicit_rules -> explicit_rules
      end

    if items == [] or rules == [] do
      {:ok, %{matched_deals: [], discarded_count: length(items)}}
    else
      normalized_items =
        items
        |> Enum.map(&normalize_candidate_attrs/1)
        |> Enum.uniq_by(& &1.guid)

      guids =
        normalized_items
        |> Enum.map(& &1.guid)
        |> Enum.reject(&is_nil/1)

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

      unseen_items =
        Enum.reject(normalized_items, fn item ->
          is_nil(item.guid) or MapSet.member?(existing_guids, item.guid)
        end)

      deal_candidates =
        Enum.map(unseen_items, fn item ->
          build_in_memory_deal(item, feed)
        end)

      {:ok, %{matches_by_rule: matches_by_rule}} =
        DealScout.Alerts.Matcher.match_batch(deal_candidates, rules, opts)

      matched_guids =
        matches_by_rule
        |> Map.values()
        |> List.flatten()
        |> Enum.map(& &1.guid)
        |> MapSet.new()

      matched_items =
        Enum.filter(unseen_items, fn item ->
          MapSet.member?(matched_guids, item.guid)
        end)

      feed_id = feed.id
      feed_slug = Keyword.get(opts, :feed_slug, feed.slug || "custom")

      persisted_deals =
        Enum.reduce(matched_items, [], fn item, acc ->
          case insert_single_deal(item, feed_id, feed_slug) do
            {:ok, deal} ->
              [deal | acc]

            _ ->
              acc
          end
        end)
        |> Enum.reverse()

      guid_to_persisted = Map.new(persisted_deals, fn d -> {d.guid, d} end)

      persisted_matches_by_rule =
        Enum.reduce(matches_by_rule, %{}, fn {rule, candidates}, acc ->
          deals =
            candidates
            |> Enum.map(&Map.get(guid_to_persisted, &1.guid))
            |> Enum.reject(&is_nil/1)

          if deals != [] do
            Map.put(acc, rule, deals)
          else
            acc
          end
        end)

      if map_size(persisted_matches_by_rule) > 0 do
        Alerts.record_and_dispatch(persisted_matches_by_rule)
      end

      discarded_count = length(items) - length(persisted_deals)
      {:ok, %{matched_deals: persisted_deals, discarded_count: discarded_count}}
    end
  end

  defp build_in_memory_deal(item, %Feed{} = feed) do
    country =
      Map.get(item, :country) ||
        CrossBorder.detect_country(item) ||
        %{
          code: "DE",
          country_code: "DE",
          flag: "🇩🇪",
          name: "Deutschland",
          is_germany: true,
          is_eu: true
        }

    keyboard_warning = Map.get(item, :keyboard_warning) || CrossBorder.keyboard_warning(item)
    default_merchant = feed.name || "Custom"
    merchant_name = Map.get(item, :merchant_name) || default_merchant

    %Deal{
      guid: Map.get(item, :guid),
      title: Map.get(item, :title),
      url: Map.get(item, :url),
      price: Map.get(item, :price),
      description: Map.get(item, :description),
      clean_text: Map.get(item, :clean_text),
      temperature: Map.get(item, :temperature) || 100,
      raw_merchant: Map.get(item, :raw_merchant) || merchant_name,
      image_url: Map.get(item, :image_url),
      published_at:
        Map.get(item, :published_at) || DateTime.utc_now() |> DateTime.truncate(:second),
      country: country,
      keyboard_warning: keyboard_warning,
      feed_id: feed.id,
      feed: feed,
      merchant: %Merchant{name: merchant_name}
    }
  end

  @doc """
  Backfills an existing `%Deal{}` that lacks a `merchant_id` by resolving its merchant,
  recording the deal in merchant statistics, and updating the deal record.
  """
  def backfill_deal_merchant(%Deal{} = deal, opts \\ []) do
    feed_slug = Keyword.get(opts, :feed_slug) || get_feed_slug(deal.feed_id)
    temperature = Keyword.get(opts, :temperature, deal.temperature)

    merchant =
      ensure_merchant(deal.raw_merchant,
        url: deal.url,
        text: deal.clean_text
      )

    record_merchant_deal(merchant.id, feed_slug, temperature)
    merchant
  end

  defp process_items([], _feed_id, _feed_slug), do: []

  defp process_items(items, feed_id, feed_slug) do
    normalized_items =
      items
      |> Enum.map(&normalize_candidate_attrs/1)
      |> Enum.uniq_by(& &1.guid)

    guids =
      normalized_items
      |> Enum.map(& &1.guid)
      |> Enum.reject(&is_nil/1)

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
      Enum.reject(normalized_items, fn item ->
        is_nil(item.guid) or MapSet.member?(existing_guids, item.guid)
      end)

    if new_items == [] do
      []
    else
      inserted_deals =
        Enum.reduce(new_items, [], fn item, acc ->
          case insert_single_deal(item, feed_id, feed_slug) do
            {:ok, deal} -> [deal | acc]
            _ -> acc
          end
        end)
        |> Enum.reverse()

      if inserted_deals != [] do
        Alerts.process_new_deals(inserted_deals)
      end

      inserted_deals
    end
  end

  defp insert_single_deal(item, feed_id, feed_slug) do
    merchant =
      if item.merchant_id do
        Repo.get(Merchant, item.merchant_id)
      else
        ensure_merchant(item.merchant_name,
          url: item.url,
          text: item.clean_text
        )
      end

    merchant_id = if merchant, do: merchant.id, else: nil

    canonical_id =
      if item.canonical_deal_id do
        item.canonical_deal_id
      else
        candidate_attrs = %{
          merchant_id: merchant_id,
          feed_id: feed_id,
          title: item.title,
          price: item.price,
          url: item.url,
          published_at: item.published_at
        }

        case Deduplicator.find_canonical_deal(candidate_attrs) do
          %{id: cid} -> cid
          _ -> nil
        end
      end

    country = CrossBorder.detect_country(item)
    keyboard_warning = CrossBorder.keyboard_warning(item)

    deal_attrs = %{
      feed_id: feed_id,
      merchant_id: merchant_id,
      canonical_deal_id: canonical_id,
      guid: item.guid,
      title: item.title,
      url: item.url,
      description: nil,
      clean_text: item.clean_text,
      price: item.price,
      raw_merchant: item.raw_merchant || item.merchant_name,
      image_url: item.image_url,
      idealo_url: item.idealo_url,
      geizhals_url: item.geizhals_url,
      temperature: item.temperature,
      published_at: item.published_at
    }

    %Deal{country: country, keyboard_warning: keyboard_warning}
    |> Deal.changeset(deal_attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: :guid
    )
    |> case do
      {:ok, %Deal{id: nil}} ->
        {:duplicate, item.guid}

      {:ok, %Deal{} = deal} ->
        if is_nil(deal.price) do
          Logger.warning(
            "[DealScout.Ingestion] Deal ingested without price (requires investigation): " <>
              "id=#{deal.id} feed=#{feed_slug || feed_id} title=#{inspect(deal.title)} url=#{deal.url}"
          )
        end

        record_feed_deal(feed_id, not is_nil(deal.canonical_deal_id))

        if merchant do
          record_merchant_deal(merchant.id, feed_slug, item.temperature)
        end

        deal = Repo.preload(deal, [:feed, :merchant, duplicates: [:feed]])
        Deals.broadcast_deal({:ok, deal})

        {:ok, deal}

      error ->
        error
    end
  end

  defp normalize_candidate_attrs(attrs) when is_map(attrs) do
    get = fn key -> Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) end
    merchant_name = get.(:merchant) || get.(:merchant_name)
    description = get.(:description)

    clean_text =
      case get.(:clean_text) do
        text when is_binary(text) and text != "" -> text
        _ when is_binary(description) and description != "" -> Parser.clean_html(description)
        other -> other
      end

    %{
      feed_id: get.(:feed_id),
      feed_slug: get.(:feed_slug),
      merchant_id: get.(:merchant_id),
      merchant_name: merchant_name,
      raw_merchant: get.(:raw_merchant) || merchant_name,
      canonical_deal_id: get.(:canonical_deal_id),
      guid: get.(:guid),
      title: get.(:title),
      url: get.(:url),
      description: description,
      clean_text: clean_text,
      price: get.(:price),
      image_url: get.(:image_url),
      idealo_url: get.(:idealo_url),
      geizhals_url: get.(:geizhals_url),
      temperature: get.(:temperature),
      published_at: get.(:published_at)
    }
  end

  defp ensure_merchant(merchant_name, opts) do
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

  defp record_merchant_deal(merchant_id, feed_slug, temperature) do
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

        merchant
        |> Merchant.changeset(%{
          deal_count: new_deal_count,
          feed_counts: updated_feed_counts,
          avg_temperature: updated_avg_temp,
          trust_level: merchant.trust_level,
          last_seen_at: now
        })
        |> Repo.update()
        |> case do
          {:ok, updated} -> updated
          {:error, _} -> merchant
        end
    end
  end

  defp record_feed_deal(nil, _is_duplicate), do: :ok

  defp record_feed_deal(feed_id, is_duplicate) do
    dup_inc = if is_duplicate, do: 1, else: 0

    from(f in DealScout.Feeds.Feed, where: f.id == ^feed_id)
    |> Repo.update_all(inc: [total_deals_ingested: 1, total_duplicates_ingested: dup_inc])

    :ok
  end

  defp get_feed_slug(nil), do: nil

  defp get_feed_slug(feed_id) do
    case Repo.get(DealScout.Feeds.Feed, feed_id) do
      %{slug: slug} -> slug
      _ -> nil
    end
  end
end
