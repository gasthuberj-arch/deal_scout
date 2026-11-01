defmodule DealScoutWeb.PushReceiptControllerTest do
  use DealScoutWeb.ConnCase, async: true

  alias DealScout.Repo
  alias DealScout.Accounts.User
  alias DealScout.Notifications.PushDeliveryLog

  setup do
    user =
      Repo.insert!(%User{
        email: "receipt-user-#{System.unique_integer([:positive])}@example.com",
        hashed_password: "dummy_password"
      })

    log =
      Repo.insert!(%PushDeliveryLog{
        user_id: user.id,
        tracking_id: "track-receipt-123",
        status: "delivered",
        http_status: 201
      })

    %{user: user, log: log}
  end

  test "POST /api/push/receipt records receipt timestamp and delay", %{conn: conn, log: log} do
    now_ms = System.system_time(:millisecond)

    conn =
      post(conn, ~p"/api/push/receipt", %{
        "tracking_id" => "track-receipt-123",
        "received_at" => now_ms,
        "client_delay_ms" => 350
      })

    assert json_response(conn, 200) == %{"status" => "ok"}

    reloaded = Repo.get!(PushDeliveryLog, log.id)
    assert %DateTime{} = reloaded.client_received_at
    assert is_integer(reloaded.client_delay_ms) and reloaded.client_delay_ms >= 0
  end

  test "POST /api/push/receipt ignores unknown tracking_id gracefully", %{conn: conn} do
    conn =
      post(conn, ~p"/api/push/receipt", %{
        "tracking_id" => "unknown-id",
        "received_at" => System.system_time(:millisecond),
        "client_delay_ms" => 100
      })

    assert json_response(conn, 200) == %{"status" => "ignored"}
  end
end
