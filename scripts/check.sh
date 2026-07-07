#!/usr/bin/env bash
# PSCD -- Pharos Symbol Collision Detector
#
# Scans Pharos mainnet (default) or testnet for ERC-20 tokens whose on-chain
# `symbol()` matches a candidate. Emits a structured report to stdout
# (markdown, json, or text) and progress logs to stderr.
#
# Usage:
#   bash scripts/check.sh SYMBOL [options]
#
# Options:
#   --network NAME         mainnet | testnet [default: mainnet]
#   --max-blocks N         scan only the last N most-recent blocks
#   --from-block N         explicit start block (default: 0)
#   --to-block N           explicit end block (default: latest)
#   --step N               blocks per eth_getLogs batch (default 1000, max 1000)
#   --workers N            parallel eth_call workers (default 6)
#   --format FMT           md | json | txt [default: md]
#   --quiet                suppress progress on stderr
#   --demo                 check the symbol 'USDC' on a bounded range
#   -h, --help             show this help
#
# Examples:
#   bash scripts/check.sh USDC --network mainnet
#   bash scripts/check.sh USDC --max-blocks 50000
#   bash scripts/check.sh USDC --from-block 9000000 --to-block 9050000
#   bash scripts/check.sh USDC --format json

set -uo pipefail

# ---- Load network config ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET_JSON="$SCRIPT_DIR/../assets/networks.json"
if [ ! -f "$NET_JSON" ]; then
  echo "Error: $NET_JSON not found" >&2
  exit 1
fi

# Read a single field from a network entry
get_field() {
  local net_name="$1" field="$2"
  python3 -c "
import json,sys
try:
  d=json.load(open('$NET_JSON'))
  for n in d['networks']:
    if n['name']=='$net_name':
      v=n.get('$field','')
      print(v if v is not None else '')
      sys.exit(0)
except Exception as e:
  print('', file=sys.stderr)
  sys.exit(1)
" 2>/dev/null
}

# JSON-RPC POST helper using curl + python parser (more portable than cast rpc)
rpc_call() {
  local rpc="$1" method="$2"
  shift 2
  python3 - "$rpc" "$method" "$@" <<'PY'
import json, sys, urllib.request
rpc, method = sys.argv[1], sys.argv[2]
params = []
for arg in sys.argv[3:]:
    try:
        params.append(json.loads(arg))
    except json.JSONDecodeError:
        params.append(arg)
payload = {"jsonrpc":"2.0","method":method,"params":params,"id":1}
req = urllib.request.Request(
    rpc, data=json.dumps(payload).encode(),
    headers={"Content-Type":"application/json"}
)
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        body = json.loads(r.read().decode())
        if "result" in body:
            result = body["result"]
            # If scalar (string/number/hex), print raw; if list/dict, print JSON
            if isinstance(result, (list, dict)):
                print(json.dumps(result, ensure_ascii=False))
            else:
                print(result)
        elif "error" in body:
            sys.stderr.write(f"RPC error: {body['error']}\n")
            sys.exit(2)
except Exception as e:
    sys.stderr.write(f"RPC request failed: {e}\n")
    sys.exit(2)
PY
}

# ---- Arg parsing ----
NETWORK="mainnet"
MAX_BLOCKS=""
FROM_BLOCK=""
TO_BLOCK=""
STEP=1000
WORKERS=6
FORMAT="md"
QUIET=0
DEMO=0
SYMBOL=""

usage() {
  sed -n '2,/^set -uo pipefail/p' "$0" | sed 's/^# \{0,1\}//' | head -40
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --network) NETWORK="$2"; shift 2 ;;
    --max-blocks) MAX_BLOCKS="$2"; shift 2 ;;
    --step) STEP="$2"; shift 2 ;;
    --workers) WORKERS="$2"; shift 2 ;;
    --from-block) FROM_BLOCK="$2"; shift 2 ;;
    --to-block) TO_BLOCK="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --demo) DEMO=1; shift ;;
    -*) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *) SYMBOL="$1"; shift ;;
  esac
done

log() { [ "$QUIET" = "0" ] && echo "$@" >&2 || true; }

# Validate format early
case "$FORMAT" in
  md|json|txt) ;;
  *) echo "PSCD: --format must be md, json, or txt (got: '$FORMAT')" >&2; exit 2 ;;
esac

# Resolve network
case "$NETWORK" in
  mainnet) NET_KEY="mainnet" ;;
  testnet) NET_KEY="atlantic-testnet" ;;
  *) echo "Unknown network: $NETWORK (expected: mainnet|testnet)" >&2; exit 2 ;;
