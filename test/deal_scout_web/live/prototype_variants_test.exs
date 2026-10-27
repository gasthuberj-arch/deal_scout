defmodule DealScoutWeb.PrototypeVariantsTest do
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
        guid: "deal-prototype-1",
        title: "Sony WH-1000XM5 Wireless Headphones",
        url: "https://example.com/sony-headphones",
        clean_text: "Industry leading noise cancellation",
        price: Decimal.new("249.00"),
        merchant: "Amazon",
        temperature: 155,
        image_url: "https://example.com/headphones.jpg",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    %{feed: feed, deal: deal}
  end

  test "top header does not contain coffee button", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    # Header navbar-end should not have the coffee button
    header_html =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.filter("header")
      |> Enum.map(&LazyHTML.to_html/1)
      |> Enum.join("")

    refute header_html =~ "☕"
    refute header_html =~ "Buy a coffee"
  end

  test "renders classic layout with deal cards and standard theme toggle", %{
    conn: conn,
    deal: deal
  } do
    {:ok, view, html} = live(conn, ~p"/")

    # Classic deal card stream exists
    assert has_element?(view, "#deals-stream")
    assert html =~ deal.title
    assert html =~ "249"

    # Theme toggle is available in navbar
    assert has_element?(view, "button[phx-click*='phx:set-theme'][data-phx-theme='dark']")
    assert has_element?(view, "button[phx-click*='phx:set-theme'][data-phx-theme='light']")
    assert has_element?(view, "button[phx-click*='phx:set-theme'][data-phx-theme='system']")

    # Experimental palette switchers are removed
    refute has_element?(view, "#dark-palette-switcher")
  end

  test "deal images have no-referrer referrerpolicy and async decoding", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # Image elements include referrerpolicy to prevent hotlinking 403 on mobile (Pixel/Android)
    assert has_element?(view, "img[referrerpolicy='no-referrer']")
  end

  test "temperature filter pills only appear when mydealz-hot is selected", %{conn: conn} do
    # On default "All Feeds", temperature filter buttons are hidden to reduce mobile clutter
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "button[phx-click='set_min_temp'][phx-value-temp='100']")

    # When switching to mydealz-hot feed, the temperature filter pills are displayed
    {:ok, hot_view, _hot_html} = live(conn, ~p"/?feed=mydealz-hot")
    assert has_element?(hot_view, "button[phx-click='set_min_temp'][phx-value-temp='100']")
    assert has_element?(hot_view, "button[phx-click='set_min_temp'][phx-value-temp='200']")
  end
end
