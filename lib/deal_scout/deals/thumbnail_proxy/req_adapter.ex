defmodule DealScout.Deals.ThumbnailProxy.ReqAdapter do
  @moduledoc """
  Production HTTP adapter for fetching upstream deal thumbnails using Req.
  """

  @doc """
  Fetches an upstream image over HTTP.
  """
  def fetch(url) when is_binary(url) do
    Req.get(url,
      headers: [
        {"user-agent",
         "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"},
        {"accept", "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"}
      ],
      receive_timeout: 4000,
      max_retries: 1
    )
  end
end
