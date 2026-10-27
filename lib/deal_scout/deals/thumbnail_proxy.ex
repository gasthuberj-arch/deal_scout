defmodule DealScout.Deals.ThumbnailProxy do
  @moduledoc """
  The **Deal thumbnail proxy** module for DealScout.

  Provides a deep module interface for proxying, caching, and concurrency-limiting
  remote deal thumbnail images. Reliably serves deal thumbnails to mobile and ad-blocked
  clients via the same-origin server with zero cross-origin or anti-hotlinking issues.

  Encapsulates:
  - Level 1 in-memory ETS cache with hard capacity cap (`@max_entries 150`, ~1-2 MB max RAM).
  - Level 2 persistent disk cache surviving restarts and deploys.
  - Concurrency permit limiter (`@max_concurrent 4`) with caller deadline expiration,
    cancellation on caller timeout, and monitor slot reclamation to prevent connection stampedes.
  - Size constraint enforcement (`@max_item_bytes 60_000` = 60 KB).
  - Injectable HTTP fetcher seam satisfying the Two-Adapter Rule (ReqAdapter in prod, TestAdapter in tests).
  - Graceful fallback redirect to direct upstream CDN URLs on saturation, timeout, or errors.
  """

  use GenServer
  require Logger

  alias DealScout.Repo
  alias DealScout.Deals.Deal

  @table :deal_image_cache
  @max_entries 150
  @max_item_bytes 60_000
  @ttl_seconds 900
  @disk_ttl_seconds 3_600
  @sweep_interval_ms 300_000
  @max_concurrent 4
  @default_permit_timeout 3_000

  # ============================================================================
  # Public Interface
  # ============================================================================

  @doc """
  Starts the ThumbnailProxy GenServer supervising the cache table, disk sweeper,
  and concurrency queue.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Fetches or serves a cached deal thumbnail.

  Returns:
  - `{:ok, content_type, body}` on cache hit or successful upstream proxying.
  - `{:redirect, external_url}` when upstream fails, times out, or concurrency is saturated.
  - `:not_found` when the deal does not exist or has no image URL.
  """
  @spec get_thumbnail(term(), keyword()) ::
          {:ok, String.t(), binary()} | {:redirect, String.t()} | :not_found
  def get_thumbnail(deal_id, opts \\ []) do
    case normalize_id(deal_id) do
      nil ->
        :not_found

      id ->
        case get_cached(id) do
          {:ok, content_type, body} ->
            {:ok, content_type, body}

          :miss ->
            fetch_and_cache(id, opts)
        end
    end
  end

  @doc """
  Manually inserts an image into the tiered cache.
  Useful for tests and background pre-warming.
  """
  def put(deal_id, content_type, body) when is_binary(body) do
    case normalize_id(deal_id) do
      nil -> {:error, :invalid_id}
      id -> put_raw(id, content_type, body)
    end
  end

  def put(_, _, _), do: {:error, :invalid_body}

  @doc """
  Returns the current number of in-memory ETS entries.
  """
  def size do
    :ets.info(@table, :size)
  rescue
    _ -> 0
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

  @doc false
  def cache_dir do
    Application.get_env(
      :deal_scout,
      :image_cache_dir,
      Path.join(System.tmp_dir!(), "deal_scout_image_cache")
    )
  end

  @doc false
  def disk_path(deal_id) do
    Path.join(cache_dir(), "#{deal_id}.cache")
  end

  @doc false
  def acquire_permit(timeout \\ @default_permit_timeout) do
    req_ref = make_ref()

    try do
      GenServer.call(__MODULE__, {:acquire, req_ref, timeout}, timeout)
    catch
      :exit, _ ->
        GenServer.cast(__MODULE__, {:cancel_acquire, req_ref})
        {:error, :busy}
    end
  end

  @doc false
  def release_permit(ref) do
    GenServer.cast(__MODULE__, {:release, ref})
  end

  @doc false
  def adapter do
    Application.get_env(
      :deal_scout,
      :thumbnail_fetcher,
      DealScout.Deals.ThumbnailProxy.ReqAdapter
    )
  end

  # ============================================================================
  # Internal Cache & Concurrency Pipeline
  # ============================================================================

  defp get_cached(deal_id) do
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
            insert_ets(deal_id, content_type, body)
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

  defp fetch_and_cache(deal_id, opts) do
    case Repo.get(Deal, deal_id) do
      %Deal{image_url: url} when is_binary(url) and url != "" ->
        timeout = Keyword.get(opts, :permit_timeout, @default_permit_timeout)

        with {:ok, ref} <- acquire_permit(timeout) do
          try do
            execute_fetch(deal_id, url, opts)
          after
            release_permit(ref)
          end
        else
          {:error, :busy} ->
            {:redirect, url}
        end

      _ ->
        :not_found
    end
  end

  defp execute_fetch(deal_id, url, opts) do
    case fetch_upstream(url, opts) do
      {:ok, %{status: 200, body: body} = resp}
      when is_binary(body) and byte_size(body) <= @max_item_bytes ->
        content_type = extract_content_type(resp)
        _ = put_raw(deal_id, content_type, body)
        {:ok, content_type, body}

      {:ok, %{status: 200, body: body} = resp} when is_binary(body) ->
        content_type = extract_content_type(resp)
        {:ok, content_type, body}

      _ ->
        {:redirect, url}
    end
  end

  defp fetch_upstream(url, opts) do
    fetcher = Keyword.get(opts, :fetcher)

    result =
      cond do
        is_function(fetcher, 1) ->
          fetcher.(url)

        true ->
          configured = adapter()

          cond do
            is_function(configured, 1) ->
              configured.(url)

            is_atom(configured) and function_exported?(configured, :fetch, 1) ->
              configured.fetch(url)

            true ->
              DealScout.Deals.ThumbnailProxy.ReqAdapter.fetch(url)
          end
      end

    case result do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
      other -> {:ok, other}
    end
  rescue
    e ->
      Logger.debug("[ThumbnailProxy] Upstream fetch failed for #{url}: #{Exception.message(e)}")
      {:error, :fetch_failed}
  end

  defp extract_content_type(%Req.Response{} = resp) do
    case Req.Response.get_header(resp, "content-type") do
      [ct | _] when is_binary(ct) -> ct
      _ -> "image/jpeg"
    end
  end

  defp extract_content_type(%{headers: headers}) when is_map(headers) do
    Map.get(headers, "content-type", "image/jpeg")
  end

  defp extract_content_type(%{headers: headers}) when is_list(headers) do
    case List.keyfind(headers, "content-type", 0) do
      {_, ct} when is_binary(ct) -> ct
      _ -> "image/jpeg"
    end
  end

  defp extract_content_type(_), do: "image/jpeg"

  defp put_raw(deal_id, content_type, body) when is_binary(body) do
    if byte_size(body) > @max_item_bytes do
      {:error, :too_large}
    else
      insert_ets(deal_id, content_type, body)
      write_to_disk(deal_id, content_type, body)
      :ok
    end
  end

  defp insert_ets(deal_id, content_type, body) do
    try do
      if :ets.info(@table, :size) >= @max_entries do
        prune_oldest()
      end

      :ets.insert(@table, {deal_id, content_type, body, System.monotonic_time(:second)})
    rescue
      _ -> :ok
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

  defp normalize_id(id) when is_integer(id) and id > 0, do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} when int_id > 0 -> int_id
      _ -> nil
    end
  end

  defp normalize_id(_), do: nil

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

  # ============================================================================
  # GenServer Callbacks (Permit Queue & Periodic Sweep)
  # ============================================================================

  @impl true
  def init(opts) do
    table =
      case :ets.info(@table) do
        :undefined ->
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

        _ ->
          @table
      end

    File.mkdir_p!(cache_dir())
    schedule_sweep()

    max_concurrent = Keyword.get(opts, :max_concurrent, @max_concurrent)

    {:ok,
     %{
       table: table,
       active: %{},
       queue: :queue.new(),
       max_concurrent: max_concurrent
     }}
  end

  @impl true
  def handle_call({:acquire, req_ref, timeout}, {from_pid, _} = from, state) do
    if map_size(state.active) < state.max_concurrent do
      mref = Process.monitor(from_pid)
      new_active = Map.put(state.active, mref, from_pid)
      {:reply, {:ok, mref}, %{state | active: new_active}}
    else
      deadline = System.monotonic_time(:millisecond) + timeout
      new_queue = :queue.in({from, req_ref, deadline}, state.queue)
      {:noreply, %{state | queue: new_queue}}
    end
  end

  @impl true
  def handle_cast({:release, mref}, state) do
    Process.demonitor(mref, [:flush])
    new_active = Map.delete(state.active, mref)
    {:noreply, advance_queue(%{state | active: new_active})}
  end

  @impl true
  def handle_cast({:cancel_acquire, req_ref}, state) do
    filtered_list =
      state.queue
      |> :queue.to_list()
      |> Enum.reject(fn {_from, ref, _deadline} -> ref == req_ref end)

    new_queue = :queue.from_list(filtered_list)
    {:noreply, %{state | queue: new_queue}}
  end

  @impl true
  def handle_info({:DOWN, mref, :process, _pid, _reason}, state) do
    new_active = Map.delete(state.active, mref)
    {:noreply, advance_queue(%{state | active: new_active})}
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
      cutoff_time = System.os_time(:second) - @disk_ttl_seconds

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

  defp advance_queue(state) do
    if map_size(state.active) < state.max_concurrent do
      case :queue.out(state.queue) do
        {{:value, {{from_pid, _} = from, _req_ref, deadline}}, rest_queue} ->
          now = System.monotonic_time(:millisecond)

          if now <= deadline and Process.alive?(from_pid) do
            mref = Process.monitor(from_pid)
            new_active = Map.put(state.active, mref, from_pid)
            GenServer.reply(from, {:ok, mref})
            %{state | active: new_active, queue: rest_queue}
          else
            advance_queue(%{state | queue: rest_queue})
          end

        {:empty, _} ->
          state
      end
    else
      state
    end
  end
end
