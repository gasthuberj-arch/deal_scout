defmodule DealScout.Deals.Cache do
  @moduledoc """
  In-memory ETS read-cache for high-throughput deal stream rendering.
  Shields the SQLite database from read load when multiple users browse, filter,
  or scroll the live deals feed.
  """

  use GenServer
  require Logger
  import Ecto.Query, warn: false

  alias DealScout.Repo
  alias DealScout.Deals.Deal

  @table :deal_scout_deals_cache
  @cache_size 250

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns cached canonical deals matching common feed/filter options.
  Returns `{:ok, [Deal]}` or `:fallback` if the query should go to SQL.
  """
  def get_deals(opts \\ []) do
    search = Keyword.get(opts, :search)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 40)
    feed_id = Keyword.get(opts, :feed_id)
    merchant = Keyword.get(opts, :merchant)
    exclude_dropshippers = Keyword.get(opts, :exclude_dropshippers, false)
    min_temp = Keyword.get(opts, :min_temperature)
    group_deals = Keyword.get(opts, :group_deals, true)

    # If within cache window and no full-text search, serve directly from RAM
    if (is_nil(search) or search == "") and offset + limit <= @cache_size do
      case :ets.lookup(@table, :cached_deals) do
        [{:cached_deals, deals}] ->
          filtered =
            deals
            |> Enum.filter(fn d ->
              matches_filter?(d, feed_id, merchant, exclude_dropshippers, min_temp, group_deals)
            end)
            |> Enum.slice(offset, limit)

          {:ok, filtered}

        _ ->
          :fallback
      end
    else
      :fallback
    end
  rescue
    _ -> :fallback
  end

  @doc """
  Refreshes the ETS cache from the database.
  """
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create public ETS table with read concurrency
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

    # Load initial cache asynchronously so startup is fast
    send(self(), :load_initial_cache)

    {:ok, %{}}
  end

  @impl true
  def handle_info(:load_initial_cache, state) do
    load_cache_from_db()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    load_cache_from_db()
    {:noreply, state}
  end

  defp load_cache_from_db do
    deals =
      Deal
      |> join(:inner, [d], f in assoc(d, :feed), as: :feed)
      |> join(:left, [d], m in assoc(d, :merchant), as: :merchant)
      |> order_by([d], desc: d.published_at, desc: d.id)
      |> limit(@cache_size)
      |> preload([d, feed: f, merchant: m],
        feed: f,
        merchant: m,
        duplicates: [:feed, :merchant]
      )
      |> Repo.all()

    :ets.insert(@table, {:cached_deals, deals})
    Logger.debug("[DealScout.Cache] Cached #{length(deals)} recent deals in ETS.")
  rescue
    e ->
      Logger.warning(
        "[DealScout.Cache] Could not pre-populate deals cache: #{Exception.message(e)}"
      )
  end

  defp matches_filter?(deal, feed_id, merchant, exclude_dropshippers, min_temp, group_deals) do
    matches_feed? = is_nil(feed_id) or (deal.feed_id && deal.feed_id == feed_id)

    matches_merchant? =
      is_nil(merchant) or
        (deal.merchant && deal.merchant.slug == merchant)

    matches_dropshipper? =
      not exclude_dropshippers or
        is_nil(deal.merchant) or
        deal.merchant.trust_level != "dropshipper"

    matches_temperature? =
      is_nil(min_temp) or
        (not is_nil(deal.temperature) and deal.temperature >= min_temp)

    matches_grouping? =
      not group_deals or is_nil(deal.canonical_deal_id)

    matches_feed? and matches_merchant? and matches_dropshipper? and matches_temperature? and
      matches_grouping?
  end
end
