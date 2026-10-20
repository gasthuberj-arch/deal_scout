defmodule DealScout.Feeds.Fetcher.ReqAdapter do
  @moduledoc """
  Production HTTP adapter for feed fetching using Req.
  """
  @behaviour DealScout.Feeds.Fetcher

  @impl true
  def fetch(url, headers) do
    Req.get(url, headers: headers, receive_timeout: 15_000, retry: false)
  end
end
