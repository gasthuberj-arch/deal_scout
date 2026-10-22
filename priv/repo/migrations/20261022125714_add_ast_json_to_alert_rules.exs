defmodule DealScout.Repo.Migrations.AddAstJsonToAlertRules do
  use Ecto.Migration

  def change do
    alter table(:alert_rules) do
      add :ast_json, :map
    end

    create_if_not_exists index(:alert_rules, [:is_active])
  end
end
