defmodule DealScout.Backup.Watcher do
  @moduledoc """
  Monitors the Litestream local replica directory (`/data/litestream`),
  indexes generations, snapshots, and WAL frames, and broadcasts
  newly created frames to connected backup channel subscribers in near real-time.
  """
  use GenServer
  require Logger

  @pubsub DealScout.PubSub
  @pubsub_topic "backup:internal"
  @default_poll_interval_ms 2_000

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns all current replica files with their relative paths, sizes, and sha256 checksums.
  """
  def list_files(server \\ __MODULE__) do
    GenServer.call(server, :list_files)
  end

  @doc """
  Scans the replica directory directly and returns a map of all files.
  """
  def scan_replica(replica_dir) do
    if File.dir?(replica_dir) do
      replica_dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.reject(&File.dir?/1)
      |> Enum.map(fn full_path ->
        rel_path = Path.relative_to(full_path, replica_dir)
        stat = File.stat!(full_path)
        sha256 = calculate_sha256(full_path)

        mtime_iso =
          case NaiveDateTime.from_erl(stat.mtime) do
            {:ok, ndt} -> NaiveDateTime.to_iso8601(ndt)
            _ -> nil
          end

        %{
          path: rel_path,
          full_path: full_path,
          size: stat.size,
          mtime: mtime_iso,
          sha256: sha256
        }
      end)
    else
      []
    end
  end

  @doc """
  Given the client's current state (a list or map of files/generations it already has),
  returns the list of missing relative file paths that need to be sent.
  """
  def missing_files_for_client(client_state, replica_dir \\ nil) do
    dir = replica_dir || get_replica_dir()
    current_files = scan_replica(dir)

    have_files =
      case client_state do
        %{"have_files" => files} when is_list(files) ->
          MapSet.new(files)

        files when is_list(files) ->
          MapSet.new(files)

        %{"have_generations" => gens} when is_map(gens) ->
          # Filter based on latest indices if available
          filter_by_generations(current_files, gens)

        _ ->
          MapSet.new()
      end

    case have_files do
      %MapSet{} = set ->
        current_files
        |> Enum.reject(fn f -> MapSet.member?(set, f.path) end)
        |> Enum.sort_by(& &1.path)

      filtered_files when is_list(filtered_files) ->
        Enum.sort_by(filtered_files, & &1.path)
    end
  end

  @doc """
  Forces an immediate rescan of the replica directory.
  """
  def check_now(server \\ __MODULE__) do
    send(server, :poll)
    :ok
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    replica_dir = Keyword.get(opts, :replica_dir, get_replica_dir())
    poll_interval = Keyword.get(opts, :poll_interval_ms, get_poll_interval())

    enabled =
      Keyword.get(opts, :enabled, Application.get_env(:deal_scout, :backup_watcher_enabled, true))

    state = %{
      replica_dir: replica_dir,
      poll_interval_ms: poll_interval,
      enabled: enabled,
      known_files: %{}
    }

    # Initial scan
    initial_known =
      if enabled do
        scan_and_index(replica_dir)
      else
        %{}
      end

    state = %{state | known_files: initial_known}

    if enabled and poll_interval > 0 do
      schedule_poll(poll_interval)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:list_files, _from, state) do
    files =
      state.known_files
      |> Map.values()
      |> Enum.sort_by(& &1.path)

    {:reply, files, state}
  end

  @impl true
  def handle_info(:poll, state) do
    if state.enabled do
      current_indexed = scan_and_index(state.replica_dir)

      # Detect new or modified files
      Enum.each(current_indexed, fn {path, meta} ->
        case Map.get(state.known_files, path) do
          nil ->
            broadcast_new_file(meta)

          %{sha256: old_sha} when old_sha != meta.sha256 ->
            broadcast_new_file(meta)

          _already_known ->
            :ok
        end
      end)

      schedule_poll(state.poll_interval_ms)
      {:noreply, %{state | known_files: current_indexed}}
    else
      {:noreply, state}
    end
  end

  defp schedule_poll(interval_ms) when interval_ms > 0 do
    Process.send_after(self(), :poll, interval_ms)
  end

  defp schedule_poll(_), do: :ok

  defp scan_and_index(dir) do
    scan_replica(dir)
    |> Map.new(fn meta -> {meta.path, meta} end)
  end

  defp broadcast_new_file(meta) do
    Logger.info(
      "[DealScout.Backup] Discovered new replica frame: #{meta.path} (#{meta.size} bytes)"
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      @pubsub_topic,
      {:new_backup_file, meta.path, meta.full_path, meta.size, meta.sha256}
    )
  end

  defp filter_by_generations(current_files, gens) do
    # When client sends {"gen_id" => %{"latest_snapshot" => s, "latest_wal" => w}}
    Enum.filter(current_files, fn f ->
      # Check if file belongs to a generation the client already fully has
      case parse_litestream_path(f.path) do
        {:snapshot, gen_id, idx} ->
          client_snapshot = get_in(gens, [gen_id, "latest_snapshot"]) || -1
          idx > client_snapshot

        {:wal, gen_id, idx} ->
          client_wal = get_in(gens, [gen_id, "latest_wal"]) || -1
          idx > client_wal

        _ ->
          true
      end
    end)
  end

  defp parse_litestream_path(path) do
    # Format: generations/<gen_id>/snapshots/<idx>.snapshot.lz4 or generations/<gen_id>/wal/<idx>.wal.lz4
    parts = Path.split(path)

    case parts do
      ["generations", gen_id, "snapshots", filename] ->
        idx = parse_index(filename)
        {:snapshot, gen_id, idx}

      ["generations", gen_id, "wal", filename] ->
        idx = parse_index(filename)
        {:wal, gen_id, idx}

      _ ->
        :other
    end
  end

  defp parse_index(filename) do
    case Integer.parse(filename) do
      {int, _} -> int
      _ -> 0
    end
  end

  def calculate_sha256(path) do
    case File.read(path) do
      {:ok, data} ->
        :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

      _ ->
        nil
    end
  end

  defp get_replica_dir do
    Application.get_env(:deal_scout, :litestream_replica_dir, "/data/litestream")
  end

  defp get_poll_interval do
    Application.get_env(:deal_scout, :backup_watcher_poll_interval_ms, @default_poll_interval_ms)
  end
end
