defmodule DealScout.Repo.Migrations.AddPwaPushAndRuleEnhancements do
  use Ecto.Migration

  def change do
    create table(:push_subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :endpoint, :text, null: false
      add :p256dh, :text, null: false
      add :auth, :text, null: false
      add :user_agent, :text
      add :device_name, :string
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:push_subscriptions, [:user_id])
    create unique_index(:push_subscriptions, [:endpoint])

    alter table(:alert_rules) do
      add :notify_push, :boolean, default: true, null: false
      add :notify_email, :boolean, default: false, null: false
      add :delivery_mode, :string, default: "instant", null: false
      add :country_filter, :string, default: "all", null: false
      add :exclude_foreign_keyboards, :boolean, default: false, null: false
      add :merchant_filter, :string, default: "all", null: false
      add :cooldown_minutes, :integer, default: 0, null: false
      add :last_notified_at, :utc_datetime
    end

    alter table(:user_matches) do
      add :notified_via_push, :boolean, default: false, null: false
      add :digest_at, :utc_datetime
    end
  end
end
