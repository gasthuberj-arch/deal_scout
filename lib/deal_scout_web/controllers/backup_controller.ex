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
        conn
        |> put_resp_content_type("application/x-sqlite3")
        |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
        |> stream_and_cleanup_snapshot(backup_path)

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to generate SQLite backup snapshot."})
    end
  end

  defp stream_and_cleanup_snapshot(conn, backup_path) do
    case conn.adapter do
      {Plug.Adapters.Test.Conn, _} ->
        # In test environments, send_file reads the file into memory synchronously.
        conn = send_file(conn, 200, backup_path)
        File.rm(backup_path)
        conn

      _ ->
        parent = self()

        conn
        |> register_before_send(fn c ->
          Task.start(fn ->
            ref = Process.monitor(parent)

            receive do
              {:DOWN, ^ref, :process, ^parent, _reason} ->
                File.rm(backup_path)
            end
          end)

          c
        end)
        |> send_file(200, backup_path)
    end
  end
end
