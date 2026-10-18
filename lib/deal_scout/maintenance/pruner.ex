defmodule DealScout.Maintenance.Pruner do
  @moduledoc """
  Background GenServer that automatically purges deals older than 30 days
  to keep SQLite database file lean and within small hosting/backup footprints.
  """

  use GenServer
  require Logger

  alias DealScout.Deals

  # 24 hours
  @daily_interval_ms 24 * 60 * 60 * 1000
  @retention_days 30

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @daily_interval_ms)
    days = Keyword.get(opts, :retention_days, @retention_days)

    # Run initial prune after 1 minute
    Process.send_after(self(), :prune, 60_000)

    {:ok, %{interval_ms: interval, days: days}}
  end

  @impl true
  def handle_info(:prune, state) do
    prune_deals(state.days)
    schedule_next(state.interval_ms)
    {:noreply, state}
  end

  defp prune_deals(days) do
    {count, _} = Deals.prune_old_deals(days)

    if count > 0 do
      Logger.info("[DealScout.Pruner] Pruned #{count} deals older than #{days} days.")
    end
  rescue
    e ->
      Logger.error("[DealScout.Pruner] Error pruning deals: #{Exception.message(e)}")
  end

  defp schedule_next(interval_ms) do
    Process.send_after(self(), :prune, interval_ms)
  end
end
