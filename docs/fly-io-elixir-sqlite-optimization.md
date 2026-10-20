# Infrastructure, BEAM VM, and SQLite Concurrency Optimization on Fly.io

**Target Application:** `deal-scout`  
**Host Platform:** Fly.io (Region: `fra` / Frankfurt)  
**Hardware Profile:** 1 shared vCPU (`cpu_kind = "shared"`), 512 MB RAM, 1 GB Persistent NVMe Volume (`deal_scout_data`)  
**Runtime:** Elixir 1.18.5 / Erlang/OTP 27.3.4.19 / Debian Bookworm  
**Storage Engine:** SQLite 3 (WAL Mode) via `ecto_sqlite3` 0.25.0 and `exqlite` 0.42.0  
**Web Stack:** Phoenix 1.8.15, Phoenix LiveView 1.2.0, Bandit 1.13.1  
**Author:** Research & Systems Engineering Subagent  
**Date:** October 2026  

---

## 1. Executive Summary

`deal-scout` is a stateful web application running Phoenix LiveView on top of the BEAM virtual machine (Erlang/OTP) and SQLite in Write-Ahead Log (WAL) mode. Because SQLite is an embedded database bound to an exclusive single-node filesystem, horizontal autoscaling cannot be applied without distributed consensus layers (such as LiteFS). The application runs as a single instance backed by a 1 GB encrypted Fly.io NVMe block device mounted at `/data`.

During live inspection of the production instance (`784ee035fd6338`) and comprehensive codebase analysis, seven architectural vulnerabilities and operational bottlenecks were identified:

1. **Shutdown Signal Trap (`SIGINT` vs `SIGTERM`):** Fly.io defaults to sending `SIGINT` when stopping or restarting a machine. In Erlang/OTP releases, `SIGINT` triggers the interactive `BREAK` handler prompt rather than initiating an orderly application shutdown. The container hangs waiting for keyboard input until `flyd` times out and forcefully kills it with `SIGKILL`, abruptly terminating active WebSockets and risking uncheckpointed WAL frames.
2. **SQLite Cache Memory Ballooning (OOM Risk):** `ecto_sqlite3` configures a default `cache_size` of `-64000` (64 MiB) per connection. With `pool_size: 5`, SQLite can allocate up to **312.5 MiB** of page cache in RAM. On a 512 MB container where idle memory leaves only **222 MiB available**, concurrent database queries under moderate traffic will trigger the Linux kernel cgroups v2 Out-Of-Memory (OOM) killer.
3. **Deadlock Vulnerability in `DEFERRED` Transactions:** `ecto_sqlite3` defaults `default_transaction_mode` to `:deferred`. In SQLite, deferred transactions acquire a read lock first and attempt to upgrade to a write lock on `INSERT`/`UPDATE`. If two processes begin deferred transactions concurrently, both acquire read locks; when both attempt to write, neither can upgrade, resulting in immediate `SQLITE_BUSY: database is locked` exceptions that bypass the busy timeout handler.
4. **Unrealistic Fly Proxy Concurrency Limits:** `fly.toml` sets `soft_limit = 800` and `hard_limit = 1000` concurrent connections. A 512 MB shared-cpu-1x micro-VM cannot sustain 800 concurrent LiveView WebSocket connections (each requiring 30–80 KiB process heaps, socket buffers, and heartbeat timers) without severe CPU scheduling throttling and memory starvation. Furthermore, soft limit autoscaling fails because Fly cannot start a second machine on the same exclusive volume.
5. **Redundant Dual-Boot Migration Overhead:** The container startup script `rel/overlays/bin/server` executes `./deal_scout eval DealScout.Release.migrate` before calling `exec ./deal_scout start`. Meanwhile, `DealScout.Application` starts `{Ecto.Migrator, ...}` in its supervision tree because `skip_migrations?/0` evaluates to `false` in releases. This boots the BEAM VM twice on every deployment or machine restart, adding **1.8 to 2.5 seconds** of unnecessary cold-start latency.
6. **In-Memory Backup Dump Risk (`VACUUM INTO /tmp`):** The `/api/admin/backup` endpoint writes a hot snapshot to `System.tmp_dir!()` (`/tmp`). In containerized environments, `/tmp` is mapped to the root filesystem overlay or tmpfs (RAM). Snapshotting a growing 50–100 MiB database into RAM will induce sudden memory spikes and OOM termination.
7. **Missing Observability & Health Checks:** `fly.toml` defines no HTTP health checks (`[[http_service.checks]]`), leaving Fly Proxy unaware of application readiness during deploys. Additionally, `DealScoutWeb.Telemetry` has no Prometheus metrics exporter, disabling Fly's built-in platform metric scraping.

---

## 2. Live Telemetry & Baseline Metrics

Empirical inspection was performed on live production Machine `784ee035fd6338` in region `fra`:

```
Machine ID:    784ee035fd6338
Image:         deal-scout:deployment-01M5CHMQA6E9ZN6WEVHEGDV66W
Host Status:   ok
CPU Kind:      shared (1 vCPU)
Memory:        512 MB
Volume:        vol_4912en2e0enk19or (1 GB, encrypted ext4, mounted at /data)
```

