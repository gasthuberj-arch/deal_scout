defmodule DealScout.Feedback.FeedbackEntry do
  use Ecto.Schema
  import Ecto.Changeset

  @categories ~w(bug feature_request scraper_issue other)
  @statuses ~w(new under_review resolved archived)

  schema "feedbacks" do
    field :category, :string
    field :message, :string
    field :page_url, :string
    field :status, :string, default: "new"

    belongs_to :user, DealScout.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def categories, do: @categories
  def statuses, do: @statuses

  @doc """
  Changeset for creating a feedback entry from user input.
  Note that user_id must be assigned programmatically and not cast here.
  """
  def create_changeset(feedback_entry, attrs) do
    feedback_entry
    |> cast(attrs, [:category, :message, :page_url])
    |> validate_required([:category, :message])
    |> validate_inclusion(:category, @categories,
      message: "must be one of: #{Enum.join(@categories, ", ")}"
    )
    |> validate_length(:message, min: 5, max: 2000)
    |> validate_length(:page_url, max: 500)
  end

  @doc """
  Changeset for updating the administrative status of a feedback entry.
  """
  def status_changeset(feedback_entry, attrs) do
    feedback_entry
    |> cast(attrs, [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses,
      message: "must be one of: #{Enum.join(@statuses, ", ")}"
    )
  end
end
