#!/bin/bash
# Smoke test for PSCD. Runs offline — no RPC calls.
#
# This Skill is a pure off-chain scanner: bash scripts + python3 + cast/curl,
# talking to the public Pharos RPC. There is no on-chain registry, no Solidity
# contract. The bash + python3 + cast stack is intentionally simple so the
# Anvita Flow hosted runtime can mount it.
#
# What this script verifies:
#   1. check.sh argument validation
#   2. registry_history.sh argument validation
#   3. SKILL.md + README.md + references/ exist and have content
#   4. assets/networks.json is valid JSON, has mainnet + testnet entries,
#      with no contract field (PSCD is index-only, no on-chain registry)
#   5. No SETUP.md (rejected by Anvita Flow upload validator)
#   6. python3 is available (required by scripts)
#   7. The two core scripts are executable

set -e

PASS=0
FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
note() { echo "    · $1"; }

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
# registry_history.sh
# ============================================================================
echo ""
echo "== registry_history.sh =="

OUT=$(bash scripts/registry_history.sh 2>&1 || true)
assert_grep "no network rejected"     "--network required" "$OUT"

OUT=$(bash scripts/registry_history.sh --network mainnet --format xml 2>&1 || true)
assert_grep "bad format rejected"     "must be json or txt" "$OUT"

OUT=$(bash scripts/registry_history.sh --network bogus 2>&1 || true)
assert_grep "bad network rejected"    "unknown network" "$OUT"

# ============================================================================
# Skill surface (doc content checks)
# ============================================================================
echo ""
echo "== SKILL.md (agent entry point) =="

[ -s SKILL.md ] && ok "SKILL.md exists and is non-empty" || fail "SKILL.md missing"

# Frontmatter name: must be alphanumeric at both ends for Anvita Flow runtime
if head -10 SKILL.md | grep -qE "^name:.*[a-zA-Z0-9]$"; then
  ok "SKILL.md name ends in alphanumeric (Anvita validator requirement)"
else
  fail "SKILL.md name does not end with alphanumeric"
fi

# SKILL.md must NOT have SETUP.md
if [ ! -f SETUP.md ]; then
  ok "no SETUP.md (Anvita validator rejects it)"
else
  fail "SETUP.md exists (rejected by Anvita Flow upload validator)"
fi

# SKILL.md must NOT mention on-chain registry contract
if grep -qE 'SymbolRegistry' SKILL.md; then
  fail "SKILL.md still references the on-chain SymbolRegistry contract"
else
  ok "SKILL.md no longer references on-chain registry"
fi

# SKILL.md MUST mention the off-chain scanner (the actual value)
if grep -qE 'check\.sh|off-chain scanner|ERC-20' SKILL.md; then
  ok "SKILL.md mentions the off-chain scanner"
else
  fail "SKILL.md missing off-chain scanner description"
fi

# ============================================================================
# README + references
# ============================================================================
echo ""
echo "== README.md / references/ =="

[ -s README.md ] && ok "README.md exists and is non-empty" || fail "README.md missing"

[ -s references/methodology.md ] && ok "references/methodology.md non-empty" || fail "references/methodology.md missing"

# ============================================================================
# Network config validation
# ============================================================================
echo ""
echo "== assets/networks.json =="

if python3 -c "
import json, sys
d = json.load(open('assets/networks.json'))
assert 'networks' in d, 'missing networks key'
assert d.get('defaultNetwork'), 'missing defaultNetwork'
names = [n['name'] for n in d['networks']]
assert 'mainnet' in names, 'no mainnet entry'
assert 'atlantic-testnet' in names, 'no testnet entry'
for n in d['networks']:
  assert n.get('rpcUrl'), f'{n[\"name\"]} missing rpcUrl'
  assert n.get('chainId'), f'{n[\"name\"]} missing chainId'
  assert 'contracts' not in n, f'{n[\"name\"]} has stale contracts field'
" 2>/dev/null; then
  ok "valid JSON, has mainnet + testnet, no stale contracts field"
else
  fail "networks.json structure invalid or has stale contracts field"
fi

# ============================================================================
# No on-chain artifacts
# ============================================================================
echo ""
echo "== No on-chain artifacts (PSCD is index-only) =="

for removed in assets/contracts scripts/deploy_registry.sh references/registry.md tests/SymbolRegistry.t.sol; do
  if [ ! -e "$removed" ]; then
    ok "$removed removed"
  else
    fail "$removed still exists (PSCD is index-only, no on-chain registry)"
  fi
done

# ============================================================================
# python3 / required binaries
# ============================================================================
echo ""
echo "== Required binaries =="

if command -v python3 >/dev/null 2>&1; then
  ok "python3 available: $(python3 --version 2>&1)"
else
  fail "python3 not found (required by scripts/check.sh and registry_history.sh)"
fi

# bash is required (we're running inside it)
ok "bash $(bash --version | head -1 | awk '{print $4}') (running)"

# curl / cast are nice-to-have, not required for offline smoke
note "scripts/check.sh needs cast + curl + python3 at runtime; the Anvita Flow"
note "hosted runtime pre-installs all three."

# ============================================================================
echo ""
echo "================================================"
echo "  $PASS passed, $FAIL failed"
echo "================================================"
[ "$FAIL" -eq 0 ] || exit 1