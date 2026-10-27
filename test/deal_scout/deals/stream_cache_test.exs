defmodule DealScout.Deals.StreamCacheTest do
  use DealScout.DataCase, async: false

  alias DealScout.Deals
  alias DealScout.Deals.StreamCache
  alias DealScout.Feeds.Feed

  setup do
    StreamCache.clear()

    feed =
      Repo.insert!(%Feed{
        name: "CacheTest Feed",
        slug: "cachetest-feed",
        url: "https://example.com/rss",
        is_active: true
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, deal} =
      Deals.insert_deal(%{
        feed_id: feed.id,
        guid: "cache-deal-1",
        title: "Sony PlayStation 5 Pro",
        clean_text: "Brand new console discount",
        url: "https://example.com/ps5",
        price: Decimal.new("699.00"),
        merchant: "MediaMarkt",
        published_at: now
      })

    StreamCache.clear()

    %{feed: feed, deal: deal, now: now}
  end

  describe "StreamCache deep interface" do
    test "fetch/3 caches on cacheable opts and evicts when TTL passes" do
      called_count = :atomics.new(1, [])

      compute_fn = fn ->
        :atomics.add(called_count, 1, 1)
        ["computed-item-1"]
      end

      opts = [feed_id: 42]

      # First fetch with past TTL inserts an immediately expired entry
      assert ["computed-item-1"] = StreamCache.fetch(opts, compute_fn, -1_000)
      assert :atomics.get(called_count, 1) == 1

      # Second fetch detects expired entry and recomputes with fresh TTL
      assert ["computed-item-1"] = StreamCache.fetch(opts, compute_fn, 5_000)
      assert :atomics.get(called_count, 1) == 2

      # Third fetch hits the fresh cache without recomputing
      assert ["computed-item-1"] = StreamCache.fetch(opts, compute_fn, 5_000)
      assert :atomics.get(called_count, 1) == 2
    end

    test "fetch/3 bypasses cache when opts are not cacheable" do
      called_count = :atomics.new(1, [])

      compute_fn = fn ->
        :atomics.add(called_count, 1, 1)
        ["uncached-result"]
      end

      # Search query should bypass cache
      assert ["uncached-result"] = StreamCache.fetch([search: "laptop"], compute_fn)
      assert :atomics.get(called_count, 1) == 1

      assert ["uncached-result"] = StreamCache.fetch([search: "laptop"], compute_fn)
      assert :atomics.get(called_count, 1) == 2

      # Offset > 0 should bypass cache
      assert ["uncached-result"] = StreamCache.fetch([offset: 30], compute_fn)
      assert :atomics.get(called_count, 1) == 3

      # min_temperature should bypass cache
      assert ["uncached-result"] = StreamCache.fetch([min_temperature: 100], compute_fn)
      assert :atomics.get(called_count, 1) == 4

      # None of these bypassed calls populated the cache
      assert StreamCache.size() == 0
    end

    test "invalidate/1 selectively purges matching feed and global all stream" do
      # Populate feed 10, feed 20, and all
      StreamCache.fetch([feed_id: 10], fn -> [:feed_10] end)
      StreamCache.fetch([feed_id: 20], fn -> [:feed_20] end)
      StreamCache.fetch([], fn -> [:all_feeds] end)

      assert StreamCache.size() == 3

      # Invalidate feed 10 (should remove feed 10 and all, but keep feed 20)
      StreamCache.invalidate(feed_id: 10)
      assert StreamCache.size() == 1

      # Invalidate all without feed_id clears everything
      StreamCache.invalidate()
      assert StreamCache.size() == 0
    end
  end

  describe "Deals.list_deals integration" do
    test "list_deals/1 caches stream results and invalidates on broadcast_deal", %{
      feed: feed,
      deal: deal,
      now: now
    } do
      results1 = Deals.list_deals(feed_id: feed.id)
      assert length(results1) == 1
      assert hd(results1).id == deal.id

      # Insert a second deal directly into Repo (bypassing ingestion broadcast)
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
      results = Deals.list_deals(search: "PlayStation")
      assert Enum.any?(results, &(&1.id == deal.id))

      results = Deals.list_deals(search: "discount")
      assert Enum.any?(results, &(&1.id == deal.id))

      results = Deals.list_deals(search: "MediaMarkt")
      assert Enum.any?(results, &(&1.id == deal.id))

      results = Deals.list_deals(search: "XBoxNonexistentXYZ")
      refute Enum.any?(results, &(&1.id == deal.id))
    end
  end
end
