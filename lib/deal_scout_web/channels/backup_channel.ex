defmodule DealScoutWeb.BackupChannel do
  use DealScoutWeb, :channel

  alias DealScout.Backup.Status, as: BackupStatus
  alias DealScout.Backup.Watcher, as: BackupWatcher

  @pubsub DealScout.PubSub
  @pubsub_topic "backup:internal"

  @impl true
  def join("backup:sync", params, socket) do
    client_id = socket.assigns[:client_id] || "unknown-client"
    remote_ip = socket.assigns[:remote_ip] || "unknown"

    meta = %{
      remote_ip: remote_ip,
      client_version: params["version"] || "1.0",
      hostname: params["hostname"] || "nas"
    }

    BackupStatus.client_connected(client_id, meta)
    Phoenix.PubSub.subscribe(@pubsub, @pubsub_topic)

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
    missing_files = BackupWatcher.missing_files_for_client(client_state)

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
    replica_dir = Application.get_env(:deal_scout, :litestream_replica_dir, "/data/litestream")

    with :ok <- validate_relative_path(requested_path),
         full_path = Path.expand(Path.join(replica_dir, requested_path)),
         true <- String.starts_with?(full_path, Path.expand(replica_dir)),
         {:ok, binary} <- File.read(full_path) do
      sha256 = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
      size = byte_size(binary)

      BackupStatus.record_file_sent(requested_path, size)

      {:reply,
       {:ok,
        %{
          path: requested_path,
          size: size,
          sha256: sha256,
          data: Base.encode64(binary)
        }}, socket}
    else
      false ->
        {:reply, {:error, %{reason: "Path traversal forbidden"}}, socket}

      {:error, :enoent} ->
        {:reply, {:error, %{reason: "File not found"}}, socket}

      {:error, reason} when is_binary(reason) ->
        {:reply, {:error, %{reason: reason}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("ping", _params, socket) do
    client_id = socket.assigns[:client_id]
    BackupStatus.record_ping(client_id)
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
    if client_id, do: BackupStatus.client_disconnected(client_id)
    :ok
  end

  defp validate_relative_path(path) do
    cond do
      not is_binary(path) ->
        {:error, "Invalid path type"}

      String.starts_with?(path, "/") or String.starts_with?(path, "\\") ->
        {:error, "Absolute paths not allowed"}

      String.contains?(path, "..") ->
        {:error, "Path traversal with '..' not allowed"}

      String.contains?(path, <<0>>) ->
        {:error, "Null bytes not allowed"}

      true ->
        :ok
    end
  end
end
