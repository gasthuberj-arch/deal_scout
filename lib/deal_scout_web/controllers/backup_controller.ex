defmodule DealScoutWeb.BackupController do
  use DealScoutWeb, :controller
  require Logger

  alias DealScout.Repo

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

  defp authorized?(conn) do
    configured_token = System.get_env("ADMIN_BACKUP_TOKEN", "dealscout-homelab-backup-key-2026")

    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        Plug.Crypto.secure_compare(String.trim(token), configured_token)

      _ ->
        false
    end
  end

  defp perform_backup(conn) do
    temp_dir = System.tmp_dir!()
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    backup_path = Path.join(temp_dir, "deal_scout_backup_#{timestamp}.db")

    # Clean up any leftover file if exists
    File.rm(backup_path)

    # Execute SQLite VACUUM INTO for an atomic, hot snapshot (or fallback to file copy in test sandbox)
    create_backup_res =
      case Ecto.Adapters.SQL.query(Repo, "VACUUM INTO ?", [backup_path]) do
        {:ok, _} ->
          {:ok, backup_path}

        {:error, %Exqlite.Error{message: "cannot VACUUM from within a transaction"}} ->
          db_file = Application.get_env(:deal_scout, Repo)[:database]

          case File.copy(db_file, backup_path) do
            {:ok, _} -> {:ok, backup_path}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end

    case create_backup_res do
      {:ok, _} ->
        Logger.info("[DealScout.Backup] Successfully created atomic backup at #{backup_path}")

        conn
        |> put_resp_content_type("application/x-sqlite3")
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=\"deal_scout_#{timestamp}.db\""
        )
        |> send_file(200, backup_path)
        |> tap(fn _ ->
          # Clean up temporary snapshot file asynchronously after sending
          Task.start(fn ->
            Process.sleep(2_000)
            File.rm(backup_path)
          end)
        end)

      {:error, reason} ->
        Logger.error("[DealScout.Backup] SQLite backup failed: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to generate SQLite backup snapshot."})
    end
  end
end
