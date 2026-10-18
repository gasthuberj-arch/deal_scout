defmodule DealScout.Alerts.AlertRule do
  use Ecto.Schema
  import Ecto.Changeset

  schema "alert_rules" do
    field :name, :string
    field :keywords, :string
    field :negative_keywords, :string
    field :max_price, :decimal
    field :source_filter, :string, default: "all"
    field :min_temperature, :integer
    field :exclude_dropshippers, :boolean, default: true
    field :is_active, :boolean, default: true

    belongs_to :user, DealScout.Accounts.User
    has_many :user_matches, DealScout.Alerts.UserMatch

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(alert_rule, attrs) do
    alert_rule
    |> cast(attrs, [
      :user_id,
      :name,
      :keywords,
      :negative_keywords,
      :max_price,
      :source_filter,
      :min_temperature,
      :exclude_dropshippers,
      :is_active
    ])
    |> validate_required([:user_id, :name, :keywords])
    |> validate_length(:name, min: 2, max: 100)
    |> validate_length(:keywords, min: 2, max: 255)
  end
end
