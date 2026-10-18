defmodule DealScoutWeb.DealLiveTest do
  use DealScoutWeb.ConnCase
  import Phoenix.LiveViewTest

  alias DealScout.Repo
  alias DealScout.Feeds.Feed
  alias DealScout.Deals.Deal

  setup do
    feed =
      Repo.insert!(%Feed{name: "MyDealz", slug: "mydealz", url: "https://www.mydealz.de/rss"})

    deal =
      Repo.insert!(%Deal{
        feed_id: feed.id,
        guid: "deal-12345",
        title: "Apple MacBook Air M3 16GB",
        url: "https://example.com/deal",
        clean_text: "Great laptop discount",
        price: Decimal.new("1099.00"),
        merchant: "Amazon",
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

    # Search filtering
    assert render(view) =~ deal.title

    html_filtered =
      view
      |> element("form")
      |> render_change(%{"q" => "NonexistentProductXYZ"})

    refute html_filtered =~ deal.title
  end
end
