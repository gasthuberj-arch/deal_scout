defmodule DealScout.Analytics.Server do
  @moduledoc """
  State lifecycle, persistence, and background warmer for `DealScout.Analytics`.
  Owns the `:deal_scout_analytics_cache` ETS table, coordinates periodic
  re-computation of aggregate metrics, persists atomic snapshots to disk, and
  serves stale-while-revalidate snapshots so web requests never encounter cold-start
  delays or database queries.
  """

  use GenServer
  require Logger

  alias DealScout.Analytics

  @table :deal_scout_analytics_cache
  @default_interval_ms 60_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Triggers a synchronous refresh of the cached analytics metrics."
  def refresh_now(server \\ __MODULE__, timeout \\ 30_000) do
    if GenServer.whereis(server) do
      GenServer.call(server, :refresh_now, timeout)
    else
      stats = Analytics.compute_deal_intelligence_stats()
      Analytics.put_cached_stats(stats)
      stats
    end
  end

  @doc "Triggers an asynchronous background refresh of the cached analytics metrics."
  def warm_now(server \\ __MODULE__) do
    if GenServer.whereis(server) do
      GenServer.cast(server, :refresh)
    else
      :ok
    end
  end

  @doc """
  Computes the default file path for the persisted analytics snapshot.
  Stores the binary snapshot on the persistent volume directory alongside the SQLite database.
  """
  def default_snapshot_path do
    case Application.get_env(:deal_scout, :analytics_snapshot_path) do
      false ->
        nil

      path when is_binary(path) and path != "" ->
        path

      _ ->
        db_path =
          try do
            DealScout.Repo.config()[:database] || "deal_scout.db"
          rescue
            _ -> "deal_scout.db"
          end

        dir = Path.dirname(Path.expand(db_path))
        Path.join(dir, "analytics_snapshot.bin")
    end
  end

  @doc "Loads the persisted analytics snapshot from disk, if present and valid."
  def load_snapshot(path) when is_binary(path) do
    with true <- File.exists?(path),
         {:ok, binary} <- File.read(path),
         {:ok, %{} = stats} <- safe_binary_to_term(binary) do
      {:ok, stats}
    else
      _ -> :error
    end
  end

  def load_snapshot(_), do: :error

  @doc """
  Atomically persists the analytics snapshot to disk using a write-and-rename pattern.
  Protects against file corruption if the VM or container is terminated mid-write.
  """
  def persist_snapshot(path, stats) when is_binary(path) and is_map(stats) do
    tmp_path = path <> ".tmp.#{System.unique_integer([:positive])}"
    dir = Path.dirname(path)
    File.mkdir_p(dir)

    with {:ok, binary} <- safe_term_to_binary(stats),
         :ok <- File.write(tmp_path, binary),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      error ->
        _ = File.rm(tmp_path)

        Logger.warning(
          "[Analytics.Server] Failed to persist analytics snapshot to #{path}: #{inspect(error)}"
        )

        :error
    end
  rescue
    e ->
      Logger.warning(
        "[Analytics.Server] Exception persisting analytics snapshot: #{Exception.message(e)}"
      )

      :error
  end

  def persist_snapshot(_path, _stats), do: :ok

  @doc "Returns a baseline empty snapshot map with all expected keys."
  def empty_snapshot do
    %{
      total_deals: 0,
      deals_last_30d: 0,
      total_duplicates: 0,
      duplicates_last_30d: 0,
      canonical_deals: 0,
      avg_temperature: 0.0,
      deals_last_24h: 0,
      deals_last_hour: 0,
      deals_per_hour: 0.0,
      deals_per_min: 0.0,
      deals_by_feed: [],
      recent_duplicate_clusters: [],
      cross_border_count: 0,
      foreign_kb_count: 0
    }
  end

  @impl true
  def init(opts) do
    table =
      case :ets.info(@table) do
        :undefined ->
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

        _ ->
          @table
      end

    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    snapshot_path = Keyword.get(opts, :snapshot_path, default_snapshot_path())

    auto_warm? =
      Keyword.get(opts, :auto_warm, Application.get_env(:deal_scout, :start_feed_poller, true))

    seed_or_restore_snapshot(snapshot_path)

    state = %{table: table, interval_ms: interval, snapshot_path: snapshot_path}

    if auto_warm? do
      {:ok, state, {:continue, :initial_warm}}
    else
      {:ok, state}
    end
  end

  defp seed_or_restore_snapshot(snapshot_path) do
    case :ets.lookup(@table, :deal_intelligence_stats) do
      [] ->
        stats =
          case load_snapshot(snapshot_path) do
            {:ok, restored} ->
              Logger.info(
                "[Analytics.Server] Restored #{restored.total_deals} deals from disk snapshot"
              )

              restored

            :error ->
              empty_snapshot()
          end

        Analytics.put_cached_stats(stats)

      _ ->
        :ok
    end
  end

  @impl true
  def handle_continue(:initial_warm, state) do
    do_refresh(state)
    schedule_next(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:refresh_now, _from, state) do
    stats = do_refresh(state)
    {:reply, stats, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    do_refresh(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh_tick, state) do
    do_refresh(state)
    schedule_next(state.interval_ms)
    {:noreply, state}
  end

  defp do_refresh(state) do
    stats = Analytics.compute_deal_intelligence_stats()
    Analytics.put_cached_stats(stats)

    if state.snapshot_path do
      persist_snapshot(state.snapshot_path, stats)
    end

    stats
  rescue
    e ->
      Logger.error(
        "[Analytics.Server] Failed to refresh analytics cache: #{Exception.message(e)}"
      )

      nil
  end

  defp schedule_next(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :refresh_tick, interval_ms)
  end

  defp schedule_next(_), do: :ok

  defp safe_binary_to_term(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    _ -> :error
  end

  defp safe_term_to_binary(term) do
    {:ok, :erlang.term_to_binary(term, compressed: 6)}
  rescue
    _ -> :error
  end
end
