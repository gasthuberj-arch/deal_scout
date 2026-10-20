defmodule DealScout.Feeds.Fetcher.TestAdapter do
  @moduledoc """
  In-memory test double adapter for feed fetching.
  Provides deterministic offline responses and supports URL-specific stubs.
  """
  @behaviour DealScout.Feeds.Fetcher

  @table :deal_scout_test_feed_responses

  @default_xml """
  <?xml version="1.0" encoding="utf-8"?>
  <rss version="2.0" xmlns:pepper="https://www.pepper.com">
    <channel>
      <title>Test Deals Feed</title>
      <item>
        <title><![CDATA[120° - Nintendo Switch OLED]]></title>
        <link>https://example.com/switch-oled</link>
        <guid>test-feed-guid-switch-1</guid>
        <pubDate>Sun, 18 Oct 2026 16:00:00 +0200</pubDate>
        <description><![CDATA[<strong>299,00€ - MediaMarkt</strong><br />Top Konsole!]]></description>
        <pepper:merchant name="MediaMarkt" price="299,00€"/>
      </item>
    </channel>
  </rss>
  """

  @impl true
  def fetch(url, headers) do
    ensure_table()

    case lookup_response(url) do
      {:ok, resp} ->
        {:ok, resp}

      {:error, reason} ->
        {:error, reason}

      fun when is_function(fun, 2) ->
        fun.(url, headers)

      nil ->
        if_none_match = get_header(headers, "if-none-match")

        if if_none_match == "test-etag" do
          {:ok, %{status: 304, body: "", headers: []}}
        else
          {:ok, %{status: 200, body: @default_xml, headers: [{"etag", "test-etag"}]}}
        end
    end
  end

  def stub_url(url, response) do
    ensure_table()
    :ets.insert(@table, {url, response})
    :ok
  end

  def stub_default(response) do
    ensure_table()
    :ets.insert(@table, {:default, response})
    :ok
  end

  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  def default_xml, do: @default_xml

  defp lookup_response(url) do
    case :ets.lookup(@table, url) do
      [{^url, resp}] ->
        resp

      [] ->
        case :ets.lookup(@table, :default) do
          [{:default, resp}] -> resp
          [] -> nil
        end
    end
  end

  defp ensure_table do
    case :ets.info(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      _ ->
        @table
    end
  end

  defp get_header(headers, key) when is_list(headers) do
    case List.keyfind(headers, key, 0) do
      {_, val} -> val
      _ -> nil
    end
  end

  defp get_header(_, _), do: nil
end
