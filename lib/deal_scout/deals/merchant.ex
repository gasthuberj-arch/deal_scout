defmodule DealScout.Deals.Merchant do
  use Ecto.Schema
  import Ecto.Changeset

  schema "merchants" do
    field :name, :string
    field :slug, :string
    field :domain, :string
    field :trust_level, :string, default: "unverified"
    field :deal_count, :integer, default: 0
    field :feed_counts, :map, default: %{}
    field :avg_temperature, :float, default: 0.0
    field :last_seen_at, :utc_datetime

    has_many :deals, DealScout.Deals.Deal

    timestamps(type: :utc_datetime)
  end

  @trust_levels ~w(verified unverified high_risk dropshipper)

  def trust_levels, do: @trust_levels

  @doc false
  def changeset(merchant, attrs) do
    merchant
    |> cast(attrs, [
      :name,
      :slug,
      :domain,
      :trust_level,
      :deal_count,
      :feed_counts,
      :avg_temperature,
      :last_seen_at
    ])
    |> validate_required([:name, :slug])
    |> validate_inclusion(:trust_level, @trust_levels)
    |> unique_constraint(:slug)
  end
end
