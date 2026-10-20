# DealScout Real-Time NAS Backup & Restore (NixOS)

This directory contains the client and NixOS configuration to pull real-time SQLite backups from your remote DealScout Phoenix server down to your homelab NAS.

---

## Architecture Overview

```
 +---------------------------------------------------------+
 |           Fly.io / Remote Server (DealScout)            |
 |                                                         |
 |  [DealScout Phoenix App]                                |
 |     │                                                   |
 |     │ Writes WAL transactions                           |
 |     ▼                                                   |
 |  [/data/deal_scout.db]                                  |
 |     ▲                                                   |
 |     │ Monitored by Litestream                           |
 |  [Litestream Replicate Daemon]                          |
 |     │                                                   |
 |     │ Outputs immutable LTX / WAL frames                |
 |     ▼                                                   |
 |  [/data/litestream/] (Local replica cache)              |
 |     │                                                   |
 |  [DealScout.Backup.Watcher]                             |
 |     │                                                   |
 |     ▼ Streams new frames via WebSocket                  |
 |  [DealScoutWeb.BackupChannel (/socket/backup)]          |
 +─────────────────────────▲───────────────────────────────+
                           │
             Outbound WSS  │ (Zero open ports on NAS)
             Encrypted     │ Bearer Token Auth
             WebSocket     │ Auto-reconnecting
                           │
 +─────────────────────────┴───────────────────────────────+
 |                   NixOS NAS / Homelab                   |
 |                                                         |
 |  [dealscout_backup_client.py (systemd service)]         |
 |     │                                                   |
 |     │ Verifies SHA-256 and saves atomically             |
 |     ▼                                                   |
 |  [/var/lib/dealscout-backup/]                           |
 |     ├── generations/                                    |
 |     │   └── <uuid>/                                     |
 |     │       ├── snapshots/                              |
 |     │       └── wal/                                    |
 |     │                                                   |
 |     │ Automatic 24h Verification:                       |
 |     ▼                                                   |
 |  `litestream restore` ──► `PRAGMA integrity_check;`     |
 +---------------------------------------------------------+
```

### Key Highlights
1. **Zero Open Ports on NAS:** The NAS initiates an outbound WebSocket connection to DealScout. No port forwarding, public IP, or dynamic DNS required on your NAS.
2. **Sub-second Deltas:** Litestream generates transaction frames as writes occur. The server pushes them to the NAS immediately over the persistent WebSocket.
3. **Asymmetric Retention:** Server maintains ~48 hours of frames to protect Fly's 1GB volume; NAS keeps all historical frames (30+ days) for point-in-time recovery.
4. **Guaranteed Integrity:** Client validates SHA-256 for each incoming frame, and runs an automated periodic restore + `PRAGMA integrity_check;`.

---

## NixOS Setup Options

### Option 1: Declarative NixOS Flake / Module (Recommended)

1. Add DealScout to your system flake inputs (or import `./module.nix` directly):
```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    dealscout.url = "path:/path/to/deal_scout/clients/nas-backup"; # or git repo
  };

  outputs = { self, nixpkgs, dealscout }: {
    nixosConfigurations.your-nas = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        dealscout.nixosModules.backup
        {
          services.dealscout-backup = {
            enable = true;
            serverUrl = "wss://deal-scout.fly.dev";
            tokenFile = "/run/secrets/dealscout_backup_token"; # sops-nix / agenix
            backupDir = "/var/lib/dealscout-backup";
            verifyIntervalHours = 24;
          };
        }
      ];
    };
  };
}
```

2. Rebuild your NixOS system:
```bash
sudo nixos-rebuild switch
```

3. Check service status:
```bash
systemctl status dealscout-backup
journalctl -u dealscout-backup -f
```

---

### Option 2: Standalone Execution via `nix-shell`

You can run the backup client directly without adding it to your NixOS configuration:

```bash
nix-shell -p "python3.withPackages (ps: [ ps.websockets ])" litestream sqlite \
  --run "python3 ./dealscout_backup_client.py \
    --server-url wss://deal-scout.fly.dev \
    --token YOUR_ADMIN_BACKUP_TOKEN \
    --backup-dir $HOME/backups/deal_scout"
```

For a one-shot sync and exit:
```bash
python3 ./dealscout_backup_client.py --once ...
```

---

## Verifying Backup & Restoring

### 1. Check Live Backup Status
You can query DealScout's status endpoint from any authenticated machine:
```bash
curl -H "Authorization: Bearer YOUR_ADMIN_BACKUP_TOKEN" \
  https://deal-scout.fly.dev/api/admin/backup/status | jq .
```

### 2. Manual Integrity Check on NAS
```bash
litestream restore -o /tmp/check.db file:///var/lib/dealscout-backup
sqlite3 /tmp/check.db "PRAGMA integrity_check;"
rm /tmp/check.db
```

### 3. Disaster Recovery (Restoring to Server)
If your Fly.io volume is destroyed or corrupted:

Run the interactive recovery tool:
```bash
./scripts/restore-to-server.sh /var/lib/dealscout-backup
```

You can also specify a target timestamp for point-in-time recovery:
```bash
./scripts/restore-to-server.sh /var/lib/dealscout-backup "2026-10-20T12:00:00Z"
```

The tool will:
1. Run `litestream restore` into a temporary SQLite file.
2. Execute `PRAGMA integrity_check;` and display table row counts.
3. Offer automated restoration via `fly sftp put` or SSH.
