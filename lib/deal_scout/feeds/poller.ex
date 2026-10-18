defmodule DealScout.Feeds.Poller do
  @moduledoc """
  Background GenServer that periodically polls configured RSS deal feeds.
  Uses HTTP conditional requests (ETags, If-Modified-Since) to save bandwidth.
  Parses new deals, inserts them into SQLite, and triggers the alert matcher.
  """

  use GenServer
  require Logger

  alias DealScout.Feeds
  alias DealScout.Deals
  alias DealScout.Alerts
  alias DealScout.Feeds.Parser

  # 2 minutes
  @default_interval_ms 120_000
  @user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36 DealScout/1.0"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually triggers a feed polling cycle immediately.
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
    # Stagger initial poll slightly so the supervision tree finishes starting up
    initial_delay = Keyword.get(opts, :initial_delay_ms, 2_000)

    Process.send_after(self(), :poll, initial_delay)

    {:ok, %{interval_ms: interval}}
  end

  @impl true
  def handle_info(:poll, state) do
    poll_all_feeds()
    schedule_poll(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:poll_now, state) do
    poll_all_feeds()
    {:noreply, state}
  end

  # ============================================================================
  # Polling Logic
  # ============================================================================

  def poll_all_feeds do
    feeds = Feeds.list_active_feeds()
    Logger.info("[DealScout.Poller] Polling #{length(feeds)} active feeds...")

    for feed <- feeds do
      poll_feed(feed)
    end
  end

  def poll_feed(feed) do
    headers = build_headers(feed)

    case Req.get(feed.url, headers: headers, receive_timeout: 15_000) do
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

    # 1. Parse items into deal attributes
    deal_attrs_list = Parser.parse_feed(body, feed.id)

    # 2. Insert new deals (deduplicating on guid)
    new_deals = Deals.insert_new_deals(deal_attrs_list)

    if length(new_deals) > 0 do
      Logger.info("[DealScout.Poller] Ingested #{length(new_deals)} new deals from #{feed.name}.")
      # 3. Match new deals against user alert rules
      Alerts.process_new_deals(new_deals)
    end

    # 4. Update feed metadata
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

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
