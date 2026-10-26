defmodule DealScout.Analytics do
  @moduledoc """
  High-performance analytics queries for deal intelligence and operational monitoring.
  """

  import Ecto.Query, warn: false
  alias DealScout.Repo
  alias DealScout.Deals.Deal
  alias DealScout.Feeds.Feed
  alias DealScout.Accounts.User

  @table :deal_scout_analytics_cache
  @default_analytics_ttl_ms 60_000

  @doc """
  Computes aggregated deal intelligence metrics for the `/analytics` dashboard.
  Uses an in-memory ETS cache with a 60-second TTL to avoid heavy recalculations.
  """
  def get_deal_intelligence_stats do
    now = System.monotonic_time(:millisecond)

    case lookup_cached_stats() do
      {:ok, stats, expires_at} when expires_at > now ->
        stats

      _ ->
        stats = compute_deal_intelligence_stats()
        put_cached_stats(stats)
        stats
    end
  end

  @doc """
  Stores computed deal intelligence stats in the analytics ETS cache.
  """
  def put_cached_stats(stats) do
    if :ets.whereis(@table) != :undefined do
      now = System.monotonic_time(:millisecond)
      :ets.insert(@table, {:deal_intelligence_stats, stats, now + @default_analytics_ttl_ms})
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Invalidates the analytics ETS cache.
  """
  def invalidate_analytics_cache do
    if :ets.whereis(@table) != :undefined do
      :ets.delete(@table, :deal_intelligence_stats)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp lookup_cached_stats do
    if :ets.whereis(@table) != :undefined do
      case :ets.lookup(@table, :deal_intelligence_stats) do
        [{:deal_intelligence_stats, stats, expires_at}] -> {:ok, stats, expires_at}
        _ -> :error
      end
    else
      :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Directly computes aggregated deal intelligence metrics without consulting cache.
  """
  def compute_deal_intelligence_stats do
    deals_last_30d = Repo.aggregate(Deal, :count, :id) || 0
    feed_deals_sum = Repo.aggregate(Feed, :sum, :total_deals_ingested) || 0
    total_deals = max(feed_deals_sum, deals_last_30d)

    duplicates_last_30d =
      Repo.one(from d in Deal, where: not is_nil(d.canonical_deal_id), select: count(d.id)) || 0

    feed_duplicates_sum = Repo.aggregate(Feed, :sum, :total_duplicates_ingested) || 0
    total_duplicates = max(feed_duplicates_sum, duplicates_last_30d)

    avg_temp =
      case Repo.one(from d in Deal, where: not is_nil(d.temperature), select: avg(d.temperature)) do
        nil -> 0.0
        %Decimal{} = dec -> Decimal.to_float(dec) |> Float.round(1)
        float when is_float(float) -> Float.round(float, 1)
        int when is_integer(int) -> int * 1.0
      end

    now = DateTime.utc_now()
    since_24h = DateTime.add(now, -24 * 3600, :second)
    since_1h = DateTime.add(now, -3600, :second)

    deals_last_24h =
      Repo.one(
        from d in Deal,
          where: d.published_at >= ^since_24h or d.inserted_at >= ^since_24h,
          select: count(d.id)
      ) || 0

    deals_last_hour =
      Repo.one(
        from d in Deal,
          where: d.published_at >= ^since_1h or d.inserted_at >= ^since_1h,
          select: count(d.id)
      ) || 0

    deals_per_hour =
      if deals_last_24h > 0 do
        Float.round(deals_last_24h / 24.0, 1)
      else
        0.0
      end

    deals_per_min =
      if deals_last_24h > 0 do
        Float.round(deals_last_24h / (24.0 * 60.0), 2)
      else
        0.0
      end

    deals_by_feed =
      from(f in Feed,
        left_join: d in assoc(f, :deals),
        group_by: [f.id, f.name, f.total_deals_ingested],
        having: count(d.id) > 0 or f.total_deals_ingested > 0,
        select: %{
          feed_name: f.name,
          total_deals_ingested: f.total_deals_ingested,
          deals_last_30d: count(d.id)
        }
      )
      |> Repo.all()
      |> Enum.map(&normalize_feed_deal_counts/1)
      |> Enum.sort_by(& &1.deal_count, :desc)

    recent_duplicate_clusters =
      from(d in Deal,
        where: is_nil(d.canonical_deal_id),
        join: dup in assoc(d, :duplicates),
        group_by: [d.id, d.title, d.price],
        select: %{
          id: d.id,
          title: d.title,
          price: d.price,
          duplicate_count: count(dup.id)
        },
        order_by: [desc: count(dup.id), desc: d.id],
        limit: 5
      )
      |> Repo.all()

    cross_border_count =
      Repo.one(from d in Deal, where: not is_nil(d.country), select: count(d.id)) || 0

    foreign_kb_count =
      Repo.one(from d in Deal, where: not is_nil(d.keyboard_warning), select: count(d.id)) || 0

    %{
      total_deals: total_deals,
      deals_last_30d: deals_last_30d,
      total_duplicates: total_duplicates,
      duplicates_last_30d: duplicates_last_30d,
      canonical_deals: total_deals - total_duplicates,
      avg_temperature: avg_temp,
      deals_last_24h: deals_last_24h,
      deals_last_hour: deals_last_hour,
      deals_per_hour: deals_per_hour,
      deals_per_min: deals_per_min,
      deals_by_feed: deals_by_feed,
      recent_duplicate_clusters: recent_duplicate_clusters,
      cross_border_count: cross_border_count,
      foreign_kb_count: foreign_kb_count
    }
  end

  @doc """
  Computes operational & real-time system metrics for `/admin/system`.
  """
  def get_system_ops_stats do
    active_sessions_count =
      try do
        DealScoutWeb.Presence.list("deals:presence") |> map_size()
      rescue
        _ -> 0
      end

    total_users_count = Repo.aggregate(User, :count, :id) || 0

    feeds_status =
      from(f in Feed,
        left_join: d in assoc(f, :deals),
        group_by: [
          f.id,
          f.name,
          f.slug,
          f.url,
          f.last_fetched_at,
          f.is_active,
          f.poll_interval_seconds,
          f.backoff_until,
          f.last_error_status,
          f.total_deals_ingested
        ],
        select: %{
          id: f.id,
          name: f.name,
          slug: f.slug,
          url: f.url,
          last_fetched_at: f.last_fetched_at,
          is_active: f.is_active,
          poll_interval_seconds: f.poll_interval_seconds,
          backoff_until: f.backoff_until,
          last_error_status: f.last_error_status,
          total_deals_ingested: f.total_deals_ingested,
          deals_last_30d: count(d.id)
        },
        order_by: [asc: f.name]
      )
      |> Repo.all()
      |> Enum.map(&normalize_feed_deal_counts/1)

    beam_memory_mb =
      Float.round(:erlang.memory(:total) / (1024 * 1024), 1)

    uptime_seconds =
      elem(:erlang.statistics(:wall_clock), 0) |> div(1000)

    %{
      active_sessions_count: active_sessions_count,
      total_users_count: total_users_count,
      feeds_status: feeds_status,
      beam_memory_mb: beam_memory_mb,
      uptime_seconds: uptime_seconds
    }
  end

  defp normalize_feed_deal_counts(row) do
    deals_last_30d = row.deals_last_30d || 0
    deal_count = max(row.total_deals_ingested || 0, deals_last_30d)

    row
    |> Map.put(:deal_count, deal_count)
    |> Map.put(:deals_last_30d, deals_last_30d)
  end
end
