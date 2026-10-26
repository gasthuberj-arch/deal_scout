defmodule DealScout.Repo.Migrations.AddCrossBorderFieldsToDeals do
  use Ecto.Migration

  def up do
    alter table(:deals) do
      add :country, :map
      add :keyboard_warning, :map
    end

    flush()

    execute(fn ->
      repo = repo()
      query = "SELECT id, url, title, clean_text FROM deals WHERE country IS NULL"

      case Ecto.Adapters.SQL.query(repo, query, []) do
        {:ok, %{rows: rows}} when rows != [] ->
          for [id, url, title, clean_text] <- rows do
            country =
              DealScout.Deals.CrossBorder.detect_country(%{
                url: url,
                title: title,
                clean_text: clean_text
              })

            kb =
              DealScout.Deals.CrossBorder.keyboard_warning(%{
                url: url,
                title: title,
                clean_text: clean_text
              })

            if country || kb do
              country_json = if country, do: Jason.encode!(country), else: nil
              kb_json = if kb, do: Jason.encode!(kb), else: nil

              Ecto.Adapters.SQL.query(
                repo,
                "UPDATE deals SET country = ?, keyboard_warning = ? WHERE id = ?",
                [country_json, kb_json, id]
              )
            end
          end

        _ ->
          :ok
      end
    end)
  end

  def down do
    alter table(:deals) do
      remove :country
      remove :keyboard_warning
    end
  end
end
