defmodule DealScout.AnalyticsTest do
  use DealScout.DataCase

  alias DealScout.Analytics
  alias DealScout.Repo
  alias DealScout.Deals
  alias DealScout.Feeds.Feed

  setup do
    feed =
      Repo.insert!(%Feed{name: "MyDealz", slug: "mydealz", url: "https://www.mydealz.de/rss"})

    {:ok, deal1} =
      Deals.insert_deal(%{
        feed_id: feed.id,
        guid: "analytics-deal-1",
        title: "Apple iPhone 15 Pro",
        url: "https://www.amazon.de/dp/B0CHX1TNVL",
        price: Decimal.new("999.00"),
        merchant: "Amazon",
        temperature: 150,
        published_at: DateTime.utc_now()
      })

    {:ok, deal2} =
      Deals.insert_deal(%{
        feed_id: feed.id,
        guid: "analytics-deal-2",
        title: "Apple iPhone 15 Pro Max",
        url: "https://www.amazon.de/dp/B0CHX1TNVL?tag=dup",
        price: Decimal.new("999.00"),
        merchant: "Amazon",
        temperature: 200,
        canonical_deal_id: deal1.id,
        published_at: DateTime.utc_now()
      })

    Analytics.invalidate_analytics_cache()

    %{feed: feed, deal1: deal1, deal2: deal2}
  end

  test "get_deal_intelligence_stats returns accurate aggregated metrics" do
    stats = Analytics.get_deal_intelligence_stats()

    assert stats.total_deals >= 2
    assert stats.total_duplicates >= 1
    assert stats.canonical_deals == stats.total_deals - stats.total_duplicates
    assert stats.avg_temperature > 0.0
    assert length(stats.deals_by_feed) >= 1
  end

  test "get_deal_intelligence_stats caches result across calls until invalidated" do
    stats1 = Analytics.get_deal_intelligence_stats()

    # Inserting another deal won't immediately alter the cached stats
    feed = Repo.get_by!(Feed, slug: "mydealz")

    {:ok, _deal3} =
      Deals.insert_deal(%{
        feed_id: feed.id,
        guid: "analytics-deal-cached-test",
        title: "Apple iPad Air",
        url: "https://www.amazon.de/dp/B0CHX1TTEST",
        price: Decimal.new("599.00"),
        merchant: "Amazon",
        temperature: 300,
        published_at: DateTime.utc_now()
      })

    stats2 = Analytics.get_deal_intelligence_stats()
    assert stats2.total_deals == stats1.total_deals

    # When invalidated, fresh stats are computed
    Analytics.invalidate_analytics_cache()
    stats3 = Analytics.get_deal_intelligence_stats()
    assert stats3.total_deals == stats1.total_deals + 1
  end

  test "Analytics refreshes cache on demand" do
    Analytics.invalidate_analytics_cache()

    Analytics.refresh_now()

    stats = Analytics.get_deal_intelligence_stats()
    assert is_map(stats)
    assert stats.total_deals >= 2
  end

  test "get_system_ops_stats returns presence count, users, and feed health" do
    ops = Analytics.get_system_ops_stats()

    assert is_integer(ops.active_sessions_count)
    assert is_integer(ops.total_users_count)
    assert is_list(ops.feeds_status)
    assert is_float(ops.beam_memory_mb)
    assert is_integer(ops.uptime_seconds)
  end
end
