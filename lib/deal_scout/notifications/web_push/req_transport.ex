defmodule DealScout.Notifications.WebPush.ReqTransport do
  @moduledoc """
  Production HTTP transport using Req to deliver encrypted Web Push notifications.
  """
  @behaviour DealScout.Notifications.WebPush.Transport

  @impl true
  def post(endpoint, body, headers) do
    Req.post(endpoint, body: body, headers: headers, retry: false)
  end
end
