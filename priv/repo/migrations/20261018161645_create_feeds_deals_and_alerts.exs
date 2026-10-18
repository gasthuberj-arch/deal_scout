defmodule DealScout.Repo.Migrations.CreateFeedsDealsAndAlerts do
  use Ecto.Migration

  def change do
    create table(:feeds) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :url, :string, null: false
      add :etag, :string
      add :last_modified, :string
      add :last_fetched_at, :utc_datetime
      add :is_active, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:feeds, [:slug])

    create table(:deals) do
      add :feed_id, references(:feeds, on_delete: :delete_all), null: false
      add :guid, :string, null: false
      add :title, :string, null: false
      add :url, :text, null: false
      add :description, :text
      add :clean_text, :text
      add :price, :decimal, precision: 10, scale: 2
      add :merchant, :string
      add :image_url, :text
      add :published_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:deals, [:guid])
    create index(:deals, [:feed_id])
    create index(:deals, [:published_at])

    create table(:alert_rules) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :keywords, :string, null: false
      add :negative_keywords, :string
      add :max_price, :decimal, precision: 10, scale: 2
      add :source_filter, :string, default: "all", null: false
      add :is_active, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:alert_rules, [:user_id])

    create table(:user_matches) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :deal_id, references(:deals, on_delete: :delete_all), null: false
      add :alert_rule_id, references(:alert_rules, on_delete: :delete_all), null: false
      add :is_read, :boolean, default: false, null: false
      add :notified_via_email, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_matches, [:user_id, :deal_id, :alert_rule_id])
    create index(:user_matches, [:user_id, :is_read])
  end
end
