defmodule DealScout.Repo.Migrations.CreatePushDeliveryLogs do
  use Ecto.Migration

  def change do
    create table(:push_delivery_logs) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :user_match_id, references(:user_matches, on_delete: :nilify_all)
      add :push_subscription_id, references(:push_subscriptions, on_delete: :nilify_all)
      add :tracking_id, :string, null: false
      add :endpoint, :string
      add :status, :string, null: false
      add :http_status, :integer
      add :error_message, :string
      add :gateway_duration_ms, :integer
      add :client_received_at, :utc_datetime_usec
      add :client_delay_ms, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:push_delivery_logs, [:user_id])
    create unique_index(:push_delivery_logs, [:tracking_id])
    create index(:push_delivery_logs, [:inserted_at])
  end
end
