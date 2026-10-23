defmodule DealScout.Notifications.DigestWorker do
  @moduledoc """
  Periodic GenServer timer that triggers `DealScout.Notifications.Dispatcher.flush_pending_digests/1`
  for users with hourly or daily digest delivery modes.
  """

  use GenServer

  alias DealScout.Notifications.Dispatcher

  # Check every 15 minutes by default
  @default_interval :timer.minutes(15)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule_check(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:check_digests, state) do
    send_pending_digests()
    schedule_check(state.interval)
    {:noreply, state}
  end

  @doc """
  Flushes all pending unnotified digest matches via `DealScout.Notifications.Dispatcher`.
  """
  defdelegate send_pending_digests(opts \\ []), to: Dispatcher, as: :flush_pending_digests

  defp schedule_check(interval) do
    Process.send_after(self(), :check_digests, interval)
  end
end
