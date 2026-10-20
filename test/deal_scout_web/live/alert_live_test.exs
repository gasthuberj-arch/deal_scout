defmodule DealScoutWeb.AlertLiveTest do
  use DealScoutWeb.ConnCase
  import Phoenix.LiveViewTest

  alias DealScout.Alerts

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

    index_live |> element("button", "Got it") |> render_click()
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
end
