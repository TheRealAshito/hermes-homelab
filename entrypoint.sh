#!/bin/bash
set -e

# ── Block all RFC1918 / private ranges ──────────────────────────────
# Prevents the container from reaching your LAN (192.168.x, 10.x, 172.16-31.x)
# while still allowing outbound internet (cloud APIs).
if iptables -L INPUT >/dev/null 2>&1; then
  echo "[entrypoint] Applying network isolation rules..."

  # Allow loopback and already-established connections
  iptables -A INPUT  -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT
  iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

  # Allow DNS to Docker gateway (needed for name resolution)
  iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

  # Block all private IP ranges (RFC1918 + link-local)
  for NET in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16; do
    iptables -A INPUT  -d "$NET" -j DROP
    iptables -A OUTPUT -d "$NET" -j DROP
  done

  echo "[entrypoint] Network isolation active — LAN access blocked."
else
  echo "[entrypoint] WARNING: iptables not available, skipping network isolation."
fi

# ── Fix ownership (volume mounts may arrive as root on first run) ───
chown -R hermes:hermes /workspace /home/hermes 2>/dev/null || true

# ── Basic auth for ttyd ────────────────────────────────────────────
if [ -n "$TTYD_USER" ] && [ -n "$TTYD_PASSWORD" ]; then
  set -- "$@" --credential "$TTYD_USER:$TTYD_PASSWORD"
else
  echo "[entrypoint] WARNING: TTYD_USER / TTYD_PASSWORD not set — terminal is OPEN!"
fi

# ── Drop to hermes user and launch ─────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║  Hermes Homelab — Web Terminal Ready     ║"
echo "  ║  Run 'hermes setup' to configure your AI ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

exec gosu hermes "$@"
