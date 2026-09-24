#!/bin/bash
set -e

echo "[entrypoint] Hermes Homelab starting..."

# ══════════════════════════════════════════════════════════════════════
# NETWORK ISOLATION (best-effort — warns but doesn't block ttyd)
# ══════════════════════════════════════════════════════════════════════

{
  # ── Egress policy (drives the firewall below AND tool routing) ────────
  #   EGRESS_PROXY_URL unset/empty (default) — OPEN: the internet is
  #     reachable on every port (research, package installs, git+ssh, ...).
  #     No allowlist anywhere. Only the local network is unreachable.
  #   EGRESS_PROXY_URL=http://hermes-egress-proxy:8888 — ALLOWLIST mode:
  #     all web egress goes through the default-deny proxy (egress-proxy/)
  #     and the firewall only lets DNS + the proxy through.
  #   (EGRESS_MODE=proxy from an earlier revision is honored as an alias.)
  PROXY_URL="${EGRESS_PROXY_URL:-}"
  if [ "${EGRESS_MODE:-}" = "proxy" ] && [ -z "$PROXY_URL" ]; then
    PROXY_URL="http://${EGRESS_PROXY_HOST:-hermes-egress-proxy}:${EGRESS_PROXY_PORT:-8888}"
  fi
  if [ -n "$PROXY_URL" ]; then
    export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
    export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL"
  fi

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

    if [ -n "$PROXY_URL" ]; then
      # ALLOWLIST mode — only the proxy is reachable. The rule is
      # SUBNET-based (not a /32): a proxy recreate that changes its
      # container IP, or Docker DNS not being ready at entrypoint time,
      # must not strand all egress. It must precede the RFC1918 DROP loop
      # below (the proxy lives on a private docker subnet).
      PROXY_PORT="${EGRESS_PROXY_PORT:-}"
      if [ -z "$PROXY_PORT" ]; then
        _hp="${PROXY_URL#*://}"; _hp="${_hp%%/*}"; PROXY_PORT="${_hp##*:}"
      fi
      case "$PROXY_PORT" in ''|*[!0-9]*) PROXY_PORT=8888;; esac
      PROXY_CIDR=$(ip route 2>/dev/null | awk '/proto kernel/ {print $1; exit}')
      if [ -z "$PROXY_CIDR" ]; then
        PROXY_HOST="${EGRESS_PROXY_HOST:-hermes-egress-proxy}"
        for _ in 1 2 3 4 5; do
          PROXY_IP=$(getent hosts "$PROXY_HOST" 2>/dev/null | awk 'NR==1{print $1}')
          [ -n "$PROXY_IP" ] && PROXY_CIDR="$PROXY_IP/32" && break
          sleep 1
        done
      fi
      if [ -n "$PROXY_CIDR" ]; then
        iptables -A OUTPUT -d "$PROXY_CIDR" -p tcp --dport "$PROXY_PORT" -j ACCEPT
        echo "[entrypoint] Egress: ALLOWLIST mode — via $PROXY_URL (default deny)."
      else
        echo "[entrypoint] WARNING: egress proxy unresolved — web egress BLOCKED (fail-safe)."
      fi
    else
      echo "[entrypoint] Egress: OPEN mode — internet allowed (all ports), local network blocked."
    fi

    # Local network + special ranges: NEVER reachable (both modes).
    for NET in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 224.0.0.0/4 240.0.0.0/4 0.0.0.0/8; do
      iptables -A OUTPUT -d "$NET" -j DROP
    done
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
    [ -z "$PROXY_URL" ] && iptables -A OUTPUT -j ACCEPT
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
    ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    # Local IPv6 space is never reachable (both modes).
    ip6tables -A OUTPUT -d fc00::/7 -j DROP
    ip6tables -A OUTPUT -d fe80::/10 -j DROP
    ip6tables -A OUTPUT -d ff00::/8 -j DROP
    if [ -z "$PROXY_URL" ]; then
      ip6tables -A OUTPUT -j ACCEPT
      echo "[entrypoint] IPv6: internet allowed, ULA/link-local/multicast blocked."
    else
      echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || true
      echo "[entrypoint] IPv6 outbound blocked (allowlist mode is IPv4-only)."
    fi
  else
    echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || true
    echo "[entrypoint] IPv6 disabled at kernel level (ip6tables unavailable)."
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
  # /opt/hermes-agent: running hermes/pip as root leaves root-owned
  # __pycache__ in the venv, which trips `hermes update`'s safety check
  # ("this install's venv contains files owned by another user").
  chown -R hermes:hermes /opt/hermes-agent 2>/dev/null
} || true

# ══════════════════════════════════════════════════════════════════════
# TEMP DIR FOR EXTRACTED NATIVE LIBS
# /tmp is mounted noexec (Docker tmpfs default), so tools that extract +
# dlopen() a native lib at runtime (opencode's OpenTUI renderer) must write
# it elsewhere — TMPDIR points at this exec-capable dir (see Dockerfile).
# Clean stale extracted libs from previous runs (~14 MB each). The glob only
# matches the "<16 hex>-<8 chars>.so" pattern those extractors use.
# ══════════════════════════════════════════════════════════════════════

{
  TMPDIR="${TMPDIR:-/home/hermes/.hermes/cache/tmp}"
  mkdir -p "$TMPDIR"
  chown hermes:hermes "$TMPDIR"
  rm -f "$TMPDIR"/.????????????????-????????.so
  rm -f /tmp/.????????????????-????????.so
} 2>/dev/null || true

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
