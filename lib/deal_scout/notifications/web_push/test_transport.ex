defmodule DealScout.Notifications.WebPush.TestTransport do
  @moduledoc """
  In-memory test double transport for Web Push notifications.
  Captures delivered notifications and allows stubbing responses (e.g. 201 Created or 410 Gone).
  """
  @behaviour DealScout.Notifications.WebPush.Transport

  @table :deal_scout_test_web_push_table

  @impl true
  def post(endpoint, body, headers) do
    ensure_table()

    # Record notification delivery
    record_delivery(endpoint, body, headers)

    case lookup_response(endpoint) do
      {:ok, resp} ->
        {:ok, resp}

      {:error, reason} ->
        {:error, reason}

      fun when is_function(fun, 3) ->
        fun.(endpoint, body, headers)

      nil ->
        {:ok, %{status: 201, body: ""}}
    end
  end

  def stub_endpoint(endpoint, response) do
    ensure_table()
    :ets.insert(@table, {{:stub, endpoint}, response})
    :ok
  end

  def stub_default(response) do
    ensure_table()
    :ets.insert(@table, {:default_stub, response})
    :ok
  end

  def delivered_notifications do
    ensure_table()

    :ets.tab2list(@table)
    |> Enum.filter(fn
      {{:delivery, _id}, _val} -> true
      _ -> false
    end)
    |> Enum.map(fn {{:delivery, _id}, val} -> val end)
    |> Enum.reverse()
  end

  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp record_delivery(endpoint, body, headers) do
    id = System.unique_integer([:monotonic, :positive])
    :ets.insert(@table, {{:delivery, id}, %{endpoint: endpoint, body: body, headers: headers}})
  end

  defp lookup_response(endpoint) do
    case :ets.lookup(@table, {:stub, endpoint}) do
      [{{:stub, ^endpoint}, resp}] ->
        resp

      [] ->
        case :ets.lookup(@table, :default_stub) do
          [{:default_stub, resp}] -> resp
          [] -> nil
        end
    end
  end

  defp ensure_table do
    case :ets.info(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      _ ->
        @table
    end
  end
end
