defmodule DealScoutWeb.FeedbackWidgetTest do
  use DealScoutWeb.ConnCase
  import Phoenix.LiveViewTest

  alias DealScout.AccountsFixtures
  alias DealScout.Feedback

  describe "feedback button and modal visibility" do
    test "unauthenticated visitor does not see the feedback widget", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      refute html =~ "id=\"feedback-trigger-btn\""
      refute html =~ "id=\"feedback-modal\""
    end

    test "signed-in user sees the floating feedback button and modal", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "id=\"feedback-trigger-btn\""
      assert html =~ "id=\"feedback-modal\""
      assert has_element?(view, "#feedback-trigger-btn")
      assert has_element?(view, "#feedback-modal")
      assert has_element?(view, "#feedback-form")
    end
  end

  describe "feedback submission" do
    setup %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "authenticated user can submit feedback successfully", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/")

      form_data = %{
        "feedback" => %{
          "category" => "bug",
          "message" => "Found a broken link in one of the deal cards.",
          "page_url" => "/deals"
        }
      }

      view
      |> form("#feedback-form", form_data)
      |> render_submit()

      # Assert feedback record created in DB
      feedbacks = Feedback.list_feedbacks(%{"category" => "bug"})
      assert length(feedbacks) == 1
      entry = hd(feedbacks)
      assert entry.user_id == user.id
      assert entry.message == "Found a broken link in one of the deal cards."
      assert entry.category == "bug"
      assert entry.page_url == "/deals"
      assert entry.status == "new"

      # Flash message displayed
      assert render(view) =~ "Thank you for your feedback! Our team has received your message."
    end

    test "submitting invalid feedback displays error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      form_data = %{
        "feedback" => %{
          "category" => "bug",
          # Too short (< 5 chars)
          "message" => "Hi",
          "page_url" => "/"
        }
      }

      view
      |> form("#feedback-form", form_data)
      |> render_submit()

      assert render(view) =~ "Could not send feedback"
    end

    test "rate limit rejects excessive submissions", %{conn: conn, user: user} do
      # Pre-create 5 feedback entries for the user
      for i <- 1..5 do
        {:ok, _} =
          Feedback.create_feedback(user, %{
            "category" => "other",
            "message" => "Pre-existing feedback #{i}"
          })
      end

      {:ok, view, _html} = live(conn, ~p"/")

      form_data = %{
        "feedback" => %{
          "category" => "feature_request",
          "message" => "One more request that should be blocked",
          "page_url" => "/"
        }
      }

      view
      |> form("#feedback-form", form_data)
      |> render_submit()

      assert render(view) =~ "You have submitted feedback multiple times recently"
    end
  end
end
