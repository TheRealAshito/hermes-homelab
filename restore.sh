#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# HERMES HOMELAB — RESTORE
# Restores a backup created by backup.sh.
# ⚠ This OVERWRITES current data.
#
# Usage: bash restore.sh ./backups/hermes-backup-20260920-143000.tar.gz
# ══════════════════════════════════════════════════════════════════════
set -e

BACKUP_FILE="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR=$(grep "^DATA_DIR=" "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2 || echo "./data")

if [ -z "$BACKUP_FILE" ]; then
  echo "Usage: bash restore.sh <backup-file.tar.gz>"
  exit 1
fi

if [ ! -f "$BACKUP_FILE" ]; then
  echo "Error: File not found: $BACKUP_FILE"
  exit 1
fi

echo "[restore] WARNING: This will OVERWRITE all hermes data."
echo "[restore] Backup: $BACKUP_FILE"
echo "[restore] Target: $DATA_DIR"
read -p "[restore] Continue? (y/N) " -n 1 -r
echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "[restore] Aborted."
  exit 0
fi

echo "[restore] Stopping container..."
cd "$SCRIPT_DIR" && docker compose down

echo "[restore] Restoring..."
rm -rf "$DATA_DIR"/{workspace,hermes-config}/*
tar xzf "$BACKUP_FILE" -C "$SCRIPT_DIR"

echo "[restore] Restarting..."
docker compose up -d

echo "[restore] Done."
