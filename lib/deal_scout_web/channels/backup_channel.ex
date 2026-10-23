defmodule DealScoutWeb.BackupChannel do
  use DealScoutWeb, :channel

  alias DealScout.Backup

  @impl true
  def join("backup:sync", params, socket) do
    client_id = socket.assigns[:client_id] || "unknown-client"
    remote_ip = socket.assigns[:remote_ip] || "unknown"

    meta = %{
      remote_ip: remote_ip,
      client_version: params["version"] || "1.0",
      hostname: params["hostname"] || "nas"
    }

    Backup.client_connected(client_id, meta)
    Backup.subscribe()

    {:ok,
     %{
       status: "connected",
       server_time: DateTime.utc_now(),
       message: "DealScout Backup Sync Channel connected"
     }, socket}
  end

  @impl true
  def handle_in("handshake", payload, socket) do
    client_state = payload || %{}
    missing_files = Backup.missing_files_for_client(client_state)

    {:reply,
     {:ok,
      %{
        status: "ok",
        missing_count: length(missing_files),
        missing_files: missing_files
      }}, socket}
  end

  @impl true
  def handle_in("request_file", %{"path" => requested_path}, socket) do
    case Backup.read_replica_file(requested_path) do
      {:ok, %{path: path, size: size, sha256: sha256, data: data}} ->
        {:reply,
         {:ok,
          %{
            path: path,
            size: size,
            sha256: sha256,
            data: data
          }}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  @impl true
  def handle_in("ping", _params, socket) do
    client_id = socket.assigns[:client_id]
    Backup.record_ping(client_id)
    {:reply, {:ok, %{pong: System.system_time(:millisecond)}}, socket}
  end

  @impl true
  def handle_info({:new_backup_file, rel_path, _full_path, size, sha256}, socket) do
    push(socket, "new_file", %{
      path: rel_path,
      size: size,
      sha256: sha256
    })

    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    client_id = socket.assigns[:client_id]
    if client_id, do: Backup.client_disconnected(client_id)
    :ok
  end
end
