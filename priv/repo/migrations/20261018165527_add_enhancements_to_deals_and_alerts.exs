defmodule DealScout.Repo.Migrations.AddEnhancementsToDealsAndAlerts do
  use Ecto.Migration

  def change do
    create table(:merchants) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :domain, :string
      add :trust_level, :string, default: "unverified", null: false
      add :deal_count, :integer, default: 0, null: false
      add :feed_counts, :map, default: "{}", null: false
      add :avg_temperature, :float, default: 0.0
      add :last_seen_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:merchants, [:slug])

    alter table(:deals) do
      add :merchant_id, references(:merchants, on_delete: :nilify_all)
      add :idealo_url, :text
      add :geizhals_url, :text
      add :temperature, :integer
    end

    create index(:deals, [:merchant_id])
    create index(:deals, [:temperature])

    alter table(:alert_rules) do
      add :min_temperature, :integer
      add :exclude_dropshippers, :boolean, default: true, null: false
    end
  end
end
