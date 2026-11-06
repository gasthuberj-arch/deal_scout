# DealScout 🎯

A high-performance real-time German RSS deal monitor and keyword alert system built with **Elixir, Phoenix LiveView, and SQLite**.

DealScout continuously aggregates deals from major German deal portals, normalizes prices and merchant metadata in real time, evaluates user keyword rules via compiled in-memory automatons, and streams instant alerts to the browser.

---

## 📚 Documentation & Architecture Guides

| Document | Description |
| :--- | :--- |
| **[`GLOSSARY.md`](GLOSSARY.md)** | Canonical domain terms, architecture vocabulary, and naming rules |
| **[`ROADMAP.md`](ROADMAP.md)** | Detailed feature roadmap and architecture specifications |
| **[`AGENTS.md`](AGENTS.md)** | Guidelines, invariants, and context pointers for AI agents |
| **[`docs/adr/`](docs/adr/)** | Architectural Decision Records (ADRs) |
| **[`docs/fly-io-elixir-sqlite-optimization.md`](docs/fly-io-elixir-sqlite-optimization.md)** | Production guide for zero-cost Fly.io micro-VM SQLite deployment |

---

## ✨ Key Features

- **Multi-Portal Aggregation**: Ingests feeds from [MyDealz](https://www.mydealz.de/rss), [DealDoktor](https://www.dealdoktor.de/feed/), [MonsterDealz](https://www.monsterdealz.de/feed/), [Schnäppchenfuchs](https://schnaeppchenfuchs.com/rss), and [Mein-Deal](https://www.mein-deal.com/feed/).
- **Zero-Polling Real-Time Feed**: Powered by Phoenix LiveView streams and PubSub. New deals stream to the UI with constant memory footprint.
- **Compiled Keyword Matching Engine**:
  - Multi-token required phrases and comma-separated OR queries (e.g. `RTX 4080, RTX 5080`).
  - Negative/exclusion keywords (e.g. `defekt, kühler, zubehör, suche`).
  - Price ceilings and portal source filters.
  - In-memory Aho-Corasick prefiltering and compute guard protection against pathological queries.
- **Matched Deals Inbox & Web Audio Alerts**:
  - Persistent inbox tracking unread matches.
  - Browser-synthesized two-tone audio chime (Web Audio API, zero audio assets needed).
- **Safe Homelab / NAS Backups**:
  - Hot SQLite snapshots via `VACUUM INTO` on `GET /api/admin/backup`.
  - Bearer token authentication (`ADMIN_BACKUP_TOKEN`).
  - Pull-based: Homelab or NAS pulls daily snapshots with **zero open inbound ports**.
- **Automated Retention**: Built-in background worker purges deals older than 30 days to keep the SQLite database lean.
- **Invite-Gated Registration**: Built-in authentication (`phx.gen.auth`) protected by a secret invite code (`INVITE_CODE`).

---

## 🛠️ Tech Stack & Philosophy (Free-Tier Friendly)

| Layer | Technology | Rationale |
| :--- | :--- | :--- |
| **Backend** | Elixir 1.18+ / OTP 27 | Fault-tolerant concurrency, GenServers, and real-time PubSub |
| **Web UI** | Phoenix 1.8 (LiveView + Tailwind CSS v4) | Reactive UI without JS framework fatigue; DaisyUI for primitives |
| **Storage** | SQLite3 (`ecto_sqlite3` + `exqlite`) | Single-file database, zero setup, fast and free |
| **HTTP Client** | `Req` | Fast HTTP requests with conditional `ETag` and `If-Modified-Since` caching |
| **Parser** | `Floki` | Fast XML and HTML parsing for deal descriptions and prices |
| **Search & Index** | SQLite FTS5 + In-Memory Aho-Corasick | Hybrid historical backtesting and instant streaming matching |

---

## 🚀 Quick Start (Local Development)

### Prerequisites
- Elixir 1.17+ and Erlang/OTP 27
- Node.js is **not required** (esbuild and tailwind run standalone)

### 1. Setup & Install Dependencies
```bash
cd ~/code/deal_scout
mix setup
```

### 2. Populate Deal Feeds & Seed Data
```bash
mix run priv/repo/seeds.exs
```

### 3. Run Quality & Test Checks
```bash
mix precommit
```

### 4. Start Phoenix Server
```bash
mix phx.server
# or inside IEx:
iex -S mix phx.server
```

Visit [`http://localhost:4000`](http://localhost:4000) in your browser.
- Default invite code for registration: `dealscout2026`
- Outgoing confirmation emails in dev: [`http://localhost:4000/dev/mailbox`](http://localhost:4000/dev/mailbox)

---

## 🔒 Key Environment Variables

| Variable | Default (Dev) | Description |
| :--- | :--- | :--- |
| `INVITE_CODE` | `dealscout2026` | Secret code required when creating a new user account |
| `ADMIN_BACKUP_TOKEN` | *(required in prod)* | Bearer token for accessing `/api/admin/backup` |
| `ADMIN_PASSWORD` | `dealscout2026!` | Initial admin password used by `priv/repo/seeds.exs` |
| `DATABASE_PATH` | `deal_scout_dev.db` (dev) / `/data/deal_scout.db` (prod) | Path to SQLite database file |
| `COFFEE_URL` | `https://ko-fi.com` | Optional Ko-fi profile URL for the support modal |
| `EBAY_CLIENT_ID` | *(optional)* | eBay Developer App ID for the eBay sniper poller |
| `EBAY_CLIENT_SECRET` | *(optional)* | eBay Developer App Secret for OAuth2 authentication |
| `EBAY_ENABLED` | `true` | Set to `false` to disable the eBay background poller |
| `PHX_SERVER` | `true` | Enables HTTP server in production releases |

---

## 📦 Pull-Based Homelab / NAS Backups

Since a home NAS is typically behind NAT or Tailscale without public inbound ports, the NAS **initiates the backup pull**:

1. Copy `scripts/pull-nas-backup.sh` to your NAS or homelab server.
2. Configure your environment:
   ```bash
   export DEAL_SCOUT_URL="https://your-deal-scout.fly.dev"
   export ADMIN_BACKUP_TOKEN="your-secure-token"
   export BACKUP_DIR="/volume1/backups/deal_scout"
   ```
3. Run manually or schedule in `crontab` (e.g. daily at 3:00 AM):
   ```cron
   0 3 * * * /home/user/scripts/pull-nas-backup.sh >> /var/log/deal_scout_backup.log 2>&1
   ```

The script requests an atomic SQLite snapshot (`VACUUM INTO`), saves it locally with timestamps, and rotates snapshots older than 14 days.

---

## ☁️ Deployment to Fly.io

DealScout runs on Fly.io with a single 1GB persistent SQLite volume:

```bash
# 1. Create app configuration
fly launch --no-deploy

# 2. Create persistent volume for SQLite in Frankfurt (fra)
fly volumes create deal_scout_data --size 1 --region fra

# 3. Set production secrets
fly secrets set \
  SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  INVITE_CODE="your-family-secret" \
  ADMIN_BACKUP_TOKEN="your-secure-backup-token"

# 4. Deploy
fly deploy
```

---

## 📝 Key Architectural Decisions

1. **SQLite over PostgreSQL**: Single-file storage running directly on the Fly.io micro-VM volume. Eliminates database daemon overhead and network latency. Multi-node write concurrency is unnecessary for single-instance deal monitoring.
2. **Pull-Based Backup over Push Replication**: Allows firewalled homelabs to safely pull hot SQLite backups without exposing any ports.
3. **HTTP Polling (2-min interval) with Conditional Headers**: Preserves feed bandwidth using `ETag` and `If-Modified-Since` headers while avoiding Cloudflare bans.
4. **Web Audio Synthesis**: Browser Web Audio API oscillator creates audio chime without external MP3/WAV assets.
