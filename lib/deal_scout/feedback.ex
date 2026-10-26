defmodule DealScout.Feedback do
  @moduledoc """
  Context module for managing user feedback submissions and admin review workflows.
  """
  import Ecto.Query, warn: false
  alias DealScout.Repo
  alias DealScout.Accounts.User
  alias DealScout.Feedback.FeedbackEntry

  @max_submissions_per_hour 5

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking feedback changes.
  """
  def change_feedback(%FeedbackEntry{} = feedback \\ %FeedbackEntry{}, attrs \\ %{}) do
    FeedbackEntry.create_changeset(feedback, attrs)
  end

  @doc """
  Checks if the user has reached the rate limit (5 submissions per hour).
  """
  def rate_limited?(user_id) when is_integer(user_id) do
    one_hour_ago = DateTime.utc_now() |> DateTime.add(-3600, :second)

    count =
      from(f in FeedbackEntry,
        where: f.user_id == ^user_id and f.inserted_at >= ^one_hour_ago,
        select: count(f.id)
      )
      |> Repo.one()

    count >= @max_submissions_per_hour
  end

  def rate_limited?(_), do: false

  @doc """
  Creates a feedback entry for an authenticated scope or user.
  Enforces a rate limit of 5 submissions per hour per user.
  """
  def create_feedback(%DealScout.Accounts.Scope{user: %User{} = user}, attrs) do
    create_feedback(user, attrs)
  end

  def create_feedback(%User{id: user_id}, attrs) do
    if rate_limited?(user_id) do
      {:error, :rate_limited}
    else
      %FeedbackEntry{user_id: user_id}
      |> FeedbackEntry.create_changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Returns a list of feedbacks, optionally filtered by status and category.
  Preloads the user association.
  """
  def list_feedbacks(filters \\ %{}) do
    query =
      from f in FeedbackEntry,
        order_by: [desc: f.inserted_at],
        preload: [:user]

    query
    |> maybe_filter_status(filters[:status] || filters["status"])
    |> maybe_filter_category(filters[:category] || filters["category"])
    |> Repo.all()
  end

  @doc """
  Returns aggregated counts of feedbacks by status.
  """
  def count_feedbacks_by_status do
    counts =
      from(f in FeedbackEntry,
        group_by: f.status,
        select: {f.status, count(f.id)}
      )
      |> Repo.all()
      |> Map.new()

    total = Enum.reduce(counts, 0, fn {_k, v}, acc -> acc + v end)

    %{
      total: total,
      new: Map.get(counts, "new", 0),
      under_review: Map.get(counts, "under_review", 0),
      resolved: Map.get(counts, "resolved", 0),
      archived: Map.get(counts, "archived", 0)
    }
  end

  @doc """
  Gets a single feedback entry by ID, preloading user.
  Raises Ecto.NoResultsError if not found.
  """
  def get_feedback!(id) do
    FeedbackEntry
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Updates the status of a feedback entry.
  """
  def update_feedback_status(%FeedbackEntry{} = feedback, status) do
    feedback
    |> FeedbackEntry.status_changeset(%{status: status})
    |> Repo.update()
  end

  @doc """
  Deletes a feedback entry.
  """
  def delete_feedback(%FeedbackEntry{} = feedback) do
    Repo.delete(feedback)
  end

  defp maybe_filter_status(query, status) when is_binary(status) and status not in ["", "all"] do
    from f in query, where: f.status == ^status
  end

  defp maybe_filter_status(query, _), do: query

  defp maybe_filter_category(query, category)
       when is_binary(category) and category not in ["", "all"] do
    from f in query, where: f.category == ^category
  end

  defp maybe_filter_category(query, _), do: query
end
