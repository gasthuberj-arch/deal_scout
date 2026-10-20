defmodule DealScout.Feeds.Fetcher do
  @moduledoc """
  Interface for fetching remote feed data over HTTP.
  Satisfies the Two-Adapter Rule with ReqAdapter (production) and TestAdapter (offline test double).
  """

  @callback fetch(url :: String.t(), headers :: list()) ::
              {:ok, %{status: integer(), body: binary(), headers: term()}}
              | {:error, term()}

  @doc """
  Fetches a feed from the given URL using the configured adapter.
  """
  def fetch(url, headers \\ []) do
    adapter().fetch(url, headers)
  end

  @doc """
  Returns the configured fetcher adapter.
  """
  def adapter do
    Application.get_env(:deal_scout, :feed_fetcher, DealScout.Feeds.Fetcher.ReqAdapter)
  end
end
