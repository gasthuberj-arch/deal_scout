defmodule DealScout.FeedbackTest do
  use DealScout.DataCase, async: false

  alias DealScout.Feedback
  alias DealScout.AccountsFixtures

  describe "feedback submission and management" do
    test "create_feedback/2 creates a feedback entry with valid attributes" do
      user = AccountsFixtures.user_fixture()

      attrs = %{
        "category" => "bug",
        "message" => "Found an issue with price tracking.",
        "page_url" => "/deals?q=rtx"
      }

      assert {:ok, feedback} = Feedback.create_feedback(user, attrs)
      assert feedback.user_id == user.id
      assert feedback.category == "bug"
      assert feedback.message == "Found an issue with price tracking."
      assert feedback.page_url == "/deals?q=rtx"
      assert feedback.status == "new"
    end

    test "create_feedback/2 accepts current_scope" do
      user = AccountsFixtures.user_fixture()
      scope = AccountsFixtures.user_scope_fixture(user)

      attrs = %{
        "category" => "feature_request",
        "message" => "Allow exporting filtered deals as CSV.",
        "page_url" => "/deals"
      }

      assert {:ok, feedback} = Feedback.create_feedback(scope, attrs)
      assert feedback.user_id == user.id
    end

    test "create_feedback/2 validates required category and message length" do
      user = AccountsFixtures.user_fixture()

      # Invalid category
      assert {:error, changeset} =
               Feedback.create_feedback(user, %{
                 "category" => "invalid_category",
                 "message" => "Valid message here"
               })

      assert "must be one of: bug, feature_request, scraper_issue, other" in errors_on(changeset).category

      # Message too short (< 5 chars)
      assert {:error, changeset} =
               Feedback.create_feedback(user, %{
                 "category" => "other",
                 "message" => "Hi"
               })

      assert errors_on(changeset).message != []
    end

    test "create_feedback/2 enforces rate limiting (max 5 submissions per hour)" do
      user = AccountsFixtures.user_fixture()

      for i <- 1..5 do
        assert {:ok, _} =
                 Feedback.create_feedback(user, %{
                   "category" => "other",
                   "message" => "Feedback submission number #{i}"
                 })
      end

      # 6th submission should be rate limited
      assert {:error, :rate_limited} =
               Feedback.create_feedback(user, %{
                 "category" => "other",
                 "message" => "This 6th submission must be rejected"
               })
    end

    test "list_feedbacks/1 filters by status and category" do
      user = AccountsFixtures.user_fixture()

      {:ok, fb1} =
        Feedback.create_feedback(user, %{"category" => "bug", "message" => "Bug message one"})

      {:ok, fb2} =
        Feedback.create_feedback(user, %{
          "category" => "feature_request",
          "message" => "Feature message"
        })

      {:ok, _} = Feedback.update_feedback_status(fb1, "resolved")

      all_feedbacks = Feedback.list_feedbacks()
      assert length(all_feedbacks) >= 2

      resolved_feedbacks = Feedback.list_feedbacks(%{"status" => "resolved"})
      assert Enum.any?(resolved_feedbacks, &(&1.id == fb1.id))
      refute Enum.any?(resolved_feedbacks, &(&1.id == fb2.id))

      feature_feedbacks = Feedback.list_feedbacks(%{"category" => "feature_request"})
      assert Enum.any?(feature_feedbacks, &(&1.id == fb2.id))
      refute Enum.any?(feature_feedbacks, &(&1.id == fb1.id))
    end

    test "count_feedbacks_by_status/0 returns aggregated counts" do
      user = AccountsFixtures.user_fixture()

      {:ok, fb} =
        Feedback.create_feedback(user, %{"category" => "other", "message" => "Some feedback"})

      counts = Feedback.count_feedbacks_by_status()
      assert counts.total >= 1
      assert counts.new >= 1

      {:ok, _} = Feedback.update_feedback_status(fb, "under_review")
      updated_counts = Feedback.count_feedbacks_by_status()
      assert updated_counts.under_review >= 1
    end

    test "delete_feedback/1 deletes a feedback entry" do
      user = AccountsFixtures.user_fixture()

      {:ok, fb} =
        Feedback.create_feedback(user, %{"category" => "other", "message" => "To be deleted"})

      assert {:ok, _} = Feedback.delete_feedback(fb)
      assert_raise Ecto.NoResultsError, fn -> Feedback.get_feedback!(fb.id) end
    end
  end
end
