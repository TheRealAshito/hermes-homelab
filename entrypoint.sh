#!/bin/bash
set -e

echo "[entrypoint] Hermes Homelab starting..."

# ══════════════════════════════════════════════════════════════════════
# NETWORK ISOLATION
# Default policy: DROP. Only DNS, HTTP(S) to non-private IPs allowed.
# ══════════════════════════════════════════════════════════════════════

# Disable IPv6 (best-effort)
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || true

if iptables -L INPUT >/dev/null 2>&1; then
  echo "[entrypoint] Applying IPv4 network isolation..."

  iptables -F INPUT
  iptables -F OUTPUT

  # Default: DROP everything
  iptables -P INPUT   DROP
  iptables -P OUTPUT  DROP
  iptables -P FORWARD DROP

  # Allow loopback
  iptables -A INPUT  -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT

  # Allow established/related connections (return traffic from API calls)
  iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

  # ── BLOCK all private/LAN ranges FIRST (before any port allows) ──
  for NET in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16; do
    iptables -A OUTPUT -d "$NET" -j DROP
    iptables -A INPUT  -s "$NET" -j DROP
  done
  iptables -A OUTPUT -d 224.0.0.0/4 -j DROP
  iptables -A INPUT  -s 224.0.0.0/4 -j DROP

  # ── THEN allow DNS and HTTP(S) to public IPs ──
  iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 80  -j ACCEPT

  echo "[entrypoint] Network isolation active (default DROP, LAN blocked)."
else
  echo "[entrypoint] WARNING: iptables not available — network isolation DISABLED!"
fi

# IPv6
if ip6tables -L INPUT >/dev/null 2>&1; then
  echo "[entrypoint] Blocking IPv6..."
  ip6tables -F INPUT
  ip6tables -F OUTPUT
  ip6tables -P INPUT   DROP
  ip6tables -P OUTPUT  DROP
  ip6tables -P FORWARD DROP
  ip6tables -A INPUT  -i lo -j ACCEPT
  ip6tables -A OUTPUT -o lo -j ACCEPT
  echo "[entrypoint] IPv6 blocked."
fi

# ══════════════════════════════════════════════════════════════════════
# FILESYSTEM HARDENING
# ══════════════════════════════════════════════════════════════════════

find / -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true
chown -R hermes:hermes /workspace /home/hermes 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════
# GITHUB MCP AUTO-CONFIG
# ══════════════════════════════════════════════════════════════════════

echo "[entrypoint] Checking GitHub MCP auto-config..."
gosu hermes /gh-mcp-init.sh 2>&1 || echo "[entrypoint] GitHub MCP init skipped (non-fatal)."

# ══════════════════════════════════════════════════════════════════════
# TTYD AUTHENTICATION
# ══════════════════════════════════════════════════════════════════════

if [ -n "$TTYD_USER" ] && [ -n "$TTYD_PASSWORD" ]; then
  set -- "$@" --credential "$TTYD_USER:$TTYD_PASSWORD"
else
  echo "[entrypoint] WARNING: TTYD_USER / TTYD_PASSWORD not set — terminal is OPEN!"
fi

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║  Hermes Homelab — Web Terminal Ready     ║"
echo "  ║  Run 'hermes setup' to configure your AI ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

exec gosu hermes "$@"
