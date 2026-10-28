defmodule DealScoutWeb.Admin.SystemLiveTest do
  use DealScoutWeb.ConnCase
  import Phoenix.LiveViewTest

  alias DealScout.AccountsFixtures

  setup do
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

    # Clicking trigger_ebay_poll when unconfigured shows flash notice
    rendered =
      view
      |> element("button[phx-click='trigger_ebay_poll']")
      |> render_click()

    assert rendered =~ "eBay"
  end
end
