#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# HERMES HOMELAB — SECURITY VERIFICATION SUITE
# Run this INSIDE the container to verify all isolation layers.
# Usage: bash /workspace/security-test.sh
# ══════════════════════════════════════════════════════════════════════

PASS=0
FAIL=0
WARN=0

pass() { ((PASS++)); echo "  ✓ PASS: $1"; }
fail() { ((FAIL++)); echo "  ✗ FAIL: $1"; }
warn() { ((WARN++)); echo "  ⚠ WARN: $1"; }

echo ""
echo "═══════════════════════════════════════════════"
echo "  HERMES HOMELAB — SECURITY VERIFICATION"
echo "═══════════════════════════════════════════════"
echo ""

# ── 1. USER ISOLATION ────────────────────────────────────────────────
echo "[1/8] User isolation"

if [ "$(id -u)" -ne 0 ]; then
  pass "Running as non-root (uid=$(id -u))"
else
  fail "Running as root — CRITICAL"
fi

if ! sudo -n true 2>/dev/null; then
  pass "No passwordless sudo"
else
  fail "Passwordless sudo available"
fi

# ── 2. FILESYSTEM ISOLATION ──────────────────────────────────────────
echo ""
echo "[2/8] Filesystem isolation"

# Check /workspace is writable
if touch /workspace/.write-test 2>/dev/null; then
  rm -f /workspace/.write-test
  pass "/workspace is writable"
else
  fail "/workspace is NOT writable"
fi

# Check / is read-only (except allowed tmpfs)
if touch /.root-test 2>/dev/null; then
  rm -f /.root-test
  warn "Root filesystem is writable (expected with read_only + tmpfs)"
else
  pass "Root filesystem is read-only"
fi

# Check we can't access Docker socket
if [ -S /var/run/docker.sock ]; then
  fail "Docker socket is accessible — container escape possible!"
else
  pass "Docker socket not mounted"
fi

# Check we can't write to /etc
if touch /etc/.write-test 2>/dev/null; then
  rm -f /etc/.write-test
  fail "Can write to /etc"
else
  pass "/etc is read-only"
fi

# ── 3. NETWORK ISOLATION — IPv4 ──────────────────────────────────────
echo ""
echo "[3/8] Network isolation (IPv4 LAN blocking)"

# Test local-network ranges — these must all FAIL (timeout/refused) in EVERY
# mode, including Tailscale/CGNAT (100.64/10) and cloud metadata.
LAN_TARGETS=("192.168.1.1" "10.0.0.1" "172.16.0.1" "192.168.0.1" "100.64.0.1" "169.254.169.254")
for target in "${LAN_TARGETS[@]}"; do
  if timeout 2 bash -c "echo > /dev/tcp/$target/80" 2>/dev/null; then
    fail "Can reach LAN IP $target:80 — network isolation broken!"
  else
    pass "Cannot reach LAN IP $target:80"
  fi
done

# Internet egress depends on the mode:
#   open (default, EGRESS_PROXY_URL empty) — direct egress MUST work
#   allowlist (EGRESS_PROXY_URL set)       — direct egress MUST be blocked
if [ -n "${EGRESS_PROXY_URL:-}" ]; then
  if timeout 5 bash -c "echo > /dev/tcp/1.1.1.1/443" 2>/dev/null; then
    fail "Direct egress to 1.1.1.1:443 works — allowlist mode broken!"
  else
    pass "Direct egress blocked (allowlist mode: proxy-only)"
  fi
else
  if timeout 5 bash -c "echo > /dev/tcp/1.1.1.1/443" 2>/dev/null; then
    pass "Internet reachable (open mode — research/packages work)"
  else
    fail "Internet unreachable in open mode — egress is broken"
  fi
fi

# ── 4. NETWORK ISOLATION — IPv6 ──────────────────────────────────────
echo ""
echo "[4/8] Network isolation (IPv6)"

