defmodule DealScout.Repo.Migrations.AddAnalyticsPartialIndexesToDeals do
  use Ecto.Migration

  def up do
    create_if_not_exists index(:deals, [:country],
                           where: "country IS NOT NULL",
                           name: :deals_country_not_null_index
                         )

    create_if_not_exists index(:deals, [:keyboard_warning],
                           where: "keyboard_warning IS NOT NULL",
                           name: :deals_keyboard_warning_not_null_index
                         )
  end

  def down do
    drop_if_exists index(:deals, [:keyboard_warning],
                     name: :deals_keyboard_warning_not_null_index
                   )

    drop_if_exists index(:deals, [:country], name: :deals_country_not_null_index)
  end
end
