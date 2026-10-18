defmodule DealScout.Deals.DeduplicatorTest do
  use DealScout.DataCase

  alias DealScout.Repo
  alias DealScout.Deals
  alias DealScout.Deals.Deduplicator
  alias DealScout.Feeds.Feed

  setup do
    feed1 =
      Repo.insert!(%Feed{name: "MyDealz", slug: "mydealz", url: "https://www.mydealz.de/rss"})

    feed2 =
      Repo.insert!(%Feed{
        name: "DealDoktor",
        slug: "dealdoktor",
        url: "https://www.dealdoktor.de/feed/"
      })

    %{feed1: feed1, feed2: feed2}
  end

  test "token_similarity calculates Jaccard similarity without stop words" do
    title_a = "Sony WH-1000XM5 Wireless Kopfhörer mit ANC für 249€"
    title_b = "Sony WH-1000XM5 Wireless Kopfhörer Noise Cancelling"

    similarity = Deduplicator.token_similarity(title_a, title_b)
    assert similarity >= 0.50
  end

  test "matches_deal? by Amazon ASIN", %{feed1: feed1, feed2: _feed2} do
    {:ok, deal1} =
      Deals.insert_deal(%{
        feed_id: feed1.id,
        guid: "deal-asin-1",
        title: "Apple iPhone 15 128GB Black",
        url: "https://www.amazon.de/dp/B0CHX1TNVL?tag=md-21",
        price: Decimal.new("749.00"),
        merchant: "Amazon",
        published_at: DateTime.utc_now()
      })

    # Same product posted on DealDoktor with slightly different affiliate url & title
    candidate = %{
      title: "Apple iPhone 15 128GB Schwarz Deal",
      price: Decimal.new("749.00"),
      url: "https://www.amazon.de/gp/product/B0CHX1TNVL?ref=dd_deal",
      merchant_id: deal1.merchant_id,
      published_at: DateTime.utc_now()
    }

    canonical = Deduplicator.find_canonical_deal(candidate)
    assert canonical != nil
    assert canonical.id == deal1.id
  end

  test "matches_deal? by title similarity and ±3% price tolerance", %{feed1: feed1} do
    {:ok, deal1} =
      Deals.insert_deal(%{
        feed_id: feed1.id,
        guid: "deal-title-1",
        title: "LG OLED55C37LA 4K Smart TV 120Hz",
        url: "https://www.mediamarkt.de/de/product/_lg-oled55c37la.html",
        price: Decimal.new("1000.00"),
        merchant: "MediaMarkt",
        published_at: DateTime.utc_now()
      })

    # Same product within 3% price tolerance (1020€ is +2%)
    candidate = %{
      title: "LG OLED 55 C37LA 4K TV",
      price: Decimal.new("1020.00"),
      url: "https://www.mediamarkt.de/de/product/_lg-oled55c37la.html?partner=123",
      merchant_id: deal1.merchant_id,
      published_at: DateTime.utc_now()
    }

    canonical = Deduplicator.find_canonical_deal(candidate)
    assert canonical != nil
    assert canonical.id == deal1.id
  end

  test "automatically links canonical_deal_id during insert_deal", %{feed1: feed1, feed2: feed2} do
    {:ok, original} =
      Deals.insert_deal(%{
        feed_id: feed1.id,
        guid: "guid-orig",
        title: "Sony PlayStation 5 Slim Digital",
        url: "https://www.amazon.de/dp/B0CLT544NZ",
        price: Decimal.new("399.00"),
        merchant: "Amazon",
        published_at: DateTime.utc_now()
      })

    assert original.canonical_deal_id == nil

    {:ok, duplicate} =
      Deals.insert_deal(%{
        feed_id: feed2.id,
        guid: "guid-dup",
        title: "PS5 Slim Digital Edition Konsole",
        url: "https://www.amazon.de/dp/B0CLT544NZ?tag=dd-21",
        price: Decimal.new("399.00"),
        merchant: "Amazon",
        published_at: DateTime.utc_now()
      })

    assert duplicate.canonical_deal_id == original.id

    # Verify grouping in list_deals
    grouped = Deals.list_deals(group_deals: true)
    assert length(grouped) == 1
    [canonical] = grouped
    assert canonical.id == original.id
    assert length(canonical.duplicates) == 1
    assert hd(canonical.duplicates).id == duplicate.id

    # Verify ungrouped list_deals returns both
    ungrouped = Deals.list_deals(group_deals: false)
    assert length(ungrouped) == 2
  end
end
