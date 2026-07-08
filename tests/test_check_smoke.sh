#!/bin/bash
# Smoke test for PSCD. Runs offline — no RPC calls.
#
# This Skill is cast-only. The remaining bash script (deploy_registry.sh) is
# an OPTIONAL forge-based one-time deploy helper. It is NOT part of the
# runtime surface that the Steward Agent invokes — every Skill operation is
# a direct cast call against the already-deployed SymbolRegistry contract.
#
# What this script verifies:
#   1. deploy_registry.sh argument validation
#   2. SKILL.md + README.md + references/ exist and have content
#   3. assets/contracts/SymbolRegistry.sol is syntactically valid Solidity
#   4. assets/networks.json is valid JSON with the mainnet SymbolRegistry populated
#   5. The SymbolRegistry compile output exists (forge build artifact)
#   6. No stragglers from the old bash-skill era (no scripts/check.sh etc.)

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
# deploy_registry.sh -- the only remaining bash script
# ============================================================================
echo ""
echo "== deploy_registry.sh =="

OUT=$(bash scripts/deploy_registry.sh 2>&1 || true)
assert_grep "no network rejected"     "--network required" "$OUT"

OUT=$(bash scripts/deploy_registry.sh --network bogus 2>&1 || true)
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

# Capability Index MUST be cast-only (no bash pipes, no 'scripts/' references).
# grep across the whole file (one line could have `cast` and another could have
# `isClaimed`, since the URL might break the line).
if grep -q 'cast call' SKILL.md && grep -q 'isClaimed' SKILL.md; then
  ok "SKILL.md has cast-only isClaimed invocation"
else
  fail "SKILL.md missing cast-only isClaimed"
fi

if grep -q 'cast send' SKILL.md && grep -q 'register(string,string)' SKILL.md; then
  ok "SKILL.md has cast-only register invocation"
else
  fail "SKILL.md missing cast-only register"
fi

# SKILL.md must NOT reference the removed bash scanner
if grep -qE 'scripts/check\.sh|scripts/scan_symbol\.sh' SKILL.md; then
  fail "SKILL.md still references removed bash scanner"
else
  ok "SKILL.md no longer references removed bash scanner"
fi

# ============================================================================
# README + references
# ============================================================================
echo ""
echo "== README.md / references/ =="

[ -s README.md ] && ok "README.md exists and is non-empty" || fail "README.md missing"

for f in references/registry.md references/methodology.md; do
  [ -s "$f" ] && ok "$f non-empty" || fail "$f missing"
done

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
mains = [n for n in d['networks'] if n.get('name') == 'mainnet']
if not mains: sys.exit('no mainnet network entry')
sr = mains[0].get('contracts', {}).get('SymbolRegistry')
if not sr or not sr.startswith('0x') or len(sr) != 42:
  sys.exit(f'mainnet SymbolRegistry not a valid 0x address: {sr!r}')
" 2>/dev/null; then
  ok "valid JSON, has defaultNetwork + mainnet SymbolRegistry (0x + 42 chars)"
else
  fail "networks.json structure invalid or missing mainnet SymbolRegistry"
fi

# ============================================================================
# Solidity contract -- must compile cleanly via forge build
# ============================================================================
echo ""
echo "== SymbolRegistry.sol =="

[ -s assets/contracts/SymbolRegistry.sol ] && ok "contract source present" || fail "contract source missing"

if command -v forge >/dev/null 2>&1; then
  if forge build --silent 2>/dev/null; then
    ok "forge build succeeds"
    if [ -f out/SymbolRegistry.sol/SymbolRegistry.json ]; then
      ok "SymbolRegistry.json artifact present"
    else
      fail "SymbolRegistry.json artifact missing after build"
    fi
  else
    fail "forge build failed"
  fi
else
  note "forge not installed — skipping build check"
fi

# ============================================================================
# No stragglers from the old bash-skill era
# ============================================================================
echo ""
echo "== Removed bash scripts (should not exist) =="

for removed in scripts/check.sh scripts/query_registry.sh scripts/register_symbol.sh scripts/release_symbol.sh scripts/registry_history.sh scripts/_registry_history_parse.py SETUP.md; do
  if [ -e "$removed" ]; then
    fail "$removed still exists (should be removed for cast-only flow)"
  else
    ok "$removed removed"
  fi
done

# ============================================================================
echo ""
echo "================================================"
echo "  $PASS passed, $FAIL failed"
echo "================================================"
[ "$FAIL" -eq 0 ] || exit 1