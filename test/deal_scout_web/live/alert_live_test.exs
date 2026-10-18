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
end