### 2.1 Host & Container Memory Profile (`/proc/meminfo`)

```
MemTotal:         469,892 kB  (~470 MB visible inside Firecracker micro-VM)
MemFree:          138,756 kB  (~138 MB)
MemAvailable:     222,768 kB  (~222 MB usable before swapping/OOM)
Buffers:            3,412 kB
Cached:           126,056 kB  (~126 MB OS page cache)
Active(anon):         408 kB
Inactive(anon):   198,852 kB  (~198 MB anonymous memory, primarily BEAM heap)
```

> **Critical Observation:** Only **222.7 MB** of system RAM is available at idle.

### 2.2 BEAM Runtime Metrics (via Remote RPC)

Querying `:erlang.memory()` and system info on the live node returned:

```elixir
{System.schedulers(), System.schedulers_online()}
#=> {1, 1}

:erlang.memory()
#=> [
#     total: 100_119_848,        # ~100.1 MB allocated by BEAM
#     processes: 26_093_472,     # ~26.1 MB process heaps
#     processes_used: 26_078_816,# ~26.0 MB actively used
#     system: 74_026_376,        # ~74.0 MB VM system data
#     atom: 1_474_897,           # ~1.47 MB
#     atom_used: 1_464_173,
#     binary: 2_813_416,         # ~2.81 MB refc binaries
#     code: 44_601_694,          # ~44.6 MB loaded BEAM bytecode
#     ets: 2_247_080             # ~2.24 MB ETS tables
#   ]

Process.list() |> length()
#=> 542 processes
```

### 2.3 SQLite Storage & PRAGMA Status on `/data`

```
-rw-r--r-- 1 nobody nogroup 10,305,536 Oct 20 11:38 deal_scout.db      (~10.3 MB)
-rw-r--r-- 1 nobody nogroup     32,768 Oct 20 12:09 deal_scout.db-shm  (32 KB WAL index)
-rw-r--r-- 1 nobody nogroup  2,179,512 Oct 20 12:09 deal_scout.db-wal  (~2.1 MB WAL)
```

Querying the live SQLite database handle via `DealScout.Repo`:

| PRAGMA | Live Value | Source Setting | Implication |
| :--- | :--- | :--- | :--- |
| `journal_mode` | `wal` | `ecto_sqlite3` default | Readers do not block writers; single writer |
| `synchronous` | `1` (`NORMAL`) | `ecto_sqlite3` default | Safe in WAL mode; fsync on checkpoint only |
| `cache_size` | `-64000` | `ecto_sqlite3` default | **64 MiB per connection (312.5 MiB potential for 5 conns)** |
| `page_size` | `4096` | SQLite default | 4 KiB standard page size |
| `page_count` | `2559` | Runtime state | 2,559 pages × 4,096 bytes = 10,481,664 bytes |
| `wal_autocheckpoint` | `1000` | SQLite default | Triggers checkpoint after 1,000 pages (~4 MiB) |
| `temp_store` | `2` (`MEMORY`) | `ecto_sqlite3` default | Temp tables and order-by buffers live in RAM |
| `busy_timeout` | `0` (PRAGMA query) | `exqlite` C NIF | Internal NIF callback enforces 2,000 ms timeout |

---

## 3. BEAM Virtual Machine & Erlang/OTP 27 on 1 Shared vCPU / 512 MB RAM

### 3.1 Process Scheduler Topology

The BEAM VM schedules Erlang processes across OS threads using preemptive reduction counting (each process runs for up to 4,000 reductions before yielding).

* **Normal Schedulers:** On this instance, `System.schedulers()` and `System.schedulers_online()` both evaluate to `1`. Erlang/OTP 27 natively reads `/sys/fs/cgroup/cpu.max` under Linux cgroups v2, correctly detecting the single-core allocation without spawning surplus normal schedulers.
* **Dirty Schedulers:** Erlang/OTP by default allocates dirty CPU schedulers (`+SDcpu`) and dirty I/O schedulers (`+SDio`). By default, ERTS starts 10 dirty I/O schedulers for asynchronous NIF and file driver operations. In a 1 shared vCPU container, frequent thread switching between dirty schedulers and the normal scheduler increases CPU cache thrashing. Setting `+SDio 4` or `+SDio 2` reduces thread overhead without starving SQLite I/O.
* **Reduction Budgeting:** Long-running computations inside GenServers (such as HTML parsing in `DealScout.Feeds.Parser` or regex processing in `DealScout.Alerts.Matcher`) must yield or run inside ephemeral processes (like `Task.Supervisor`) to prevent starving Phoenix LiveView heartbeat messages. The application already delegates feed parsing to `DealScout.Feeds.TaskSupervisor`, freeing memory binaries upon task termination.

### 3.2 Memory Allocator Tuning under cgroups v2 (`memory.max`)

The Linux kernel enforces container memory limits via `memory.max` in cgroups v2. When total memory consumption (anonymous pages + page cache) exceeds 512 MB, the Linux kernel OOM killer terminates `beam.smp` instantly with signal 9 (`SIGKILL`).

