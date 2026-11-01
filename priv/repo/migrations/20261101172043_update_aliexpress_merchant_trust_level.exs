defmodule DealScout.Repo.Migrations.UpdateAliexpressMerchantTrustLevel do
  use Ecto.Migration

  def up do
    execute "UPDATE merchants SET trust_level = 'unverified' WHERE slug IN ('aliexpress', 'ali-express') AND trust_level = 'dropshipper'"
  end

  def down do
    execute "UPDATE merchants SET trust_level = 'dropshipper' WHERE slug IN ('aliexpress', 'ali-express') AND trust_level = 'unverified'"
  end
end
