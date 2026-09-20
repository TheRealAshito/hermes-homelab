#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# HERMES HOMELAB — VOLUME BACKUP
# Creates a compressed tarball of all hermes volumes.
# Run from the host (not inside the container).
#
# Usage:  bash backup.sh                  # saves to ./backups/
#         bash backup.sh /path/to/dir     # saves to specified dir
# ══════════════════════════════════════════════════════════════════════
set -e

BACKUP_DIR="${1:-./backups}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/hermes-backup-$TIMESTAMP.tar.gz"

echo "[backup] Creating backup of hermes-homelab volumes..."
echo "[backup] Output: $BACKUP_FILE"

mkdir -p "$BACKUP_DIR"

# Use a temporary alpine container to tar the volumes
docker run --rm \
  -v hermes-workspace:/data/workspace:ro \
  -v hermes-config:/data/config:ro \
  -v hermes-home:/data/home:ro \
  -v "$(cd "$BACKUP_DIR" && pwd):/backup" \
  alpine:3.19 \
  tar czf "/backup/hermes-backup-$TIMESTAMP.tar.gz" \
    -C /data \
    workspace config home

SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
echo "[backup] Done. Size: $SIZE"
echo "[backup] To restore: bash restore.sh $BACKUP_FILE"
