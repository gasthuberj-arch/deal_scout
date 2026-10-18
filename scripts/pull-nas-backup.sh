#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# DealScout NAS Backup Pull Script
# Runs on your locked-down Homelab/NAS (e.g. via cron or systemd timer)
# Pulls an atomic SQLite snapshot via HTTP over Tailscale or direct URL.
# Zero inbound ports required on your NAS.
# ==============================================================================

# Configuration
DEAL_SCOUT_URL="${DEAL_SCOUT_URL:-http://localhost:4000}"
BACKUP_TOKEN="${ADMIN_BACKUP_TOKEN:-dealscout-homelab-backup-key-2026}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/deal_scout}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TARGET_FILE="$BACKUP_DIR/deal_scout_$TIMESTAMP.db"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Requesting atomic backup from $DEAL_SCOUT_URL..."

if curl -s -f -H "Authorization: Bearer $BACKUP_TOKEN" \
  "$DEAL_SCOUT_URL/api/admin/backup" \
  -o "$TARGET_FILE"; then

  FILE_SIZE=$(du -h "$TARGET_FILE" | cut -f1)
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup successfully downloaded to $TARGET_FILE ($FILE_SIZE)"

  # Prune backups older than RETENTION_DAYS
  find "$BACKUP_DIR" -type f -name "deal_scout_*.db" -mtime +"$RETENTION_DAYS" -exec rm -f {} +
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleaned up backups older than $RETENTION_DAYS days."
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Failed to pull backup from $DEAL_SCOUT_URL" >&2
  exit 1
fi
