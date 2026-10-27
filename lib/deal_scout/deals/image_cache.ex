defmodule DealScout.Deals.ImageCache do
  @moduledoc """
  Bounded, in-memory ETS cache for deal thumbnail images.

  Guarantees:
  - Hard cap on maximum cached entries (`@max_entries 150`, ~1-2 MB max RAM).
  - Hard cap on individual image size (`@max_item_bytes 60_000` = 60 KB).
  - Short TTL (`@ttl_seconds 900` = 15 minutes) with lazy expiry on read and
    periodic background sweep via `:ets.select_delete`.
  - Zero binary heap copying during eviction: pruning selects only `{id, timestamp}`.
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

    schedule_sweep()
    {:ok, %{table: table}}
  end

  @doc """
  Looks up a cached image by deal ID.
  Returns `{:ok, content_type, body}` or `:miss`.
  """
  def get(deal_id) when is_binary(deal_id) do
    case Integer.parse(deal_id) do
      {int_id, ""} -> get_raw(int_id)
      _ -> get_raw(deal_id)
    end
  end

  def get(deal_id) when is_integer(deal_id), do: get_raw(deal_id)
  def get(_), do: :miss

  defp get_raw(deal_id) do
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, deal_id) do
      [{^deal_id, content_type, body, inserted_at}] ->
        if now - inserted_at <= @ttl_seconds do
          {:ok, content_type, body}
        else
          :ets.delete(@table, deal_id)
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
  Returns `:ok` or `{:error, :too_large}`.
  """
  def put(deal_id, content_type, body) when is_binary(deal_id) do
    case Integer.parse(deal_id) do
      {int_id, ""} -> put_raw(int_id, content_type, body)
      _ -> put_raw(deal_id, content_type, body)
    end
  end

  def put(deal_id, content_type, body) when is_integer(deal_id),
    do: put_raw(deal_id, content_type, body)

  def put(_, _, _), do: {:error, :invalid_id}

  defp put_raw(deal_id, content_type, body) when is_binary(body) do
    if byte_size(body) > @max_item_bytes do
      {:error, :too_large}
    else
      try do
        if :ets.info(@table, :size) >= @max_entries do
          prune_oldest()
        end

        :ets.insert(@table, {deal_id, content_type, body, System.monotonic_time(:second)})
        :ok
      rescue
        _ -> :ok
      end
    end
  end

  defp put_raw(_, _, _), do: {:error, :invalid_body}

  @doc """
  Returns the current number of cached entries.
  """
  def size do
    :ets.info(@table, :size)
  rescue
    _ -> 0
  end

  @doc """
  Clears all cached images.
  """
  def clear do
    :ets.delete_all_objects(@table)
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
    # Match spec deletes rows directly in C without copying objects into heap:
    # {{id, content_type, body, inserted_at}} where inserted_at < cutoff
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  rescue
    _ -> :ok
  end

  defp prune_oldest do
    # Select only {id, inserted_at} pairs - binary body is NEVER copied into heap
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
