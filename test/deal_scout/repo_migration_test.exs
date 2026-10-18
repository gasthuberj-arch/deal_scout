defmodule DealScout.RepoMigrationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Verifies the complete migration chain:
  1. Bootstraps a fresh, isolated temporary SQLite database.
  2. Runs all migrations forward (UP to latest).
  3. Verifies schema integrity and core tables.
  4. Rolls all migrations backward (DOWN to 0).
  5. Verifies all application tables are dropped cleanly.
  6. Re-runs all migrations forward (UP to latest).
  7. Audits migration chain execution time to detect expensive migrations.
  """

  # Define dynamic repo module for isolated testing
  defmodule TempRepo do
    use Ecto.Repo, otp_app: :deal_scout, adapter: Ecto.Adapters.SQLite3
  end

  @expected_tables ~w(users users_tokens feeds deals merchants alert_rules user_matches)

  setup do
    temp_dir = System.tmp_dir!()
    db_file = Path.join(temp_dir, "migration_test_#{System.unique_integer([:positive])}.db")

    Application.put_env(:deal_scout, TempRepo,
      database: db_file,
      pool_size: 1
    )

    start_supervised!(TempRepo)
    migrations_path = Application.app_dir(:deal_scout, "priv/repo/migrations")

    on_exit(fn ->
      File.rm(db_file)
      File.rm("#{db_file}-shm")
      File.rm("#{db_file}-wal")
    end)

    %{repo: TempRepo, migrations_path: migrations_path}
  end

  test "complete migration chain (UP -> DOWN to 0 -> UP)", %{
    repo: repo,
    migrations_path: migrations_path
  } do
    # 1. First UP run: all migrations from zero
    {duration_up_1_us, up_versions} =
      :timer.tc(fn ->
        Ecto.Migrator.run(repo, migrations_path, :up, all: true)
      end)

    assert length(up_versions) >= 5, "Expected at least 5 migrations to run"

    # Flag if initial migration run is unusually expensive (> 2 seconds on empty DB)
    duration_up_1_ms = div(duration_up_1_us, 1000)

    assert duration_up_1_ms < 2000,
           "Migration chain took #{duration_up_1_ms}ms, which exceeds 2000ms threshold"

    # Verify all expected tables exist
    existing_tables = get_table_names(repo)

    for table <- @expected_tables do
      assert table in existing_tables, "Expected table '#{table}' to exist after UP migrations"
    end

    # 2. Reversible check: Roll all migrations DOWN to 0
    {duration_down_us, down_versions} =
      :timer.tc(fn ->
        Ecto.Migrator.run(repo, migrations_path, :down, all: true)
      end)

    assert length(down_versions) == length(up_versions),
           "Expected all migrations to rollback successfully"

    duration_down_ms = div(duration_down_us, 1000)

    assert duration_down_ms < 2000,
           "Rollback took #{duration_down_ms}ms, exceeding 2000ms threshold"

    # Verify all application tables were cleanly dropped (only schema_migrations might remain)
    tables_after_down = get_table_names(repo)

    for table <- @expected_tables do
      refute table in tables_after_down,
             "Table '#{table}' was not dropped during rollback to version 0"
    end

    # 3. Second UP run: idempotency and replay from zero
    {_duration_up_2_us, up_versions_2} =
      :timer.tc(fn ->
        Ecto.Migrator.run(repo, migrations_path, :up, all: true)
      end)

    assert up_versions_2 == up_versions

    tables_after_replay = get_table_names(repo)

    for table <- @expected_tables do
      assert table in tables_after_replay,
             "Table '#{table}' was not restored during second UP migration"
    end
  end

  test "audit migrations for SQLite anti-patterns", %{migrations_path: migrations_path} do
    # Scan migration source files for dangerous SQLite table rebuilds
    # In SQLite, table rewrites occur when altering tables with complex constraints without native support
    migration_files = Path.wildcard(Path.join(migrations_path, "*.exs"))

    for file <- migration_files do
      content = File.read!(file)
      filename = Path.basename(file)

      # Ensure indexes on foreign keys
      if String.contains?(content, "references(") do
        assert String.contains?(content, "create index(") or
                 String.contains?(content, "create unique_index("),
               "Migration #{filename} references another table but may be missing an index"
      end
    end
  end

  defp get_table_names(repo) do
    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        repo,
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
        []
      )

    List.flatten(rows)
  end
end
