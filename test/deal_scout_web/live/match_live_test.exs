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
    {:ok, index_live, _html} = live(conn, ~p"/matches")

    assert has_element?(index_live, "#match-#{match.id}")
    assert has_element?(index_live, "#match-#{match.id}", deal.title)
    assert has_element?(index_live, "#match-#{match.id}", rule.name)

    # Toggle chime sound
    assert has_element?(index_live, "button[phx-click='toggle_sound']", "Chime On")
    index_live |> element("button[phx-click='toggle_sound']") |> render_click()
    assert has_element?(index_live, "button[phx-click='toggle_sound']", "Muted")

    # Mark single match as read
    index_live
    |> element("button[phx-click='mark_read'][phx-value-id='#{match.id}']")
    |> render_click()

    refute has_element?(index_live, "#match-#{match.id} .badge-info", "NEW")
  end

  test "highlights target deal when ?highlight=ID query parameter is passed", %{
    conn: conn,
    match: match
  } do
    {:ok, index_live, _html} = live(conn, ~p"/matches?highlight=#{match.id}")

    assert has_element?(index_live, "#match-#{match.id}")
    assert has_element?(index_live, "#match-#{match.id}", "Target Deal")
  end

  test "displays Idealo comparison link and cross-border warnings on matched deal", %{
    conn: conn,
    user: user,
    feed: feed,
    rule: rule
  } do
    {:ok, foreign_deal} =
      DealScout.Deals.insert_deal(%{
        feed_id: feed.id,
        guid: "deal-foreign-laptop-1",
        title: "ASUS Vivobook 15 [Amazon.es]",
        url: "https://amazon.es/dp/B0123",
        clean_text: "Top Laptop mit AZERTY Tastatur",
        price: Decimal.new("499.00"),
        idealo_url: "https://www.idealo.de/preisvergleich/OffersOfProduct/12345.html",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    match =
      Repo.insert!(%UserMatch{
        user_id: user.id,
        deal_id: foreign_deal.id,
        alert_rule_id: rule.id,
        is_read: false
      })

    {:ok, index_live, _html} = live(conn, ~p"/matches")

    # Idealo button is present with correct link
    assert has_element?(
             index_live,
             "a[href='https://www.idealo.de/preisvergleich/OffersOfProduct/12345.html']",
             "Idealo"
           )

    # Cross-border Spanish origin flag and keyboard badge
    assert has_element?(index_live, "#match-#{match.id}", "ES")
    assert has_element?(index_live, "#match-#{match.id}", "Non-German Keyboard Layout detected")
  end
end
