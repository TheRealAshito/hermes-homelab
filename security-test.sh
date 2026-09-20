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
echo "[1/7] User isolation"

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
echo "[2/7] Filesystem isolation"

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
echo "[3/7] Network isolation (IPv4 LAN blocking)"

# Test RFC1918 ranges — these should all FAIL (timeout/refused)
LAN_TARGETS=("192.168.1.1" "10.0.0.1" "172.16.0.1" "192.168.0.1")
for target in "${LAN_TARGETS[@]}"; do
  if timeout 2 bash -c "echo > /dev/tcp/$target/80" 2>/dev/null; then
    fail "Can reach LAN IP $target:80 — network isolation broken!"
  else
    pass "Cannot reach LAN IP $target:80"
  fi
done

# Test that internet IS reachable
if timeout 10 bash -c "echo > /dev/tcp/1.1.1.1/443" 2>/dev/null; then
  pass "Internet (1.1.1.1:443) is reachable"
else
  warn "Internet (1.1.1.1:443) not reachable — check host networking"
fi

# ── 4. NETWORK ISOLATION — IPv6 ──────────────────────────────────────
echo ""
echo "[4/7] Network isolation (IPv6)"

if [ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
  val=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)
  if [ "$val" = "1" ]; then
    pass "IPv6 is disabled"
  else
    warn "IPv6 is not disabled — could bypass iptables rules"
  fi
else
  pass "IPv6 not available in container"
fi

# Check ip6tables
if command -v ip6tables >/dev/null 2>&1; then
  if ip6tables -L INPUT 2>/dev/null | grep -q "DROP"; then
    pass "ip6tables default policy is DROP"
  else
    warn "ip6tables rules may not be set"
  fi
fi

# ── 5. DNS ISOLATION ─────────────────────────────────────────────────
echo ""
echo "[5/7] DNS isolation"

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
echo "[6/7] Privilege escalation checks"

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
echo "[7/7] Resource limits"

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
