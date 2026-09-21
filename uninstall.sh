#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# HERMES HOMELAB — UNINSTALL
# Removes the container, image, network, host iptables rules, and
# optionally the data directory.
#
# Usage: sudo bash uninstall.sh [--keep-data]
# ══════════════════════════════════════════════════════════════════════
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEEP_DATA=false
CONTAINER_SUBNET="172.28.0.0/16"

[ "$1" = "--keep-data" ] && KEEP_DATA=true

echo ""
echo "═══════════════════════════════════════════════"
echo "  HERMES HOMELAB — UNINSTALL"
echo "═══════════════════════════════════════════════"
echo ""

# ── 1. Stop and remove container + network ──────────────────────────
echo "[1/4] Stopping and removing container..."
cd "$SCRIPT_DIR" && docker compose down 2>/dev/null && echo "      ✓ Container removed." || echo "      (no container running)"

# ── 2. Remove Docker image ──────────────────────────────────────────
echo ""
echo "[2/4] Removing Docker image..."
docker rmi hermes-homelab-hermes:latest 2>/dev/null && echo "      ✓ Image removed." || echo "      (no image found)"

# ── 3. Remove host iptables rules ───────────────────────────────────
echo ""
echo "[3/4] Removing host-level iptables rules..."
if iptables -L DOCKER-USER >/dev/null 2>&1; then
  for NET in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4; do
    iptables -D DOCKER-USER -s "$CONTAINER_SUBNET" -d "$NET" -j DROP 2>/dev/null && echo "      Removed: $CONTAINER_SUBNET → $NET DROP"
  done
  echo "      ✓ Host iptables rules removed."

  # Save updated rules
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save 2>/dev/null || true
  elif command -v iptables-save >/dev/null 2>&1; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  fi
else
  echo "      (no iptables / DOCKER-USER chain found)"
fi

# ── 4. Data directory ───────────────────────────────────────────────
echo ""
if $KEEP_DATA; then
  echo "[4/4] Keeping data directory (--keep-data)."
  DATA_DIR=$(grep "^DATA_DIR=" "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2 || echo "./data")
  echo "      Data preserved at: $DATA_DIR"
else
  echo "[4/4] Data directory..."
  DATA_DIR=$(grep "^DATA_DIR=" "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2 || echo "./data")
  if [ -d "$DATA_DIR" ]; then
    echo "      Location: $DATA_DIR"
    read -p "      Delete ALL data (workspace, chats, memory)? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      rm -rf "$DATA_DIR"
      echo "      ✓ Data deleted."
    else
      echo "      Data preserved."
    fi
  else
    echo "      (no data directory found)"
  fi
fi

# ── Clean up symlinks ──────────────────────────────────────────────
if [ -L "$SCRIPT_DIR/data" ]; then
  rm -f "$SCRIPT_DIR/data"
fi

echo ""
echo "═══════════════════════════════════════════════"
echo "  UNINSTALL COMPLETE"
echo "═══════════════════════════════════════════════"
echo ""
echo "  Removed: container, image, iptables rules"
if $KEEP_DATA; then
  echo "  Preserved: data directory"
else
  echo "  Data: deleted (if confirmed)"
fi
echo ""
echo "  The project files (Dockerfile, scripts, etc.) are still here."
echo "  To fully remove: rm -rf $SCRIPT_DIR"
echo ""
