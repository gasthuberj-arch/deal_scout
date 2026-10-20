defmodule DealScout.Alerts.AlertRule do
  use Ecto.Schema
  import Ecto.Changeset

  @delivery_modes ~w(instant hourly_digest daily_digest)
  @country_filters ~w(all de_only eu_only)
  @merchant_filters ~w(all verified_only)

  schema "alert_rules" do
    field :name, :string
    field :keywords, :string
    field :negative_keywords, :string
    field :max_price, :decimal
    field :source_filter, :string, default: "all"
    field :min_temperature, :integer
    field :exclude_dropshippers, :boolean, default: true
    field :is_active, :boolean, default: true

    field :notify_push, :boolean, default: true
    field :notify_email, :boolean, default: false
    field :delivery_mode, :string, default: "instant"
    field :country_filter, :string, default: "all"
    field :exclude_foreign_keyboards, :boolean, default: false
    field :merchant_filter, :string, default: "all"
    field :cooldown_minutes, :integer, default: 0
    field :last_notified_at, :utc_datetime

    belongs_to :user, DealScout.Accounts.User
    has_many :user_matches, DealScout.Alerts.UserMatch

    timestamps(type: :utc_datetime)
  end

  def delivery_modes, do: @delivery_modes
  def country_filters, do: @country_filters
  def merchant_filters, do: @merchant_filters

  @doc """
  Checks if the alert rule is currently in a cooldown window to prevent notification bursts.
  """
  def in_cooldown?(%__MODULE__{cooldown_minutes: mins, last_notified_at: last_at})
      when is_integer(mins) and mins > 0 and not is_nil(last_at) do
    diff_seconds = DateTime.diff(DateTime.utc_now(), last_at, :second)
    diff_seconds < mins * 60
  end

  def in_cooldown?(_rule), do: false

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
      :is_active,
      :notify_push,
      :notify_email,
      :delivery_mode,
      :country_filter,
      :exclude_foreign_keyboards,
      :merchant_filter,
      :cooldown_minutes,
      :last_notified_at
    ])
    |> validate_required([:user_id, :name, :keywords])
    |> validate_length(:name, min: 2, max: 100)
    |> validate_length(:keywords, min: 2, max: 255)
    |> validate_inclusion(:delivery_mode, @delivery_modes)
    |> validate_inclusion(:country_filter, @country_filters)
    |> validate_inclusion(:merchant_filter, @merchant_filters)
    |> validate_number(:cooldown_minutes, greater_than_or_equal_to: 0)
  end
end
