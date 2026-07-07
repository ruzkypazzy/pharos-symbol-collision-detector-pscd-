#!/usr/bin/env bash
# query_registry.sh -- Read whether a symbol has an active claim on SymbolRegistry.
#
# Usage:
#   bash scripts/query_registry.sh SYMBOL [--network mainnet|testnet] [--format json|txt]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET_JSON="$SCRIPT_DIR/../assets/networks.json"

NETWORK=""
RPC_URL_OVERRIDE=""
SYMBOL=""
FORMAT="json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) NETWORK="$2"; shift 2 ;;
    --rpc-url) RPC_URL_OVERRIDE="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo pipefail/p' "$0" | sed 's/^# \{0,1\}//' | head -15; exit 0 ;;
    -*) echo "query_registry: unknown flag: $1" >&2; exit 2 ;;
    *) SYMBOL="$1"; shift ;;
  esac
done

if [ -z "$SYMBOL" ]; then
  echo "query_registry: SYMBOL argument is required (e.g. SKP, USDC)" >&2
  exit 2
fi

if [ -z "$NETWORK" ]; then
  echo "query_registry: --network required (mainnet|testnet)" >&2
  exit 2
fi

case "$FORMAT" in
  json|txt) ;;
  *) echo "query_registry: --format must be json or txt" >&2; exit 2 ;;
esac

case "$NETWORK" in
  mainnet) NET_KEY="mainnet" ;;
  testnet) NET_KEY="atlantic-testnet" ;;
  *) echo "query_registry: unknown network '$NETWORK'" >&2; exit 2 ;;
esac

if ! command -v cast >/dev/null 2>&1; then
  echo "Error: 'cast' not found. Install Foundry:" >&2
  echo "  curl -L https://foundry.paradigm.xyz | bash && foundryup" >&2
  exit 1
fi

read_field() {
  python3 -c "
import json
d=json.load(open('$NET_JSON'))
for n in d['networks']:
  if n['name']=='$NET_KEY':
    print(n.get('$1',''))
    break
"
}

RPC_URL="${RPC_URL_OVERRIDE:-$(read_field rpcUrl)}"
EXPLORER_URL=$(read_field explorerUrl)
REGISTRY=$(python3 -c "
import json
d=json.load(open('$NET_JSON'))
for n in d['networks']:
  if n['name']=='$NET_KEY':
    print(n.get('contracts',{}).get('SymbolRegistry',''))
    break
")

if [ -z "$REGISTRY" ]; then
  echo "query_registry: SymbolRegistry not configured for '$NET_KEY'." >&2
  echo "  Run: bash scripts/deploy_registry.sh --network $NETWORK" >&2
  exit 1
fi

# Compute normalized symbol and hash
NORM_SYMBOL=$(echo "$SYMBOL" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
NORM_UPPER=$(echo "$NORM_SYMBOL" | tr '[:lower:]' '[:upper:]')
SYMBOL_HASH=$(cast keccak "$NORM_UPPER" 2>/dev/null)

# isClaimed(string) returns (bool)
IS_CLAIMED_HEX=$(cast call "$REGISTRY" "isClaimed(string)(bool)" "$SYMBOL" --rpc-url "$RPC_URL" 2>/dev/null | head -1 | tr -d ' ')

IS_CLAIMED=0
case "$IS_CLAIMED_HEX" in
  true|1|0x1)  IS_CLAIMED=1 ;;
  false|0|0x0|"") IS_CLAIMED=0 ;;
esac

if [ "$FORMAT" = "json" ]; then
  if [ "$IS_CLAIMED" -eq 1 ]; then
    # Fetch full claim record
    CLAIMER=$(cast call "$REGISTRY" "getClaim(string)((address,uint256,uint64,uint64,string,bool))" "$SYMBOL" --rpc-url "$RPC_URL" 2>/dev/null | head -1)
    # Parse the tuple - cast returns it as a parenthesized list
    CLAIM_JSON=$(python3 - "$SYMBOL" "$NORM_SYMBOL" "$SYMBOL_HASH" "$NET_KEY" "$REGISTRY" "$EXPLORER_URL" "$CLAIMER" <<'PY'
import json, sys, re
(symbol, norm, symhash, net_key, registry, explorer, raw) = sys.argv[1:]
def parse_tuple(s):
    # Strip outer parens, split by comma
    s = s.strip()
    if s.startswith("(") and s.endswith(")"):
        s = s[1:-1]
    parts = []
    depth = 0
    cur = ""
    for ch in s:
        if ch == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            if ch == "(" : depth += 1
            elif ch == ")": depth -= 1
            cur += ch
    if cur.strip():
        parts.append(cur.strip())
    return parts

parts = parse_tuple(raw) if raw and raw.strip() else []
# Expect 6 elements: address, uint256, uint64, uint64, string, bool
def to_int(x):
    x = x.strip()
    if not x: return 0
    if x.startswith("0x"):
        return int(x, 16)
    return int(x)
addr, deposit, ts, blk, uri, active = (parts + [""]*6)[:6]
out = {
    "network": net_key,
    "registryAddress": registry,
    "candidate": symbol,
    "normalized": norm,
    "symbolHash": symhash,
    "explorer": f"{explorer.rstrip('/')}/address/{registry}",
    "claimed": True,
    "claimer": addr,
    "deposit_wei": str(to_int(deposit)),
    "timestamp": to_int(ts),
    "blockNumber": to_int(blk),
    "projectURI": uri.strip('"'),
    "active": (active.strip().lower() in ("true", "1", "0x1")),
}
print(json.dumps(out, indent=2, ensure_ascii=False))
PY
)
    echo "$CLAIM_JSON"
  else
    cat <<JSON
{
  "network": "$NET_KEY",
  "registryAddress": "$REGISTRY",
  "candidate": "$SYMBOL",
  "normalized": "$NORM_SYMBOL",
  "symbolHash": "$SYMBOL_HASH",
  "explorer": "$EXPLORER_URL/address/$REGISTRY",
  "claimed": false
}
JSON
  fi
else
  if [ "$IS_CLAIMED" -eq 1 ]; then
    CLAIMER=$(cast call "$REGISTRY" "getClaim(string)((address,uint256,uint64,uint64,string,bool))" "$SYMBOL" --rpc-url "$RPC_URL" 2>/dev/null | head -1)
    echo "CLAIMED on $NET_KEY"
    echo "  Symbol:     $SYMBOL"
    echo "  Claim hash: $SYMBOL_HASH"
    echo "  Record:     $CLAIMER"
    echo "  Explorer:   $EXPLORER_URL/address/$REGISTRY"
  else
    echo "NOT CLAIMED on $NET_KEY"
    echo "  Symbol:     $SYMBOL"
    echo "  Claim hash: $SYMBOL_HASH"
    echo "  Registry:   $REGISTRY"
  fi
fi

exit 0