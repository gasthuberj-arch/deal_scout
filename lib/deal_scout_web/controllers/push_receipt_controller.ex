defmodule DealScoutWeb.PushReceiptController do
  use DealScoutWeb, :controller

  alias DealScout.Notifications

  def create(conn, %{"tracking_id" => tracking_id} = params) do
    received_at =
      case Map.get(params, "received_at") do
        val when is_integer(val) -> val
        _ -> System.system_time(:millisecond)
      end

    delay_ms =
      case Map.get(params, "client_delay_ms") do
        val when is_integer(val) -> val
        _ -> 0
      end

    case Notifications.record_receipt(tracking_id, received_at, delay_ms) do
      {:ok, _log} ->
        json(conn, %{status: "ok"})

      {:error, _reason} ->
        json(conn, %{status: "ignored"})
    end
  end

  def create(conn, _params) do
    json(conn, %{status: "ignored"})
  end
end
