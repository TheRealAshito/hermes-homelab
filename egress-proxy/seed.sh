#!/bin/bash
# Seed ./data/egress-allowlist.conf from egress-proxy/allowlist.default on
# first use. Existing files are NEVER touched (empty file = deny-all is an
# intentional choice). Handles the docker bind-mount pitfall: mounting a
# missing file makes docker create a DIRECTORY at that path.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# DATA_DIR: env wins, then .env (same convention as backup.sh / run.sh)
if [ -z "${DATA_DIR:-}" ] && [ -f "$SCRIPT_DIR/.env" ]; then
  DATA_DIR=$(grep "^DATA_DIR=" "$SCRIPT_DIR/.env" | cut -d= -f2-)
fi
DATA_DIR="${DATA_DIR:-$SCRIPT_DIR/data}"

TARGET="$DATA_DIR/egress-allowlist.conf"
mkdir -p "$DATA_DIR"

if [ -d "$TARGET" ]; then
  echo "[seed] $TARGET is a directory (docker created it from a missing bind) — replacing with the default allowlist"
  rmdir "$TARGET" 2>/dev/null || true
fi

if [ ! -f "$TARGET" ]; then
  cp "$SCRIPT_DIR/egress-proxy/allowlist.default" "$TARGET"
  echo "[seed] created $TARGET from egress-proxy/allowlist.default"
else
  echo "[seed] $TARGET exists — leaving it untouched"
fi