esac

RPC_URL=$(get_field "$NET_KEY" "rpcUrl")
EXPLORER_URL=$(get_field "$NET_KEY" "explorerUrl")
CHAIN_ID=$(get_field "$NET_KEY" "chainId")
NATIVE_TOKEN=$(get_field "$NET_KEY" "nativeToken")

if [ -z "$RPC_URL" ]; then
  echo "PSCD: could not read rpcUrl for network '$NET_KEY' from $NET_JSON" >&2
  exit 1
fi

# Validate numeric flags
for pair in "MAX_BLOCKS:$MAX_BLOCKS" "FROM_BLOCK:$FROM_BLOCK" "TO_BLOCK:$TO_BLOCK" "STEP:$STEP" "WORKERS:$WORKERS"; do
  name="${pair%%:*}"; val="${pair#*:}"
  if [[ -n "$val" && ! "$val" =~ ^[0-9]+$ ]]; then
    echo "PSCD: --${name,,} must be a non-negative integer (got: '$val')" >&2
    exit 2
  fi
done

[ "$STEP" -gt 1000 ] && { log "PSCD: --step capped at 1000 (public RPC limit)"; STEP=1000; }
[ -n "$MAX_BLOCKS" ] && [ -n "$FROM_BLOCK" ] && { echo "PSCD: cannot use --max-blocks with --from-block" >&2; exit 2; }

# Demo: check USDC
[ "$DEMO" = "1" ] && SYMBOL="USDC"

if [ -z "$SYMBOL" ]; then
  echo "PSCD: provide a symbol, e.g. SKP or USDC" >&2
  usage >&2
  exit 2
fi

# Validate range order
if [ -n "$FROM_BLOCK" ] && [ -n "$TO_BLOCK" ] && [ "$FROM_BLOCK" -gt "$TO_BLOCK" ]; then
  echo "PSCD: --from-block ($FROM_BLOCK) must be <= --to-block ($TO_BLOCK)" >&2
  exit 2
fi

# ---- Foundry required for cast call ----
if ! command -v cast >/dev/null 2>&1; then
  echo "Error: 'cast' not found. Install Foundry:" >&2
  echo "  curl -L https://foundry.paradigm.xyz | bash && foundryup" >&2
  exit 1
fi

# ---- Resolve block range ----
HEAD_HEX=$(rpc_call "$RPC_URL" eth_blockNumber)
HEAD_DEC=$(cast --to-dec "$HEAD_HEX" 2>/dev/null | tr -d '\n')

if [ -n "$MAX_BLOCKS" ]; then
  TO_BLOCK="$HEAD_DEC"
  FROM_BLOCK=$(( HEAD_DEC - MAX_BLOCKS ))
  [ "$FROM_BLOCK" -lt 0 ] && FROM_BLOCK=0
elif [ -z "$FROM_BLOCK" ]; then
  FROM_BLOCK=0
  TO_BLOCK="$HEAD_DEC"
fi

