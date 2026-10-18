defmodule DealScoutWeb.AnalyticsLiveTest do
  use DealScoutWeb.ConnCase
  import Phoenix.LiveViewTest

  alias DealScout.Repo
  alias DealScout.Deals
  alias DealScout.Feeds.Feed

  setup do
    user = DealScout.AccountsFixtures.user_fixture()

    feed =
      Repo.insert!(%Feed{name: "MyDealz", slug: "mydealz", url: "https://www.mydealz.de/rss"})

    {:ok, deal} =
      Deals.insert_deal(%{
        feed_id: feed.id,
        guid: "deal-analytics-live",
        title: "Sony PlayStation 5",
        url: "https://www.amazon.de/dp/B0CLT544NZ",
        price: Decimal.new("449.00"),
        merchant: "Amazon",
        temperature: 250,
        published_at: DateTime.utc_now()
      })

    %{user: user, feed: feed, deal: deal}
  end

  test "redirects unauthenticated user to log in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/analytics")
  end

  test "authenticated user views analytics dashboard and updates metrics", %{
    conn: conn,
    user: user,
    deal: deal
  } do
    conn = log_in_user(conn, user)
    {:ok, view, html} = live(conn, ~p"/analytics")

    assert html =~ "Deal Market Intelligence"
    assert html =~ "Total Deals Ingested"
    assert html =~ "Duplicates Consolidated"
    assert html =~ "Ingestion Velocity"
    assert html =~ "MyDealz"
    assert html =~ deal.merchant.name

    # Trigger refresh
    assert view
           |> element("button[phx-click='refresh']")
           |> render_click() =~ "Analytics metrics updated."
  end
end
