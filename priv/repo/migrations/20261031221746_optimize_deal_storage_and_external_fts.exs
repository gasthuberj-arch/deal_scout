defmodule DealScout.Repo.Migrations.OptimizeDealStorageAndExternalFts do
  use Ecto.Migration

  def up do
    # Drop old FTS triggers and table first so clearing `description` doesn't fire 1-by-1 FTS updates
    execute("DROP TRIGGER IF EXISTS deals_ai;")
    execute("DROP TRIGGER IF EXISTS deals_ad;")
    execute("DROP TRIGGER IF EXISTS deals_au;")
    execute("DROP TABLE IF EXISTS deals_fts;")

    # Clear redundant raw HTML descriptions now that clean_text and metadata are extracted at parse time
    execute("UPDATE deals SET description = NULL WHERE description IS NOT NULL;")

    # External-content FTS5 table backed directly by `deals` to avoid duplicating text in `deals_fts_content`
    execute("""
    CREATE VIRTUAL TABLE deals_fts USING fts5(
      title,
      clean_text,
      merchant,
      content='deals',
      content_rowid='id',
      tokenize='unicode61 remove_diacritics 2'
    );
    """)

    execute("""
    CREATE TRIGGER deals_ai AFTER INSERT ON deals BEGIN
      INSERT INTO deals_fts(rowid, title, clean_text, merchant)
      VALUES (new.id, new.title, new.clean_text, new.merchant);
    END;
    """)

    execute("""
    CREATE TRIGGER deals_ad AFTER DELETE ON deals BEGIN
      INSERT INTO deals_fts(deals_fts, rowid, title, clean_text, merchant)
      VALUES ('delete', old.id, old.title, old.clean_text, old.merchant);
    END;
    """)

    execute("""
    CREATE TRIGGER deals_au AFTER UPDATE OF title, clean_text, merchant ON deals BEGIN
      INSERT INTO deals_fts(deals_fts, rowid, title, clean_text, merchant)
      VALUES ('delete', old.id, old.title, old.clean_text, old.merchant);
      INSERT INTO deals_fts(rowid, title, clean_text, merchant)
      VALUES (new.id, new.title, new.clean_text, new.merchant);
    END;
    """)

    execute("INSERT INTO deals_fts(deals_fts) VALUES('rebuild');")
  end

  def down do
    execute("DROP TRIGGER IF EXISTS deals_ai;")
    execute("DROP TRIGGER IF EXISTS deals_ad;")
    execute("DROP TRIGGER IF EXISTS deals_au;")
    execute("DROP TABLE IF EXISTS deals_fts;")

    execute("""
    CREATE VIRTUAL TABLE IF NOT EXISTS deals_fts USING fts5(
      title,
      clean_text,
      merchant,
      tokenize='unicode61 remove_diacritics 2'
    );
    """)

    execute("""
    CREATE TRIGGER IF NOT EXISTS deals_ai AFTER INSERT ON deals BEGIN
      INSERT INTO deals_fts(rowid, title, clean_text, merchant)
      VALUES (new.id, coalesce(new.title, ''), coalesce(new.clean_text, ''), coalesce(new.merchant, ''));
    END;
    """)

    execute("""
    CREATE TRIGGER IF NOT EXISTS deals_ad AFTER DELETE ON deals BEGIN
      DELETE FROM deals_fts WHERE rowid = old.id;
    END;
    """)

    execute("""
    CREATE TRIGGER IF NOT EXISTS deals_au AFTER UPDATE OF title, clean_text, merchant ON deals BEGIN
      DELETE FROM deals_fts WHERE rowid = old.id;
      INSERT INTO deals_fts(rowid, title, clean_text, merchant)
      VALUES (new.id, coalesce(new.title, ''), coalesce(new.clean_text, ''), coalesce(new.merchant, ''));
    END;
    """)

    execute("""
    INSERT OR REPLACE INTO deals_fts(rowid, title, clean_text, merchant)
    SELECT id, coalesce(title, ''), coalesce(clean_text, ''), coalesce(merchant, '')
    FROM deals;
    """)
  end
end
