defmodule DealScoutWeb.Admin.SystemLiveTest do
  use DealScoutWeb.ConnCase
  import Phoenix.LiveViewTest

  alias DealScout.AccountsFixtures

  setup do
    DealScout.Notifications.invalidate_delivery_metrics_cache(24)
    admin = AccountsFixtures.admin_fixture()
    regular_user = AccountsFixtures.user_fixture()

    %{admin: admin, regular_user: regular_user}
  end

  test "redirects unauthenticated visitor to log in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/admin/system")
  end

  test "redirects regular authenticated user to root", %{conn: conn, regular_user: user} do
    conn = log_in_user(conn, user)

    assert {:error,
            {:redirect,
             %{to: "/", flash: %{"error" => "You must be an administrator to access this page."}}}} =
             live(conn, ~p"/admin/system")
  end

  test "admin user mounts system health dashboard and triggers feed polling", %{
    conn: conn,
    admin: admin
  } do
    conn = log_in_user(conn, admin)
    {:ok, view, html} = live(conn, ~p"/admin/system")

    assert html =~ "System &amp; Infrastructure Health" or
             html =~ "System & Infrastructure Health"

    assert html =~ "Active Connected Sessions"
    assert html =~ "BEAM VM Memory"
    assert html =~ "RSS &amp; Atom Feed Poller Health" or html =~ "RSS & Atom Feed Poller Health"

    assert html =~ "Compute Budget &amp; Alert Query Performance" or
             html =~ "Compute Budget & Alert Query Performance"

    # Trigger immediate poll
    assert view
           |> element("button[phx-click='trigger_poll']")
           |> render_click() =~ "Triggered immediate background poll for all feeds."

    # Backup & replication section
    assert render(view) =~ "Remote NAS Backup &amp; Litestream Replication" or
             render(view) =~ "Remote NAS Backup & Litestream Replication"

    # Simulate NAS connecting and refreshing
    DealScout.Backup.Status.client_connected("nas-live-1", %{remote_ip: "10.0.0.99"})

    refreshed_html =
      view
      |> element("button[phx-click='refresh_metrics']")
      |> render_click()

    assert refreshed_html =~ "NAS Client Connected"
    assert refreshed_html =~ "10.0.0.99"
  end

  test "displays auto-paused rules and allows admin to resume them", %{
    conn: conn,
    admin: admin,
    regular_user: user
  } do
    rule =
      DealScout.Repo.insert!(%DealScout.Alerts.AlertRule{
        user_id: user.id,
        name: "Super Slow Regex Rule",
        keywords: "broad query term",
        is_active: false,
        pause_reason:
          "Auto-paused: Query evaluation took 42.5ms (exceeded 30ms compute budget). Simplify keywords or remove broad terms.",
        last_eval_duration_us: 42_500
      })

    conn = log_in_user(conn, admin)
    {:ok, view, html} = live(conn, ~p"/admin/system")

    assert html =~ "1 Auto-Paused"
    assert html =~ "Super Slow Regex Rule"
    assert html =~ user.email
    assert html =~ "42.5 ms"
    assert has_element?(view, "#resume-auto-paused-rule-btn-#{rule.id}")

    # Resume the rule from admin console
    rendered =
      view
      |> element("#resume-auto-paused-rule-btn-#{rule.id}")
      |> render_click()

    assert rendered =~ "Alert rule &quot;Super Slow Regex Rule&quot; resumed successfully." or
             rendered =~ "Alert rule \"Super Slow Regex Rule\" resumed successfully."

    # Check rule was resumed in DB
    reloaded = DealScout.Repo.get!(DealScout.Alerts.AlertRule, rule.id)
    assert reloaded.is_active == true
    assert is_nil(reloaded.pause_reason)

    assert has_element?(view, "#no-auto-paused-rules")
  end

  test "allows admin to manually pause a problematic slow rule", %{
    conn: conn,
    admin: admin,
    regular_user: user
  } do
    rule =
      DealScout.Repo.insert!(%DealScout.Alerts.AlertRule{
        user_id: user.id,
        name: "Heavy Mining Alert",
        keywords: "crypto gpu",
        is_active: true,
        last_eval_duration_us: 25_000
      })

    conn = log_in_user(conn, admin)
    {:ok, view, html} = live(conn, ~p"/admin/system")

    assert html =~ "Heavy Mining Alert"
    assert html =~ "25.0 ms"
    assert has_element?(view, "#pause-slowest-rule-btn-#{rule.id}")

    # Pause rule from console
    rendered =
      view
      |> element("#pause-slowest-rule-btn-#{rule.id}")
      |> render_click()

    assert rendered =~ "Alert rule &quot;Heavy Mining Alert&quot; paused." or
             rendered =~ "Alert rule \"Heavy Mining Alert\" paused."

    # Check rule is paused in DB
    reloaded = DealScout.Repo.get!(DealScout.Alerts.AlertRule, rule.id)
    assert reloaded.is_active == false
    assert reloaded.pause_reason == "Manually paused by administrator"
  end

  test "admin views eBay Sofort-Kauf sniper status card and triggers poll", %{
    conn: conn,
    admin: admin
  } do
    conn = log_in_user(conn, admin)
    {:ok, view, html} = live(conn, ~p"/admin/system")

    assert html =~ "eBay Sofort-Kauf Sniper Health"
    assert html =~ "In-Memory Seen Cache"
    assert html =~ "EBAY_DE"

    assert has_element?(view, "#trigger-ebay-poll-btn")

    # Clicking trigger_ebay_poll when unconfigured shows flash notice
    view
    |> element("#trigger-ebay-poll-btn")
    |> render_click()

    assert has_element?(view, ".alert-error", "eBay integration is not configured")
  end

  test "admin views memory, swap, storage metrics and triggers safe recovery actions", %{
    conn: conn,
    admin: admin
  } do
    DealScout.Notifications.invalidate_delivery_metrics_cache(24)

    conn = log_in_user(conn, admin)
    {:ok, view, _html} = live(conn, ~p"/admin/system")

    # Key cards exist
    assert has_element?(view, "#system-memory-gauge-card")
    assert has_element?(view, "#sqlite-storage-card")
    assert has_element?(view, "#admin-push-status-card")

    # Safe Checkpoint action
    assert has_element?(view, "#safe-checkpoint-btn")

    view
    |> element("#safe-checkpoint-btn")
    |> render_click()

    assert has_element?(view, ".alert-info", "SQLite WAL safely")

    # Safe Memory Reclamation action
    assert has_element?(view, "#safe-reclaim-mem-btn")

    view
    |> element("#safe-reclaim-mem-btn")
    |> render_click()

    assert has_element?(view, ".alert-info", "Released SQLite idle pager caches")

    # Safe Cache Re-warm action
    assert has_element?(view, "#safe-refresh-cache-btn")

    view
    |> element("#safe-refresh-cache-btn")
    |> render_click()

    assert has_element?(view, ".alert-info", "StreamCache refreshed in-place")
  end

  test "active alarms banner displays when an anomaly is present", %{
    conn: conn,
    admin: admin,
    regular_user: user
  } do
    # Trigger an auto-paused rule
    DealScout.Repo.insert!(%DealScout.Alerts.AlertRule{
      user_id: user.id,
      name: "Pathological Query Rule",
      keywords: "alarm test query",
      is_active: false,
      pause_reason: "Auto-paused: Query took 55.0ms (exceeded 30ms budget)."
    })

    # Evaluate health monitor state
    DealScout.Admin.HealthMonitor.check_now()

    DealScout.Notifications.invalidate_delivery_metrics_cache(24)

    conn = log_in_user(conn, admin)
    {:ok, view, _html} = live(conn, ~p"/admin/system")

    assert has_element?(view, "#active-alarms-banner")
    assert has_element?(view, "#active_alarms-auto_paused_rules")
    assert has_element?(view, "#active_alarms-auto_paused_rules", "Alert Rules Auto-Paused")
  end

  test "displays web push delivery diagnostics and per-device confirmation health", %{
    conn: conn,
    admin: admin
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    now_usec = DateTime.utc_now()

    sub =
      DealScout.Repo.insert!(%DealScout.Notifications.PushSubscription{
        user_id: admin.id,
        endpoint: "https://fcm.googleapis.com/fcm/send/sys-live-token",
        p256dh: "test-p256dh",
        auth: "test-auth",
        device_name: "Admin Pixel 8",
        user_agent:
          "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/123.0 Mobile Safari/537.36"
      })

    DealScout.Repo.insert!(%DealScout.Notifications.PushDeliveryLog{
      user_id: admin.id,
      push_subscription_id: sub.id,
      tracking_id: "sys-live-track-1",
      status: "delivered",
      endpoint: sub.endpoint,
      gateway_duration_ms: 110,
      client_delay_ms: 320,
      client_received_at: now_usec,
      inserted_at: now
    })

    DealScout.Notifications.invalidate_delivery_metrics_cache(24)
    DealScout.Notifications.invalidate_device_metrics_cache(24)

    conn = log_in_user(conn, admin)
    {:ok, view, _html} = live(conn, ~p"/admin/system")

    assert has_element?(view, "#web-push-diagnostics-card")

    assert has_element?(
             view,
             "#web-push-diagnostics-card",
             "Web Push Delivery & Browser Receipt Diagnostics"
           )

    assert has_element?(view, "#web-push-diagnostics-card", "100.0%")
    assert has_element?(view, "#web-push-diagnostics-card", "320 ms")
    assert has_element?(view, "#push-devices-table")
    assert has_element?(view, "#push-devices-table", "Admin Pixel 8")
    assert has_element?(view, "#push-devices-table", "Chrome on Android")
    assert has_element?(view, "#push-devices-table", "0 Pending")

    # Filter to pending only - since this device has 0 pending, it shouldn't show in pending list
    view |> element("#device-filter-pending-only") |> render_click()

    assert has_element?(
             view,
             "#push-devices-empty",
             "All active devices have 100% confirmed receipts"
           )

    # Switch back to all devices
    view |> element("#device-filter-all") |> render_click()
    assert has_element?(view, "#push-devices-table", "Admin Pixel 8")
  end
end