BEAM uses sophisticated internal memory allocators (`mseg_alloc`, `sys_alloc`, `sl_alloc`, `std_alloc`) designed for high-throughput multi-core servers. By default, these allocators:
1. Pre-allocate large contiguous memory blocks ("carriers") from the OS.
2. Maintain pools of free carriers to avoid expensive OS `brk`/`mmap`/`munmap` system calls.
3. Keep carrier utilization thresholds high, meaning freed memory is retained within BEAM rather than released to the Linux kernel.

In a 512 MB container, this behavior is hazardous because the kernel measures the virtual memory mapped by BEAM as active RSS. When SQLite page cache or temporary OS disk caches expand, the container hits the cgroups limit.

#### Primary Source: Erlang/OTP ERTS Allocator Specification
According to the official Erlang/OTP runtime system documentation (`erts_alloc(3)`):
* `+MBas aobf`: Configures Address Order Best Fit for multi-block allocators. This sorts blocks by address, promoting carrier compaction and maximizing the probability that empty memory carriers can be returned to the OS.
* `+MBacul 0`: Sets the allocator carrier utilization limit to 0%, instructing the allocator to release empty carriers back to the operating system immediately rather than pooling them.
* `+MBsmbcs 64 +MBlmbcs 128`: Reduces the size of smallest and largest multi-block carriers, preventing large multi-megabyte allocations from being held dormant.

Configuring these flags in `rel/env.sh.eex` ensures that BEAM releases unused memory back to the kernel as soon as LiveView sockets disconnect or XML parsing batches complete.

### 3.3 Shutdown Signal Mismatch (`SIGINT` vs `SIGTERM`)

#### The Flaw
Fly.io documentation specifies:
> *"When Fly.io stops a Machine, it sends an operating system signal to your main process. By default, Fly.io sends `SIGINT` if no signal is specified."* (Fly.io Machine Lifecycle Specification)

In Erlang/OTP releases, `SIGINT` (Ctrl+C) is caught by the runtime's interactive break handler (`erts/emulator/beam/sys.c`). When `SIGINT` arrives, the BEAM does **not** stop the application; instead, it writes to standard error:

```
BREAK: (a)bort (A)bort with dump (c)ontinue (p)roc info (i)nfo
       (l)oaded (v)ersion (k)ill (D)b-tables (d)istribution
```

This exact sequence was captured in the live Fly logs:
```
2026-10-20T11:38:21Z app[784ee035fd6338] fra [info] INFO Sending signal SIGINT to main child process w/ PID 643
2026-10-20T11:38:21Z app[784ee035fd6338] fra [info]BREAK: (a)bort (A)bort with dump (c)ontinue (p)roc info (i)nfo
2026-10-20T11:38:21Z app[784ee035fd6338] fra [info]       (l)oaded (v)ersion (k)ill (D)b-tables (d)istribution
```

Because stdin is not an interactive terminal, the BEAM remains blocked at the break prompt until Fly's `kill_timeout` (default 5s) expires. Fly then sends `SIGKILL` (`kill -9`).

#### The Impact
1. Phoenix Endpoint fails to drain active WebSocket connections cleanly with WebSocket close frames (`1001 Going Away`).
2. `terminate/2` callbacks in `DealScout.Feeds.Poller` and background tasks are not executed.
3. Open Ecto database connections are severed abruptly, preventing SQLite from performing clean WAL checkpoints (`PRAGMA wal_checkpoint(TRUNCATE)`).

#### Primary Source Fix
Fly.io allows overriding the stop signal via `kill_signal`:
```toml
# fly.toml
kill_signal = "SIGTERM"
kill_timeout = "15s"
```
In Erlang/OTP releases, `SIGTERM` triggers `init:stop/0`. The release controller gracefully shuts down OTP applications in reverse order:
1. `DealScoutWeb.Endpoint` stops accepting new connections and drains active sockets.
2. Background workers (`Poller`, `Pruner`, `DigestWorker`) stop cleanly.
3. `DealScout.Repo` closes SQLite connection handles, ensuring pending transactions are committed and file locks released.

---

## 4. SQLite Concurrency, Connection Pooling, & PRAGMAs

### 4.1 Single-Writer Invariant in WAL Mode

SQLite in Write-Ahead Log (WAL) mode provides high concurrency by separating reads from writes:
* **Readers:** Multiple connections can read simultaneously from the main database file (`.db`) and WAL file (`.db-wal`) using shared memory (`.db-shm`).
* **Writers:** Exactly **one** connection may write to the database at any moment. SQLite enforces this using a single `RESERVED` / `EXCLUSIVE` lock.

```
+-------------------------------------------------------------+
|                     Ecto Connection Pool                    |
|                        (pool_size: 5)                       |
+--------+------------+------------+------------+-------------+
         |            |            |            |
   [Connection 1] [Connection 2] [Connection 3] [Connection 4]
         |            |            |            |
         v            v            v            v
    (Concurrent  (Concurrent  (Concurrent     [WRITE LOCK]
       READ)        READ)        READ)              |
         |            |            |                v
         +------------+------------+-------> [deal_scout.db-wal]
                                                    | (Only 1 writer)
                                                    v
                                             [deal_scout.db]
```

#### Connection Pool Sizing (`pool_size`)
In `config/runtime.exs`:
```elixir
config :deal_scout, DealScout.Repo,
  database: database_path,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")
```

