#!/usr/bin/env bash
set -e

# Ensure data directory and image cache directory exist
mkdir -p /data/image_cache

exec /app/bin/server
