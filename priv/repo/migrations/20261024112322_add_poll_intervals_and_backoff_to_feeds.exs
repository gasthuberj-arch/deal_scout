defmodule DealScout.Repo.Migrations.AddPollIntervalsAndBackoffToFeeds do
  use Ecto.Migration

  def change do
    alter table(:feeds) do
      add :poll_interval_seconds, :integer, default: 120, null: false
      add :backoff_until, :utc_datetime
      add :consecutive_errors, :integer, default: 0, null: false
      add :last_error_status, :integer
    end
  end
end
