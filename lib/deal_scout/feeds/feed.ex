defmodule DealScout.Feeds.Feed do
  use Ecto.Schema
  import Ecto.Changeset

  schema "feeds" do
    field :name, :string
    field :slug, :string
    field :url, :string
    field :etag, :string
    field :last_modified, :string
    field :last_fetched_at, :utc_datetime
    field :poll_interval_seconds, :integer, default: 120
    field :backoff_until, :utc_datetime
    field :consecutive_errors, :integer, default: 0
    field :last_error_status, :integer
    field :is_active, :boolean, default: true
    field :total_deals_ingested, :integer, default: 0
    field :total_duplicates_ingested, :integer, default: 0

    has_many :deals, DealScout.Deals.Deal

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(feed, attrs) do
    feed
    |> cast(attrs, [
      :name,
      :slug,
      :url,
      :etag,
      :last_modified,
      :last_fetched_at,
      :poll_interval_seconds,
      :backoff_until,
      :consecutive_errors,
      :last_error_status,
      :is_active
    ])
    |> validate_required([:name, :slug, :url])
    |> validate_number(:poll_interval_seconds, greater_than_or_equal_to: 10)
    |> unique_constraint(:slug)
  end
end
