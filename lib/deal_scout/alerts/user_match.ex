defmodule DealScout.Alerts.UserMatch do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_matches" do
    field :is_read, :boolean, default: false
    field :notified_via_email, :boolean, default: false
    field :notified_via_push, :boolean, default: false
    field :digest_at, :utc_datetime

    belongs_to :user, DealScout.Accounts.User
    belongs_to :deal, DealScout.Deals.Deal
    belongs_to :alert_rule, DealScout.Alerts.AlertRule

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(user_match, attrs) do
    user_match
    |> cast(attrs, [
      :user_id,
      :deal_id,
      :alert_rule_id,
      :is_read,
      :notified_via_email,
      :notified_via_push,
      :digest_at
    ])
    |> validate_required([:user_id, :deal_id, :alert_rule_id])
    |> unique_constraint([:user_id, :deal_id, :alert_rule_id])
  end
end
