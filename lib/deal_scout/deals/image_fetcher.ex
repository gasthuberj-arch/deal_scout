defmodule DealScout.Deals.ImageFetcher do
  @moduledoc """
  Bounded concurrency limiter for upstream deal image fetches.
  Ensures at most `@max_concurrent` active outbound HTTP image requests are in flight,
  preventing CPU and bandwidth starvation on constrained single-core instances.

  Includes:
  - Crash-safe slot reclamation via `Process.monitor/1`.
  - Queue-deadline expiration to eliminate ghost permits when waiting callers time out.
  """
  use GenServer

  @max_concurrent 4

  @doc """
  Starts the ImageFetcher concurrency limiter.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Executes the given function within an acquired concurrency permit.
  If no permits are available within `timeout` ms, returns `{:error, :busy}`.
  """
  def with_permit(fun, timeout \\ 3000) when is_function(fun, 0) do
    case acquire(timeout) do
      {:ok, ref} ->
        try do
          fun.()
        after
          release(ref)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Acquires a concurrency permit, blocking up to `timeout` ms.
  """
  def acquire(timeout \\ 3000) do
    GenServer.call(__MODULE__, {:acquire, timeout}, timeout)
  catch
    :exit, _ -> {:error, :busy}
  end

  @doc """
  Releases a previously acquired concurrency permit.
  """
  def release(ref) do
    GenServer.cast(__MODULE__, {:release, ref})
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    {:ok, %{active: %{}, queue: :queue.new(), max_concurrent: @max_concurrent}}
  end

  @impl true
  def handle_call({:acquire, timeout}, {from_pid, _} = from, state) do
    if map_size(state.active) < state.max_concurrent do
      mref = Process.monitor(from_pid)
      new_active = Map.put(state.active, mref, from_pid)
      {:reply, {:ok, mref}, %{state | active: new_active}}
    else
      # Track caller deadline so expired queue items never receive ghost permits
      deadline = System.monotonic_time(:millisecond) + timeout
      new_queue = :queue.in({from, deadline}, state.queue)
      {:noreply, %{state | queue: new_queue}}
    end
  end

  @impl true
  def handle_cast({:release, mref}, state) do
    Process.demonitor(mref, [:flush])
    new_active = Map.delete(state.active, mref)
    {:noreply, advance_queue(%{state | active: new_active})}
  end

  @impl true
  def handle_info({:DOWN, mref, :process, _pid, _reason}, state) do
    new_active = Map.delete(state.active, mref)
    {:noreply, advance_queue(%{state | active: new_active})}
  end

  defp advance_queue(state) do
    if map_size(state.active) < state.max_concurrent do
      case :queue.out(state.queue) do
        {{:value, {{from_pid, _} = from, deadline}}, rest_queue} ->
          now = System.monotonic_time(:millisecond)

          # Only grant permit if caller hasn't timed out and process is still alive
          if now <= deadline and Process.alive?(from_pid) do
            mref = Process.monitor(from_pid)
            new_active = Map.put(state.active, mref, from_pid)
            GenServer.reply(from, {:ok, mref})
            %{state | active: new_active, queue: rest_queue}
          else
            # Caller timed out or died while queued; skip and check next in line
            advance_queue(%{state | queue: rest_queue})
          end

        {:empty, _} ->
          state
      end
    else
      state
    end
  end
end
