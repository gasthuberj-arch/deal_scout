defmodule DealScout.Backup.Status do
  @moduledoc """
  Tracks real-time backup health, connected NAS client state,
  and replication metrics for DealScout.
  """
  use GenServer
  require Logger

  @name __MODULE__

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Returns the current status of the backup system, connected client, and replication metrics.
  """
  def get_status(server \\ @name) do
    GenServer.call(server, :get_status)
  end

  @doc """
  Registers a newly connected backup client.
  """
  def client_connected(client_id), do: client_connected(@name, client_id, %{})

  def client_connected(client_id, metadata) when is_map(metadata) do
    client_connected(@name, client_id, metadata)
  end

  def client_connected(server, client_id) do
    client_connected(server, client_id, %{})
  end

  def client_connected(server, client_id, metadata) do
    GenServer.cast(server, {:client_connected, client_id, metadata})
  end

  @doc """
  Registers a disconnected backup client.
  """
  def client_disconnected(client_id), do: client_disconnected(@name, client_id)

  def client_disconnected(server, client_id) do
    GenServer.cast(server, {:client_disconnected, client_id})
  end

  @doc """
  Records a successful file chunk or snapshot sent to the client.
  """
  def record_file_sent(file_path, byte_size), do: record_file_sent(@name, file_path, byte_size)

  def record_file_sent(server, file_path, byte_size) do
    GenServer.cast(server, {:record_file_sent, file_path, byte_size})
  end

  @doc """
  Records a keepalive heartbeat / ping from a client.
  """
  def record_ping(client_id), do: record_ping(@name, client_id)

  def record_ping(server, client_id) do
    GenServer.cast(server, {:record_ping, client_id})
  end

  @doc """
  Resets status state (useful in test setup).
  """
  def reset(server \\ @name) do
    GenServer.call(server, :reset)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    {:ok, initial_state()}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    replica_dir = Application.get_env(:deal_scout, :litestream_replica_dir, "/data/litestream")
    replica_summary = inspect_replica_dir(replica_dir)

    status = %{
      client_connected: state.connected_client != nil,
      connected_client: state.connected_client,
      last_sync_at: state.last_sync_at,
      last_ping_at: state.last_ping_at,
      files_synced_count: state.files_synced_count,
      bytes_synced_count: state.bytes_synced_count,
      last_file_sent: state.last_file_sent,
      replica_dir: replica_dir,
      replica_summary: replica_summary,
      uptime_seconds: System.monotonic_time(:second) - state.started_at
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    {:reply, :ok, initial_state()}
  end

  @impl true
  def handle_cast({:client_connected, client_id, metadata}, state) do
    now = DateTime.utc_now()
    Logger.info("[DealScout.Backup] Client connected: #{client_id} (meta: #{inspect(metadata)})")

    client_info =
      metadata
      |> Map.put(:client_id, client_id)
      |> Map.put(:connected_at, now)
      |> Map.put(:last_seen_at, now)

    {:noreply, %{state | connected_client: client_info, last_ping_at: now}}
  end

  @impl true
  def handle_cast({:client_disconnected, client_id}, state) do
    Logger.info("[DealScout.Backup] Client disconnected: #{client_id}")

    new_connected =
      case state.connected_client do
        %{client_id: ^client_id} -> nil
        other -> other
      end

    {:noreply, %{state | connected_client: new_connected}}
  end

  @impl true
  def handle_cast({:record_file_sent, file_path, byte_size}, state) do
    now = DateTime.utc_now()

    new_state = %{
      state
      | last_sync_at: now,
        last_file_sent: file_path,
        files_synced_count: state.files_synced_count + 1,
        bytes_synced_count: state.bytes_synced_count + byte_size
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:record_ping, _client_id}, state) do
    now = DateTime.utc_now()

    new_client =
      if state.connected_client do
        Map.put(state.connected_client, :last_seen_at, now)
      else
        nil
      end

    {:noreply, %{state | last_ping_at: now, connected_client: new_client}}
  end

  defp initial_state do
    %{
      connected_client: nil,
      last_sync_at: nil,
      last_ping_at: nil,
      files_synced_count: 0,
      bytes_synced_count: 0,
      last_file_sent: nil,
      started_at: System.monotonic_time(:second)
    }
  end

  defp inspect_replica_dir(replica_dir) do
    if File.dir?(replica_dir) do
      generations_dir = Path.join(replica_dir, "generations")

      if File.dir?(generations_dir) do
        case File.ls(generations_dir) do
          {:ok, gens} ->
            %{
              exists: true,
              generations_count: length(gens),
              generations: Enum.sort(gens)
            }

          _ ->
            %{exists: true, generations_count: 0, generations: []}
        end
      else
        %{exists: true, generations_count: 0, generations: []}
      end
    else
      %{exists: false, generations_count: 0, generations: []}
    end
  end
end