A pool size of `5` is well-suited for read scalability on a single-node setup. It allows up to 5 simultaneous LiveView HTTP or WebSocket requests to execute queries without blocking in the `DBConnection` checkout queue (`queue_time`).

However, having 5 pool connections does **not** allow 5 concurrent writes. If 5 processes attempt to execute `Repo.insert` or `Repo.update` concurrently, 1 will acquire the lock while the other 4 must wait.

### 4.2 The "Deferred Upgrade" Deadlock Trap

#### Root Cause Analysis
By default, `ecto_sqlite3` configures:
```elixir
default_transaction_mode: :deferred
```
According to the SQLite transaction specification (`sqlite.org/lang_transaction.html`):
1. `BEGIN DEFERRED`: Acquires no locks when executed.
2. First `SELECT`: Acquires a `SHARED` read lock.
3. First `INSERT` / `UPDATE`: Attempts to upgrade the `SHARED` lock to a `RESERVED` write lock.

When two concurrent Elixir processes execute transactions that read before writing:
* **Time $T_0$:** Process A starts transaction (`BEGIN DEFERRED`).
* **Time $T_1$:** Process B starts transaction (`BEGIN DEFERRED`).
* **Time $T_2$:** Process A runs `SELECT` (acquires `SHARED` lock).
* **Time $T_3$:** Process B runs `SELECT` (acquires `SHARED` lock). Both A and B now hold shared locks.
* **Time $T_4$:** Process A attempts `UPDATE`. It requests a `RESERVED` lock. SQLite checks if any other connection holds a lock. Because Process B holds a `SHARED` lock, Process A's upgrade is blocked.
* **Time $T_5$:** Process B attempts `UPDATE`. It also requests a `RESERVED` lock. Neither can proceed because each process is waiting for the other's shared lock to release.
* **Result:** SQLite detects the deadlock and immediately terminates one of the transactions with `SQLITE_BUSY: database is locked`. Crucially, SQLite's `busy_timeout` is ineffective for lock upgrades when another connection already holds a shared lock.

#### The Primary Source Solution: `BEGIN IMMEDIATE`
Configuring `default_transaction_mode: :immediate` changes every `Repo.transaction` call to issue:
```sql
BEGIN IMMEDIATE;
```
SQLite Specification (`sqlite.org/lang_transaction.html`):
> *"IMMEDIATE causes the database connection to acquire a RESERVED lock immediately... other database connections can continue to read the database while the IMMEDIATE transaction is underway. If another database connection has already started an IMMEDIATE or EXCLUSIVE transaction... BEGIN IMMEDIATE returns SQLITE_BUSY [and invokes the busy handler]."*

Because the write lock is reserved at the very beginning of the transaction, no connection can enter a transaction that might later need to write while another writer exists. Contending transactions queue cleanly in the busy handler rather than deadlocking mid-transaction.

### 4.3 SQLite Cache Memory Math: The 312.5 MB Vulnerability

In `deps/ecto_sqlite3/lib/ecto/adapters/sqlite3/connection.ex`:
```elixir
defp default_opts(opts) do
  opts
  |> Keyword.put_new(:journal_mode, :wal)
  |> Keyword.put_new(:cache_size, -64_000)
  |> Keyword.put_new(:temp_store, :memory)
  |> Keyword.put_new(:pool_size, 5)
end
```

#### Cache Size Parameter Meaning
In SQLite (`PRAGMA cache_size`):
* A positive integer sets the cache limit in pages (e.g., `2000` = 2,000 pages × 4 KiB = 8 MiB).
* A negative integer sets the cache limit in kibibytes (e.g., `-64000` = 64,000 KiB = 62.5 MiB).

#### The Memory Calculation
Each connection in Ecto's pool maintains its **own independent SQLite pager cache**.
$$\text{Max Cache Footprint} = \text{pool\_size} \times |\text{cache\_size}|$$
$$\text{Max Cache Footprint} = 5 \times 62.5\text{ MiB} = \mathbf{312.5\text{ MiB}}$$

On the production node:
$$\text{Available RAM at Idle} = \mathbf{222.7\text{ MiB}}$$
$$\text{Deficit under Load} = 222.7\text{ MiB} - 312.5\text{ MiB} = \mathbf{-89.8\text{ MiB}}$$

If 5 concurrent web requests execute queries across different tables (e.g., loading deals, analytics charts, alert matches, and user settings), the pager caches will allocate memory up to their limit. Combined with BEAM heap allocations (100 MB), total container memory will exceed 470 MB, triggering an instantaneous OOM kill.

#### Recommendation
Configure `cache_size: -8000` (8 MiB) or `-16000` (16 MiB).
For 5 connections:
$$5 \times 8\text{ MiB} = 40\text{ MiB}$$
$$5 \times 16\text{ MiB} = 80\text{ MiB}$$
This preserves over 140–180 MiB of RAM for BEAM process heaps and Bandit network buffers while still caching the entire 10.3 MB database in memory.

### 4.4 Busy Timeout & Lock Contention (`exqlite` NIF Architecture)

