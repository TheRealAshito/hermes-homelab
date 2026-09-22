#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# HERMES HOMELAB — PERSISTENCE VERIFICATION SUITE
# Run from the HOST (not inside the container).
# Usage: bash persistence-test.sh
# ══════════════════════════════════════════════════════════════════════

set -e

PASS=0
FAIL=0

pass() { ((PASS++)); echo "  ✓ PASS: $1"; }
fail() { ((FAIL++)); echo "  ✗ FAIL: $1"; }

echo ""
echo "═══════════════════════════════════════════════"
echo "  HERMES HOMELAB — PERSISTENCE VERIFICATION"
echo "═══════════════════════════════════════════════"
echo ""

# ── Helper: exec into container as hermes user ──────────────────────
cx() { docker exec hermes-homelab bash -c "$1"; }

# ── 1. Create test markers ──────────────────────────────────────────
echo "[1/4] Creating test markers in volumes..."

# Workspace marker
cx "echo 'persistence-test-marker' > /workspace/.persistence-test"
pass "Created /workspace/.persistence-test"

# Home marker (in ~/.hermes which IS mounted)
cx "echo 'config-marker' > /home/hermes/.hermes/.persistence-test"
pass "Created ~/.hermes/.persistence-test"

# ── 2. Restart container (no rebuild) ───────────────────────────────
echo ""
echo "[2/4] Restarting container (docker compose restart)..."
docker compose restart hermes
sleep 5

if cx "cat /workspace/.persistence-test" 2>/dev/null | grep -q "persistence-test-marker"; then
  pass "Workspace survives restart"
else
  fail "Workspace lost on restart"
fi

if cx "cat /home/hermes/.hermes/.persistence-test" 2>/dev/null | grep -q "config-marker"; then
  pass "Hermes config survives restart"
else
  fail "Hermes config lost on restart"
fi

# ── 3. Rebuild container ────────────────────────────────────────────
echo ""
echo "[3/4] Rebuilding container (docker compose up -d --build)..."
docker compose up -d --build hermes
sleep 10

if cx "cat /workspace/.persistence-test" 2>/dev/null | grep -q "persistence-test-marker"; then
  pass "Workspace survives rebuild"
else
  fail "Workspace lost on rebuild"
fi

if cx "cat /home/hermes/.hermes/.persistence-test" 2>/dev/null | grep -q "config-marker"; then
  pass "Hermes config survives rebuild"
else
  fail "Hermes config lost on rebuild"
fi

# ── 4. Clean up test markers ────────────────────────────────────────
echo ""
echo "[4/4] Cleaning up test markers..."
cx "rm -f /workspace/.persistence-test /home/hermes/.hermes/.persistence-test"
pass "Cleaned up"

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo "  RESULTS: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  echo "  ⛔ PERSISTENCE ISSUES DETECTED"
  exit 1
else
  echo "  ✅ All persistence checks passed."
  exit 0
fi
