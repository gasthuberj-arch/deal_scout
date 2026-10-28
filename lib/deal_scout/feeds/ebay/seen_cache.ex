defmodule DealScout.Feeds.Ebay.SeenCache do
  @moduledoc """
  High-throughput, low-memory ETS cache for seen eBay item IDs.

  Prevents evaluating rules or sending duplicate alerts on consecutive polls.
  Holds up to 5,000 item IDs in memory (~300 KB RAM) and prunes oldest entries
  when capacity is exceeded, ensuring zero SQLite disk overhead.
  """

  @table :seen_ebay_items
  @default_max_size 5_000

  @doc """
  Returns true if the item ID (or guid) has already been seen.
  """
  def seen?(id) when is_binary(id) do
    ensure_table_exists()
    :ets.member(@table, id)
  end

  def seen?(_), do: false

  @doc """
  Marks an item ID (or guid) as seen.
  """
  def put(id) when is_binary(id) do
    ensure_table_exists()
    now = System.os_time(:second)
    :ets.insert(@table, {id, now})
    :ok
  end

  def put(_), do: :ok

  @doc """
  Marks a list of item IDs (or guids) as seen.
  """
  def put_all(ids) when is_list(ids) do
    ensure_table_exists()
    now = System.os_time(:second)

    records =
      ids
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&{&1, now})

    :ets.insert(@table, records)
    :ok
  end

  @doc """
  Filters a list of items or maps, keeping only those that have not yet been seen.
  Extracts the item ID using `:guid`, `"guid"`, `:item_id`, or `"itemId"`.
  """
  def filter_unseen(items) when is_list(items) do
    ensure_table_exists()

    Enum.reject(items, fn item ->
      id = extract_id(item)
      seen?(id)
    end)
  end

  @doc """
  Returns the current number of tracked item IDs in the cache.
  """
  def size do
    ensure_table_exists()
    :ets.info(@table, :size) || 0
  end

  @doc """
  Prunes the cache if it exceeds `max_size` (default: 5,000).
  Removes the oldest entries to bring the cache back to target capacity.
  """
  def prune(max_size \\ @default_max_size) do
    ensure_table_exists()
    current_size = size()

    if current_size > max_size do
      excess = current_size - max_size

      # Collect all items sorted by inserted timestamp ascending
      oldest_keys =
        :ets.tab2list(@table)
        |> Enum.sort_by(fn {_id, inserted_at} -> inserted_at end)
        |> Enum.take(excess)
        |> Enum.map(fn {id, _} -> id end)

      Enum.each(oldest_keys, &:ets.delete(@table, &1))
      {:ok, length(oldest_keys)}
    else
      {:ok, 0}
    end
  end

  @doc """
  Clears all seen items from the cache.
  """
  def clear do
    ensure_table_exists()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp extract_id(item) when is_map(item) do
    Map.get(item, :guid) || Map.get(item, "guid") ||
      Map.get(item, :item_id) || Map.get(item, "itemId") ||
      Map.get(item, :id) || Map.get(item, "id")
  end

  defp extract_id(id) when is_binary(id), do: id
  defp extract_id(_), do: nil

  defp ensure_table_exists do
    case :ets.info(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> @table
        end

      _ ->
        @table
    end
  end
end