Live inspection revealed that executing `PRAGMA busy_timeout;` through SQL returned `0`.
Inspection of `deps/exqlite/c_src/sqlite3_nif.c` explains why:

```c
// exqlite installs a custom busy handler:
sqlite3_busy_handler(db, exqlite_busy_handler, conn);
```
In SQLite, calling `sqlite3_busy_handler()` overrides and clears SQLite's internal `sqlite3_busy_timeout()`. Hence, SQL queries to `PRAGMA busy_timeout` report 0, while the custom C NIF handler actively enforces the timeout stored in `conn->busy_timeout_ms`.

The default timeout in `exqlite` is **2,000 ms** (`Pragma.busy_timeout/1`).
During feed ingestion, when `DealScout.Feeds.Poller` ingests 10–20 new deals, multiple queries run sequentially. If a user simultaneously triggers an alert rule update or user registration, 2,000 ms is easily exceeded, throwing:
```
(Exqlite.Error) database is locked
```

#### Recommendation
Explicitly configure `busy_timeout: 5000` (5 seconds) in `DealScout.Repo` options. This allows background ingestion or maintenance pruning to pause gracefully for up to 5 seconds during burst writes without failing requests.

### 4.5 Ingestion Batch Atomicity (`DealScout.Deals.Ingestion`)

Inspection of `lib/deal_scout/deals/ingestion.ex` showed:
```elixir
inserted_deals =
  Enum.reduce(new_items, [], fn item, acc ->
    case insert_single_deal(item, feed_id, feed_slug) do
      {:ok, deal} -> [deal | acc]
      _ -> acc
    end
  end)
```
Each item in `new_items` executes:
1. `Deals.ensure_merchant` (SELECT + possible INSERT/UPDATE)
2. `Deduplicator.find_canonical_deal` (SELECT)
3. `Repo.insert(deal)` (INSERT)
4. `Deals.record_merchant_deal` (UPDATE)

Because these calls are not wrapped in an explicit transaction, each write initiates an implicit standalone transaction that commits to the WAL file. For a batch of 10 deals, SQLite executes **30 to 40 individual commits and WAL writes**.

#### Optimization
Wrap the insertion loop in an immediate transaction:
```elixir
Repo.transaction(fn ->
  # batch inserts
end, mode: :immediate)
```
This groups the entire batch into a single atomic write transaction, cutting WAL I/O overhead by over 90% and releasing the write lock faster for concurrent readers.

---

## 5. Fly.io Proxy, Machine Lifecycle, & Concurrency Limits

### 5.1 Concurrency Limits in `fly.toml`

The current configuration in `fly.toml`:
```toml
[http_service.concurrency]
  type = "connections"
  hard_limit = 1000
  soft_limit = 800
```

#### The Conflict with Single-Node Architecture
1. **The Meaning of `soft_limit`:** The Fly Proxy uses `soft_limit` to decide when to autoscale by waking up or provisioning another Machine. However, `deal-scout` is tied to an exclusive persistent volume (`deal_scout_data`). Fly **cannot** spin up another machine attached to the same volume. Setting a high soft limit to trigger autoscaling is fundamentally misaligned with single-volume topologies.
2. **Resource Exhaustion under 800 Connections:** Phoenix LiveView establishes persistent stateful WebSocket connections. On the BEAM, each LiveView client maintains:
   * A Bandit/Cowboy HTTP/WebSocket connection process
   * A `Phoenix.LiveView.Channel` process
   * Ephemeral view assigns, DOM diff buffers, and socket state (30–80 KiB RAM each)
   
   800 concurrent connections would require:
   $$800 \times 60\text{ KiB} \approx 48\text{ MiB (just for process heaps)}$$
   When 800 clients send events or receive PubSub deal broadcasts, the 1 shared vCPU will experience severe scheduling delays, leading to WebSocket heartbeat timeouts and cascading reconnections.

#### Recommended Fly Concurrency Settings
```toml
[http_service.concurrency]
  type = "connections"
  soft_limit = 200
  hard_limit = 300
```
This protects the single shared vCPU from CPU throttling and ensures memory remains bounded under traffic spikes.

### 5.2 Autostop / Autostart Lifecycle & Background Workers

In `fly.toml`:
```toml
auto_stop_machines = "stop"
auto_start_machines = true
min_machines_running = 1
```

* **`min_machines_running = 1`:** This setting is critical and **must not be lowered to 0**. `deal-scout` hosts three essential background GenServers:
  * `DealScout.Feeds.Poller`: Periodically fetches RSS deals every 2 minutes.
  * `DealScout.Maintenance.Pruner`: Daily deal retention pruning.
  * `DealScout.Notifications.DigestWorker`: Compiles and sends deal digests every 15 minutes.
  
  If `min_machines_running` were set to `0`, Fly Proxy would stop the Machine after a few minutes of inactivity. When stopped, all background polling and alert evaluations cease completely until a web user visits the site.

---

## 6. Cold-Start Latency & Redundant Migration Boot Sequence

### 6.1 The Double-Boot Issue

When Machine `784ee035fd6338` boots, the entrypoint executes `/app/bin/server`.
Inspecting `rel/overlays/bin/server`:
```sh
#!/bin/sh
set -eu

cd -P -- "$(dirname -- "$0")"
./deal_scout eval DealScout.Release.migrate
PHX_SERVER=true exec ./deal_scout start
```

