#!/usr/bin/env bash
set -e

# Ensure data directory and litestream replica directory exist
mkdir -p "${LITESTREAM_REPLICA_PATH:-/data/litestream}"

# If litestream is installed and config is present, use litestream replicate --exec
if command -v litestream >/dev/null 2>&1 && [ -f /etc/litestream.yml ]; then
  echo "[DealScout Entrypoint] Launching Litestream replication daemon wrapping /app/bin/server..."
  exec litestream replicate -config /etc/litestream.yml -exec "/app/bin/server"
else
  echo "[DealScout Entrypoint] Launching /app/bin/server directly..."
  exec /app/bin/server
fi
