defmodule DealScout.Deals.ImageCache do
  @moduledoc """
  In-memory ETS cache for deal thumbnail images.
  Caches proxied deal images so mobile devices on adblockers/private DNS
  can load images reliably without re-fetching from external CDNs.
  """
  use GenServer

  @table :deal_image_cache
  @max_entries 500

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @doc """
  Looks up a cached image by deal ID. Returns `{:ok, content_type, body}` or `:miss`.
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
    case :ets.lookup(@table, deal_id) do
      [{^deal_id, content_type, body, _inserted_at}] ->
        {:ok, content_type, body}

      _ ->
        :miss
    end
  rescue
    _ -> :miss
  end

  @doc """
  Stores a fetched image in the cache.
  """
  def put(deal_id, content_type, body) when is_binary(deal_id) do
    case Integer.parse(deal_id) do
      {int_id, ""} -> put_raw(int_id, content_type, body)
      _ -> put_raw(deal_id, content_type, body)
    end
  end

  def put(deal_id, content_type, body) when is_integer(deal_id),
    do: put_raw(deal_id, content_type, body)

  def put(_, _, _), do: :ok

  defp put_raw(deal_id, content_type, body) when is_binary(body) do
    try do
      if :ets.info(@table, :size) > @max_entries do
        prune_cache()
      end

      :ets.insert(@table, {deal_id, content_type, body, System.monotonic_time(:second)})
      :ok
    rescue
      _ -> :ok
    end
  end

  defp prune_cache do
    try do
      :ets.tab2list(@table)
      |> Enum.sort_by(fn {_id, _ct, _body, ts} -> ts end)
      |> Enum.take(div(@max_entries, 2))
      |> Enum.each(fn {id, _, _, _} -> :ets.delete(@table, id) end)
    rescue
      _ -> :ok
    end
  end
end
