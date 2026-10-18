defmodule DealScout.Deals.CacheTest do
  use DealScout.DataCase

  alias DealScout.Deals.Cache
  alias DealScout.Deals
  alias DealScout.Feeds.Feed
  alias DealScout.Repo

  test "cache starts, loads deals from db into ETS, and serves get_deals" do
    feed =
      Repo.insert!(%Feed{name: "MyDealz", slug: "mydealz", url: "https://www.mydealz.de/rss"})

    {:ok, deal} =
      Deals.insert_deal(%{
        feed_id: feed.id,
        guid: "cache-deal-1",
        title: "Apple AirPods Pro 2",
        url: "https://www.amazon.de/dp/B0BDHW48P2",
        price: Decimal.new("229.00"),
        merchant: "Amazon",
        temperature: 150,
        published_at: DateTime.utc_now()
      })

    # Start supervised cache in test process
    start_supervised!({Cache, []})

    # Trigger cache reload and wait for completion
    Cache.refresh()
    :timer.sleep(50)

    assert {:ok, cached_deals} = Cache.get_deals(limit: 10, offset: 0)
    assert length(cached_deals) >= 1
    assert Enum.any?(cached_deals, fn d -> d.id == deal.id end)
  end
end
