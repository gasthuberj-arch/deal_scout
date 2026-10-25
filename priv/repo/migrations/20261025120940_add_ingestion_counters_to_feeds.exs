defmodule DealScout.Repo.Migrations.AddIngestionCountersToFeeds do
  use Ecto.Migration

  def up do
    alter table(:feeds) do
      add :total_deals_ingested, :integer, default: 0, null: false
      add :total_duplicates_ingested, :integer, default: 0, null: false
    end

    flush()

    execute("""
    UPDATE feeds
    SET total_deals_ingested = (
      SELECT COUNT(*) FROM deals WHERE deals.feed_id = feeds.id
    ),
    total_duplicates_ingested = (
      SELECT COUNT(*) FROM deals WHERE deals.feed_id = feeds.id AND deals.canonical_deal_id IS NOT NULL
    )
    """)
  end

  def down do
    alter table(:feeds) do
      remove :total_deals_ingested
      remove :total_duplicates_ingested
    end
  end
end
