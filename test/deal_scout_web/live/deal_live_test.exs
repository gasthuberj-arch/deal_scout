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
end
