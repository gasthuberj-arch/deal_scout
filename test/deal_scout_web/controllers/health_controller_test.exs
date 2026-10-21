defmodule DealScoutWeb.HealthControllerTest do
  use DealScoutWeb.ConnCase

  test "GET /health returns 200 ok", %{conn: conn} do
    conn = get(conn, ~p"/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
