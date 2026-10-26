defmodule DealScout.Analytics.Warmer do
  @moduledoc """
  Background GenServer that periodically refreshes the deal intelligence analytics cache.

  By warming the cache on a timer (default: every 60 seconds), web and LiveView requests
  never perform heavy aggregate calculations or trigger cache stampedes under high concurrency.
  Lookups remain instant (ETS read concurrency) and exactly one background calculation runs
  at any given time.
  """

  use GenServer
  require Logger

  alias DealScout.Analytics

  @table :deal_scout_analytics_cache
  # Default refresh every 60 seconds
  @default_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers an immediate synchronous or asynchronous refresh of the analytics cache.
  """
  def warm_now do
    GenServer.cast(__MODULE__, :refresh)
  end

  @impl true
  def init(opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)

    # Perform initial warm immediately on start
    send(self(), :refresh)

    {:ok, %{interval_ms: interval}}
  end

  @impl true
  def handle_info(:refresh, state) do
    refresh_stats()
    schedule_next(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    refresh_stats()
    {:noreply, state}
  end

  defp refresh_stats do
    stats = Analytics.compute_deal_intelligence_stats()
    Analytics.put_cached_stats(stats)
  rescue
    e ->
      Logger.error(
        "[DealScout.Analytics.Warmer] Failed to warm analytics cache: #{Exception.message(e)}"
      )
  end

  defp schedule_next(interval_ms) do
    Process.send_after(self(), :refresh, interval_ms)
  end
end
