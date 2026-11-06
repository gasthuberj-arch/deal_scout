defmodule DealScout.Analytics do
  @moduledoc """
  High-performance analytics queries for deal intelligence and operational monitoring.
  """

  import Ecto.Query, warn: false
  alias DealScout.Repo
  alias DealScout.Deals.Deal
  alias DealScout.Feeds.Feed
  alias DealScout.Accounts.{Scope, User}
  alias DealScout.Notifications.{PushDeliveryLog, PushSubscription}
  alias DealScout.Analytics.Server

  @table :deal_scout_analytics_cache
  @default_analytics_ttl_ms 15 * 60_000
  @push_metrics_ttl_ms 60_000

  defdelegate warm_now(), to: Server
  defdelegate refresh_now(), to: Server

  @doc """
  Computes aggregated deal intelligence metrics for the `/analytics` dashboard.
  Uses an in-memory ETS cache snapshot with background warming to ensure web requests
  remain instant and never trigger database stampedes under high concurrency.
  """
  def get_deal_intelligence_stats do
    case lookup_cached_stats() do
      {:ok, stats} ->
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
    try do
      now = System.monotonic_time(:millisecond)
      :ets.insert(@table, {:deal_intelligence_stats, stats, now + @default_analytics_ttl_ms})
      :ok
    rescue
      _ -> :ok
    end
  end

  @doc """
  Invalidates the analytics ETS cache.
  """
  def invalidate_analytics_cache do
    try do
      :ets.delete(@table, :deal_intelligence_stats)
      :ok
    rescue
      _ -> :ok
    end
  end

  defp lookup_cached_stats do
    case :ets.lookup(@table, :deal_intelligence_stats) do
      [{:deal_intelligence_stats, stats, _expires_at}] -> {:ok, stats}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Directly computes aggregated deal intelligence metrics without consulting cache.
  """
  def compute_deal_intelligence_stats do
    now = DateTime.utc_now()
    since_30d = DateTime.add(now, -30 * 24 * 3600, :second)
    since_24h = DateTime.add(now, -24 * 3600, :second)
    since_1h = DateTime.add(now, -3600, :second)

    agg =
      Repo.one(
        from d in Deal,
          select: %{
            stored_deals: count(d.id),
            deals_last_30d: filter(count(d.id), d.published_at >= ^since_30d),
            deals_last_24h: filter(count(d.id), d.published_at >= ^since_24h),
            deals_last_hour: filter(count(d.id), d.published_at >= ^since_1h),
            stored_duplicates: filter(count(d.id), not is_nil(d.canonical_deal_id)),
            duplicates_last_30d:
              filter(
                count(d.id),
                not is_nil(d.canonical_deal_id) and d.published_at >= ^since_30d
              ),
            avg_temp: filter(avg(d.temperature), not is_nil(d.temperature)),
            cross_border_count: filter(count(d.id), not is_nil(d.country)),
            foreign_kb_count: filter(count(d.id), not is_nil(d.keyboard_warning))
          }
      ) || %{}

    stored_deals = Map.get(agg, :stored_deals, 0)
    feed_deals_sum = Repo.aggregate(Feed, :sum, :total_deals_ingested) || 0
    total_deals = max(feed_deals_sum, stored_deals)

    deals_last_30d = Map.get(agg, :deals_last_30d, 0)
    stored_duplicates = Map.get(agg, :stored_duplicates, 0)
    duplicates_last_30d = Map.get(agg, :duplicates_last_30d, 0)
    feed_duplicates_sum = Repo.aggregate(Feed, :sum, :total_duplicates_ingested) || 0
    total_duplicates = max(feed_duplicates_sum, stored_duplicates)

    avg_temp =
      case Map.get(agg, :avg_temp) do
        nil -> 0.0
        %Decimal{} = dec -> Decimal.to_float(dec) |> Float.round(1)
        float when is_float(float) -> Float.round(float, 1)
        int when is_integer(int) -> int * 1.0
      end

    deals_last_24h = Map.get(agg, :deals_last_24h, 0)
    deals_last_hour = Map.get(agg, :deals_last_hour, 0)
    cross_border_count = Map.get(agg, :cross_border_count, 0)
    foreign_kb_count = Map.get(agg, :foreign_kb_count, 0)

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
        left_join: d in Deal,
        on: d.feed_id == f.id and d.published_at >= ^since_30d,
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
        where: is_nil(d.canonical_deal_id) and d.published_at >= ^since_30d,
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
    since_30d = DateTime.add(DateTime.utc_now(), -30 * 24 * 3600, :second)

    feeds_status =
      from(f in Feed,
        left_join: d in Deal,
        on: d.feed_id == f.id and d.published_at >= ^since_30d,
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

  # ============================================================================
  # Push Delivery Analytics & Device Performance (Cached in ETS)
  # ============================================================================

  @doc """
  Returns aggregated push delivery metrics for the specified rolling time window in hours (default 24).
  Uses ETS caching with a 60-second TTL to avoid database load.
  """
  def get_delivery_metrics(hours \\ 24) when is_integer(hours) and hours > 0 do
    cache_key = {:push_delivery_metrics, hours}

    case lookup_cached_metrics(cache_key) do
      {:ok, metrics} ->
        metrics

      _ ->
        metrics = compute_delivery_metrics(hours)
        put_cached_metrics(cache_key, metrics)
        metrics
    end
  end

  @doc """
  Invalidates the cached delivery metrics in ETS.
  """
  def invalidate_delivery_metrics_cache(hours \\ 24) when is_integer(hours) and hours > 0 do
    try do
      :ets.delete(@table, {:push_delivery_metrics, hours})
      :ok
    rescue
      _ -> :ok
    end
  end

  @doc """
  Invalidates cached device delivery metrics in ETS.
  """
  def invalidate_device_metrics_cache do
    try do
      :ets.match_delete(@table, {{:device_delivery_metrics, :_, :_}, :_, :_})
      :ets.match_delete(@table, {{:device_delivery_metrics, :_}, :_, :_})
      :ok
    rescue
      _ -> :ok
    end
  end

  def invalidate_device_metrics_cache(_hours), do: invalidate_device_metrics_cache()

  @doc """
  Parses a user-agent string into a concise, human-friendly Browser on OS label.
  e.g. "Safari on iOS", "Chrome on Android", "Firefox on macOS", "Edge on Windows".
  """
  def parse_user_agent(nil), do: "Web Browser"
  def parse_user_agent(""), do: "Web Browser"

  def parse_user_agent(ua) when is_binary(ua) do
    os =
      cond do
        String.contains?(ua, "iPhone") -> "iOS"
        String.contains?(ua, "iPad") -> "iPadOS"
        String.contains?(ua, "Android") -> "Android"
        String.contains?(ua, "Macintosh") or String.contains?(ua, "Mac OS X") -> "macOS"
        String.contains?(ua, "Windows") -> "Windows"
        String.contains?(ua, "Linux") -> "Linux"
        true -> nil
      end

    browser =
      cond do
        String.contains?(ua, "Edg/") or String.contains?(ua, "Edge/") -> "Edge"
        String.contains?(ua, "OPR/") or String.contains?(ua, "Opera/") -> "Opera"
        String.contains?(ua, "Chrome/") or String.contains?(ua, "CriOS/") -> "Chrome"
        String.contains?(ua, "Firefox/") or String.contains?(ua, "FxiOS/") -> "Firefox"
        String.contains?(ua, "Safari/") -> "Safari"
        true -> nil
      end

    case {browser, os} do
      {nil, nil} -> "Web Browser"
      {browser, nil} -> browser
      {nil, os} -> "Browser on #{os}"
      {browser, os} -> "#{browser} on #{os}"
    end
  end

  @doc """
  Returns per-device delivery metrics for the given scope (or nil / :all for global admin view).
  Metrics are cached in ETS with a 60-second TTL to avoid database load.
  """
  def get_device_delivery_metrics(scope_or_user_or_nil \\ nil, hours \\ 24)

  def get_device_delivery_metrics(target, hours)
      when (target in [nil, :all] or is_struct(target, Scope) or is_struct(target, User) or
              is_integer(target)) and
             is_integer(hours) and hours > 0 do
    user_id =
      case target do
        %Scope{user: %User{id: uid}} -> uid
        %User{id: uid} -> uid
        uid when is_integer(uid) -> uid
        _ -> nil
      end

    cache_key = {:device_delivery_metrics, user_id, hours}

    case lookup_cached_metrics(cache_key) do
      {:ok, metrics} ->
        metrics

      _ ->
        metrics = compute_device_delivery_metrics(user_id, hours)
        put_cached_metrics(cache_key, metrics)
        metrics
    end
  end

  @doc """
  Computes per-device delivery statistics for active subscriptions within the last `hours` hours.
  Executes a single-pass index-assisted SQL join on `push_subscriptions` and `push_delivery_logs`.
  Sorts devices with pending confirmations first (descending pending count), then by recent activity.
  """
  def compute_device_delivery_metrics(user_id_or_nil, hours \\ 24)
      when is_integer(hours) and hours > 0 do
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    base_query =
      from s in PushSubscription,
        left_join: u in assoc(s, :user),
        left_join: l in PushDeliveryLog,
        on: l.push_subscription_id == s.id and l.inserted_at >= ^since,
        group_by: [s.id, u.id],
        select: %{
          id: s.id,
          subscription_id: s.id,
          user_id: s.user_id,
          user: u,
          device_name: coalesce(s.device_name, "Web Browser"),
          user_agent: s.user_agent,
          endpoint: s.endpoint,
          sent_count: count(l.id) |> filter(l.status == "delivered"),
          confirmed_count: count(l.id) |> filter(not is_nil(l.client_received_at)),
          last_receipt_at: max(l.client_received_at),
          last_attempt_at: coalesce(max(l.inserted_at), s.last_used_at),
          inserted_at: s.inserted_at,
          last_used_at: s.last_used_at
        }

    query =
      case user_id_or_nil do
        nil -> base_query
        user_id when is_integer(user_id) -> where(base_query, [s], s.user_id == ^user_id)
      end

    Repo.all(query)
    |> Enum.map(fn row ->
      pending = max(0, row.sent_count - row.confirmed_count)

      %{
        id: row.id,
        subscription_id: row.subscription_id,
        user_id: row.user_id,
        user: row.user,
        device_name: row.device_name,
        browser_info: parse_user_agent(row.user_agent),
        endpoint: row.endpoint,
        sent_count: row.sent_count,
        confirmed_count: row.confirmed_count,
        pending_count: pending,
        last_receipt_at: row.last_receipt_at,
        last_attempt_at: row.last_attempt_at,
        inserted_at: row.inserted_at,
        last_used_at: row.last_used_at
      }
    end)
    |> Enum.sort_by(fn m ->
      attempt_ms =
        case m.last_attempt_at do
          %DateTime{} = dt -> DateTime.to_unix(dt, :millisecond)
          _ -> 0
        end

      {-m.pending_count, -attempt_ms}
    end)
  end

  @doc """
  Computes aggregated push delivery statistics across all users over the last `hours` hours.
  Executes a single-pass index-scanned aggregate on `push_delivery_logs` without grouping.
  """
  def compute_delivery_metrics(hours \\ 24) when is_integer(hours) and hours > 0 do
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    query =
      from(l in PushDeliveryLog,
        where: l.inserted_at >= ^since,
        select: %{
          total: count(l.id),
          delivered_to_gateway: count(l.id) |> filter(l.status == "delivered"),
          device_confirmed: count(l.id) |> filter(not is_nil(l.client_received_at)),
          expired: count(l.id) |> filter(l.status == "expired"),
          no_subscriptions: count(l.id) |> filter(l.status == "no_subscriptions"),
          http_error: count(l.id) |> filter(l.status == "http_error"),
          network_error: count(l.id) |> filter(l.status == "network_error"),
          skipped_cooldown: count(l.id) |> filter(l.status == "skipped_cooldown"),
          avg_client_delay_ms: avg(l.client_delay_ms) |> filter(not is_nil(l.client_delay_ms)),
          avg_gateway_ms: avg(l.gateway_duration_ms) |> filter(not is_nil(l.gateway_duration_ms))
        }
      )

    res = Repo.one(query) || %{}

    total = Map.get(res, :total) || 0
    delivered = Map.get(res, :delivered_to_gateway) || 0
    confirmed = Map.get(res, :device_confirmed) || 0
    pending = max(0, delivered - confirmed)

    rate =
      if delivered > 0 do
        Float.round(confirmed / delivered * 100, 1)
      else
        0.0
      end

    avg_client =
      case Map.get(res, :avg_client_delay_ms) do
        nil -> nil
        %Decimal{} = d -> Decimal.to_float(d) |> round()
        val when is_float(val) -> round(val)
        val when is_integer(val) -> val
      end

    avg_gateway =
      case Map.get(res, :avg_gateway_ms) do
        nil -> nil
        %Decimal{} = d -> Decimal.to_float(d) |> round()
        val when is_float(val) -> round(val)
        val when is_integer(val) -> val
      end

    %{
      total: total,
      delivered_to_gateway: delivered,
      device_confirmed: confirmed,
      pending_confirmation: pending,
      confirmation_rate_pct: rate,
      expired: Map.get(res, :expired) || 0,
      no_subscriptions: Map.get(res, :no_subscriptions) || 0,
      http_error: Map.get(res, :http_error) || 0,
      network_error: Map.get(res, :network_error) || 0,
      skipped_cooldown: Map.get(res, :skipped_cooldown) || 0,
      avg_client_delay_ms: avg_client,
      avg_gateway_ms: avg_gateway,
      hours: hours
    }
  end

  defp lookup_cached_metrics(cache_key) do
    try do
      now = System.monotonic_time(:millisecond)

      case :ets.lookup(@table, cache_key) do
        [{^cache_key, metrics, expires_at}] when expires_at > now ->
          {:ok, metrics}

        _ ->
          :error
      end
    rescue
      _ -> :error
    end
  end

  defp put_cached_metrics(cache_key, metrics) do
    try do
      now = System.monotonic_time(:millisecond)
      :ets.insert(@table, {cache_key, metrics, now + @push_metrics_ttl_ms})
      :ok
    rescue
      _ -> :ok
    end
  end
end
