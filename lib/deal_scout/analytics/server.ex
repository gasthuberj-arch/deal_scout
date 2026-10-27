defmodule DealScout.Analytics.Server do
  @moduledoc """
  State lifecycle and background warmer for `DealScout.Analytics`.
  Owns the `:deal_scout_analytics_cache` ETS table, coordinates periodic
  re-computation of aggregate metrics, and serves stale-while-revalidate snapshots
  so web requests never execute heavy database queries.
  """

  use GenServer
  require Logger

  alias DealScout.Analytics

  @table :deal_scout_analytics_cache
  @default_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Triggers a synchronous refresh of the cached analytics metrics."
  def refresh_now(timeout \\ 30_000) do
    if GenServer.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :refresh_now, timeout)
    else
      stats = Analytics.compute_deal_intelligence_stats()
      Analytics.put_cached_stats(stats)
      stats
    end
  end

  @doc "Triggers an asynchronous background refresh of the cached analytics metrics."
  def warm_now do
    if GenServer.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, :refresh)
    else
      :ok
    end
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

    auto_warm? =
      Keyword.get(opts, :auto_warm, Application.get_env(:deal_scout, :start_feed_poller, true))

    if auto_warm? do
      {:ok, %{table: table, interval_ms: interval}, {:continue, :initial_warm}}
    else
      {:ok, %{table: table, interval_ms: interval}}
    end
  end

  @impl true
  def handle_continue(:initial_warm, state) do
    do_refresh()
    schedule_next(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:refresh_now, _from, state) do
    stats = do_refresh()
    {:reply, stats, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    do_refresh()
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh_tick, state) do
    do_refresh()
    schedule_next(state.interval_ms)
    {:noreply, state}
  end

  defp do_refresh do
    stats = Analytics.compute_deal_intelligence_stats()
    Analytics.put_cached_stats(stats)
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
end
