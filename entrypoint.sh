#!/bin/bash
set -e

echo "[entrypoint] Hermes Homelab starting..."

# ══════════════════════════════════════════════════════════════════════
# NETWORK ISOLATION
# Wrapped in { } || true so a missing NET_ADMIN capability warns but
# doesn't kill the script before ttyd starts.
# ══════════════════════════════════════════════════════════════════════

{
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
} || echo "[entrypoint] WARNING: network isolation setup had errors (continuing)."

# ══════════════════════════════════════════════════════════════════════
# FIX OWNERSHIP ON PERSISTENT DIRS (best-effort, non-fatal)
# ══════════════════════════════════════════════════════════════════════

{
  chown hermes:hermes /workspace 2>/dev/null
  chown -R hermes:hermes /home/hermes/.local 2>/dev/null
  chown -R hermes:hermes /home/hermes/.hermes 2>/dev/null
  chown hermes:hermes /home/hermes 2>/dev/null
} || true

# ══════════════════════════════════════════════════════════════════════
# GITHUB MCP AUTO-CONFIG (best-effort, non-fatal)
# ══════════════════════════════════════════════════════════════════════

{
  echo "[entrypoint] Checking GitHub MCP auto-config..."
  timeout 5 gosu hermes /gh-mcp-init.sh 2>&1
} || echo "[entrypoint] GitHub MCP init skipped (non-fatal)."

# ══════════════════════════════════════════════════════════════════════
# START TTYD (must succeed — this is the whole point of the container)
# Build the full command here so --credential goes BEFORE the shell.
# ttyd syntax: ttyd [options] <command> — anything after <command> is
# passed to the command, not to ttyd itself.
# ══════════════════════════════════════════════════════════════════════

TTYD_CMD=(ttyd --writable -t fontSize=14 '-t theme={"background":"#1e1e2e","foreground":"#cdd6f4"}')

if [ -n "$TTYD_USER" ] && [ -n "$TTYD_PASSWORD" ]; then
  TTYD_CMD+=(--credential "$TTYD_USER:$TTYD_PASSWORD")
else
  echo "[entrypoint] WARNING: TTYD_USER / TTYD_PASSWORD not set — terminal is OPEN!"
fi

TTYD_CMD+=(bash)

exec gosu hermes "${TTYD_CMD[@]}"
