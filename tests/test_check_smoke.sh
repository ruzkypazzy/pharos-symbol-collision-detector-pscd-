#!/bin/bash
# Smoke test for PSCD scripts. Runs offline — no RPC calls.
# Verifies that all scripts handle common error paths gracefully.

set -e

PASS=0
FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

assert_grep() {
  local name="$1" pattern="$2" output="$3"
  if echo "$output" | grep -qE -- "$pattern"; then
    ok "$name"
  else
    fail "$name (expected to match /$pattern/, got: $output)"
  fi
}

# ============================================================================
# check.sh
# ============================================================================
echo ""
echo "== check.sh =="

OUT=$(bash scripts/check.sh --help 2>&1)
assert_grep "help shows usage"        "Usage:" "$OUT"
assert_grep "help mentions scanner"   "Symbol Collision" "$OUT"

OUT=$(bash scripts/check.sh 2>&1 || true)
assert_grep "no symbol rejected"      "provide a symbol" "$OUT"

OUT=$(bash scripts/check.sh USDC --network foo 2>&1 || true)
assert_grep "bad network rejected"    "Unknown network" "$OUT"

OUT=$(bash scripts/check.sh USDC --from-block 100 --to-block 50 2>&1 || true)
assert_grep "reversed range rejected" "must be <=" "$OUT"

OUT=$(bash scripts/check.sh USDC --bad-flag 2>&1 || true)
assert_grep "unknown flag rejected"   "unknown flag" "$OUT"

OUT=$(bash scripts/check.sh USDC --max-blocks abc 2>&1 || true)
assert_grep "non-numeric rejected"    "must be a non-negative integer" "$OUT"

OUT=$(bash scripts/check.sh USDC --format yaml 2>&1 || true)
assert_grep "bad format rejected"     "must be md, json, or txt" "$OUT"

OUT=$(bash scripts/check.sh USDC --max-blocks 100 --from-block 50 2>&1 || true)
assert_grep "mutually exclusive flags" "cannot use --max-blocks with --from-block" "$OUT"

# ============================================================================
# deploy_registry.sh
# ============================================================================
echo ""
echo "== deploy_registry.sh =="

OUT=$(bash scripts/deploy_registry.sh 2>&1 || true)
assert_grep "no network rejected"     "--network required" "$OUT"

OUT=$(bash scripts/deploy_registry.sh --network bogus 2>&1 || true)
assert_grep "bad network rejected"    "unknown network" "$OUT"

# ============================================================================
# register_symbol.sh
# ============================================================================
echo ""
echo "== register_symbol.sh =="

OUT=$(bash scripts/register_symbol.sh 2>&1 || true)
assert_grep "no symbol rejected"      "SYMBOL argument is required" "$OUT"

OUT=$(bash scripts/register_symbol.sh SKP 2>&1 || true)
assert_grep "no network rejected"     "--network required" "$OUT"

# ============================================================================
# query_registry.sh
# ============================================================================
echo ""
echo "== query_registry.sh =="

OUT=$(bash scripts/query_registry.sh 2>&1 || true)
assert_grep "no symbol rejected"      "SYMBOL argument is required" "$OUT"

OUT=$(bash scripts/query_registry.sh SKP 2>&1 || true)
assert_grep "no network rejected"     "--network required" "$OUT"

OUT=$(bash scripts/query_registry.sh SKP --network mainnet --format xml 2>&1 || true)
assert_grep "bad format rejected"     "must be json or txt" "$OUT"

# ============================================================================
# release_symbol.sh
# ============================================================================
echo ""
echo "== release_symbol.sh =="

OUT=$(bash scripts/release_symbol.sh 2>&1 || true)
assert_grep "no symbol rejected"      "SYMBOL argument is required" "$OUT"

OUT=$(bash scripts/release_symbol.sh SKP 2>&1 || true)
assert_grep "no network rejected"     "--network required" "$OUT"

# ============================================================================
# registry_history.sh
# ============================================================================
echo ""
echo "== registry_history.sh =="

OUT=$(bash scripts/registry_history.sh 2>&1 || true)
assert_grep "no network rejected"     "--network required" "$OUT"

OUT=$(bash scripts/registry_history.sh --network mainnet --format xml 2>&1 || true)
assert_grep "bad format rejected"     "must be json or txt" "$OUT"

# ============================================================================
# Network config validation
# ============================================================================
echo ""
echo "== assets/networks.json =="

if python3 -c "import json; d=json.load(open('assets/networks.json')); assert 'networks' in d; assert d['defaultNetwork']; assert any(n.get('contracts',{}).get('SymbolRegistry') is not None for n in d['networks'])" 2>/dev/null; then
  ok "valid JSON, has defaultNetwork + contracts.SymbolRegistry field"
else
  fail "networks.json structure invalid"
fi

# ============================================================================
echo ""
echo "================================================"
echo "  $PASS passed, $FAIL failed"
echo "================================================"
[ "$FAIL" -eq 0 ]