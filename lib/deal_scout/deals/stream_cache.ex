defmodule DealScout.Deals.StreamCache do
  @moduledoc false
  use GenServer

  @table :deal_scout_stream_cache

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

    {:ok, %{table: table}}
  end
end
