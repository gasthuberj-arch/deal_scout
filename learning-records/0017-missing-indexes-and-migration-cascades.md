# Mastered Missing Indexes and Migration Cascades

Captured the failure modes of unindexed sparse filters, OR-disjunction query scans, and unscoped trigger cascades during SQLite migrations.

## Evidence
- Authored Lesson 0014 and interactive checkpoint covering partial indexes, column-scoped triggers, and external-content FTS5 tables.
- Synthesized the real-world DealScout migration fix (`OptimizeDealStorageAndExternalFts`) and the seeded N-1 migration performance gate in `test/deal_scout/repo_migration_test.exs`.

## Key Insights
- **Partial Indexes for Sparse Columns:** Creating `WHERE column IS NOT NULL` partial indexes avoids indexing millions of null rows, keeping B-trees tiny and replacing full-table scans with fast index seeks.
- **The OR Disjunction Trap:** Queries joining conditions across multiple columns with `OR` (e.g. `published_at >= ^t or inserted_at >= ^t`) defeat single-column B-tree indexes and force full table scans.
- **Unscoped Trigger Cascades:** Naked `AFTER UPDATE ON <table>` triggers fire on updates to *any* column. Running a bulk update (e.g. clearing descriptions) fires row-by-row FTS index modifications for every row, ballooning the WAL and locking the database.
- **Bulk Migration Discipline:** Always drop triggers before running bulk data transformations, and rebuild full-text search indexes once at the end using `INSERT INTO deals_fts(deals_fts) VALUES('rebuild')`.
- **External-Content FTS5:** Specifying `content='deals'` prevents FTS5 from duplicating all raw text in hidden shadow tables, reducing disk and cache footprints by over 60%.
