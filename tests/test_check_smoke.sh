#!/bin/bash
# Smoke test for the Foundry port of pharos-symbol-collision-detector.
set -e
SCRIPT="scripts/check.sh"

# Test 1: help
bash "$SCRIPT" --help >/dev/null

# Test 2: no args
if bash "$SCRIPT" 2>&1 | grep -q "provide a symbol"; then
  echo "OK: no-args shows usage"
else
  echo "FAIL: no-args did not show usage"; exit 1
fi

# Test 3: bad network
if bash "$SCRIPT" USDC --network foo 2>&1 | grep -q "Unknown network"; then
  echo "OK: bad network rejected"
else
  echo "FAIL: bad network not rejected"; exit 1
fi

# Test 4: from > to
if bash "$SCRIPT" USDC --from-block 100 --to-block 50 2>&1 | grep -q "must be <="; then
  echo "OK: from>to rejected"
else
  echo "FAIL: from>to not rejected"; exit 1
fi

# Test 5: cast missing
if ! command -v cast >/dev/null 2>&1; then
  if bash "$SCRIPT" USDC --network mainnet 2>&1 | grep -q "cast.*not found"; then
    echo "OK: cast-missing error is clear"
  else
    echo "FAIL: cast-missing error unclear"; exit 1
  fi
else
  echo "OK: cast is installed (live test would require Pharos RPC access)"
fi

echo ""
echo "All smoke tests passed."
