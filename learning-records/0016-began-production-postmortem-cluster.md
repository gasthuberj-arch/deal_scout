# Began Production Post-Mortem Cluster (Lessons 0013–0016)

Initiated a four-lesson post-mortem curriculum analyzing real mistakes recently introduced and fixed in DealScout across SQLite storage/migrations (`0622c75`, `a293663`), migration testing philosophy (`a293663` → `b03d524`), B-Tree/partial indexing and ETS cache refresh (`8baf24d`), and LiveView transport, Service Worker interception, cross-session navigation, and OTP startup blocking (`848901c`, `9fdf8f4`, `3f258c9`).

## Implications
- Connects the abstract vocabulary in [[GLOSSARY.md]] (such as **Implementation Coupling**, **Speculative Generality**, and **Seam** testing) directly to concrete mistakes we made in our own commits (e.g., writing and then deleting the 130-line AST migration linter in favor of the seeded `N-1 → N` WAL/runtime gate).
- Establishes operational guardrails for SQLite (`content='deals'` external-content FTS5, `AFTER UPDATE OF` column-scoped triggers, partial indexes) and Phoenix LiveView (`sessionStorage` LongPoll sticky flags, Service Worker `/live` bypass, `href` across `live_session` boundaries, and `handle_continue/2` boot non-blocking).
