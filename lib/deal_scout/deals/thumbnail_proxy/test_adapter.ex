defmodule DealScout.Deals.ThumbnailProxy.TestAdapter do
  @moduledoc """
  In-memory test double adapter for deal thumbnail fetching.
  Provides deterministic offline responses without external HTTP calls.
  """

  @table :deal_scout_test_thumbnail_responses
  @default_image <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>

  def fetch(url) when is_binary(url) do
    ensure_table()

    case lookup_response(url) do
      {:ok, resp} ->
        {:ok, resp}

      {:error, reason} ->
        {:error, reason}

      fun when is_function(fun, 1) ->
        fun.(url)

      %{} = resp ->
        {:ok, resp}

      nil ->
        {:ok,
         %{
           status: 200,
           body: @default_image,
           headers: [{"content-type", "image/png"}]
         }}
    end
  end

  def put_response(url, response) do
    ensure_table()
    :ets.insert(@table, {url, response})
    :ok
  end

  def reset do
    if :ets.info(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  defp ensure_table do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

      _ ->
        @table
    end
  rescue
    _ -> @table
  end

  defp lookup_response(url) do
    case :ets.lookup(@table, url) do
      [{^url, resp}] -> resp
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
