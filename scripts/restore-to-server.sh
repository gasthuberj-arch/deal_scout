#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# DealScout Disaster Recovery Restore Script
# Restores a verified SQLite database from your NAS Litestream replica
# and uploads it back to your production server (Fly.io or custom host).
# ==============================================================================

BACKUP_DIR="${1:-${DEALSCOUT_BACKUP_DIR:-$HOME/backups/deal_scout}}"
RESTORE_TIMESTAMP="${2:-}"
FLY_APP="${FLY_APP:-deal-scout}"

echo "==================================================================="
echo " DealScout Disaster Recovery Restore Tool"
echo "==================================================================="
echo "Replica directory: $BACKUP_DIR"
if [ -n "$RESTORE_TIMESTAMP" ]; then
  echo "Target timestamp:  $RESTORE_TIMESTAMP (Point-in-time recovery)"
fi
echo "==================================================================="

if [ ! -d "$BACKUP_DIR/generations" ]; then
  echo "ERROR: No 'generations' directory found in $BACKUP_DIR." >&2
  echo "Make sure the backup directory contains the Litestream replica." >&2
  exit 1
fi

if ! command -v litestream >/dev/null 2>&1; then
  echo "ERROR: 'litestream' CLI tool is required on this machine." >&2
  echo "Install via: nix-shell -p litestream (NixOS) or brew/apt" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d)
RESTORED_DB="$TMP_DIR/deal_scout_restored.db"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "--> Restoring SQLite database from Litestream replica..."
RESTORE_ARGS=("-o" "$RESTORED_DB")
if [ -n "$RESTORE_TIMESTAMP" ]; then
  RESTORE_ARGS+=("-timestamp" "$RESTORE_TIMESTAMP")
fi
RESTORE_ARGS+=("file://$BACKUP_DIR")

litestream restore "${RESTORE_ARGS[@]}"

if [ ! -f "$RESTORED_DB" ]; then
  echo "ERROR: litestream restore failed to produce $RESTORED_DB" >&2
  exit 1
fi

echo "--> Verifying SQLite database integrity..."
if command -v sqlite3 >/dev/null 2>&1; then
  CHECK_RESULT=$(sqlite3 "$RESTORED_DB" "PRAGMA integrity_check;")
  if [ "$CHECK_RESULT" != "ok" ]; then
    echo "ERROR: PRAGMA integrity_check failed: $CHECK_RESULT" >&2
    exit 1
  fi
  echo "    [OK] PRAGMA integrity_check passed."

  DEAL_COUNT=$(sqlite3 "$RESTORED_DB" "SELECT count(*) FROM deals;" 2>/dev/null || echo "N/A")
  USER_COUNT=$(sqlite3 "$RESTORED_DB" "SELECT count(*) FROM users;" 2>/dev/null || echo "N/A")
  echo "    Stats: $DEAL_COUNT deals, $USER_COUNT users found in restored database."
else
  echo "    [WARN] sqlite3 CLI not found, skipping PRAGMA check."
fi

DB_SIZE=$(du -h "$RESTORED_DB" | cut -f1)
echo "--> Database restored and verified successfully ($DB_SIZE) at $RESTORED_DB"
echo ""
echo "Select restoration method:"
echo "1) Fly.io SFTP upload (Automated via fly CLI)"
echo "2) SSH / SCP upload (Direct copy to custom host/container)"
echo "3) Keep restored file and do manual copy"
read -r -p "Enter choice [1-3]: " CHOICE

case "$CHOICE" in
  1)
    if ! command -v fly >/dev/null 2>&1 && ! command -v flyctl >/dev/null 2>&1; then
      echo "ERROR: fly CLI is not installed." >&2
      exit 1
    fi
    FLY_BIN=$(command -v fly || command -v flyctl)

    echo "Fetching machines for app '$FLY_APP'..."
    $FLY_BIN machines list -a "$FLY_APP"

    read -r -p "Enter Machine ID to restore into: " MACHINE_ID

    echo "Stopping machine $MACHINE_ID to prevent SQLite lock contention..."
    $FLY_BIN machine stop "$MACHINE_ID" -a "$FLY_APP" || true

    echo "Uploading database via SFTP to /data/deal_scout.db..."
    $FLY_BIN sftp put "$RESTORED_DB" "/data/deal_scout.db" -a "$FLY_APP"

    echo "Starting machine $MACHINE_ID..."
    $FLY_BIN machine start "$MACHINE_ID" -a "$FLY_APP"

    echo "Done! Machine restarted with restored database."
    ;;

  2)
    read -r -p "Enter SSH target (e.g. user@server.com): " SSH_TARGET
    read -r -p "Enter remote path [/data/deal_scout.db]: " REMOTE_PATH
    REMOTE_PATH="${REMOTE_PATH:-/data/deal_scout.db}"

    echo "Copying to $SSH_TARGET:$REMOTE_PATH..."
    scp "$RESTORED_DB" "$SSH_TARGET:$REMOTE_PATH"
    echo "Done!"
    ;;

  3)
    DEST_FILE="${HOME}/deal_scout_restored_$(date +%Y%m%d_%H%M%S).db"
    cp "$RESTORED_DB" "$DEST_FILE"
    echo "Saved restored database to: $DEST_FILE"
    ;;

  *)
    echo "Invalid choice. Exiting."
    exit 1
    ;;
esac
