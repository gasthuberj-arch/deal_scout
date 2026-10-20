defmodule DealScout.Repo.Migrations.AddDealsFts do
  use Ecto.Migration

  def up do
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
    CREATE TRIGGER IF NOT EXISTS deals_au AFTER UPDATE ON deals BEGIN
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

  def down do
    execute("DROP TRIGGER IF EXISTS deals_ai;")
    execute("DROP TRIGGER IF EXISTS deals_ad;")
    execute("DROP TRIGGER IF EXISTS deals_au;")
    execute("DROP TABLE IF EXISTS deals_fts;")
  end
end
