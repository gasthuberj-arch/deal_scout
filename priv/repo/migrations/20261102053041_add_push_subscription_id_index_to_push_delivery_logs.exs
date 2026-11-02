defmodule DealScout.Repo.Migrations.AddPushSubscriptionIdIndexToPushDeliveryLogs do
  use Ecto.Migration

  def change do
    create index(:push_delivery_logs, [:push_subscription_id, :inserted_at])
  end
end