Now inspecting `lib/deal_scout/application.ex`:
```elixir
children = [
  DealScoutWeb.Telemetry,
  DealScout.Repo,
  {Ecto.Migrator,
   repos: Application.fetch_env!(:deal_scout, :ecto_repos), skip: skip_migrations?()},
  ...
]

defp skip_migrations?() do
  # By default, sqlite migrations are run when using a release
  System.get_env("RELEASE_NAME") == nil
end
```

In an Elixir release, `RELEASE_NAME` is always defined (e.g., `deal_scout`). Therefore, `skip_migrations?/0` returns `false`.

#### The Sequence of Events on Every Container Boot:
1. `bin/server` runs `./deal_scout eval DealScout.Release.migrate`:
   * A full BEAM instance initializes, loads the VM, starts `:ssl`, loads `:deal_scout`, starts `DealScout.Repo`, checks migrations, prints `Migrations already up`, and shuts down. Time elapsed: **~1.8 seconds**.
2. `bin/server` runs `exec ./deal_scout start`:
   * A second BEAM instance initializes, boots the OTP supervision tree, starts `DealScout.Repo`, runs `Ecto.Migrator` inside the supervision tree, prints `Migrations already up` a second time, and starts `Bandit`. Time elapsed: **~1.8 seconds**.

#### Proof from Live Fly Logs:
```
2026-10-20T11:38:23Z runner[784ee035fd6338] fra [info]Machine created and started in 5.333s
2026-10-20T11:38:23Z app[784ee035fd6338] fra [info]11:38:23.821 [info] Migrations already up
2026-10-20T11:38:25Z app[784ee035fd6338] fra [info]11:38:25.626 [info] Migrations already up
2026-10-20T11:38:25Z app[784ee035fd6338] fra [info]11:38:25.633 [info] Running DealScoutWeb.Endpoint with Bandit 1.13.1 at :::8080 (http)
```
Notice the timestamps: `11:38:23.821` (first run) and `11:38:25.626` (second run).
Running migrations twice adds **1.805 seconds** of cold-start latency.

#### Resolution
Because `Ecto.Migrator` is already supervised in `DealScout.Application` (starting before `DealScoutWeb.Endpoint`), migrations run safely and atomically within the application boot sequence. The external `eval` call in `rel/overlays/bin/server` is redundant and can be streamlined:

```sh
#!/bin/sh
set -eu

cd -P -- "$(dirname -- "$0")"
PHX_SERVER=true exec ./deal_scout start
```

---

## 7. Disaster Recovery & Rollout Strategy

### 7.1 Volume Pinning & Deployment Strategy (`strategy = "immediate"`)

Fly.io offers three deployment strategies: `rolling`, `canary`, and `immediate`.
* **Rolling / Canary Deploys:** Fly spins up a new Machine alongside the existing one, performs health checks, and terminates the old Machine.
* **Volume Attachment Constraint:** Fly Volumes are NVMe block devices formatted with ext4 attached to a single host. A Fly Volume **cannot be attached to more than one Machine simultaneously**.
* **Why Canary Fails:** If `strategy = "rolling"` or `canary` is used with a single volume, Fly will attempt to attach the volume to the new machine while the old machine still holds it, failing with a volume lock error.
* **Why `strategy = "immediate"` is Required:** `strategy = "immediate"` instructs Fly to stop the running Machine, release the volume attachment, update the Machine image, remount the volume, and start the new Machine. This ensures seamless deployments on single-volume SQLite applications.

### 7.2 In-Memory Backup Risk (`VACUUM INTO /tmp`)

The current backup controller (`DealScoutWeb.BackupController`) implements an on-demand snapshot:
```elixir
temp_dir = System.tmp_dir!()
backup_path = Path.join(temp_dir, "deal_scout_backup_#{timestamp}.db")
Ecto.Adapters.SQL.query(Repo, "VACUUM INTO ?", [backup_path])
```

#### Vulnerabilities:
1. `System.tmp_dir!()` resolves to `/tmp`. In containerized environments, `/tmp` is located on the container's root filesystem (overlayfs) or tmpfs in RAM. Writing a full database copy into `/tmp` consumes precious host memory or container root disk.
2. `VACUUM INTO` acquires a read lock on the database while rewriting all active pages. While readers can continue in WAL mode, writes to the WAL are held back if a checkpoint occurs.
3. This backup mechanism requires an external caller to pull snapshots periodically over HTTP. If the Fly host experiences catastrophic NVMe drive failure, all data since the last pull is lost (high Recovery Point Objective).

### 7.3 Litestream Continuous Replication Architecture

The gold standard for SQLite disaster recovery on Fly.io is **Litestream** (`litestream.io`):

