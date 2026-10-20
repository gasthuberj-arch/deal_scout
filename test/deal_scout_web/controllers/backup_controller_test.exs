defmodule DealScoutWeb.BackupControllerTest do
  use DealScoutWeb.ConnCase

  @test_token "test-admin-backup-token-12345"

  setup do
    prev_app_token = Application.get_env(:deal_scout, :backup_token)
    prev_env_token = System.get_env("ADMIN_BACKUP_TOKEN")

    Application.put_env(:deal_scout, :backup_token, @test_token)
    System.delete_env("ADMIN_BACKUP_TOKEN")

    on_exit(fn ->
      if prev_app_token do
        Application.put_env(:deal_scout, :backup_token, prev_app_token)
      else
        Application.delete_env(:deal_scout, :backup_token)
      end

      if prev_env_token do
        System.put_env("ADMIN_BACKUP_TOKEN", prev_env_token)
      else
        System.delete_env("ADMIN_BACKUP_TOKEN")
      end
    end)

    :ok
  end

  test "GET /api/admin/backup returns 401 Unauthorized without token", %{conn: conn} do
    conn = get(conn, ~p"/api/admin/backup")
    assert response(conn, 401)
    assert json_response(conn, 401)["error"] =~ "Unauthorized"
  end

  test "GET /api/admin/backup returns 401 Unauthorized with invalid token", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer wrong-token")
      |> get(~p"/api/admin/backup")

    assert response(conn, 401)
    assert json_response(conn, 401)["error"] =~ "Unauthorized"
  end

  test "GET /api/admin/backup returns 401 with malformed authorization header", %{conn: conn} do
    for header <- ["Bearer ", "Basic #{@test_token}", "Token #{@test_token}", ""] do
      res_conn =
        conn
        |> put_req_header("authorization", header)
        |> get(~p"/api/admin/backup")

      assert response(res_conn, 401)
      assert json_response(res_conn, 401)["error"] =~ "Unauthorized"
    end
  end

  test "GET /api/admin/backup returns 401 when token is not configured or empty", %{conn: conn} do
    Application.delete_env(:deal_scout, :backup_token)
    System.delete_env("ADMIN_BACKUP_TOKEN")

    unconfigured_conn =
      conn
      |> put_req_header("authorization", "Bearer #{@test_token}")
      |> get(~p"/api/admin/backup")

    assert response(unconfigured_conn, 401)
    assert json_response(unconfigured_conn, 401)["error"] =~ "Unauthorized"

    # Also test empty string configuration
    Application.put_env(:deal_scout, :backup_token, "")

    empty_conf_conn =
      conn
      |> put_req_header("authorization", "Bearer ")
      |> get(~p"/api/admin/backup")

    assert response(empty_conf_conn, 401)
    assert json_response(empty_conf_conn, 401)["error"] =~ "Unauthorized"
  end

  test "GET /api/admin/backup streams SQLite database with valid token", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{@test_token}")
      |> get(~p"/api/admin/backup")

    assert response(conn, 200) =~ "SQLite format 3"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/x-sqlite3"

    assert get_resp_header(conn, "content-disposition")
           |> List.first() =~ "attachment; filename=\"deal_scout_"
  end

  test "GET /api/admin/backup authenticates with System env ADMIN_BACKUP_TOKEN when app env is unset",
       %{conn: conn} do
    Application.delete_env(:deal_scout, :backup_token)
    env_token = "system-env-backup-token-99"
    System.put_env("ADMIN_BACKUP_TOKEN", env_token)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{env_token}")
      |> get(~p"/api/admin/backup")

    assert response(conn, 200) =~ "SQLite format 3"
  end

  test "GET /api/admin/backup cleans up temporary backup file after sending", %{conn: conn} do
    tmp_dir = System.tmp_dir!()
    pattern = Path.join(tmp_dir, "deal_scout_backup_*.db")
    before_files = Path.wildcard(pattern)

    conn
    |> put_req_header("authorization", "Bearer #{@test_token}")
    |> get(~p"/api/admin/backup")

    after_files = Path.wildcard(pattern)
    # Any new backup file created during this request should be deleted
    new_files = after_files -- before_files
    assert new_files == []
  end

  test "GET /api/admin/backup/status returns 401 without valid token", %{conn: conn} do
    conn = get(conn, ~p"/api/admin/backup/status")
    assert response(conn, 401)
  end

  test "GET /api/admin/backup/status returns real-time status JSON with valid token", %{
    conn: conn
  } do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{@test_token}")
      |> get(~p"/api/admin/backup/status")

    assert response(conn, 200)
    data = json_response(conn, 200)
    assert data["status"] == "ok"
    assert is_map(data["backup"])
    assert Map.has_key?(data["backup"], "client_connected")
    assert Map.has_key?(data["backup"], "files_synced_count")
    assert Map.has_key?(data["backup"], "replica_summary")
  end
end
