defmodule DealScoutWeb.MatchLiveTest do
  use DealScoutWeb.ConnCase
  import Phoenix.LiveViewTest

  alias DealScout.Repo
  alias DealScout.Feeds.Feed
  alias DealScout.Alerts.{AlertRule, UserMatch}

  setup :register_and_log_in_user

  setup %{user: user} do
    feed =
      Repo.insert!(%Feed{name: "MyDealz", slug: "mydealz", url: "https://www.mydealz.de/rss"})

    {:ok, deal} =
      DealScout.Deals.insert_deal(%{
        feed_id: feed.id,
        guid: "deal-match-123",
        title: "Sony WH-1000XM5 Noise Cancelling Headphones",
        url: "https://example.com/headphones",
        clean_text: "Top active noise cancelling bluetooth headphones",
        price: Decimal.new("269.00"),
        merchant: "MediaMarkt",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    rule =
      Repo.insert!(%AlertRule{
        user_id: user.id,
        name: "Sony Headphones",
        keywords: "Sony WH-1000XM5",
        is_active: true
      })

    match =
      Repo.insert!(%UserMatch{
        user_id: user.id,
        deal_id: deal.id,
        alert_rule_id: rule.id,
        is_read: false
      })

    %{feed: feed, deal: deal, rule: rule, match: match}
  end

  test "renders matched deals and allows marking as read", %{
    conn: conn,
    deal: deal,
    rule: rule,
    match: match
  } do
    {:ok, index_live, html} = live(conn, ~p"/matches")

    assert html =~ "Matched Deals"
    assert html =~ "1 new"
    assert html =~ deal.title
    assert html =~ rule.name

    # Toggle chime sound
    assert html =~ "Chime On"
    html = index_live |> element("button[phx-click='toggle_sound']") |> render_click()
    assert html =~ "Muted"

    # Mark single match as read
    html =
      index_live
      |> element("button[phx-click='mark_read'][phx-value-id='#{match.id}']")
      |> render_click()

    refute html =~ "1 new"
  end
end
