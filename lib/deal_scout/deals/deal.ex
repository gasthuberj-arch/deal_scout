defmodule DealScout.Deals.Deal do
  use Ecto.Schema
  import Ecto.Changeset

  schema "deals" do
    field :guid, :string
    field :title, :string
    field :url, :string
    field :description, :string
    field :clean_text, :string
    field :price, :decimal
    field :merchant, :string
    field :image_url, :string
    field :published_at, :utc_datetime

    belongs_to :feed, DealScout.Feeds.Feed
    has_many :user_matches, DealScout.Alerts.UserMatch

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(deal, attrs) do
    deal
    |> cast(attrs, [
      :feed_id,
      :guid,
      :title,
      :url,
      :description,
      :clean_text,
      :price,
      :merchant,
      :image_url,
      :published_at
    ])
    |> validate_required([:feed_id, :guid, :title, :url, :published_at])
    |> unique_constraint(:guid)
  end
end
