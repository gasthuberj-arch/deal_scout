defmodule DealScout.Feeds.Ebay.Poller do
  @moduledoc """
  Periodic background worker for the eBay Sofort-Kauf sniper.

  Orchestrates the demand-driven polling cycle:
  1. Aggregates keywords from active alert rules (`QueryAggregator`).
  2. If active rules exist, searches eBay Browse API (`Client`).
  3. Filters unseen items using in-memory ETS table (`SeenCache`).
  4. Runs filter-first ephemeral matching in RAM (`Matcher`).
  5. Only persists matching items to SQLite with zero disk bloat.
  """

  use GenServer
  require Logger

  alias DealScout.Feeds.Ebay.{Client, Config, Matcher, QueryAggregator, SeenCache}

  @default_backoff_seconds 300

  defstruct [
    :timer_ref,
    :poll_interval_seconds,
    :backoff_until,
    :consecutive_errors,
    :last_poll_at,
    :last_status,
    :active_task
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers an immediate asynchronous polling cycle.
  """
  def poll_now do
    GenServer.cast(__MODULE__, :poll_now)
  end

  @doc """
  Executes a synchronous polling cycle and returns the result (useful for tests and admin).
  """
  def poll_sync(opts \\ []) do
    perform_poll_cycle(opts)
  end

  @doc """
  Returns the current poller status map.
  """
  def status do
    GenServer.call(__MODULE__, :get_status)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :poll_interval_seconds, Config.poll_interval_seconds())
    initial_delay_ms = Keyword.get(opts, :initial_delay_ms, 5_000)

    timer_ref =
      if Keyword.get(opts, :auto_start, true) do
        Process.send_after(self(), :tick, initial_delay_ms)
      else
        nil
      end

    {:ok,
     %__MODULE__{
       timer_ref: timer_ref,
       poll_interval_seconds: interval,
       backoff_until: nil,
       consecutive_errors: 0,
       last_poll_at: nil,
       last_status: :idle,
       active_task: nil
     }}
  end

  @impl true
  def handle_cast(:poll_now, state) do
    new_state = run_poll_in_task(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status_info = %{
      enabled: Config.enabled?(),
      last_poll_at: state.last_poll_at,
      last_status: state.last_status,
      consecutive_errors: state.consecutive_errors,
      backoff_until: state.backoff_until,
      seen_cache_size: SeenCache.size()
    }

    {:reply, status_info, state}
  end

  @impl true
  def handle_info(:tick, state) do
    new_state =
      if should_poll?(state) do
        run_poll_in_task(state)
      else
        state
      end

    rescheduled = schedule_next_tick(new_state)
    {:noreply, rescheduled}
  end

  # Ephemeral Task completion
  def handle_info({ref, result}, %{active_task: {_pid, ref}} = state) do
    Process.demonitor(ref, [:flush])

    new_state =
      case result do
        {:ok, stats} ->
          %{
            state
            | active_task: nil,
              last_poll_at: DateTime.utc_now(),
              last_status: {:ok, stats},
              consecutive_errors: 0,
              backoff_until: nil
          }

        {:error, :rate_limited} ->
          backoff = DateTime.add(DateTime.utc_now(), @default_backoff_seconds, :second)

          Logger.warning(
            "[DealScout.Feeds.Ebay.Poller] Rate limited by eBay, backing off until #{backoff}"
          )

          %{
            state
            | active_task: nil,
              last_poll_at: DateTime.utc_now(),
              last_status: :rate_limited,
              consecutive_errors: state.consecutive_errors + 1,
              backoff_until: backoff
          }

        {:error, reason} ->
          errors = state.consecutive_errors + 1
          backoff_seconds = min(errors * 60, @default_backoff_seconds)
          backoff = DateTime.add(DateTime.utc_now(), backoff_seconds, :second)

          Logger.warning(
            "[DealScout.Feeds.Ebay.Poller] Poll failed: #{inspect(reason)}. Backing off for #{backoff_seconds}s"
          )

          %{
            state
            | active_task: nil,
              last_poll_at: DateTime.utc_now(),
              last_status: {:error, reason},
              consecutive_errors: errors,
              backoff_until: backoff
          }
      end

    {:noreply, new_state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{active_task: {_, ref}} = state) do
    Logger.error("[DealScout.Feeds.Ebay.Poller] Active task crashed: #{inspect(reason)}")
    {:noreply, %{state | active_task: nil, last_status: {:crashed, reason}}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================================
  # Internal Polling Logic
  # ============================================================================

  defp should_poll?(state) do
    cond do
      not Config.enabled?() ->
        false

      state.active_task != nil ->
        false

      state.backoff_until != nil and
          DateTime.compare(DateTime.utc_now(), state.backoff_until) == :lt ->
        false

      true ->
        true
    end
  end

  defp run_poll_in_task(state) do
    if state.active_task == nil do
      task =
        Task.Supervisor.async_nolink(
          DealScout.Feeds.TaskSupervisor,
          fn -> perform_poll_cycle() end
        )

      %{state | active_task: {task.pid, task.ref}}
    else
      state
    end
  end

  defp schedule_next_tick(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    interval_ms = (state.poll_interval_seconds || 60) * 1_000
    ref = Process.send_after(self(), :tick, interval_ms)
    %{state | timer_ref: ref}
  end

  @doc """
  Performs one synchronous poll cycle across all active eBay queries.
  """
  def perform_poll_cycle(opts \\ []) do
    queries = QueryAggregator.list_active_queries(opts)

    if queries == [] do
      {:ok, %{queries_run: 0, new_items: 0, matched: 0, discarded: 0}}
    else
      results =
        Enum.reduce_while(
          queries,
          {:ok, %{queries_run: 0, new_items: 0, matched: 0, discarded: 0}},
          fn query, {:ok, acc} ->
            client_opts = [q: query.q] ++ Keyword.get(opts, :client_opts, [])

            case Client.search(client_opts) do
              {:ok, raw_items} ->
                guid_list = Enum.map(raw_items, & &1.guid)
                unseen = SeenCache.filter_unseen(raw_items)
                SeenCache.put_all(guid_list)
                SeenCache.prune()

                {:ok, match_res} = Matcher.evaluate_and_persist(unseen, opts)

                new_acc = %{
                  queries_run: acc.queries_run + 1,
                  new_items: acc.new_items + length(unseen),
                  matched: acc.matched + length(match_res.matched_deals),
                  discarded: acc.discarded + match_res.discarded_count
                }

                {:cont, {:ok, new_acc}}

              {:error, {:rate_limited, _, _}} ->
                {:halt, {:error, :rate_limited}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end
        )

      results
    end
  end
end
