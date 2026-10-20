defmodule DealScout.Deals.CacheTest do
  use DealScout.DataCase, async: false

  alias DealScout.Deals
  alias DealScout.Deals.Cache
  alias DealScout.Feeds.Feed

  setup do
    feed =
      Repo.insert!(%Feed{
        name: "CacheTest Feed",
        slug: "cachetest-feed",
        url: "https://example.com/rss",
        is_active: true
      })

    {:ok, deal} =
      Deals.insert_deal(%{
        feed_id: feed.id,
        guid: "cache-deal-1",
        title: "Sony PlayStation 5 Pro",
        clean_text: "Brand new console discount",
        url: "https://example.com/ps5",
        price: Decimal.new("699.00"),
        merchant: "MediaMarkt",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    %{feed: feed, deal: deal}
  end

  test "fetch_active_feeds/1 caches feeds and invalidates on feed update", %{feed: feed} do
    Cache.invalidate_feeds()

    call_count = :atomics.new(1, [])
    :atomics.put(call_count, 1, 0)

    fallback = fn ->
      :atomics.add(call_count, 1, 1)
      [feed]
    end

    # First fetch executes fallback
    result1 = Cache.fetch_active_feeds(fallback)
    assert length(result1) == 1
    assert :atomics.get(call_count, 1) == 1

    # Second fetch reads directly from ETS
    result2 = Cache.fetch_active_feeds(fallback)
    assert length(result2) == 1
    assert :atomics.get(call_count, 1) == 1

    # Invalidation clears the ETS entry
    Cache.invalidate_feeds()
    result3 = Cache.fetch_active_feeds(fallback)
    assert length(result3) == 1
    assert :atomics.get(call_count, 1) == 2
  end

  test "fetch_deals/2 caches default deals and invalidates on broadcast_deal", %{deal: deal} do
    Cache.invalidate_deals()

    opts = [limit: 60, offset: 0, group_deals: true]
    call_count = :atomics.new(1, [])
    :atomics.put(call_count, 1, 0)

    fallback = fn ->
      :atomics.add(call_count, 1, 1)
      [deal]
    end

    # First fetch hits fallback
    res1 = Cache.fetch_deals(opts, fallback)
    assert length(res1) == 1
    assert :atomics.get(call_count, 1) == 1

    # Second fetch hits cache
    res2 = Cache.fetch_deals(opts, fallback)
    assert length(res2) == 1
    assert :atomics.get(call_count, 1) == 1

    # Broadcast triggers invalidation
    Deals.broadcast_deal(deal)

    res3 = Cache.fetch_deals(opts, fallback)
    assert length(res3) == 1
    assert :atomics.get(call_count, 1) == 2
  end

  test "FTS5 search finds deals by title, keyword, and merchant", %{deal: deal} do
    # Search by title word prefix
    results = Deals.list_deals(search: "PlayStation")
    assert Enum.any?(results, &(&1.id == deal.id))

    # Search by clean_text word
    results = Deals.list_deals(search: "discount")
    assert Enum.any?(results, &(&1.id == deal.id))

    # Search by merchant
    results = Deals.list_deals(search: "MediaMarkt")
    assert Enum.any?(results, &(&1.id == deal.id))

    # Nonexistent search returns empty
    results = Deals.list_deals(search: "XBoxNonexistentXYZ")
    refute Enum.any?(results, &(&1.id == deal.id))
  end
end
