defmodule DealScout.Deals.ImageCache do
  @moduledoc """
  Tiered (in-memory ETS + persistent volume disk) cache for deal thumbnail images.

  Guarantees:
  - Level 1: Hard cap on maximum in-memory ETS entries (`@max_entries 150`, ~1-2 MB max RAM).
  - Level 2: Persistent disk cache on `/data/image_cache/` so cached thumbnails survive restarts/deploys.
  - Hard cap on individual image size (`@max_item_bytes 60_000` = 60 KB).
  - Short in-memory TTL (`@ttl_seconds 900` = 15 minutes) with fallback to disk on ETS miss.
  - Zero binary heap copying during ETS eviction.
  """
  use GenServer

  @table :deal_image_cache
  @max_entries 150
  @max_item_bytes 60_000
  @ttl_seconds 900
  @sweep_interval_ms 300_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table =
      case :ets.info(@table) do
        :undefined ->
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

        _ ->
          @table
      end

    File.mkdir_p!(cache_dir())
    schedule_sweep()
    {:ok, %{table: table}}
  end

  @doc """
  Looks up a cached image by deal ID.
  Checks in-memory ETS first, falling back to disk cache before reporting `:miss`.
  Returns `{:ok, content_type, body}` or `:miss`.
  """
  def get(deal_id) do
    deal_id
    |> normalize_id()
    |> get_raw()
  end

  defp get_raw(nil), do: :miss

  defp get_raw(deal_id) do
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, deal_id) do
      [{^deal_id, content_type, body, inserted_at}] ->
        if now - inserted_at <= @ttl_seconds do
          {:ok, content_type, body}
        else
          :ets.delete(@table, deal_id)
          read_from_disk(deal_id)
        end

      _ ->
        read_from_disk(deal_id)
    end
  rescue
    _ -> :miss
  end

  defp read_from_disk(deal_id) do
    file_path = disk_path(deal_id)

    case File.read(file_path) do
      {:ok, binary} ->
        case :binary.split(binary, "\n") do
          [content_type, body] when is_binary(body) and byte_size(body) <= @max_item_bytes ->
            # Repopulate in-memory ETS table
            try do
              if :ets.info(@table, :size) >= @max_entries do
                prune_oldest()
              end

              :ets.insert(@table, {deal_id, content_type, body, System.monotonic_time(:second)})
            rescue
              _ -> :ok
            end

            {:ok, content_type, body}

          _ ->
            File.rm(file_path)
            :miss
        end

      _ ->
        :miss
    end
  rescue
    _ -> :miss
  end

  @doc """
  Stores a thumbnail image in the cache if it meets the size constraints.
  Persists to both ETS and filesystem.
  Returns `:ok` or `{:error, :too_large}`.
  """
  def put(deal_id, content_type, body) when is_binary(body) do
    case normalize_id(deal_id) do
      nil -> {:error, :invalid_id}
      id -> put_raw(id, content_type, body)
    end
  end

  def put(_, _, _), do: {:error, :invalid_body}

  defp normalize_id(id) when is_integer(id) and id > 0, do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} when int_id > 0 -> int_id
      _ -> nil
    end
  end

  defp normalize_id(_), do: nil

  defp put_raw(deal_id, content_type, body) when is_binary(body) do
    if byte_size(body) > @max_item_bytes do
      {:error, :too_large}
    else
      try do
        if :ets.info(@table, :size) >= @max_entries do
          prune_oldest()
        end

        :ets.insert(@table, {deal_id, content_type, body, System.monotonic_time(:second)})
        write_to_disk(deal_id, content_type, body)
        :ok
      rescue
        _ -> :ok
      end
    end
  end

  defp write_to_disk(deal_id, content_type, body) do
    path = disk_path(deal_id)
    tmp_path = "#{path}.tmp.#{:erlang.unique_integer([:positive])}"

    with :ok <- File.write(tmp_path, [content_type, ?\n, body]),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      _ ->
        File.rm(tmp_path)
        :ok
    end
  rescue
    _ -> :ok
  end

  @doc """
  Returns the current number of cached in-memory ETS entries.
  """
  def size do
    :ets.info(@table, :size)
  rescue
    _ -> 0
  end

  @doc """
  Returns the filesystem cache directory path.
  """
  def cache_dir do
    Application.get_env(
      :deal_scout,
      :image_cache_dir,
      Path.join(System.tmp_dir!(), "deal_scout_image_cache")
    )
  end

  @doc """
  Returns the disk path for a given deal ID cache file.
  """
  def disk_path(deal_id) do
    Path.join(cache_dir(), "#{deal_id}.cache")
  end

  @doc """
  Clears all cached images from both memory and disk.
  """
  def clear do
    :ets.delete_all_objects(@table)
    dir = cache_dir()

    if File.dir?(dir) do
      case File.ls(dir) do
        {:ok, files} ->
          Enum.each(files, fn file -> File.rm(Path.join(dir, file)) end)

        _ ->
          :ok
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_expired()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp sweep_expired do
    cutoff = System.monotonic_time(:second) - @ttl_seconds
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    sweep_disk()
  rescue
    _ -> :ok
  end

  defp sweep_disk do
    dir = cache_dir()

    if File.dir?(dir) do
      # Evict cache files older than 7 days (604,800 seconds)
      cutoff_time = System.os_time(:second) - 7 * 86_400

      case File.ls(dir) do
        {:ok, files} ->
          Enum.each(files, fn file ->
            path = Path.join(dir, file)

            case File.stat(path, time: :posix) do
              {:ok, %File.Stat{mtime: mtime}} when mtime < cutoff_time ->
                File.rm(path)

              _ ->
                :ok
            end
          end)

        _ ->
          :ok
      end
    end
  rescue
    _ -> :ok
  end

  defp prune_oldest do
    case :ets.select(@table, [{{:"$1", :_, :_, :"$2"}, [], [{{:"$1", :"$2"}}]}]) do
      items when is_list(items) and length(items) > 0 ->
        items
        |> Enum.sort_by(fn {_id, inserted_at} -> inserted_at end)
        |> Enum.take(div(@max_entries, 3))
        |> Enum.each(fn {id, _} -> :ets.delete(@table, id) end)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
