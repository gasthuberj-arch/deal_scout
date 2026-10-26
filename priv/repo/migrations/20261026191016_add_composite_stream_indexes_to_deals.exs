defmodule DealScout.Repo.Migrations.AddCompositeStreamIndexesToDeals do
  use Ecto.Migration

  def up do
    # Drop redundant single-column index that misled the query planner into full scans
    drop_if_exists index(:deals, [:canonical_deal_id])

    # Composite index that enables instant index-ordered streaming for the default deals view
    create index(:deals, [:canonical_deal_id, :published_at, :id])

    # Composite index for feed-filtered deals view
    create index(:deals, [:feed_id, :canonical_deal_id, :published_at, :id])
  end

  def down do
    drop_if_exists index(:deals, [:feed_id, :canonical_deal_id, :published_at, :id])
    drop_if_exists index(:deals, [:canonical_deal_id, :published_at, :id])
    create_if_not_exists index(:deals, [:canonical_deal_id])
  end
end
