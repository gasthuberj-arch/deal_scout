defmodule DealScout.Repo.Migrations.AddLocaleToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :locale, :string, default: "de", null: false
    end
  end
end
