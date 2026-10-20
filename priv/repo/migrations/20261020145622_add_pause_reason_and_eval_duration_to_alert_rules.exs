defmodule DealScout.Repo.Migrations.AddPauseReasonAndEvalDurationToAlertRules do
  use Ecto.Migration

  def change do
    alter table(:alert_rules) do
      add :pause_reason, :string
      add :last_eval_duration_us, :integer
    end
  end
end
