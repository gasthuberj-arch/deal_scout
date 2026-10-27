defmodule DealScout.Deals.StreamCacheTest do
  use DealScout.DataCase, async: false

  alias DealScout.Deals
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

    Deals.invalidate_stream_cache()

    %{feed: feed, deal: deal}
  end

  test "list_deals/1 caches stream results and invalidates on broadcast_deal", %{
    feed: feed,
    deal: deal
  } do
    # First call queries DB and populates ETS cache
    results1 = Deals.list_deals(feed_id: feed.id)
    assert length(results1) == 1
    assert hd(results1).id == deal.id

    # Insert a second deal directly into Repo (bypassing ingestion broadcast)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    deal2 =
      Repo.insert!(%DealScout.Deals.Deal{
        feed_id: feed.id,
        merchant_id: deal.merchant_id,
        guid: "cache-deal-2",
        title: "Nintendo Switch OLED",
        clean_text: "Portable console deal",
        url: "https://example.com/switch",
        price: Decimal.new("299.00"),
        published_at: now
      })

    # Second call hits ETS cache, so deal2 is not yet in cached results
    results2 = Deals.list_deals(feed_id: feed.id)
    assert length(results2) == 1
    assert hd(results2).id == deal.id

    # Broadcasting deal2 triggers targeted cache invalidation
    Deals.broadcast_deal(deal2)

    # Next call fetches fresh results containing both deals
    results3 = Deals.list_deals(feed_id: feed.id)
    assert length(results3) == 2
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
