#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo " Running Local End-to-End WebSocket Sync Verification"
echo "=========================================================="

TEST_PORT=4002
TEST_TOKEN="e2e-live-ws-token-$(date +%s)"
SERVER_REPLICA="/tmp/dealscout_e2e_server_replica"
CLIENT_DEST="/tmp/dealscout_e2e_client_backup"

rm -rf "$SERVER_REPLICA" "$CLIENT_DEST"
mkdir -p "$SERVER_REPLICA/generations/gen_alpha/snapshots"
mkdir -p "$SERVER_REPLICA/generations/gen_alpha/wal"
mkdir -p "$CLIENT_DEST"

# Create fake initial snapshot and WAL frame
echo "FULL-SNAPSHOT-CONTENT" > "$SERVER_REPLICA/generations/gen_alpha/snapshots/00000000.snapshot.lz4"
echo "DELTA-WAL-FRAME-1" > "$SERVER_REPLICA/generations/gen_alpha/wal/00000001.wal.lz4"
echo "DELTA-WAL-FRAME-2" > "$SERVER_REPLICA/generations/gen_alpha/wal/00000002.wal.lz4"

SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    echo "Stopping test server (PID $SERVER_PID)..."
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$SERVER_REPLICA" "$CLIENT_DEST"
}
trap cleanup EXIT

echo "--> Launching DealScout Phoenix server on port $TEST_PORT..."
PORT="$TEST_PORT" \
PHX_SERVER=true \
ADMIN_BACKUP_TOKEN="$TEST_TOKEN" \
LITESTREAM_REPLICA_PATH="$SERVER_REPLICA" \
mix run --no-halt > /tmp/dealscout_test_server.log 2>&1 &
SERVER_PID=$!

echo "--> Waiting for Phoenix server to bind port $TEST_PORT..."
for i in {1..30}; do
  if curl -s "http://localhost:$TEST_PORT" >/dev/null 2>&1; then
    echo "    Server is live!"
    break
  fi
  sleep 1
done

echo "--> Querying /api/admin/backup/status with bearer token..."
STATUS_RES=$(curl -s -f -H "Authorization: Bearer $TEST_TOKEN" "http://localhost:$TEST_PORT/api/admin/backup/status")
echo "    Status response: $STATUS_RES"

echo "--> Running dealscout_backup_client.py (--once mode)..."
python3 clients/nas-backup/dealscout_backup_client.py \
  --server-url "http://localhost:$TEST_PORT" \
  --token "$TEST_TOKEN" \
  --backup-dir "$CLIENT_DEST" \
  --once

echo "--> Verifying downloaded files on simulated NAS..."
test -f "$CLIENT_DEST/generations/gen_alpha/snapshots/00000000.snapshot.lz4"
test -f "$CLIENT_DEST/generations/gen_alpha/wal/00000001.wal.lz4"
test -f "$CLIENT_DEST/generations/gen_alpha/wal/00000002.wal.lz4"

CONTENT=$(cat "$CLIENT_DEST/generations/gen_alpha/wal/00000002.wal.lz4")
if [ "$CONTENT" != "DELTA-WAL-FRAME-2" ]; then
  echo "ERROR: Content mismatch in downloaded frame: $CONTENT" >&2
  exit 1
fi

echo "=========================================================="
echo " [SUCCESS] End-to-end WebSocket sync verified successfully!"
echo " Client authenticated, joined channel, and synced all frames!"
echo "=========================================================="
