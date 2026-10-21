defmodule DealScoutWeb.MetricsControllerTest do
  use DealScoutWeb.ConnCase

  setup do
    Application.put_env(:deal_scout, :metrics_token, "test-metrics-token-12345")
    on_exit(fn -> Application.delete_env(:deal_scout, :metrics_token) end)
    :ok
  end

  test "GET /metrics without token returns 401 unauthorized", %{conn: conn} do
    conn = get(conn, ~p"/metrics")
    assert response(conn, 401) =~ "Unauthorized"
  end

  test "GET /metrics with invalid token returns 401 unauthorized", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer invalid-token")
      |> get(~p"/metrics")

    assert response(conn, 401) =~ "Unauthorized"
  end

  test "GET /metrics with valid Bearer token returns Prometheus metrics text", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer test-metrics-token-12345")
      |> get(~p"/metrics")

    body = response(conn, 200)
    assert response_content_type(conn, :plain) =~ "text/plain"
    assert is_binary(body)
  end

  test "GET /metrics falls back to backup_token when metrics_token is not set", %{conn: conn} do
    Application.delete_env(:deal_scout, :metrics_token)
    Application.put_env(:deal_scout, :backup_token, "fallback-backup-token-999")
    on_exit(fn -> Application.delete_env(:deal_scout, :backup_token) end)

    conn =
      conn
      |> put_req_header("authorization", "Bearer fallback-backup-token-999")
      |> get(~p"/metrics")

    assert response(conn, 200)
  end
end
