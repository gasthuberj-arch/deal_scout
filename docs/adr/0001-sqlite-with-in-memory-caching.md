# 0001: SQLite with In-Memory Caching over PostgreSQL

We run DealScout as a single-node BEAM instance on SQLite3 (`ecto_sqlite3` with WAL mode and FTS5) backed by in-memory caching (`DealScout.Analytics.Warmer` and `DealScout.KeywordEngine`) rather than hosting PostgreSQL or DuckDB.

### Context & Trade-off
PostgreSQL and DuckDB add external daemons, connection pooling complexity, network latency, and monthly cloud hosting costs. SQLite runs in-process with zero network hops and zero ongoing maintenance, easily running within Fly.io's free tier with a 1GB persistent volume. 

The trade-off is that DealScout is intentionally single-node (writes are serialized by SQLite). For our domain (a fast deal scanner with ephemeral deal ingestion and user alert rules), a single BEAM node with GenServers and SQLite handles thousands of rules and live WebSockets without scaling bottlenecks.