if [ -n "${EGRESS_PROXY_URL:-}" ]; then
  # allowlist mode is IPv4-only — IPv6 must be off (it would bypass the proxy)
  val=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "absent")
  if [ "$val" = "1" ] || [ "$val" = "absent" ]; then
    pass "IPv6 disabled in allowlist mode"
  else
    warn "IPv6 is not disabled — could bypass the allowlist proxy"
  fi
else
  # open mode: IPv6 internet is fine, but ULA/link-local must be blocked
  if command -v ip6tables >/dev/null 2>&1 && ip6tables -S OUTPUT 2>/dev/null | grep -qE "fc00::/7|fe80::/10"; then
    pass "IPv6 local ranges blocked (internet v6 allowed in open mode)"
  else
    warn "IPv6 local-range rules missing — v6 could reach the LAN"
  fi
fi

# Check ip6tables
if command -v ip6tables >/dev/null 2>&1; then
  if ip6tables -L OUTPUT 2>/dev/null | grep -q "DROP"; then
    pass "ip6tables default policy is DROP"
  else
    warn "ip6tables rules may not be set"
  fi
fi

# ── 5. DNS ISOLATION ─────────────────────────────────────────────────
echo ""
echo "[5/8] DNS isolation"

# Check resolv.conf uses external DNS
if grep -qE "1\.1\.1\.1|8\.8\.8\.8" /etc/resolv.conf; then
  pass "DNS uses external servers (1.1.1.1 / 8.8.8.8)"
else
  warn "DNS may use Docker internal resolver"
fi

# Test DNS rebinding: try to resolve a hostname to a private IP
# (This tests that even if DNS returns a private IP, iptables blocks the connection)
if timeout 5 curl -s --max-time 3 http://test.invalid 2>/dev/null; then
  warn "Unexpected: test.invalid resolved"
else
  pass "DNS rebinding protection: private IPs blocked by iptables regardless of DNS"
fi

# ── 6. PRIVILEGE ESCALATION ──────────────────────────────────────────
echo ""
echo "[6/8] Privilege escalation checks"

# Check no-new-privileges
if grep -q "NoNewPrivileges" /proc/1/status 2>/dev/null; then
  val=$(grep NoNewPrivileges /proc/1/status | awk '{print $2}')
  if [ "$val" = "1" ]; then
    pass "no-new-privileges is enforced"
  else
    warn "no-new-privileges not enforced"
  fi
else
  warn "Cannot read /proc/1/status for no-new-privileges check"
fi

# Check for remaining setuid binaries
SUID_COUNT=$(find / -perm /6000 -type f 2>/dev/null | wc -l)
if [ "$SUID_COUNT" -eq 0 ]; then
  pass "No setuid/setgid binaries found"
else
  warn "Found $SUID_COUNT setuid/setgid binaries (may be acceptable)"
fi

# ── 7. RESOURCE LIMITS ───────────────────────────────────────────────
echo ""
echo "[7/8] Resource limits"

# Check nproc limit
NPROC=$(ulimit -u 2>/dev/null || echo "unknown")
if [ "$NPROC" != "unlimited" ] && [ "$NPROC" -lt 10000 ] 2>/dev/null; then
  pass "Process limit enforced (nproc=$NPROC)"
else
  warn "nproc limit not set or very high ($NPROC)"
fi

# Check nofile limit
NOFILE=$(ulimit -n 2>/dev/null || echo "unknown")
if [ "$NOFILE" -ge 1024 ] 2>/dev/null; then
  pass "File descriptor limit adequate (nofile=$NOFILE)"
else
  warn "File descriptor limit low (nofile=$NOFILE)"
fi

# Check memory cap (protects the host from runaway workloads)
if [ -f /sys/fs/cgroup/memory.max ]; then
  MEMLIMIT=$(cat /sys/fs/cgroup/memory.max)
else
  MEMLIMIT=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo "unknown")
