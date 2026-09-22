#!/bin/bash
set -e

echo "[entrypoint] Hermes Homelab starting..."

# ══════════════════════════════════════════════════════════════════════
# NETWORK ISOLATION
# INPUT:  ACCEPT (users need to connect to the web terminal)
# OUTPUT: DROP by default (container cannot reach LAN or internet)
#         then selectively allow DNS + HTTPS to public IPs only
# ══════════════════════════════════════════════════════════════════════

# Disable IPv6 (best-effort)
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || true

if iptables -L INPUT >/dev/null 2>&1; then
  echo "[entrypoint] Applying network isolation..."

  iptables -F INPUT
  iptables -F OUTPUT

  # INPUT: ACCEPT — allow inbound connections (browser → terminal)
  iptables -P INPUT ACCEPT

  # OUTPUT: DROP — block all outbound by default
  iptables -P OUTPUT DROP

  # FORWARD: DROP — container shouldn't forward traffic
  iptables -P FORWARD DROP

  # Allow loopback
  iptables -A INPUT  -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT

  # Allow established/related (return traffic for allowed outbound)
  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

  # Block ALL RFC1918 + link-local + multicast OUTBOUND (before port allows)
  for NET in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4; do
    iptables -A OUTPUT -d "$NET" -j DROP
  done

  # Allow DNS, HTTP, HTTPS to public IPs
  iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 80  -j ACCEPT

  echo "[entrypoint] Network isolation active (inbound OK, outbound LAN blocked)."
else
  echo "[entrypoint] WARNING: iptables not available — network isolation DISABLED!"
fi

# IPv6
if ip6tables -L INPUT >/dev/null 2>&1; then
  echo "[entrypoint] Blocking IPv6..."
  ip6tables -F INPUT
  ip6tables -F OUTPUT
  ip6tables -P INPUT   ACCEPT
  ip6tables -P OUTPUT  DROP
  ip6tables -P FORWARD DROP
  ip6tables -A INPUT  -i lo -j ACCEPT
  ip6tables -A OUTPUT -o lo -j ACCEPT
  echo "[entrypoint] IPv6 outbound blocked."
fi

# ══════════════════════════════════════════════════════════════════════
# FIX OWNERSHIP ON PERSISTENT DIRS (best-effort, non-fatal)
# Only touches top-level entries — full recursive chown on every start
# is slow and fights with bind-mounted volumes that already have correct
# ownership from setup-host.sh.
# ══════════════════════════════════════════════════════════════════════

chown hermes:hermes /workspace 2>/dev/null || true
chown -R hermes:hermes /home/hermes/.local 2>/dev/null || true
chown -R hermes:hermes /home/hermes/.hermes 2>/dev/null || true
chown hermes:hermes /home/hermes 2>/dev/null || true

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