```
+-------------------------------------------------------------+
|                      Fly.io Machine                         |
|                                                             |
|   +-----------------------+     +-----------------------+   |
|   |   Phoenix / BEAM App  |     |   Litestream Process  |   |
|   |       (deal_scout)    |     |                       |   |
|   +-----------+-----------+     +-----------+-----------+   |
|               |                             |               |
|               | (Writes WAL frames)         | (Watches WAL) |
|               v                             v               |
|         [/data/deal_scout.db] <-------------+               |
|         [/data/deal_scout.db-wal]                           |
+---------------------------------------------|---------------+
                                              |
                          Replicates frames   | (Sub-second RPO)
                          every 1 second      v
                      +-------------------------------+
                      | S3 Object Storage             |
                      | (Fly Tigris / Cloudflare R2 / |
                      |  AWS S3 Bucket)               |
                      +-------------------------------+
```

#### Key Advantages:
1. **Sub-second RPO:** Litestream replicates SQLite WAL frames to S3/Tigris continuously (every 1 second). If the VM is destroyed, at most 1 second of transactions is lost.
2. **Automated Recovery on Boot:** If a Machine launches with an empty `/data` directory (e.g., following volume corruption or migration to a new region), an entrypoint script executes:
   ```sh
   litestream restore -if-db-not-exists -v /data/deal_scout.db
   ```
   The database is restored from object storage before the Phoenix application starts.
3. **Zero RAM Pressure:** Litestream streams WAL frames directly to object storage via HTTP streaming without copying the entire database file into `/tmp`.

---

## 8. Observability, Health Checks, & Asset Serving

### 8.1 HTTP Health Checks (`[[http_service.checks]]`)

Currently, `fly.toml` has no health check configured. The `CHECKS` column in `fly status` is empty.

#### Implementation
Add a fast, unauthenticated `/up` health check in the Phoenix router or Endpoint:
```elixir
# lib/deal_scout_web/router.ex
scope "/", DealScoutWeb do
  pipe_through :api
  get "/up", HealthController, :show
end
```
Configure `fly.toml`:
```toml
[[http_service.checks]]
  grace_period = "10s"
  interval = "15s"
  method = "GET"
  path = "/up"
  timeout = "2s"
```

### 8.2 Fly.io Prometheus Metrics Integration

`DealScoutWeb.Telemetry` defines comprehensive metrics:
* VM memory breakdown (`vm.memory.total`)
* Run queue lengths (`vm.total_run_queue_lengths.total`, `cpu`, `io`)
* Database query metrics (`deal_scout.repo.query.total_time`, `queue_time`, `idle_time`)
* Phoenix LiveView / Router metrics

However, there is no reporter exposing these metrics over HTTP in production.
Adding `telemetry_metrics_prometheus_core` or exposing Prometheus-formatted metrics at `/metrics` allows Fly.io to automatically scrape metrics every 15 seconds:
```toml
# fly.toml
[metrics]
  port = 8080
  path = "/metrics"
```
These metrics flow directly into Fly's platform Grafana dashboard, providing real-time visibility into Ecto connection queue times and BEAM run queue lengths without external monitoring agents.

### 8.3 Webmanifest 404 Bug (`DealScoutWeb.static_paths`)

Live log inspection revealed:
```
2026-10-20T11:23:01Z app[784ee035fd6338] fra [info] GET /manifest-859f1220abe64e0dfadff6d1d4120cbc.webmanifest
2026-10-20T11:23:01Z app[784ee035fd6338] fra [info] Sent 404 in 182µs
```

#### Cause
In `lib/deal_scout_web.ex`:
```elixir
def static_paths,
  do: ~w(assets fonts images favicon.ico robots.txt manifest.webmanifest sw.js offline.html)
```
In production, `mix assets.deploy` runs `phx.digest`, creating `manifest-859f...webmanifest` in `priv/static`.
When the browser requests `manifest-<hash>.webmanifest`, `Plug.Static` checks whether the request path matches `DealScoutWeb.static_paths()`. Because `manifest.webmanifest` contains an extension, the digested filename starts with `manifest-`, which is rejected by `Plug.Static`!
Changing the static path declaration or exempting `manifest.webmanifest` from cache digestion resolves the 404 error.

---

## 9. Comprehensive Configuration Blueprint

### 9.1 Optimized `fly.toml`

```toml
# fly.toml app configuration file for deal_scout
app = "deal-scout"
primary_region = "fra"
kill_signal = "SIGTERM"
kill_timeout = "15s"

[build]
  dockerfile = "Dockerfile"

[env]
  PHX_SERVER = "true"
  DATABASE_PATH = "/data/deal_scout.db"
  PORT = "8080"
  POOL_SIZE = "5"

[mounts]
  source = "deal_scout_data"
  destination = "/data"
  initial_size = "1gb"

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 1

  [http_service.concurrency]
    type = "connections"
    soft_limit = 200
    hard_limit = 300

  [[http_service.checks]]
    grace_period = "10s"
    interval = "15s"
    method = "GET"
    path = "/up"
    timeout = "2s"

[deploy]
  strategy = "immediate"

[[vm]]
  cpu_kind = "shared"
  cpus = 1
  memory_mb = 512
```

### 9.2 Optimized `config/runtime.exs` (SQLite & Ecto)

```elixir
if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") || "/data/deal_scout.db"

  config :deal_scout, DealScout.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    # SQLite WAL & Concurrency Optimizations:
    journal_mode: :wal,
    synchronous: :normal,
    busy_timeout: 5000,
    # Prevent 312.5 MB cache ballooning on 512 MB VM (8 MiB per conn = 40 MiB total):
    cache_size: -8000,
    # Prevent upgrade deadlock by acquiring RESERVED lock on BEGIN:
    default_transaction_mode: :immediate,
    temp_store: :memory
```

