#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# HERMES HOMELAB — BACKUP
# Creates a compressed tarball of all hermes data.
# Works with both named volumes and external storage (DATA_DIR).
#
# Usage: bash backup.sh [/path/to/backup/dir]
# ══════════════════════════════════════════════════════════════════════
set -e

BACKUP_DIR="${1:-./backups}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/hermes-backup-$TIMESTAMP.tar.gz"

# Source DATA_DIR from .env if present
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR=$(grep "^DATA_DIR=" "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2 || echo "./data")

echo "[backup] Creating backup..."
echo "[backup] Source: $DATA_DIR"
echo "[backup] Output: $BACKUP_FILE"

mkdir -p "$BACKUP_DIR"

if [ -d "$DATA_DIR" ]; then
  # External storage / local data dir
  tar czf "$BACKUP_FILE" -C "$SCRIPT_DIR" data/
else
  # Docker named volumes (legacy)
  docker run --rm \
    -v hermes-homelab_hermes-workspace:/data/workspace:ro \
    -v hermes-homelab_hermes-config:/data/config:ro \
    -v hermes-homelab_hermes-home:/data/home:ro \
    -v "$(cd "$BACKUP_DIR" && pwd):/backup" \
    alpine:3.19 \
    tar czf "/backup/hermes-backup-$TIMESTAMP.tar.gz" -C /data workspace config home
fi

SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
echo "[backup] Done. Size: $SIZE"
echo "[backup] To restore: bash restore.sh $BACKUP_FILE"
