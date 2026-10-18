defmodule DealScout.Deals do
  @moduledoc """
  The Deals context for managing ingested deal records.
  """

  import Ecto.Query, warn: false
  alias DealScout.Repo
  alias DealScout.Deals.Deal

  @pubsub DealScout.PubSub
  @topic "deals:feed"

  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  def broadcast_deal({:ok, %Deal{} = deal} = result) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:new_deal, deal})
    result
  end

  def broadcast_deal(error), do: error

  @doc """
  Lists deals with optional filters:
  - :search - text query matching title or clean_text
  - :feed_id - filter by feed
  - :limit - max records (default 50)
  - :offset - pagination offset
  """
  def list_deals(opts \\ []) do
    search = Keyword.get(opts, :search)
    feed_id = Keyword.get(opts, :feed_id)
    limit = Keyword.get(opts, :limit, 60)
    offset = Keyword.get(opts, :offset, 0)

    Deal
    |> join(:inner, [d], f in assoc(d, :feed), as: :feed)
    |> preload([d, feed: f], feed: f)
    |> filter_by_search(search)
    |> filter_by_feed(feed_id)
    |> order_by([d], desc: d.published_at, desc: d.id)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  defp filter_by_search(query, nil), do: query
  defp filter_by_search(query, ""), do: query

  defp filter_by_search(query, search_term) do
    term = "%#{search_term}%"

    where(
      query,
      [d],
      like(d.title, ^term) or like(d.clean_text, ^term) or like(d.merchant, ^term)
    )
  end

  defp filter_by_feed(query, nil), do: query
  defp filter_by_feed(query, "all"), do: query

  defp filter_by_feed(query, feed_id) when is_integer(feed_id) do
    where(query, [d], d.feed_id == ^feed_id)
  end

  defp filter_by_feed(query, feed_id_str) when is_binary(feed_id_str) do
    case Integer.parse(feed_id_str) do
      {id, ""} -> where(query, [d], d.feed_id == ^id)
      _ -> query
    end
  end

  def get_deal!(id) do
    Deal
    |> preload(:feed)
    |> Repo.get!(id)
  end

  @doc """
  Inserts a single deal, ignoring duplicate guid.
  Returns {:ok, deal} or {:duplicate, guid}
  """
  def insert_deal(attrs) do
    %Deal{}
    |> Deal.changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: :guid
    )
    |> case do
      {:ok, %Deal{id: nil}} ->
        {:duplicate, attrs[:guid] || attrs["guid"]}

      {:ok, %Deal{} = deal} ->
        deal = Repo.preload(deal, :feed)
        broadcast_deal({:ok, deal})

      error ->
        error
    end
  end

  @doc """
  Bulk inserts a list of parsed deal attribute maps.
  Returns list of newly created %Deal{} structs.
  """
  def insert_new_deals(deal_attrs_list) when is_list(deal_attrs_list) do
    Enum.reduce(deal_attrs_list, [], fn attrs, acc ->
      case insert_deal(attrs) do
        {:ok, deal} -> [deal | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Deletes deals older than given number of days.
  """
  def prune_old_deals(days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second)

    from(d in Deal, where: d.published_at < ^cutoff)
    |> Repo.delete_all()
  end
end
