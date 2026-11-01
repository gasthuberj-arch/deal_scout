defmodule DealScout.Notifications.WebPush.ReqTransport do
  @moduledoc """
  Production HTTP transport using Req to deliver encrypted Web Push notifications.
  Configured with safe transient retries (5xx and connection timeouts) to prevent
  momentary network hiccups from dropping notifications.
  """
  @behaviour DealScout.Notifications.WebPush.Transport

  @impl true
  def post(endpoint, body, headers) do
    Req.post(endpoint,
      body: body,
      headers: headers,
      retry: :transient,
      max_retries: 2,
      retry_delay: fn attempt -> attempt * 200 end,
      receive_timeout: 10_000
    )
  end
end
