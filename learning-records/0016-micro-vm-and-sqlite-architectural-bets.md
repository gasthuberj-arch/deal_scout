# Mastered Micro-VM & SQLite Architectural Invariants

Identified and extracted key engineering principles from production performance breakdowns under strict deployment constraints (Fly.io 512 MB RAM / 1 shared vCPU / single-volume SQLite).

## Evidence
- Authored Lesson 0013 and interactive verification checkpoint dissecting the false assumptions that triggered cgroups OOM, database upgrade deadlocks, and dirty headless shutdowns.
- Established Reference Card 0013 covering memory multiplication math, `BEGIN IMMEDIATE` intent declaration, and OTP signal contracts.

## Key Insights
- **Multiplicative Pool State:** Memory buffers multiply across connection pools ($N_{\text{connections}} \times \text{Buffer Size}$). Library defaults (`-64000` KiB &times; 5 conns = 312.5 MiB) assume unconstrained environments and trigger instantaneous Linux cgroups v2 OOM kills in micro-VMs.
- **Fail-Fast Intent (The Lock Upgrade Trap):** In single-writer engines, `BEGIN DEFERRED` transactions deadlock when concurrent connections read before writing (`SHARED` cannot upgrade to `RESERVED`). Declaring write intent at the root with `BEGIN IMMEDIATE` serializes writers in the busy handler.
- **Physical Invariant Alignment:** Proxy admission control (`soft_limit`, `hard_limit`) must match the physical ceiling of the single node. Exclusive NVMe block storage prevents horizontal autoscaling, making phantom proxy autoscaling dangerous.
- **Process Boundary Protocol Alignment:** Container orchestrators sending default `SIGINT` freeze headless Erlang/OTP runtimes in the interactive `BREAK` handler until `SIGKILL`. Explicitly configuring `SIGTERM` enables graceful application draining and clean SQLite WAL checkpoints.
- **Streaming Over Materialization:** Snapshotting SQLite databases into `/tmp` (`VACUUM INTO`) consumes precious RAM on tmpfs. Streaming WAL mutations continuously via Litestream provides sub-second RPO with zero container memory overhead.
