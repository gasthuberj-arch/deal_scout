defmodule DealScout.Maintenance.PrunerTest do
  use DealScout.DataCase

  alias DealScout.Maintenance.Pruner
  alias DealScout.Deals
  alias DealScout.Feeds.Feed
  alias DealScout.Repo

  describe "ms_until_next_run/3" do
    test "calculates time until 03:00 UTC on the same day when current time is before 03:00" do
      now = ~U[2026-10-25 01:30:00Z]
      # 1.5 hours = 5,400,000 ms
      assert Pruner.ms_until_next_run(now, 3, 0) == 5_400_000
    end

    test "calculates time until 03:00 UTC the next day when current time is at or after 03:00" do
      now = ~U[2026-10-25 03:00:00Z]
      # 24 hours = 86,400,000 ms
      assert Pruner.ms_until_next_run(now, 3, 0) == 86_400_000

      later = ~U[2026-10-25 15:00:00Z]
      # 12 hours = 43,200,000 ms
      assert Pruner.ms_until_next_run(later, 3, 0) == 43_200_000
    end
  end

  describe "pruning and all-time ingestion counters" do
    test "prunes deals older than retention days while preserving all-time feed ingestion stats" do
      feed =
        Repo.insert!(%Feed{
          name: "MyDealz",
          slug: "mydealz-prune-test",
          url: "https://www.mydealz.de/rss"
        })

      old_date = DateTime.utc_now() |> DateTime.add(-35 * 24 * 3600, :second)
      recent_date = DateTime.utc_now() |> DateTime.add(-5 * 24 * 3600, :second)

      {:ok, old_deal} =
        Deals.insert_deal(%{
          feed_id: feed.id,
          guid: "old-deal-guid-1",
          title: "Old MacBook Deal",
          url: "https://example.com/old",
          price: Decimal.new("899.00"),
          merchant: "Apple",
          temperature: 120,
          published_at: old_date
        })

      {:ok, recent_deal} =
        Deals.insert_deal(%{
          feed_id: feed.id,
          guid: "recent-deal-guid-1",
          title: "New iPad Deal",
          url: "https://example.com/new",
          price: Decimal.new("499.00"),
          merchant: "Apple",
          temperature: 200,
          published_at: recent_date
        })

      # Start pruner with skip_auto_vacuum_setup (inside SQL sandbox)
      pid =
        start_supervised!(
          {Pruner,
           name: :test_pruner,
           retention_days: 30,
           skip_auto_vacuum_setup: true,
           interval_ms: 60_000}
        )

      send(pid, :prune)
      _ = :sys.get_state(pid)

      # Old deal is deleted from DB, recent deal remains
      assert Repo.get(Deals.Deal, old_deal.id) == nil
      assert Repo.get(Deals.Deal, recent_deal.id) != nil

      # Feed all-time counter still reflects 2 total deals ingested
      updated_feed = Repo.get!(Feed, feed.id)
      assert updated_feed.total_deals_ingested == 2

      # Analytics reflects 2 total ingested deals and 1 in the last 30 days
      stats = DealScout.Analytics.compute_deal_intelligence_stats()
      assert stats.total_deals >= 2
      assert stats.deals_last_30d == 1

      feed_stat = Enum.find(stats.deals_by_feed, &(&1.feed_name == "MyDealz"))
      assert feed_stat.deal_count == 2
      assert feed_stat.deals_last_30d == 1
    end
  end
end
