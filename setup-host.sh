#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# HERMES HOMELAB — HOST SETUP
# Run this ONCE on your homelab host as root (or with sudo).
# Sets up:
#   1. Host-level network isolation (blocks container from LAN)
#   2. External storage directory (optional)
#
# Usage: sudo bash setup-host.sh [/path/to/external/storage]
# ══════════════════════════════════════════════════════════════════════
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINER_SUBNET="172.28.0.0/16"  # Must match docker-compose.yml network config

echo ""
echo "═══════════════════════════════════════════════"
echo "  HERMES HOMELAB — HOST SETUP"
echo "═══════════════════════════════════════════════"
echo ""

# ── 1. NETWORK ISOLATION (host-level iptables) ──────────────────────
echo "[1/3] Setting up host-level network isolation..."
echo "      Container subnet: $CONTAINER_SUBNET"

# Flush any existing hermes rules (idempotent)
iptables -D DOCKER-USER -s "$CONTAINER_SUBNET" -d 10.0.0.0/8 -j DROP 2>/dev/null || true
iptables -D DOCKER-USER -s "$CONTAINER_SUBNET" -d 172.16.0.0/12 -j DROP 2>/dev/null || true
iptables -D DOCKER-USER -s "$CONTAINER_SUBNET" -d 192.168.0.0/16 -j DROP 2>/dev/null || true
iptables -D DOCKER-USER -s "$CONTAINER_SUBNET" -d 169.254.0.0/16 -j DROP 2>/dev/null || true
iptables -D DOCKER-USER -s "$CONTAINER_SUBNET" -d 224.0.0.0/4 -j DROP 2>/dev/null || true

# Block container → LAN (all RFC1918 + link-local + multicast)
for NET in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4; do
  iptables -I DOCKER-USER -s "$CONTAINER_SUBNET" -d "$NET" -j DROP
done

echo "      ✓ Container can reach internet but NOT your LAN."

# Persist rules across reboots
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save 2>/dev/null && echo "      ✓ Rules saved (iptables-persistent)."
elif command -v iptables-save >/dev/null 2>&1; then
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4
  echo "      ✓ Rules saved to /etc/iptables/rules.v4"
  echo "        Install iptables-persistent for auto-restore on boot:"
  echo "        sudo apt install iptables-persistent"
fi

# ── 2. STORAGE DIRECTORY ────────────────────────────────────────────
echo ""
echo "[2/3] Setting up storage directory..."

DATA_DIR="${1:-$SCRIPT_DIR/data}"

mkdir -p "$DATA_DIR"/{workspace,hermes-config,hermes-home}
echo "      Storage directory: $DATA_DIR"
echo "      ✓ Created: workspace/, hermes-config/, hermes-home/"

# Create .env with DATA_DIR if not exists
if ! grep -q "^DATA_DIR=" "$SCRIPT_DIR/.env" 2>/dev/null; then
  echo "DATA_DIR=$DATA_DIR" >> "$SCRIPT_DIR/.env"
  echo "      ✓ Added DATA_DIR to .env"
else
  sed -i "s|^DATA_DIR=.*|DATA_DIR=$DATA_DIR|" "$SCRIPT_DIR/.env"
  echo "      ✓ Updated DATA_DIR in .env"
fi

# ── 3. SYMLINKS (optional, for convenience) ─────────────────────────
echo ""
echo "[3/3] Creating symlinks for easy access..."

if [ "$DATA_DIR" != "$SCRIPT_DIR/data" ]; then
  # Create symlinks from project dir to external storage
  ln -sfn "$DATA_DIR/workspace" "$SCRIPT_DIR/data/workspace"
  ln -sfn "$DATA_DIR/hermes-config" "$SCRIPT_DIR/data/hermes-config"
  ln -sfn "$DATA_DIR/hermes-home" "$SCRIPT_DIR/data/hermes-home"
  mkdir -p "$SCRIPT_DIR/data"
  ln -sfn "$DATA_DIR" "$SCRIPT_DIR/data/external"
  echo "      ✓ Symlinks created in ./data/ → $DATA_DIR"
else
  echo "      Data is local (./data/), no symlinks needed."
fi

echo ""
echo "═══════════════════════════════════════════════"
echo "  SETUP COMPLETE"
echo "═══════════════════════════════════════════════"
echo ""
echo "  Network: Container blocked from LAN at host level"
echo "  Storage: $DATA_DIR"
echo ""
echo "  Next steps:"
echo "    1. Edit .env if needed (password, storage path)"
echo "    2. docker compose up -d"
echo "    3. Open http://<your-ip>:7681"
echo ""
