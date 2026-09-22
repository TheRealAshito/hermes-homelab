#!/bin/bash
set -e

echo "[entrypoint] Hermes Homelab starting..."

# ══════════════════════════════════════════════════════════════════════
# NETWORK ISOLATION (best-effort — warns but doesn't block ttyd)
# ══════════════════════════════════════════════════════════════════════

{
  echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || true

  if iptables -L INPUT >/dev/null 2>&1; then
    echo "[entrypoint] Applying network isolation..."
    iptables -F INPUT
    iptables -F OUTPUT
    iptables -P INPUT ACCEPT
    iptables -P OUTPUT DROP
    iptables -P FORWARD DROP
    iptables -A INPUT  -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    for NET in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4; do
      iptables -A OUTPUT -d "$NET" -j DROP
    done
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 80  -j ACCEPT
    echo "[entrypoint] Network isolation active (inbound OK, outbound LAN blocked)."
  else
    echo "[entrypoint] WARNING: iptables not available — network isolation DISABLED!"
  fi

  if ip6tables -L INPUT >/dev/null 2>&1; then
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
# FIX OWNERSHIP (best-effort)
# ══════════════════════════════════════════════════════════════════════

{
  chown hermes:hermes /workspace 2>/dev/null
  chown -R hermes:hermes /home/hermes/.local 2>/dev/null
  chown -R hermes:hermes /home/hermes/.hermes 2>/dev/null
  chown hermes:hermes /home/hermes 2>/dev/null
} || true

# ══════════════════════════════════════════════════════════════════════
# START TTYD
# ttyd syntax: ttyd [options] <command>
# --credential must come BEFORE the shell name.
# -t takes KEY=VALUE — each -t and its value must be separate args.
# ══════════════════════════════════════════════════════════════════════

TTYD_ARGS=(--writable -t fontSize=14)

if [ -n "$TTYD_USER" ] && [ -n "$TTYD_PASSWORD" ]; then
  TTYD_ARGS+=(--credential "$TTYD_USER:$TTYD_PASSWORD")
else
  echo "[entrypoint] WARNING: TTYD_USER / TTYD_PASSWORD not set — terminal is OPEN!"
fi

echo "[entrypoint] Starting ttyd..."
exec gosu hermes ttyd "${TTYD_ARGS[@]}" bash
