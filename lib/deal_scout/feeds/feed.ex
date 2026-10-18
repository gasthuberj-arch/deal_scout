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
    field :is_active, :boolean, default: true

    has_many :deals, DealScout.Deals.Deal

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(feed, attrs) do
    feed
    |> cast(attrs, [:name, :slug, :url, :etag, :last_modified, :last_fetched_at, :is_active])
    |> validate_required([:name, :slug, :url])
    |> unique_constraint(:slug)
  end
end
