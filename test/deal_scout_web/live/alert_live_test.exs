defmodule DealScoutWeb.AlertLiveTest do
  use DealScoutWeb.ConnCase
  import Phoenix.LiveViewTest

  alias DealScout.Alerts
  alias DealScout.Deals.{Deal, Merchant}
  alias DealScout.Feeds.Feed
  alias DealScout.Repo

  setup :register_and_log_in_user

  test "lists user alert rules and allows creating a new rule", %{conn: conn, user: user} do
    {:ok, index_live, html} = live(conn, ~p"/alerts")

    assert html =~ "Keyword Alert Rules"
    assert html =~ "No Alert Rules Configured Yet"

    # Open modal
    assert index_live |> element("a", "Add Alert Rule") |> render_click() =~ "Create Alert Rule"

    # Submit new rule form
    {:ok, _, html} =
      index_live
      |> form("form", %{
        "alert_rule" => %{
          "name" => "RTX 4080 Alert",
          "keywords" => "RTX 4080",
          "negative_keywords" => "defekt",
          "max_price" => "850.00",
          "source_filter" => "all"
        }
      })
      |> render_submit()
      |> follow_redirect(conn, ~p"/alerts")

    assert html =~ "Alert rule created successfully."
    assert html =~ "RTX 4080 Alert"
    assert html =~ "RTX 4080"
    assert html =~ "850"

    # Toggle active
    [rule] = Alerts.list_alert_rules_for_user(user.id)
    assert rule.is_active == true

    {:ok, index_live_updated, _} = live(conn, ~p"/alerts")

    index_live_updated
    |> element("button[phx-click='toggle_active']", "Pause")
    |> render_click()

    [updated_rule] = Alerts.list_alert_rules_for_user(user.id)
    assert updated_rule.is_active == false
  end

  test "creates rule with push notifications, country filters, and delivery modes", %{
    conn: conn,
    user: user
  } do
    {:ok, index_live, _} = live(conn, ~p"/alerts/new")

    {:ok, redirect_live, _html} =
      index_live
      |> form("form", %{
        "alert_rule" => %{
          "name" => "OLED TV Hunter",
          "keywords" => "\"LG G4 OLED\"",
          "country_filter" => "de_only",
          "merchant_filter" => "verified_only",
          "delivery_mode" => "hourly_digest",
          "notify_push" => "true",
          "notify_email" => "false",
          "exclude_foreign_keyboards" => "true"
        }
      })
      |> render_submit()
      |> follow_redirect(conn, ~p"/alerts")

    assert has_element?(redirect_live, "#rules", "OLED TV Hunter")
    assert has_element?(redirect_live, "#rules", "Push")
    assert has_element?(redirect_live, "#rules", "Hourly Digest")
    assert has_element?(redirect_live, "#rules", "DE Only")
    assert has_element?(redirect_live, "#rules", "Verified Stores")

    [rule] = Alerts.list_alert_rules_for_user(user.id)
    assert rule.country_filter == "de_only"
    assert rule.merchant_filter == "verified_only"
    assert rule.delivery_mode == "hourly_digest"
    assert rule.notify_push == true
    assert rule.exclude_foreign_keyboards == true
  end

  test "renders modal with autofill protection, explicit IDs, and sticky footer button", %{
    conn: conn
  } do
    {:ok, index_live, html} = live(conn, ~p"/alerts/new")

    assert has_element?(index_live, "#alert-rule-modal")
    assert has_element?(index_live, "#alert-rule-form[autocomplete='off']")
    assert has_element?(index_live, "#alert-rule-name-input[data-1p-ignore='true']")
    assert has_element?(index_live, "#alert-rule-keywords-input[data-1p-ignore='true']")
    assert has_element?(index_live, "#backtest-rule-btn[phx-click='backtest_rule']")
    assert has_element?(index_live, "#save-rule-btn[type='submit']")
    assert has_element?(index_live, "#cancel-rule-btn")
    assert has_element?(index_live, "#close-rule-modal-btn")

    # Verifies syntax help and proper quotes rendering (no raw unescaped &quot; displayed)
    assert html =~ "Search Operators &amp; Grouping Syntax"
    refute html =~ "&amp;quot;"
  end

  test "live validates form and displays real-time errors via phx-change", %{conn: conn} do
    {:ok, index_live, _} = live(conn, ~p"/alerts/new")

    # Send validate with invalid short name and keyword
    rendered =
      index_live
      |> form("#alert-rule-form", %{
        "alert_rule" => %{
          "name" => "A",
          "keywords" => "k"
        }
      })
      |> render_change()

    assert rendered =~ "should be at least 2 character"
  end

  test "edits existing rule with validation and updates successfully", %{conn: conn, user: user} do
    rule =
      DealScout.Repo.insert!(%DealScout.Alerts.AlertRule{
        user_id: user.id,
        name: "PlayStation 5",
        keywords: "PS5 Pro",
        max_price: Decimal.new("800.00"),
        is_active: true
      })

    {:ok, edit_live, _} = live(conn, ~p"/alerts/#{rule.id}/edit")

    assert has_element?(edit_live, "#alert-rule-modal")

    {:ok, _redirect_live, html} =
      edit_live
      |> form("#alert-rule-form", %{
        "alert_rule" => %{
          "name" => "PlayStation 5 Pro",
          "keywords" => "\"PS5 Pro\" Disc",
          "max_price" => "750.00"
        }
      })
      |> render_submit()
      |> follow_redirect(conn, ~p"/alerts")

    assert html =~ "Alert rule updated successfully."
    assert html =~ "PlayStation 5 Pro"

    updated = Alerts.get_user_alert_rule!(user.id, rule.id)
    assert updated.name == "PlayStation 5 Pro"
    assert updated.keywords == "\"PS5 Pro\" Disc"
    assert Decimal.equal?(updated.max_price, Decimal.new("750.00"))
  end

  test "handles PWA push subscription event and modal toggles", %{conn: conn} do
    {:ok, index_live, _html} = live(conn, ~p"/alerts")

    # Smart banner is shown
    assert has_element?(index_live, "#pwa-push-container")

    # Send iOS push status from client hook
    render_hook(index_live, "push-status", %{
      "supported" => true,
      "is_ios" => true,
      "is_standalone" => false,
      "subscribed" => false
    })

    assert has_element?(index_live, "button[phx-click='open_ios_modal']")

    # Open and close iOS instructions modal
    index_live |> element("button[phx-click='open_ios_modal']") |> render_click()
    assert has_element?(index_live, "#ios-install-modal")

    index_live |> element("#ios-install-modal button", "Got it") |> render_click()
    refute has_element?(index_live, "#ios-install-modal")

    # Save push subscription
    render_hook(index_live, "save-push-subscription", %{
      "endpoint" => "https://push.example.com/liveview-test",
      "p256dh" => "mock_p256dh",
      "auth" => "mock_auth",
      "device_name" => "Test iPhone"
    })

    assert has_element?(index_live, "#pwa-push-container")
  end

  test "backtests rule with past matching deal and displays green result card", %{conn: conn} do
    feed =
      Repo.insert!(%Feed{
        name: "MyDealz",
        slug: "mydealz-#{System.unique_integer([:positive])}",
        url: "https://example.com/rss"
      })

    merchant =
      Repo.insert!(%Merchant{
        name: "Mindfactory",
        slug: "mindfactory-#{System.unique_integer([:positive])}",
        trust_level: "verified"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%Deal{
      feed_id: feed.id,
      merchant_id: merchant.id,
      guid: "deal-rtx-super-#{System.unique_integer([:positive])}",
      title: "GIGABYTE GeForce RTX 4080 SUPER 16GB",
      clean_text: "Top Grafikkarte",
      url: "https://mindfactory.de/rtx",
      price: Decimal.new("989.00"),
      published_at: now
    })

    {:ok, index_live, _html} = live(conn, ~p"/alerts/new")

    # Initially no backtest result box is displayed
    refute has_element?(index_live, "#backtest-result")

    # Enter keywords and trigger validate
    index_live
    |> form("#alert-rule-form", %{
      "alert_rule" => %{
        "name" => "RTX Alert",
        "keywords" => "RTX 4080",
        "max_price" => "1050.00"
      }
    })
    |> render_change()

    # Click the backtest button
    index_live |> element("#backtest-rule-btn") |> render_click()

    assert has_element?(index_live, "#backtest-result")
    assert has_element?(index_live, "#backtest-result", "Last matched on")
    assert has_element?(index_live, "#backtest-result", "GIGABYTE GeForce RTX 4080 SUPER 16GB")
    assert has_element?(index_live, "#backtest-result", "Mindfactory")
    assert has_element?(index_live, "#backtest-result a", "View deal")

    # Changing form resets backtest result
    index_live
    |> form("#alert-rule-form", %{
      "alert_rule" => %{
        "keywords" => "RTX 4090"
      }
    })
    |> render_change()

    refute has_element?(index_live, "#backtest-result")
  end

  test "backtests rule with no matches and displays amber alert", %{conn: conn} do
    {:ok, index_live, _html} = live(conn, ~p"/alerts/new")

    index_live
    |> form("#alert-rule-form", %{
      "alert_rule" => %{
        "name" => "Rare Item Alert",
        "keywords" => "SuperRareNonExistentItem9999"
      }
    })
    |> render_change()

    index_live |> element("#backtest-rule-btn") |> render_click()

    assert has_element?(index_live, "#backtest-result")

    assert has_element?(
             index_live,
             "#backtest-result",
             "No past deals matched this rule in the database."
           )

    assert has_element?(
             index_live,
             "#backtest-result",
             "May be a rare item or check spelling/operators"
           )
  end

  test "backtests high volume rule and displays warning notice", %{conn: conn} do
    feed =
      Repo.insert!(%Feed{
        name: "MyDealz",
        slug: "mydealz-#{System.unique_integer([:positive])}",
        url: "https://example.com/rss"
      })

    merchant =
      Repo.insert!(%Merchant{
        name: "MediaMarkt",
        slug: "mediamarkt-#{System.unique_integer([:positive])}",
        trust_level: "verified"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for i <- 1..12 do
      Repo.insert!(%Deal{
        feed_id: feed.id,
        merchant_id: merchant.id,
        guid: "deal-lego-#{i}-#{System.unique_integer([:positive])}",
        title: "Lego Star Wars Set ##{i}",
        url: "https://example.com/lego-#{i}",
        price: Decimal.new("49.99"),
        published_at: DateTime.add(now, -i, :minute)
      })
    end

    {:ok, index_live, _html} = live(conn, ~p"/alerts/new")

    index_live
    |> form("#alert-rule-form", %{
      "alert_rule" => %{
        "name" => "Lego Alert",
        "keywords" => "Lego Star Wars"
      }
    })
    |> render_change()

    index_live |> element("#backtest-rule-btn") |> render_click()

    assert has_element?(index_live, "#backtest-result")

    assert has_element?(
             index_live,
             "#backtest-result",
             "High volume rule: matched multiple recent deals."
           )

    assert has_element?(
             index_live,
             "#backtest-result",
             "Consider adding a maximum price or specific model."
           )

    assert has_element?(index_live, "#backtest-result", "Last matched on")
  end
end
