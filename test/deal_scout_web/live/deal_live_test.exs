defmodule DealScoutWeb.DealLiveTest do
  use DealScoutWeb.ConnCase
  import Phoenix.LiveViewTest

  alias DealScout.Repo
  alias DealScout.Feeds.Feed

  setup do
    feed =
      Repo.insert!(%Feed{name: "MyDealz", slug: "mydealz", url: "https://www.mydealz.de/rss"})

    {:ok, deal} =
      DealScout.Deals.insert_deal(%{
        feed_id: feed.id,
        guid: "deal-12345",
        title: "Apple MacBook Air M3 16GB",
        url: "https://example.com/deal",
        clean_text: "Great laptop discount",
        price: Decimal.new("1099.00"),
        merchant: "Amazon",
        temperature: 194,
        idealo_url: "https://www.idealo.de/preisvergleich/OffersOfProduct/macbook.html",
        geizhals_url: "https://geizhals.de/macbook-air-m3.html",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    %{feed: feed, deal: deal}
  end

  test "disconnected and connected mount of deals stream", %{conn: conn, deal: deal} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Deal Scout"
    assert html =~ "Real-Time"
    assert html =~ deal.title
    assert html =~ "1099"

    # Temperature badge rendered
    assert html =~ "194°"

    # Comparison links rendered
    assert html =~ "Idealo Chart"
    assert html =~ "Geizhals History"

    # Search filtering
    assert render(view) =~ deal.title

    html_filtered =
      view
      |> element("#deal-search-form")
      |> render_change(%{"q" => "NonexistentProductXYZ"})

    refute html_filtered =~ deal.title
  end

  test "opens safety interstitial modal on high risk deal", %{conn: conn, feed: feed} do
    {:ok, risky_deal} =
      DealScout.Deals.insert_deal(%{
        feed_id: feed.id,
        guid: "deal-risky-999",
        title: "Super Cheap OLED TV - Nur Vorkasse",
        url: "https://scam-store.xyz/deal",
        clean_text: "Achtung nur Vorkasse per Überweisung!",
        price: Decimal.new("199.00"),
        merchant: "ScamStore",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, view, _html} = live(conn, ~p"/")

    # High risk deal is classified as high_risk
    assert risky_deal.merchant.trust_level == "high_risk"

    # Click the Open Deal button on the high risk card
    view
    |> element("button[phx-click='open_high_risk_modal'][phx-value-id='#{risky_deal.id}']")
    |> render_click()

    # Modal appears
    assert render(view) =~ "Security Notice"
    assert render(view) =~ "Never pay via direct bank transfer"

    # Dismiss modal
    view
    |> element("button[phx-click='dismiss_interstitial']")
    |> render_click()

    refute render(view) =~ "Security Notice"
  end

  test "renders duplicate deal pills and toggles grouping", %{conn: conn, feed: feed1} do
    feed2 =
      Repo.insert!(%Feed{
        name: "DealDoktor",
        slug: "dealdoktor",
        url: "https://www.dealdoktor.de/feed/"
      })

    {:ok, orig} =
      DealScout.Deals.insert_deal(%{
        feed_id: feed1.id,
        guid: "deal-ps5-orig",
        title: "Sony PlayStation 5 Slim Digital",
        url: "https://www.amazon.de/dp/B0CLT544NZ",
        price: Decimal.new("399.00"),
        merchant: "Amazon",
        published_at: DateTime.utc_now()
      })

    {:ok, dup} =
      DealScout.Deals.insert_deal(%{
        feed_id: feed2.id,
        guid: "deal-ps5-dup",
        title: "PS5 Slim Digital Konsole",
        url: "https://www.amazon.de/dp/B0CLT544NZ?tag=dd-21",
        price: Decimal.new("395.00"),
        merchant: "Amazon",
        published_at: DateTime.utc_now()
      })

    assert dup.canonical_deal_id == orig.id

    {:ok, view, html} = live(conn, ~p"/")

    # Canonical deal is visible
    assert html =~ orig.title
    # "Also on:" pill is rendered with DealDoktor and price
    assert html =~ "Also on:"
    assert html =~ "DealDoktor"
    assert html =~ "395"

    # Click Toggle Group Duplicates
    view
    |> element("button[phx-click='toggle_group_deals']")
    |> render_click()

    # When ungrouped, both deals appear in stream
    updated_html = render(view)
    assert updated_html =~ orig.title
    assert updated_html =~ dup.title
  end

  test "renders country badge and foreign keyboard warning banner", %{conn: conn, feed: feed} do
    {:ok, _fr_laptop} =
      DealScout.Deals.insert_deal(%{
        feed_id: feed.id,
        guid: "deal-laptop-fr",
        title: "ASUS ZenBook 14 OLED Laptop",
        url: "https://www.amazon.fr/dp/B08N5WRWNW",
        clean_text: "Top Notebook mit Intel Core Ultra",
        price: Decimal.new("899.00"),
        merchant: "Amazon FR",
        published_at: DateTime.utc_now()
      })

    {:ok, _view, html} = live(conn, ~p"/")

    # Country badge rendered
    assert html =~ "🇫🇷"
    assert html =~ "France"

    # Foreign keyboard alert banner rendered
    assert html =~ "Foreign Keyboard Layout"
    assert html =~ "AZERTY"
  end

  test "infinite scroll marker is rendered and load_more event appends deals", %{
    conn: conn,
    feed: feed
  } do
    for i <- 1..35 do
      {:ok, _} =
        DealScout.Deals.insert_deal(%{
          feed_id: feed.id,
          guid: "deal-scroll-#{i}",
          title: "Unique Gadget Model #{i}",
          url: "https://example#{i}.com/scroll-#{i}",
          price: Decimal.new("#{50 + i}.00"),
          merchant: "MerchantShop#{i}",
          published_at: DateTime.utc_now() |> DateTime.add(-i * 60, :second)
        })
    end

    {:ok, view, html} = live(conn, ~p"/")

    # Initial page loads with infinite scroll marker
    assert html =~ "infinite-scroll-marker"
    assert html =~ "Loading more deals..."

    # Trigger load_more
    view
    |> element("#infinite-scroll-marker button")
    |> render_click()

    updated_html = render(view)
    assert updated_html =~ "Unique Gadget Model 35"
  end
end
