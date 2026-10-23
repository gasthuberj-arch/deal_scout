defmodule DealScoutWeb.BackupController do
  use DealScoutWeb, :controller

  alias DealScout.Backup

  @doc """
  Streams an atomic SQLite backup snapshot to authenticated callers (e.g. homelab NAS).
  Protected by Bearer token authentication matching System.get_env("ADMIN_BACKUP_TOKEN").
  """
  def download(conn, _params) do
    if authorized?(conn) do
      perform_backup(conn)
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized. Valid Bearer token required in Authorization header."})
    end
  end

  @doc """
  Returns real-time health and replication status of the backup system and connected NAS client.
  """
  def status(conn, _params) do
    if authorized?(conn) do
      data = Backup.get_status()
      json(conn, %{status: "ok", backup: data})
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized. Valid Bearer token required in Authorization header."})
    end
  end

  defp authorized?(conn) do
    conn.req_headers
    |> Backup.extract_bearer_token()
    |> Backup.valid_token?(:backup)
  end

  defp perform_backup(conn) do
    case Backup.create_sqlite_snapshot() do
      {:ok, %{path: backup_path, filename: filename}} ->
        try do
          conn
          |> cleanup_on_send(backup_path)
          |> put_resp_content_type("application/x-sqlite3")
          |> put_resp_header(
            "content-disposition",
            "attachment; filename=\"#{filename}\""
          )
          |> send_file(200, backup_path)
        after
          File.rm(backup_path)
        end

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to generate SQLite backup snapshot."})
    end
  end

  defp cleanup_on_send(conn, path) do
    parent = self()

    Plug.Conn.register_before_send(conn, fn conn ->
      Task.start(fn ->
        ref = Process.monitor(parent)

        receive do
          {:DOWN, ^ref, :process, ^parent, _reason} ->
            File.rm(path)
        end
      end)

      conn
    end)
  end
end
