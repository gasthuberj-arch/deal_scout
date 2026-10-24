defmodule DealScout.Deals.Cache do
  @moduledoc """
  High-performance, in-memory ETS cache for read-heavy public streams.
  Caches the primary deals stream and active feeds list to prevent
  database connection pool contention during traffic bursts.
  """
  use GenServer

  @table :deal_scout_stream_cache
  @default_deals_ttl_ms 5_000
  @default_feeds_ttl_ms 60_000
  @default_analytics_ttl_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @doc """
  Fetches active feeds from cache or executes fallback query.
  """
  def fetch_active_feeds(fallback_fn) when is_function(fallback_fn, 0) do
    now = System.monotonic_time(:millisecond)

    case lookup(:active_feeds) do
      {:ok, feeds, expires_at} when expires_at > now ->
        feeds

      _ ->
        feeds = fallback_fn.()
        insert(:active_feeds, feeds, now + @default_feeds_ttl_ms)
        feeds
    end
  end

  @doc """
  Fetches deal intelligence analytics stats from cache or executes fallback query.
  """
  def fetch_deal_intelligence_stats(fallback_fn) when is_function(fallback_fn, 0) do
    now = System.monotonic_time(:millisecond)

    case lookup(:deal_intelligence_stats) do
      {:ok, stats, expires_at} when expires_at > now ->
        stats

      _ ->
        stats = fallback_fn.()
        insert(:deal_intelligence_stats, stats, now + @default_analytics_ttl_ms)
        stats
    end
  end

  @doc """
  Fetches deals list from cache for standard default options, or executes fallback query.
  Only caches standard requests (e.g. no search query, first page) where caching yields 100x leverage.
  """
  def fetch_deals(opts, fallback_fn) when is_function(fallback_fn, 0) do
    if cacheable_opts?(opts) do
      cache_key = {
        :deals,
        Keyword.get(opts, :feed_id, "all"),
        Keyword.get(opts, :merchant, "all"),
        Keyword.get(opts, :exclude_dropshippers, false),
        Keyword.get(opts, :group_deals, true),
        Keyword.get(opts, :limit, 60),
        Keyword.get(opts, :offset, 0)
      }

      now = System.monotonic_time(:millisecond)

      case lookup(cache_key) do
        {:ok, deals, expires_at} when expires_at > now ->
          deals

        _ ->
          deals = fallback_fn.()
          insert(cache_key, deals, now + @default_deals_ttl_ms)
          deals
      end
    else
      fallback_fn.()
    end
  end

  @doc """
  Invalidates deals entries on new deal arrival.
  """
  def invalidate_deals do
    try do
      :ets.match_delete(@table, {{:deals, :_, :_, :_, :_, :_, :_}, :_, :_})
      :ok
    rescue
      _ -> :ok
    end
  end

  @doc """
  Invalidates feeds cache on feed modification.
  """
  def invalidate_feeds do
    try do
      :ets.delete(@table, :active_feeds)
      :ok
    rescue
      _ -> :ok
    end
  end

  @doc """
  Invalidates analytics stats cache.
  """
  def invalidate_analytics do
    try do
      :ets.delete(@table, :deal_intelligence_stats)
      :ok
    rescue
      _ -> :ok
    end
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, data, expires_at}] -> {:ok, data, expires_at}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp insert(key, data, expires_at) do
    :ets.insert(@table, {key, data, expires_at})
    :ok
  rescue
    _ -> :ok
  end

  defp cacheable_opts?(opts) do
    search = Keyword.get(opts, :search)
    min_temp = Keyword.get(opts, :min_temperature)
    offset = Keyword.get(opts, :offset, 0)

    (is_nil(search) or search == "") and is_nil(min_temp) and offset == 0
  end
end
