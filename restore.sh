#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# HERMES HOMELAB — VOLUME RESTORE
# Restores a backup created by backup.sh into hermes volumes.
#
# ⚠ This OVERWRITES current volume data.
#
# Usage: bash restore.sh ./backups/hermes-backup-20260920-143000.tar.gz
# ══════════════════════════════════════════════════════════════════════
set -e

BACKUP_FILE="$1"

if [ -z "$BACKUP_FILE" ]; then
  echo "Usage: bash restore.sh <backup-file.tar.gz>"
  exit 1
fi

if [ ! -f "$BACKUP_FILE" ]; then
  echo "Error: File not found: $BACKUP_FILE"
  exit 1
fi

ABSOLUTE_PATH="$(cd "$(dirname "$BACKUP_FILE")" && pwd)/$(basename "$BACKUP_FILE")"

echo "[restore] WARNING: This will OVERWRITE all hermes volume data."
echo "[restore] Backup file: $BACKUP_FILE"
read -p "[restore] Continue? (y/N) " -n 1 -r
echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "[restore] Aborted."
  exit 0
fi

echo "[restore] Stopping container..."
docker compose down

echo "[restore] Restoring volumes..."
docker run --rm \
  -v hermes-workspace:/data/workspace \
  -v hermes-config:/data/config \
  -v hermes-home:/data/home \
  -v "$ABSOLUTE_PATH:/backup.tar.gz:ro" \
  alpine:3.19 \
  sh -c "rm -rf /data/workspace/* /data/config/* /data/home/* && \
         tar xzf /backup.tar.gz -C /data"

echo "[restore] Restarting container..."
docker compose up -d

echo "[restore] Done."
