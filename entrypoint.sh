#!/bin/bash
set -e

echo "[entrypoint] Hermes Homelab starting..."

# ══════════════════════════════════════════════════════════════════════
# NETWORK ISOLATION
# Block ALL private/LAN ranges on both IPv4 and IPv6.
# Container can reach the internet (cloud APIs) but nothing on your LAN.
# ══════════════════════════════════════════════════════════════════════

# Disable IPv6 entirely (prevents any IPv6 LAN bypass)
if [ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
  echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || true
fi

if iptables -L INPUT >/dev/null 2>&1; then
  echo "[entrypoint] Applying IPv4 network isolation..."

  # Allow loopback
  iptables -A INPUT  -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT

  # Allow established/related connections (return traffic from API calls)
  iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

  # Allow DNS (needed to resolve API hostnames)
  iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

  # Allow HTTPS (cloud API traffic)
  iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT

  # Allow HTTP (some providers redirect http→https, npm repos, etc.)
  iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT

  # Block ALL RFC1918 + link-local ranges
  for NET in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16; do
    iptables -A INPUT  -s "$NET" -j DROP
    iptables -A INPUT  -d "$NET" -j DROP
    iptables -A OUTPUT -d "$NET" -j DROP
  done

  # Block multicast (prevents LAN discovery)
  iptables -A INPUT  -d 224.0.0.0/4 -j DROP
  iptables -A OUTPUT -d 224.0.0.0/4 -j DROP

  echo "[entrypoint] IPv4 LAN access blocked."
else
  echo "[entrypoint] WARNING: iptables not available — network isolation DISABLED!"
fi

# IPv6 blocking (belt-and-suspenders)
if ip6tables -L INPUT >/dev/null 2>&1; then
  echo "[entrypoint] Applying IPv6 network isolation..."
  ip6tables -P INPUT   DROP
  ip6tables -P OUTPUT  DROP
  ip6tables -P FORWARD DROP
  ip6tables -A INPUT  -i lo -j ACCEPT
  ip6tables -A OUTPUT -o lo -j ACCEPT
  echo "[entrypoint] IPv6 fully blocked."
fi

# ══════════════════════════════════════════════════════════════════════
# FILESYSTEM HARDENING
# ══════════════════════════════════════════════════════════════════════

# Remove setuid/setgid binaries at runtime (defense-in-depth)
find / -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true

# Fix ownership (volume mounts may arrive as root on first run)
chown -R hermes:hermes /workspace /home/hermes 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════
# GITHUB MCP AUTO-CONFIG
# If gh is authenticated, configure GitHub MCP in Hermes automatically.
# ══════════════════════════════════════════════════════════════════════

echo "[entrypoint] Checking GitHub MCP auto-config..."
gosu hermes /gh-mcp-init.sh || echo "[entrypoint] GitHub MCP init skipped (non-fatal)."

# ══════════════════════════════════════════════════════════════════════
# TTYD AUTHENTICATION
# ══════════════════════════════════════════════════════════════════════

if [ -n "$TTYD_USER" ] && [ -n "$TTYD_PASSWORD" ]; then
  set -- "$@" --credential "$TTYD_USER:$TTYD_PASSWORD"
else
  echo "[entrypoint] WARNING: TTYD_USER / TTYD_PASSWORD not set — terminal is OPEN!"
fi

# ══════════════════════════════════════════════════════════════════════
# LAUNCH
# ══════════════════════════════════════════════════════════════════════

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║  Hermes Homelab — Web Terminal Ready     ║"
echo "  ║  Run 'hermes setup' to configure your AI ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

exec gosu hermes "$@"
