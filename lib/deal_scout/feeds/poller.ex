defmodule DealScout.Feeds.Poller do
  @moduledoc """
  Background GenServer that periodically polls configured RSS deal feeds.
  Spreads feed requests over time (round-robin) and processes each feed inside an
  isolated ephemeral task so that large XML DOMs and refc binaries are immediately
  freed by the BEAM VM upon task completion. Concurrency is strictly limited to 1.
  """

  use GenServer
  require Logger

  alias DealScout.Feeds
  alias DealScout.Feeds.Fetcher
  alias DealScout.Deals.Ingestion

  # 2 minutes total cycle
  @default_interval_ms 120_000
  # Minimum stagger between feeds (ms)
  @min_stagger_ms 5_000
  # Fast stagger when manually triggered (ms)
  @fast_stagger_ms 1_000
  @user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36 DealScout/1.0"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually triggers a feed polling cycle across all active feeds.
  Feeds are queued and polled sequentially with a short stagger.
  """
  def poll_now do
    GenServer.cast(__MODULE__, :poll_now)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    initial_delay = Keyword.get(opts, :initial_delay_ms, 2_000)

    timer_ref = Process.send_after(self(), :tick, initial_delay)

    {:ok,
     %{
       interval_ms: interval,
       queue: [],
       active_task: nil,
       timer_ref: timer_ref,
       mode: :normal
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    state = %{state | timer_ref: nil}

    if state.active_task != nil do
      # Previous task is still running; wait 2s before retrying
      timer_ref = Process.send_after(self(), :tick, 2_000)
      {:noreply, %{state | timer_ref: timer_ref}}
    else
      dispatch_next_feed(state)
    end
  end

  @impl true
  def handle_info({ref, _result}, state) do
    Process.demonitor(ref, [:flush])

    state =
      case state.active_task do
        {^ref, _feed_id} -> %{state | active_task: nil}
        _ -> state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if reason not in [:normal, :noproc] do
      Logger.error("[DealScout.Poller] Worker task exited abnormally: #{inspect(reason)}")
    end

    state =
      case state.active_task do
        {^ref, _feed_id} -> %{state | active_task: nil}
        _ -> state
      end

    {:noreply, state}
  end

  @impl true
  def handle_cast(:poll_now, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    feeds = Feeds.list_active_feeds()
    feed_ids = Enum.map(feeds, & &1.id)

    new_state = %{state | queue: feed_ids, mode: :fast, timer_ref: nil}

    if new_state.active_task == nil do
      dispatch_next_feed(new_state)
    else
      timer_ref = Process.send_after(self(), :tick, @fast_stagger_ms)
      {:noreply, %{new_state | timer_ref: timer_ref}}
    end
  end

  # ============================================================================
  # Dispatch & Queue Management
  # ============================================================================

  defp dispatch_next_feed(state) do
    {queue, next_feed_id, mode} =
      case state.queue do
        [] ->
          feeds = Feeds.list_active_feeds()
          feed_ids = Enum.map(feeds, & &1.id)

          case feed_ids do
            [] -> {[], nil, :normal}
            [first | rest] -> {rest, first, :normal}
          end

        [next | rest] ->
          {rest, next, state.mode}
      end

    if is_nil(next_feed_id) do
      # All feeds in cycle polled; schedule next tick after full interval
      timer_ref = Process.send_after(self(), :tick, state.interval_ms)
      {:noreply, %{state | queue: [], active_task: nil, timer_ref: timer_ref, mode: :normal}}
    else
      feed = Feeds.get_feed(next_feed_id)

      if feed && feed.is_active do
        task = spawn_poll_task(feed)

        # Stagger calculation:
        # In fast mode: short 1-second interval between feeds.
        # In normal mode: spread across interval_ms (e.g. 120s / 10 feeds = 12s).
        stagger_ms =
          if mode == :fast do
            @fast_stagger_ms
          else
            total_active = max(1, length(queue) + 1)
            max(@min_stagger_ms, div(state.interval_ms, total_active))
          end

        timer_ref = Process.send_after(self(), :tick, stagger_ms)

        {:noreply,
         %{
           state
           | queue: queue,
             active_task: {task.ref, next_feed_id},
             timer_ref: timer_ref,
             mode: mode
         }}
      else
        # Feed deleted or disabled, skip to next immediately
        dispatch_next_feed(%{state | queue: queue, mode: mode})
      end
    end
  end

  defp spawn_poll_task(feed) do
    task_fn = fn ->
      poll_feed(feed)
    end

    if Process.whereis(DealScout.Feeds.TaskSupervisor) do
      Task.Supervisor.async_nolink(DealScout.Feeds.TaskSupervisor, task_fn)
    else
      Task.async(task_fn)
    end
  end

  # ============================================================================
  # Polling Logic
  # ============================================================================

  @doc """
  Polls all active feeds synchronously. Useful in test fixtures or mix tasks.
  """
  def poll_all_feeds do
    feeds = Feeds.list_active_feeds()
    Logger.info("[DealScout.Poller] Polling #{length(feeds)} active feeds...")

    for feed <- feeds do
      poll_feed(feed)
    end

    :ok
  end

  @doc """
  Polls a single feed using HTTP conditional headers.
  """
  def poll_feed(feed) do
    headers = build_headers(feed)

    case Fetcher.fetch(feed.url, headers) do
      {:ok, %{status: 304}} ->
        Logger.debug("[DealScout.Poller] Feed '#{feed.name}' unchanged (304 Not Modified).")

        Feeds.update_feed(feed, %{
          last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, %{status: 200, body: body, headers: resp_headers}} ->
        handle_feed_response(feed, body, resp_headers)

      {:ok, %{status: status}} ->
        Logger.warning("[DealScout.Poller] Feed '#{feed.name}' returned HTTP status #{status}.")

      {:error, reason} ->
        Logger.error("[DealScout.Poller] Failed to fetch feed '#{feed.name}': #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.error(
        "[DealScout.Poller] Exception polling feed '#{feed.name}': #{Exception.message(e)}"
      )
  end

  defp handle_feed_response(feed, body, resp_headers) when is_binary(body) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    etag = get_header(resp_headers, "etag")
    last_mod = get_header(resp_headers, "last-modified")

    case Ingestion.ingest_feed(feed, body) do
      {:ok, new_deals} ->
        if length(new_deals) > 0 do
          Logger.info(
            "[DealScout.Poller] Ingested #{length(new_deals)} new deals from #{feed.name}."
          )
        end

      {:error, reason} ->
        Logger.error(
          "[DealScout.Poller] Failed to ingest feed '#{feed.name}': #{inspect(reason)}"
        )
    end

    # Update feed metadata
    attrs = %{
      last_fetched_at: now,
      etag: etag || feed.etag,
      last_modified: last_mod || feed.last_modified
    }

    Feeds.update_feed(feed, attrs)
  end

  defp handle_feed_response(_feed, _non_binary_body, _headers), do: :ok

  defp build_headers(feed) do
    headers = [
      {"user-agent", @user_agent},
      {"accept", "application/rss+xml, application/xml, text/xml;q=0.9, */*;q=0.8"}
    ]

    headers =
      if feed.etag do
        [{"if-none-match", feed.etag} | headers]
      else
        headers
      end

    if feed.last_modified do
      [{"if-modified-since", feed.last_modified} | headers]
    else
      headers
    end
  end

  defp get_header(headers, key) when is_map(headers) do
    case Map.get(headers, key) do
      [val | _] -> val
      val when is_binary(val) -> val
      _ -> nil
    end
  end

  defp get_header(headers, key) when is_list(headers) do
    case List.keyfind(headers, key, 0) do
      {_, [val | _]} -> val
      {_, val} when is_binary(val) -> val
      _ -> nil
    end
  end

  defp get_header(_, _), do: nil
end
