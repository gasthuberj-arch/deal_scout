defmodule DealScout.Repo.Migrations.RemoveDeadFeeds do
  use Ecto.Migration

  def up do
    execute "DELETE FROM feeds WHERE slug IN ('reddit-deals', 'reddit-bapcsales', 'schnaeppchenfuchs')"
  end

  def down do
    # No-op since deleted feeds were defunct
    :ok
  end
end
