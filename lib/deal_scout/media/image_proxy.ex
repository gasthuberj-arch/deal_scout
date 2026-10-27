defmodule DealScout.Media.ImageProxy do
  @moduledoc """
  The **Deal thumbnail proxy** module for DealScout.

  Safely fetches, caches, and serves deal thumbnail images for mobile and
  ad-blocked clients, encapsulating single-flight request coalescing,
  remote HTTP retrieval via `Req`, Content-Type extraction, and bounded
  in-memory ETS caching behind a small fetch interface.
  """

  use GenServer
  require Logger

  alias DealScout.Repo
  alias DealScout.Deals.Deal

  @table :deal_image_cache
  @max_entries 500
  @req_timeout 4_000

  # ============================================================================
  # Public Interface
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Fetches an image for the given deal ID.
  Returns:
  - `{:ok, content_type, body}` on cache hit or successful remote fetch
  - `{:redirect, url}` when remote fetch fails or returns non-200
  - `{:error, :not_found}` when deal does not exist or has no image_url
  """
  def fetch_image(deal_id) do
    normalized_id = normalize_id(deal_id)

    case lookup(normalized_id) do
      {:ok, content_type, body} ->
        {:ok, content_type, body}

      :miss ->
        if GenServer.whereis(__MODULE__) do
          GenServer.call(__MODULE__, {:coalesced_fetch, normalized_id}, 15_000)
        else
          # Fallback if GenServer is not running (e.g. isolated test environments)
          perform_fetch(normalized_id)
        end
    end
  end

  @doc """
  Explicitly stores a fetched image in the cache. Primarily used in tests and manual seeding.
  """
  def put_cached_image(deal_id, content_type, body) when is_binary(body) do
    normalized_id = normalize_id(deal_id)
    safe_insert(normalized_id, content_type, body)
  end

  def put_cached_image(_deal_id, _content_type, _body), do: :ok

  @doc """
  Invalidates a cached image by deal ID.
  """
  def invalidate(deal_id) do
    normalized_id = normalize_id(deal_id)

    try do
      :ets.delete(@table, normalized_id)
      :ok
    rescue
      _ -> :ok
    end
  end

  @doc """
  Clears the entire image cache.
  """
  def clear do
    try do
      :ets.delete_all_objects(@table)
      :ok
    rescue
      _ -> :ok
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    table =
      case :ets.info(@table) do
        :undefined ->
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

        _ ->
          @table
      end

    {:ok, %{table: table, pending: %{}}}
  end

  @impl true
  def handle_call({:coalesced_fetch, deal_id}, from, state) do
    # Double check ETS in case a concurrent fetch already completed
    case lookup(deal_id) do
      {:ok, content_type, body} ->
        {:reply, {:ok, content_type, body}, state}

      :miss ->
        case Map.get(state.pending, deal_id) do
          nil ->
            # First caller: register waiter and spawn worker task
            server = self()

            Task.start(fn ->
              result = perform_fetch(deal_id)
              send(server, {:fetch_complete, deal_id, result})
            end)

            new_pending = Map.put(state.pending, deal_id, [from])
            {:noreply, %{state | pending: new_pending}}

          waiters ->
            # Subsequent caller: coalesce onto existing in-flight task
            new_pending = Map.put(state.pending, deal_id, [from | waiters])
            {:noreply, %{state | pending: new_pending}}
        end
    end
  end

  @impl true
  def handle_info({:fetch_complete, deal_id, result}, state) do
    {waiters, new_pending} = Map.pop(state.pending, deal_id, [])

    # Reply to all coalesced callers
    Enum.each(waiters, fn from ->
      GenServer.reply(from, result)
    end)

    # Prune cache in background GenServer if limit exceeded
    maybe_prune()

    {:noreply, %{state | pending: new_pending}}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp lookup(deal_id) do
    case :ets.lookup(@table, deal_id) do
      [{^deal_id, content_type, body, _ts}] -> {:ok, content_type, body}
      _ -> :miss
    end
  rescue
    _ -> :miss
  end

  defp perform_fetch(deal_id) do
    case Repo.get(Deal, deal_id) do
      %Deal{image_url: url} when is_binary(url) and url != "" ->
        case fetch_remote_image(url) do
          {:ok, content_type, body} ->
            safe_insert(deal_id, content_type, body)
            {:ok, content_type, body}

          {:error, _reason} ->
            {:redirect, url}
        end

      _ ->
        {:error, :not_found}
    end
  rescue
    e ->
      Logger.warning("[ImageProxy] Error fetching deal #{deal_id}: #{Exception.message(e)}")
      {:error, :not_found}
  end

  defp fetch_remote_image(url) do
    case Req.get(url,
           headers: [
             {"user-agent",
              "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"},
             {"accept", "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"}
           ],
           receive_timeout: @req_timeout,
           max_retries: 1
         ) do
      {:ok, %Req.Response{status: 200, body: body} = resp} when is_binary(body) ->
        content_type = extract_content_type(resp)
        {:ok, content_type, body}

      other ->
        {:error, other}
    end
  rescue
    e ->
      {:error, e}
  end

  defp extract_content_type(resp) do
    case Req.Response.get_header(resp, "content-type") do
      [ct | _] when is_binary(ct) -> ct
      ct when is_binary(ct) -> ct
      _ -> "image/jpeg"
    end
  end

  defp safe_insert(deal_id, content_type, body) do
    try do
      :ets.insert(@table, {deal_id, content_type, body, System.monotonic_time(:second)})
      :ok
    rescue
      _ -> :ok
    end
  end

  defp maybe_prune do
    try do
      if :ets.info(@table, :size) > @max_entries do
        :ets.tab2list(@table)
        |> Enum.sort_by(fn {_id, _ct, _body, ts} -> ts end)
        |> Enum.take(div(@max_entries, 2))
        |> Enum.each(fn {id, _, _, _} -> :ets.delete(@table, id) end)
      end
    rescue
      _ -> :ok
    end
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> int_id
      _ -> id
    end
  end

  defp normalize_id(id), do: id
end