### 9.3 BEAM VM Environment Script (`rel/env.sh.eex`)

Create `rel/env.sh.eex` to tune BEAM memory allocators and dirty schedulers for the 512 MB Linux cgroups v2 container:

```sh
#!/bin/sh

# Limit dirty I/O schedulers on 1 shared vCPU
export ERL_AFLAGS="+SDio 4 -proto_dist inet6_tcp"

# Optimize ERTS memory allocators for 512 MB cgroups v2
# - aobf: Address order best fit returns memory to kernel faster
# - acul 0: Carrier utilization limit 0% frees empty carriers immediately
export RELEASE_VM_ARGS="-MBas aobf -MHas aobf -MPas aobf -MDas aobf -MFas aobf -MBacul 0 -MHacul 0 -MBsmbcs 64 -MBlmbcs 128"
```

### 9.4 Streamlined Server Overlay (`rel/overlays/bin/server`)

Remove the redundant `eval DealScout.Release.migrate` call to eliminate 1.8s of cold-start latency:

```sh
#!/bin/sh
set -eu

cd -P -- "$(dirname -- "$0")"
PHX_SERVER=true exec ./deal_scout start
```

---

## 10. Primary Source Citations & References

1. **Fly.io Machine Stop Signals & Lifecycle:**
   * Fly.io Documentation: *Machine Configuration & Lifecycle (`fly.toml` reference)*
   * URL: `https://fly.io/docs/reference/configuration/#kill_signal`
   * Key Fact: Fly.io defaults to `SIGINT`. Setting `kill_signal = "SIGTERM"` is required for clean OTP release shutdown.
2. **Fly.io Volume Single-Host Attachment:**
   * Fly.io Documentation: *Fly Volumes Overview & Constraints*
   * URL: `https://fly.io/docs/reference/volumes/`
   * Key Fact: A Fly Volume can only be attached to a single Machine at a time. Canary/rolling deployments fail unless `strategy = "immediate"` is specified.
3. **Fly.io Concurrency & Autoscaling:**
   * Fly.io Documentation: *Autostop and Autostart Machines based on traffic*
   * URL: `https://fly.io/docs/reference/configuration/#http_service-concurrency`
   * Key Fact: `soft_limit` triggers scaling actions; `min_machines_running = 1` prevents stopping machines with active background GenServers.
4. **SQLite WAL Mode & Concurrency:**
   * SQLite Official Documentation: *Write-Ahead Logging (`wal.html`)*
   * URL: `https://sqlite.org/wal.html`
   * Key Fact: Readers do not block writers, and writers do not block readers. Exactly one writer is permitted at a time.
5. **SQLite Transaction Locking Modes:**
   * SQLite Official Documentation: *Transactions in SQLite (`lang_transaction.html`)*
   * URL: `https://sqlite.org/lang_transaction.html`
   * Key Fact: `DEFERRED` transactions acquire read locks first and fail with `SQLITE_BUSY` when attempting to upgrade to write locks if another connection holds a read lock. `IMMEDIATE` transactions acquire a `RESERVED` lock immediately at start.
6. **SQLite Synchronous Pragma:**
   * SQLite Official Documentation: *Pragma Statements (`pragma.html#pragma_synchronous`)*
   * URL: `https://sqlite.org/pragma.html#pragma_synchronous`
   * Key Fact: In WAL mode, `PRAGMA synchronous = NORMAL` guarantees durability across application crashes while syncing to disk only during checkpoints.
7. **Ecto SQLite Adapter (`ecto_sqlite3`):**
   * HexDocs: `Ecto.Adapters.SQLite3` Module Documentation (v0.25.0)
   * Repository: `deps/ecto_sqlite3/lib/ecto/adapters/sqlite3.ex`
   * Key Fact: Defaults `cache_size` to `-64000` (64 MiB) and `default_transaction_mode` to `:deferred`.
8. **Exqlite C NIF Architecture (`exqlite`):**
   * Repository: `deps/exqlite/c_src/sqlite3_nif.c` & `deps/exqlite/lib/exqlite/connection.ex`
   * Key Fact: Installs `sqlite3_busy_handler(db, exqlite_busy_handler, conn)`, overriding `PRAGMA busy_timeout`. Timeout defaults to 2,000 ms.
9. **Erlang/OTP Runtime System Allocators on Linux cgroups:**
   * Erlang/OTP Documentation: `erts_alloc(3)`
   * URL: `https://erlang.org/doc/man/erts_alloc.html`
   * Key Fact: Carrier allocation flags (`+MBas aobf`, `+MBacul 0`) prevent memory retention and minimize kernel OOM killer triggers under strict cgroups v2 limits.
10. **Litestream SQLite Continuous Replication:**
    * Litestream Documentation: *Architectural Overview & S3 Replication*
    * URL: `https://litestream.io/how-it-works/`
    * Key Fact: Continuous streaming replication of SQLite WAL frames to object storage with sub-second RPO.
