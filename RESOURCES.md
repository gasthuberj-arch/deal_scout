# Architecture & Design Skills Resources

## Knowledge

- [Book: *A Philosophy of Software Design* by John Ousterhout](https://web.stanford.edu/~ouster/cgi-bin/book.php)
  Foundational text introducing deep vs. shallow modules, information hiding, interface complexity, and "design it twice." Use for: evaluating interface leverage and complexity hiding.
- [Book: *Use The Index, Luke!* by Markus Winand](https://use-the-index-luke.com/)
  Definitive guide to SQL indexing, B-Tree leaf traversal, composite indexes, and eliminating sort operations. Use for: query optimization and feed stream performance.
- [Book: *Designing Data-Intensive Applications* by Martin Kleppmann](https://dataintensive.net/)
  Covers stream processing, inverted indexes, cache stampedes, and distributed system trade-offs. Use for: reverse search architectures and caching strategies.
- [Documentation: Elasticsearch Percolate Query](https://www.elastic.co/guide/en/elasticsearch/reference/current/query-dsl-percolate-query.html)
  Architecture patterns for reverse search (matching documents against standing queries in stream processors).
- [Article: *Exponential Backoff And Jitter* by Marc Brooker (AWS Architecture Blog)](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/)
  Foundational analysis comparing Full Jitter, Equal Jitter, and Decorrelated Jitter to stop synchronized retry storms across distributed clients. Use for: poller retry algorithms.
- [Article: *Regular Expression Matching Can Be Simple And Fast* by Russ Cox](https://swtch.com/~rsc/regexp/regexp1.html)
  Explains the difference between backtracking NFAs and linear DFAs. Use for: understanding ReDoS vulnerabilities and Aho-Corasick performance.
- [Documentation: PostgreSQL Advisory Locks](https://www.postgresql.org/docs/current/explicit-locking.html#ADVISORY-LOCKS)
  Authoritative reference for application-level distributed mutexes, session cleanup semantics, and non-blocking lock acquisition. Use for: cluster poller consensus.
- [Documentation: SQLite FTS5 External Content Tables](https://www.sqlite.org/fts5.html#external_content_tables)
  Official SQLite guide on backing an FTS5 virtual table with an external relational table (`content='deals'`) to avoid duplicating indexed text columns inside `_content` shadow tables.
- [Documentation: SQLite CREATE TRIGGER (`AFTER UPDATE OF`)](https://www.sqlite.org/lang_createtrigger.html)
  Authoritative reference for column-scoped update triggers (`AFTER UPDATE OF col1, col2`) and trigger execution order during bulk `UPDATE` statements.
- [Documentation: SQLite Partial Indexes](https://www.sqlite.org/partialindex.html)
  Explains how `CREATE INDEX ... WHERE expr` indexes only sparse subsets of rows (such as `WHERE country IS NOT NULL`), keeping index size small and `IS NOT NULL` counts fast.
- [Documentation: SQLite Write-Ahead Logging & Checkpointing](https://www.sqlite.org/wal.html#ckpt)
  Details how WAL frames accumulate during bulk mutations and how `PRAGMA wal_checkpoint(TRUNCATE)` resets the WAL file for deterministic migration benchmarking.
- [Documentation: Phoenix LiveView Security Model (`live_session`)](https://hexdocs.pm/phoenix_live_view/security-model.html)
  Explains why live navigation (`navigate={...}`) cannot cross `live_session` boundaries over WebSockets and why cross-session links must use standard `href={...}` requests.
- [Documentation: Elixir `GenServer.handle_continue/2`](https://hexdocs.pm/elixir/GenServer.html#c:handle_continue/2)
  Official OTP callback pattern for deferring expensive initialization work out of `init/1` so supervision tree startup and port binding never block.
- [Book: *Working Effectively with Legacy Code* by Michael Feathers](https://www.oreilly.com/library/view/working-effectively-with/0131177052/)
  Introduces the concept of a "seam": a place where you can alter behavior without editing in that place. Use for: seam discipline and testability.
- [Skill: `codebase-design` (.agents/skills/codebase-design/SKILL.md)](.agents/skills/codebase-design/SKILL.md)
  The core project vocabulary for deep modules, interface depth, dependency categories, and the parallel sub-agent "Design It Twice" pattern.
- [Skill: `grilling` (.agents/skills/grilling/SKILL.md)](.agents/skills/grilling/SKILL.md)
  Technique for interrogating architecture plans systematically across a design tree frontier to eliminate hidden assumptions.

## Wisdom (Communities)

- [Elixir Forum](https://elixirforum.com/)
  High-signal community for discussing Elixir architecture, boundary design, and LiveView patterns. Use for: real-world sanity checks on Elixir module design.
- [Software Engineering Stack Exchange](https://softwareengineering.stackexchange.com/)
  Use for: comparing interface design trade-offs, port/adapter patterns, and testing seams.