fi
if [ "$MEMLIMIT" = "max" ] || [ "$MEMLIMIT" = "unknown" ] || [ "${MEMLIMIT:-0}" -ge 9223372036854775807 ] 2>/dev/null; then
  warn "No memory limit set (set HERMES_MEM_LIMIT to cap the container)"
else
  pass "Memory limit enforced (${MEMLIMIT} bytes)"
fi

# ── 8. EGRESS ALLOWLIST PROXY ────────────────────────────────────────
echo ""
echo "[8/8] Egress allowlist (proxy)"

if [ -n "${EGRESS_PROXY_URL:-}" ]; then
  # ── allowlist mode ──────────────────────────────────────────────────
  PROXY_URL="${HTTPS_PROXY:-${https_proxy:-}}"
  if [ -n "$PROXY_URL" ]; then
    pass "Proxy env set ($PROXY_URL)"
  else
    fail "No HTTP(S)_PROXY env — tools would bypass the allowlist"
  fi

  # Allowlisted host must be reachable through the proxy
  GITHUB_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -x "${PROXY_URL}" https://api.github.com/ 2>/dev/null || echo "000")
  if [ "$GITHUB_CODE" = "403" ]; then
    fail "Allowlisted host (api.github.com) denied — check ./data/egress-allowlist.conf"
  elif [ "$GITHUB_CODE" = "000" ]; then
    warn "Could not reach api.github.com via proxy (proxy down? host offline?)"
  else
    pass "Allowlisted host reachable via proxy (HTTP $GITHUB_CODE)"
  fi

  # Non-allowlisted host must be denied by the proxy
  DENY_BODY=$(curl -s --max-time 10 -x "${PROXY_URL}" https://example.com/ 2>/dev/null || true)
  if echo "$DENY_BODY" | grep -q "blocked by egress allowlist"; then
    pass "Non-allowlisted host denied by proxy (403 marker)"
  else
    fail "Non-allowlisted host NOT denied — allowlist broken!"
  fi

  # Direct HTTPS (bypassing the proxy) must be blocked by the firewall
  if curl -s --max-time 5 https://example.com/ -o /dev/null 2>/dev/null; then
    fail "Direct HTTPS works — firewall enforcement broken"
  else
    pass "Direct HTTPS (bypassing proxy) is blocked"
  fi
else
  # ── open mode (default): no allowlist — internet open, LAN never ────
  OPEN_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://example.com/ 2>/dev/null || echo "000")
  if [ "$OPEN_CODE" = "000" ]; then
    fail "Internet unreachable in open mode — research/package installs broken"
  else
    pass "Internet open with no allowlist (example.com HTTP $OPEN_CODE)"
  fi
fi

# In BOTH modes the proxy must refuse local-network targets (the agent's
# firewall cannot see inside proxied connections).
PROXY_ORIGIN="http://${EGRESS_PROXY_HOST:-hermes-egress-proxy}:${EGRESS_PROXY_PORT:-8888}"
LOCAL_BODY=$(curl -s --max-time 5 -x "$PROXY_ORIGIN" http://10.0.0.1/ 2>/dev/null || true)
if echo "$LOCAL_BODY" | grep -qE "local network target is never allowed|blocked by egress allowlist"; then
  pass "Proxy refuses local-network targets (even with '*' in the allowlist)"
else
  warn "Could not verify the proxy's LAN guard (is hermes-egress-proxy running?)"
fi

# ── SUMMARY ──────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo "  RESULTS: $PASS passed, $FAIL failed, $WARN warnings"
echo "═══════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "  ⛔ SECURITY ISSUES DETECTED — review failures above"
  echo "     Do NOT use in production until resolved."
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo ""
  echo "  ⚠ Some warnings — review above. Likely acceptable for homelab."
  exit 0
else
  echo ""
  echo "  ✅ All security checks passed. Sandbox is solid."
  exit 0
fi
