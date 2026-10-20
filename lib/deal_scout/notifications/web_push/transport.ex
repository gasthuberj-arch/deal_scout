defmodule DealScout.Notifications.WebPush.Transport do
  @moduledoc """
  Transport interface for sending Web Push HTTP payloads.
  Satisfies the Two-Adapter Rule with ReqTransport (production) and TestTransport (offline test double).
  """

  @callback post(endpoint :: String.t(), body :: binary(), headers :: list()) ::
              {:ok, %{status: integer(), body: term()}}
              | {:error, term()}
end
