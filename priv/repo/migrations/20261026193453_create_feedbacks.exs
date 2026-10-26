defmodule DealScout.Repo.Migrations.CreateFeedbacks do
  use Ecto.Migration

  def change do
    create table(:feedbacks) do
      add :user_id, references(:users, on_delete: :nilify_all)
      add :category, :string, null: false
      add :message, :text, null: false
      add :page_url, :string
      add :status, :string, default: "new", null: false

      timestamps(type: :utc_datetime)
    end

    create index(:feedbacks, [:user_id, :inserted_at])
    create index(:feedbacks, [:status, :inserted_at])
  end
end
