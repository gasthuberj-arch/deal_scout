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
    field :raw_merchant, :string, source: :merchant
    field :image_url, :string
    field :published_at, :utc_datetime
    field :idealo_url, :string
    field :geizhals_url, :string
    field :temperature, :integer
    field :country, :map
    field :keyboard_warning, :map
    field :cross_border_evaluated, :boolean, virtual: true, default: true

    belongs_to :feed, DealScout.Feeds.Feed
    belongs_to :merchant, DealScout.Deals.Merchant
    belongs_to :canonical_deal, DealScout.Deals.Deal, foreign_key: :canonical_deal_id
    has_many :duplicates, DealScout.Deals.Deal, foreign_key: :canonical_deal_id
    has_many :user_matches, DealScout.Alerts.UserMatch

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(deal, attrs) do
    deal
    |> cast(attrs, [
      :feed_id,
      :merchant_id,
      :canonical_deal_id,
      :guid,
      :title,
      :url,
      :description,
      :clean_text,
      :price,
      :raw_merchant,
      :image_url,
      :published_at,
      :idealo_url,
      :geizhals_url,
      :temperature
    ])
    |> validate_required([:feed_id, :merchant_id, :guid, :title, :url, :published_at])
    |> unique_constraint(:guid)
  end
end
