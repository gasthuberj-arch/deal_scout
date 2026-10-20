defmodule DealScout.Notifications.PushSubscription do
  use Ecto.Schema
  import Ecto.Changeset

  schema "push_subscriptions" do
    field :endpoint, :string
    field :p256dh, :string
    field :auth, :string
    field :user_agent, :string
    field :device_name, :string
    field :last_used_at, :utc_datetime

    belongs_to :user, DealScout.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(push_subscription, attrs) do
    push_subscription
    |> cast(attrs, [:endpoint, :p256dh, :auth, :user_agent, :device_name, :last_used_at])
    |> validate_required([:user_id, :endpoint, :p256dh, :auth])
    |> unique_constraint(:endpoint)
  end
end
