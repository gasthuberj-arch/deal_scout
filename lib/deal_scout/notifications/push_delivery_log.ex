defmodule DealScout.Notifications.PushDeliveryLog do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending delivered expired http_error network_error no_subscriptions skipped_cooldown)

  schema "push_delivery_logs" do
    field :tracking_id, :string
    field :endpoint, :string
    field :status, :string
    field :http_status, :integer
    field :error_message, :string
    field :gateway_duration_ms, :integer
    field :client_received_at, :utc_datetime_usec
    field :client_delay_ms, :integer

    belongs_to :user, DealScout.Accounts.User
    belongs_to :user_match, DealScout.Alerts.UserMatch
    belongs_to :push_subscription, DealScout.Notifications.PushSubscription

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc false
  def changeset(push_delivery_log, attrs) do
    push_delivery_log
    |> cast(attrs, [
      :tracking_id,
      :endpoint,
      :status,
      :http_status,
      :error_message,
      :gateway_duration_ms,
      :client_received_at,
      :client_delay_ms
    ])
    |> validate_required([:tracking_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:user)
    |> unique_constraint(:tracking_id)
  end

  @doc false
  def receipt_changeset(push_delivery_log, attrs) do
    push_delivery_log
    |> cast(attrs, [:client_received_at, :client_delay_ms])
    |> validate_required([:client_received_at])
  end
end
