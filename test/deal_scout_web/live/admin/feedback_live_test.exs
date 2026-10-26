defmodule DealScoutWeb.Admin.FeedbackLiveTest do
  use DealScoutWeb.ConnCase
  import Phoenix.LiveViewTest

  alias DealScout.AccountsFixtures
  alias DealScout.Feedback

  setup do
    admin = AccountsFixtures.admin_fixture()
    regular_user = AccountsFixtures.user_fixture()

    %{admin: admin, regular_user: regular_user}
  end

  test "redirects unauthenticated visitor to log in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/admin/feedback")
  end

  test "redirects regular authenticated user to root", %{conn: conn, regular_user: user} do
    conn = log_in_user(conn, user)

    assert {:error,
            {:redirect,
             %{to: "/", flash: %{"error" => "You must be an administrator to access this page."}}}} =
             live(conn, ~p"/admin/feedback")
  end

  test "admin user mounts feedback console, filters, updates status, and deletes feedback", %{
    conn: conn,
    admin: admin,
    regular_user: user
  } do
    # Create test feedbacks
    {:ok, fb1} =
      Feedback.create_feedback(user, %{
        "category" => "bug",
        "message" => "Price parser is skipping Idealo discounts",
        "page_url" => "/deals"
      })

    {:ok, fb2} =
      Feedback.create_feedback(user, %{
        "category" => "feature_request",
        "message" => "Please add Telegram alert webhooks",
        "page_url" => "/alerts"
      })

    conn = log_in_user(conn, admin)
    {:ok, view, html} = live(conn, ~p"/admin/feedback")

    assert html =~ "User Feedback &amp; Suggestions" or html =~ "User Feedback & Suggestions"
    assert html =~ "Admin Feedback Triage Console"
    assert html =~ "Price parser is skipping Idealo discounts"
    assert html =~ "Please add Telegram alert webhooks"

    # Filter by category
    filter_html =
      view
      |> form("#feedback-filter-form", %{"filters" => %{"category" => "bug"}})
      |> render_change()

    assert filter_html =~ "Price parser is skipping Idealo discounts"
    refute filter_html =~ "Please add Telegram alert webhooks"

    # Reset filter back to all
    view
    |> form("#feedback-filter-form", %{"filters" => %{"category" => "all"}})
    |> render_change()

    # Update status of fb1 to under_review
    assert view
           |> element(
             "button[phx-click='update_status'][phx-value-id='#{fb1.id}'][phx-value-status='under_review']"
           )
           |> render_click() =~ "Feedback status updated to Under Review."

    updated_fb1 = Feedback.get_feedback!(fb1.id)
    assert updated_fb1.status == "under_review"

    # Mark fb1 resolved
    assert view
           |> element(
             "button[phx-click='update_status'][phx-value-id='#{fb1.id}'][phx-value-status='resolved']"
           )
           |> render_click() =~ "Feedback status updated to Resolved."

    assert Feedback.get_feedback!(fb1.id).status == "resolved"

    # Delete fb2
    assert view
           |> element("button[phx-click='delete'][phx-value-id='#{fb2.id}']")
           |> render_click() =~ "Feedback entry deleted successfully."

    assert_raise Ecto.NoResultsError, fn -> Feedback.get_feedback!(fb2.id) end
  end
end
