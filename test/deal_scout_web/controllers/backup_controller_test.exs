defmodule DealScoutWeb.BackupControllerTest do
  use DealScoutWeb.ConnCase

  test "GET /api/admin/backup returns 401 Unauthorized without token", %{conn: conn} do
    conn = get(conn, ~p"/api/admin/backup")
    assert json_response(conn, 401)["error"] =~ "Unauthorized"
  end

  test "GET /api/admin/backup streams SQLite database with valid token", %{conn: conn} do
    token = System.get_env("ADMIN_BACKUP_TOKEN", "dealscout-homelab-backup-key-2026")

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/admin/backup")

    assert response(conn, 200) =~ "SQLite format 3"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/x-sqlite3"
  end
end