# Normalize candidate symbol: case-insensitive, strip whitespace
NORM_SYMBOL=$(echo "$SYMBOL" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

log ""
log "PSCD -- Pharos Symbol Collision Detector"
log "Network: $NET_KEY  (chain $CHAIN_ID, native $NATIVE_TOKEN)"
log "RPC:     $RPC_URL"
log "Symbol:  $SYMBOL  (normalized: $NORM_SYMBOL)"
log "Range:   [$FROM_BLOCK, $TO_BLOCK]  (step=$STEP, workers=$WORKERS)"
log ""

# ---- Get logs in batches via curl+python ----
log "[1/3] Fetching Transfer-from-zero logs in batches of $STEP blocks..."
TEMP=$(mktemp -d)
LOG_FILES=()
BATCH=0
CURRENT="$FROM_BLOCK"

while [ "$CURRENT" -le "$TO_BLOCK" ]; do
  END=$(( CURRENT + STEP - 1 ))
  [ "$END" -gt "$TO_BLOCK" ] && END="$TO_BLOCK"

  OUT_FILE="$TEMP/logs_${BATCH}.json"
  FROM_HEX=$(printf '0x%x' "$CURRENT")
  END_HEX=$(printf '0x%x' "$END")
  FILTER="{\"fromBlock\":\"$FROM_HEX\",\"toBlock\":\"$END_HEX\",\"topics\":[\"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef\",\"0x0000000000000000000000000000000000000000000000000000000000000000\"]}"

  rpc_call "$RPC_URL" eth_getLogs "$FILTER" > "$OUT_FILE" 2>>"$TEMP/err.log" || echo "[]" > "$OUT_FILE"

  LOG_FILES+=("$OUT_FILE")
  CURRENT=$(( END + 1 ))
  BATCH=$(( BATCH + 1 ))
done
log "  fetched $BATCH batch(es)"

# ---- Extract unique token addresses ----
log "[2/3] Extracting unique token addresses from logs..."
ADDR_FILE="$TEMP/addresses.txt"
python3 - "${LOG_FILES[@]}" > "$ADDR_FILE" <<'PY' 2>/dev/null
import json, sys, os
seen = set()
for path in sys.argv[1:]:
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        continue
    if not isinstance(data, list):
        continue
    for entry in data:
        addr = (entry.get("address") or "").lower()
        # Filter: topic[1] (from) == zero address = mint from zero
        topics = entry.get("topics") or []
        if len(topics) < 2:
            continue
        if topics[1].lower() == "0x" + "0" * 64:
            if addr.startswith("0x") and len(addr) == 42:
                seen.add(addr)
for a in sorted(seen):
    print(a)
PY
UNIQ_COUNT=$(wc -l < "$ADDR_FILE" | tr -d ' ')
log "  found $UNIQ_COUNT unique token address(es)"

# ---- For each token, fetch symbol/name/decimals in parallel ----
log "[3/3] Querying symbol() name() decimals() for each token..."

# Use xargs -P for parallel workers
fetch_one() {
  local addr="$1"
  local rpc="$2"
  local sym_raw name_raw dec_raw

  sym_raw=$(cast call --rpc-url "$rpc" "$addr" "symbol()(string)" 2>/dev/null | head -1)
  if [ -z "$sym_raw" ] || [ "$sym_raw" = "0x" ]; then
    echo "$addr||||REVERT"
    return
  fi

  # cast returns the decoded string already; strip whitespace
  sym_clean=$(echo "$sym_raw" | tr -d '\0' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  name_raw=$(cast call --rpc-url "$rpc" "$addr" "name()(string)" 2>/dev/null | head -1 | tr -d '\0' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  dec_raw=$(cast call --rpc-url "$rpc" "$addr" "decimals()(uint8)" 2>/dev/null | head -1 | tr -d ' ')

  echo "$addr|$sym_clean|$name_raw|$dec_raw"
}
export -f fetch_one

RESULTS_FILE="$TEMP/results.txt"
> "$RESULTS_FILE"

if [ "$UNIQ_COUNT" -gt 0 ]; then
  xargs -a "$ADDR_FILE" -P "$WORKERS" -I{} bash -c 'fetch_one "$@"' _ {} "$RPC_URL" \
    > "$RESULTS_FILE" 2>/dev/null || true
fi

# Filter to collisions only and remove REVERT lines
COLLISIONS_FILE="$TEMP/collisions.txt"
grep -v 'REVERT' "$RESULTS_FILE" > "$COLLISIONS_FILE" 2>/dev/null || true
COLLISION_COUNT=0
> "$TEMP/matches.txt"
while IFS='|' read -r addr sym name decimals; do
  [ -z "$addr" ] && continue
  [ -z "$sym" ] && continue
  NORM_FETCHED=$(echo "$sym" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  if [ "$NORM_FETCHED" = "$NORM_SYMBOL" ]; then
    echo "$addr|$sym|$name|$decimals" >> "$TEMP/matches.txt"
    COLLISION_COUNT=$(( COLLISION_COUNT + 1 ))
  fi
done < "$COLLISIONS_FILE"

log "  $COLLISION_COUNT collision(s) found"
log ""

# ---- Determine verdict ----
VERDICT="CLEAR"
VERDICT_MSG="No token on $NET_KEY uses the symbol '$SYMBOL' in the scanned range."
if [ "$COLLISION_COUNT" -gt 0 ]; then
  VERDICT="COLLISION"
  VERDICT_MSG="$COLLISION_COUNT token(s) on $NET_KEY use the symbol '$SYMBOL'"
fi

# ---- Render stdout ----
case "$FORMAT" in
  json)
    python3 - "$TEMP/matches.txt" "$VERDICT" "$VERDICT_MSG" "$NET_KEY" "$CHAIN_ID" "$RPC_URL" "$EXPLORER_URL" "$SYMBOL" "$NORM_SYMBOL" "$FROM_BLOCK" "$TO_BLOCK" "$UNIQ_COUNT" <<'PY'
import json, sys
(matches_path, verdict, verdict_msg, net_key, chain_id, rpc_url, explorer_url,
 symbol, norm_symbol, from_block, to_block, uniq_count) = sys.argv[1:]
collisions = []
try:
    with open(matches_path) as f:
        for line in f:
            line = line.rstrip('\n')
            if not line: continue
            parts = line.split('|', 3)
            if len(parts) < 4: continue
            addr, sym, name, decimals = parts
            collisions.append({
                "address": addr,
                "symbol": sym,
                "name": name,
                "decimals": int(decimals) if decimals.isdigit() else None,
                "ok": True,
                "explorer": f"{explorer_url.rstrip('/')}/token/{addr}",
            })
except FileNotFoundError:
    pass
out = {
    "network": net_key,
    "chainId": int(chain_id) if chain_id.isdigit() else None,
    "rpc": rpc_url,
    "candidate": symbol,
    "normalized": norm_symbol,
    "from_block": int(from_block),
    "to_block": int(to_block),
    "tokens_seen": int(uniq_count),
    "verdict": verdict,
    "verdict_msg": verdict_msg,
    "collisions": collisions,
}
print(json.dumps(out, indent=2, ensure_ascii=False))
PY
    ;;

  txt)
    echo "PSCD -- Pharos Symbol Collision Detector"
    echo "==========================================="
    echo "  chain:    $NET_KEY"
    echo "  rpc:      $RPC_URL"
    echo "  symbol:   $SYMBOL  (normalized: $NORM_SYMBOL)"
    echo "  range:    [$FROM_BLOCK, $TO_BLOCK]"
    echo "  candidates scanned: $UNIQ_COUNT"
    echo "  collisions: $COLLISION_COUNT"
    echo ""
    if [ "$COLLISION_COUNT" = "0" ]; then
      echo "  CLEAR -- no token with symbol '$SYMBOL' found in the scanned range."
    else
      echo "  COLLISIONS DETECTED"
      echo ""
      printf "  %-44s %-12s %-32s %-8s\n" "ADDRESS" "SYMBOL" "NAME" "DECIMALS"
      echo "  --------------------------------------------------------------------------------"
      while IFS='|' read -r addr sym name decimals; do
        [ -z "$addr" ] && continue
        printf "  %-44s %-12s %-32s %-8s\n" "$addr" "$sym" "${name:0:30}" "$decimals"
      done < "$TEMP/matches.txt"
      echo ""
      echo "  Explorer: $EXPLORER_URL"
    fi
    ;;

  md)
    cat <<MD
# PSCD -- Pharos Symbol Collision Detector

**Verdict:** $([ "$VERDICT" = "CLEAR" ] && echo "✅ CLEAR" || echo "⚠️ COLLISION")

$VERDICT_MSG

## Inputs

- **Network:** $NET_KEY (chain $CHAIN_ID)
- **Candidate symbol:** \`$SYMBOL\` (normalized: \`$NORM_SYMBOL\`)
- **Block range:** $FROM_BLOCK → $TO_BLOCK
- **Tokens seen in range:** $UNIQ_COUNT

MD
    if [ "$COLLISION_COUNT" -gt 0 ]; then
      echo "## Collisions ($COLLISION_COUNT)"
      echo ""
      echo "| # | Symbol | Name | Decimals | Address | Explorer |"
      echo "|---|---|---|---|---|---|"
      i=1
      while IFS='|' read -r addr sym name decimals; do
        [ -z "$addr" ] && continue
        echo "| $i | \`$sym\` | \`$name\` | $decimals | \`$addr\` | [view ↗]($EXPLORER_URL/token/$addr) |"
        i=$(( i + 1 ))
      done < "$TEMP/matches.txt"
      echo ""
      echo "### What to do"
      echo ""
      echo "- **If you control any collision:** rename your token before mainnet launch."
      echo "- **If you don't:** these are impersonators. Do not interact; verify on PharosScan."
      echo "- **If you control none:** pick a different symbol (e.g. \`${SYMBOL}X\` or \`${SYMBOL}2\`)."
    else
      echo "## Result"
      echo ""
      echo "No token on **$NET_KEY** uses the symbol \`$SYMBOL\` within the scanned block range."
      echo ""
      echo "A CLEAR result is a positive signal: the symbol you want to launch is not"
      echo "currently minted on Pharos within the scanned range."
    fi
    ;;
esac

# Clean up
rm -rf "$TEMP"
exit 0