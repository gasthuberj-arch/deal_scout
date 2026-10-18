defmodule DealScout.Repo.Migrations.AddCanonicalDealIdToDeals do
  use Ecto.Migration

  def change do
    alter table(:deals) do
      add :canonical_deal_id, references(:deals, on_delete: :nilify_all)
    end

    create index(:deals, [:canonical_deal_id])
  end
end
