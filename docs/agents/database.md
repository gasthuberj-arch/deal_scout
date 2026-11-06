# Database & Persistence Guidelines

Reference for Ecto schemas, SQLite operations, migrations, and caching in DealScout.

---

## 1. SQLite Architectural Realities

- **Driver**: `ecto_sqlite3` backed by `exqlite`.
- **Concurrency**: SQLite supports one writer at a time with concurrent readers (WAL mode).
- **Single primary**: Multi-node concurrent writing is unsupported by SQLite. DealScout runs as a single primary BEAM node with backup sync.
- **Large batches & transactions**: Keep write transactions tight. Avoid holding a write transaction across long HTTP requests or external API calls.

---

## 2. Ecto Schemas & Changesets

- **String fields**: In `Ecto.Schema`, use `:string` for all text columns (even SQLite text columns).
- **Programmatic attributes**: Fields assigned by system logic (e.g. `user_id`, `verified_at`, `canonical_deal_id`) must not be cast in user changesets. Set them explicitly:
  ```elixir
  %Deal{}
  |> cast(attrs, [:title, :url, :price, :merchant])
  |> put_assoc(:user, current_scope.user)
  ```
- **Number validation**: `validate_number/2` only validates non-nil changes. The `:allow_nil` option is unsupported and unnecessary.
- **Field access**: Always use `Ecto.Changeset.get_field(changeset, :field)` to read changeset values; schemas and changesets do not implement `Access`.
- **Association preloads**: Always preload associations (`Repo.preload/2` or `preload: [...]` in queries) when fields like `deal.merchant.name` or `match.user.email` are accessed in templates.

---

## 3. Migrations

- Always create migration files via Mix:
  ```bash
  mix ecto.gen.migration descriptive_migration_name
  ```
- Use composite indexes tailored to SQLite query planner realities (e.g. `create index(:deals, [:source_feed_id, :inserted_at])`).
- When dropping or altering tables with SQLite foreign keys, ensure index dependencies and triggers are handled explicitly.
