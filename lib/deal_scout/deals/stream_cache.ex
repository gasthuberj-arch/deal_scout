defmodule DealScout.Deals.StreamCache do
  @moduledoc """
  The **Deal stream cache** module for DealScout.

  Provides high-concurrency in-memory caching for **Deal stream filter** results.
  Shields the SQLite database from read stampedes when concurrent clients poll
  or stream identical deal feed filters.

  Encapsulates:
  - In-memory ETS table management with `read_concurrency: true`.
  - Filter option eligibility checks (only un-offset, non-search queries are cached).
  - Cache key serialization across feed, merchant, and grouping filters.
  - Read-through caching with TTL expiry (`@default_ttl_ms 300_000`).
  - In-place refresh (`refresh/3`) and selective pattern-based invalidation (`:feed_id` match-delete or global clear).
  """

  use GenServer

  @table :deal_scout_stream_cache
  @default_ttl_ms 300_000

  # ============================================================================
  # Public Interface
  # ============================================================================

  @doc """
  Starts the StreamCache GenServer which supervises the ETS table.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Executes a read-through cache lookup for deal stream queries.
  If the given `opts` are not cacheable (e.g. search query or pagination offset),
  immediately executes `compute_fn.()`. Otherwise, checks the ETS cache, returning
  cached deals if fresh, or populates the cache with the result of `compute_fn.()`.
  """
  @spec fetch(keyword(), (-> list()), pos_integer()) :: list()
  def fetch(opts, compute_fn, ttl_ms \\ @default_ttl_ms)
      when is_list(opts) and is_function(compute_fn, 0) do
    if cacheable?(opts) do
      lookup_or_compute(opts, compute_fn, ttl_ms)
    else
      compute_fn.()
    end
  end

  @doc """
  Refreshes and overwrites existing cached deal streams in-place without deleting
  them first, so concurrent readers never experience a cold cache miss.
  - If `feed_id: id` is given, refreshes cached entries for that feed, its slug, and `"all"`.
  - If no filter is given, refreshes all currently cached stream entries.
  """
  @spec refresh(keyword(), (keyword() -> list()), pos_integer()) :: :ok
  def refresh(opts \\ [], compute_for_opts_fn, ttl_ms \\ @default_ttl_ms)
      when is_list(opts) and is_function(compute_for_opts_fn, 1) do
    feed_id = Keyword.get(opts, :feed_id)
    feed_slug = Keyword.get(opts, :feed_slug)

    try do
      keys = matching_keys(feed_id, feed_slug)
      now = System.monotonic_time(:millisecond)

      Enum.each(keys, fn key ->
        key_opts = key_to_opts(key)
        fresh_data = compute_for_opts_fn.(key_opts)
        insert(key, fresh_data, now + ttl_ms)
      end)

      :ok
    rescue
      _ ->
        invalidate(opts)
    end
  end

  @doc """
  Invalidates cached deal streams.
  - If `feed_id: id` is given, selectively deletes cache entries matching that feed
    and the global 'all' feed.
  - If no filter is given, clears all stream cache entries.
  """
  @spec invalidate(keyword()) :: :ok
  def invalidate(opts \\ []) do
    feed_id = Keyword.get(opts, :feed_id)
    feed_slug = Keyword.get(opts, :feed_slug)

    try do
      if feed_id || feed_slug do
        for target <- ["all", feed_id, if(feed_id, do: to_string(feed_id)), feed_slug],
            not is_nil(target) do
          :ets.match_delete(@table, {{:deals, target, :_, :_, :_, :_, :_}, :_, :_})
        end
      else
        :ets.match_delete(@table, {{:deals, :_, :_, :_, :_, :_, :_}, :_, :_})
      end

      :ok
    rescue
      _ -> :ok
    end
  end

  @doc """
  Clears all cached streams from ETS.
  """
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Returns the number of cached stream entries currently in ETS.
  """
  def size do
    :ets.info(@table, :size)
  rescue
    _ -> 0
  end

  defp cacheable?(opts) when is_list(opts) do
    search = Keyword.get(opts, :search)
    min_temp = Keyword.get(opts, :min_temperature)
    offset = Keyword.get(opts, :offset, 0)

    (is_nil(search) or search == "") and is_nil(min_temp) and offset == 0
  end

  defp cache_key(opts) when is_list(opts) do
    feed_key = Keyword.get(opts, :feed) || Keyword.get(opts, :feed_id) || "all"
    merchant_key = Keyword.get(opts, :merchant) || "all"

    {
      :deals,
      feed_key,
      merchant_key,
      Keyword.get(opts, :exclude_dropshippers, false),
      Keyword.get(opts, :group_deals, true),
      Keyword.get(opts, :limit, 60),
      Keyword.get(opts, :offset, 0)
    }
  end

  defp key_to_opts(
         {:deals, feed_key, merchant_key, exclude_dropshippers, group_deals, limit, offset}
       ) do
    [
      feed: feed_key,
      merchant: merchant_key,
      exclude_dropshippers: exclude_dropshippers,
      group_deals: group_deals,
      limit: limit,
      offset: offset
    ]
  end

  defp matching_keys(nil, nil), do: all_cached_keys()

  defp matching_keys(feed_id, feed_slug) do
    target_feeds =
      ["all", feed_id, if(feed_id, do: to_string(feed_id)), feed_slug]
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    all_cached_keys()
    |> Enum.filter(fn {:deals, f, _m, _ed, _gd, _l, _o} -> MapSet.member?(target_feeds, f) end)
  end

  defp all_cached_keys do
    :ets.match(@table, {{:deals, :"$1", :"$2", :"$3", :"$4", :"$5", :"$6"}, :_, :_})
    |> Enum.map(fn [f, m, ed, gd, l, o] -> {:deals, f, m, ed, gd, l, o} end)
  end

  # ============================================================================
  # Internal Cache Mechanics
  # ============================================================================

  defp lookup_or_compute(opts, compute_fn, ttl_ms) do
    key = cache_key(opts)
    now = System.monotonic_time(:millisecond)

    case lookup(key) do
      {:ok, data, expires_at} when expires_at > now ->
        data

      _ ->
        data = compute_fn.()
        insert(key, data, now + ttl_ms)
        data
    end
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, data, expires_at}] -> {:ok, data, expires_at}
      _ -> :miss
    end
  rescue
    _ -> :miss
  end

  defp insert(key, data, expires_at) do
    :ets.insert(@table, {key, data, expires_at})
    :ok
  rescue
    _ -> :ok
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    table =
      case :ets.info(@table) do
        :undefined ->
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

        _ ->
          @table
      end

    {:ok, %{table: table}}
  end
end
