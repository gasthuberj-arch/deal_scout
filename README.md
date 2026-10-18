# DealScout 🎯

A real-time German RSS deal monitor and keyword alert system built with **Elixir, Phoenix LiveView, and SQLite**.

DealScout continuously monitors and aggregates the five largest German deal portals, parses deal prices and merchants, evaluates user keyword criteria in real-time, and streams instant alerts to the browser.

---

## ✨ Features

- **5 Preconfigured Deal Portals**:
  - [MyDealz](https://www.mydealz.de/rss)
  - [DealDoktor](https://www.dealdoktor.de/feed/)
  - [MonsterDealz](https://www.monsterdealz.de/feed/)
  - [Schnäppchenfuchs](https://schnaeppchenfuchs.com/rss)
  - [Mein-Deal](https://www.mein-deal.com/feed/)
- **Zero-Polling Client**: Uses Phoenix LiveView streams and PubSub. New deals and alert matches appear instantly without page refreshes.
- **Advanced Keyword Alert Rules**:
  - **Required Keywords**: Multi-token phrase and comma-separated OR matching (e.g., `RTX 4080, RTX 5080`).
  - **Negative/Exclusion Keywords**: Ignore unwanted deals (e.g., `defekt, kühler, zubehör, suche`).
  - **Max Price Threshold**: Alert only if price $\le$ your budget.
  - **Source Filter**: Limit alerts to specific portals or watch all portals.
- **Matched Deals Inbox & Web Audio Chime**:
  - Dedicated inbox tracking unread matched deals.
  - Optional browser synthesized audio chime (two-tone Web Audio API, zero audio assets needed).
- **Invite-Gated Registration**: Built-in authentication (`phx.gen.auth`) protected by a secret invite code (`INVITE_CODE`) so you can share access with friends safely.
- **Safe Homelab / NAS Backups**:
  - Atomic hot SQLite snapshots via `VACUUM INTO` on `GET /api/admin/backup`.
  - Protected with Bearer token authentication (`ADMIN_BACKUP_TOKEN`).
  - Pull-based: Your locked-down homelab NAS or Tailscale node pulls daily snapshots with **zero open inbound ports**.
- **Automated Retention**: Built-in maintenance worker automatically purges deals older than 30 days to keep the SQLite database lean.

---

## 🛠️ Tech Stack & Philosophy (Free-Tier Friendly)

| Layer | Technology | Rationale |
| :--- | :--- | :--- |
| **Backend** | Elixir 1.18+ / OTP 27 | Exceptional concurrency, GenServers, and fault tolerance |
| **Web UI** | Phoenix 1.8 (LiveView + DaisyUI + Tailwind) | Reactive real-time frontend without JS framework fatigue |
| **Storage** | SQLite3 (`ecto_sqlite3` + `exqlite`) | Zero setup, single-file database, fast and free |
| **HTTP Client** | `Req` | Fast HTTP client with conditional requests (`ETag` / `If-Modified-Since`) |
| **Parser** | `Floki` | Fast XML and HTML parsing, extracts clean text, prices, and thumbnails |

---

## 🚀 Quick Start (Local Development)

### Prerequisites
- Elixir 1.17+ and Erlang/OTP 27
- Node.js is **not required** (esbuild & tailwind run standalone)

### 1. Setup & Install Dependencies
```bash
cd ~/code/deal_scout
mix setup
```

### 2. Populate Deal Feeds
```bash
mix run priv/repo/seeds.exs
```

### 3. Start Phoenix Server
```bash
mix phx.server
# or inside IEx:
iex -S mix phx.server
```

Now visit [`http://localhost:4000`](http://localhost:4000) in your browser.

- Default invite code for new sign-ups: `dealscout2026`
- To inspect outgoing confirmation emails in development: [`http://localhost:4000/dev/mailbox`](http://localhost:4000/dev/mailbox)

---

## 🔒 Environment Variables

| Variable | Default (Dev) | Description |
| :--- | :--- | :--- |
| `INVITE_CODE` | `dealscout2026` | Secret code required when creating a new user account |
| `ADMIN_BACKUP_TOKEN` | `dealscout-homelab-backup-key-2026` | Bearer token for accessing `/api/admin/backup` |
| `DATABASE_PATH` | `deal_scout_dev.db` (dev) / `/data/deal_scout.db` (prod) | Path to SQLite database file |
| `SECRET_KEY_BASE` | *(generated in dev)* | Secret key for cookies and tokens (required in prod) |
| `PHX_SERVER` | `true` | Enables HTTP server in production releases |

---

## 📦 Pull-Based Homelab / NAS Backups

Since your homelab is locked down behind Tailscale without public inbound access, the homelab **initiates the backup pull**:

1. Copy `scripts/pull-nas-backup.sh` to your NAS or homelab server.
2. Configure your environment:
   ```bash
   export DEAL_SCOUT_URL="https://your-deal-scout.fly.dev"
   export ADMIN_BACKUP_TOKEN="your-secure-token"
   export BACKUP_DIR="/volume1/backups/deal_scout"
   ```
3. Run the script manually or add to `crontab` (e.g. daily at 3:00 AM):
   ```cron
   0 3 * * * /home/user/scripts/pull-nas-backup.sh >> /var/log/deal_scout_backup.log 2>&1
   ```

The script requests an atomic hot SQLite snapshot (`VACUUM INTO`), saves it locally with timestamps, and automatically rotates snapshots older than 14 days.

---

## ☁️ Deployment to Fly.io ($0 Free Allowance)

DealScout is configured to run on Fly.io with a single 1GB persistent SQLite volume:

### 1. Launch Fly App
```bash
fly launch --no-deploy
```

### 2. Create Persistent Volume for SQLite
```bash
fly volumes create deal_scout_data --size 1 --region fra
```

### 3. Set Production Secrets
```bash
fly secrets set \
  SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  INVITE_CODE="your-family-secret" \
  ADMIN_BACKUP_TOKEN="your-secure-backup-token"
```

### 4. Deploy
```bash
fly deploy
```

---

## 📝 Design Decisions & Compromises Made

1. **SQLite over PostgreSQL**:
   - *Rationale*: Zero server maintenance, zero running database daemons, runs entirely within the single Fly.io machine free allowance with a 1GB persistent volume.
   - *Trade-off*: Multi-node horizontal scaling is not supported (DealScout runs as a single primary node). For personal and friend group use, a single BEAM node with SQLite easily handles tens of thousands of deals and concurrent WebSockets.
2. **Pull-Based Backup over Push Replication**:
   - *Rationale*: Accommodates homelabs locked down behind Tailscale with zero inbound ports. The NAS pulls atomic snapshots on a timer.
   - *Trade-off*: Not continuous streaming WAL replication (like Litestream). Backups are periodic snapshots (e.g. daily), which is acceptable because deals are public/ephemeral and only user alert rules need disaster recovery.
3. **HTTP Polling (2-min interval) over Web Scraping**:
   - *Rationale*: Avoids Cloudflare/anti-bot bans from Pepper/MyDealz, preserves server bandwidth using conditional `ETag` and `If-Modified-Since` headers.
   - *Trade-off*: 0 to 120-second latency after deal publication, and feed retention is limited to the last 20–50 deals published per portal.
4. **Web Audio Synthesis over MP3/WAV Assets**:
   - *Rationale*: Generates a crisp two-tone audio alert using standard browser Web Audio API oscillator nodes, requiring 0 external assets and 0 bandwidth.
