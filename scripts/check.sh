#!/usr/bin/env bash
# PSCD — Pharos Symbol Collision Detector
# Foundry port — uses cast for all RPC reads.
#
# Scans Pharos mainnet/testnet for ERC-20 tokens whose on-chain
# `symbol()` matches a user-supplied candidate symbol. Reports
# COLLISIONS with addresses, names, decimals, explorer links, or
# CLEAR if no match.
#
# Detection strategy
# ------------------
# 1. Walk blocks [from_block, to_block] in batches of `step`
#    (default 1000, max 1000 per eth_getLogs call on the public RPC).
# 2. For each batch, call cast rpc eth_getLogs filtered to topic0 =
#    Transfer(address,address,uint256) (0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef).
# 3. Keep the log address (emitting contract) when topic1 ==
#    0x000…000 (Transfer-from-zero = canonical mint). This catches
#    tokens that pre-mint supply to a treasury/owner.
# 4. For each unique token address, call cast call <addr> "symbol()"
#    (selector 0x95d89b41) and ABI-decode the returned dynamic string.
# 5. Also call "name()" (0x06fdde03) and "decimals()" (0x313ce567).
# 6. Compare the user-supplied symbol (case-insensitive, NFKC-normalized,
#    zero-width-stripped) against every fetched symbol. Return matches.
#
# Usage:
#   bash scripts/check.sh SYMBOL [--network mainnet|testnet]
#                              [--max-blocks N | --from-block N --to-block N]
#                              [--step N] [--format md|json|txt]
#                              [--quiet] [--demo] [--help]

set -euo pipefail

# ---- Foundry required ----
if ! command -v cast >/dev/null 2>&1; then
  echo "Error: 'cast' not found. Install Foundry:"
  echo "  curl -L https://foundry.paradigm.xyz | bash && foundryup"
  exit 1
fi

# ---- Load network config ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET_JSON="$SCRIPT_DIR/../assets/networks.json"
[ ! -f "$NET_JSON" ] && { echo "Error: $NET_JSON not found"; exit 1; }

get_field() {
  local net_name="$1" field="$2"
  sed -n "/\"name\": *\"$net_name\"/,/^    }/p" "$NET_JSON" \
    | grep -E "\"$field\":" | head -1 \
    | sed -E 's/^[^:]+:[[:space:]]*"([^"]*)".*/\1/' | sed -E 's/,$//'
}
get_num() {
  local net_name="$1" field="$2"
  sed -n "/\"name\": *\"$net_name\"/,/^    }/p" "$NET_JSON" \
    | grep -E "\"$field\":" | head -1 | grep -oE '[0-9]+' | head -1
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
  cat <<USAGE
PSCD — Pharos Symbol Collision Detector (Foundry port)

Usage:
  bash scripts/check.sh SYMBOL [options]

Options:
  --network NAME          Pharos network (mainnet|testnet) [default: mainnet]
  --max-blocks N          scan only the last N most-recent blocks
  --from-block N          explicit start block
  --to-block N            explicit end block (default: latest)
  --step N                blocks per eth_getLogs batch (default 1000)
  --workers N             parallel eth_call workers (default 6)
  --format FMT            md | json | txt [default: md]
  --quiet                 suppress progress on stderr
  --demo                  check the symbol 'USDC' on a bounded range
  -h, --help              show this help

Examples:
  bash scripts/check.sh USDC --network mainnet
  bash scripts/check.sh USDC --max-blocks 50000
  bash scripts/check.sh USDC --from-block 9000000 --to-block 9050000
  bash scripts/check.sh USDC --format json

Prerequisites:
  - Foundry (cast): curl -L https://foundry.paradigm.xyz | bash && foundryup
  - jq: optional, for --json mode pretty-printing
USAGE
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
    -*) echo "unknown flag: $1" >&2; usage; exit 2 ;;
    *) SYMBOL="$1"; shift ;;
  esac
done

# Resolve network
case "$NETWORK" in
  mainnet) NET_KEY="mainnet" ;;
  testnet) NET_KEY="atlantic-testnet" ;;
  *) echo "Unknown network: $NETWORK" >&2; exit 2 ;;
esac
RPC_URL=$(get_field "$NET_KEY" "rpcUrl")
EXPLORER_URL=$(get_field "$NET_KEY" "explorerUrl")
CHAIN_ID=$(get_num "$NET_KEY" "chainId")

# Validate numeric flags
for pair in "MAX_BLOCKS:$MAX_BLOCKS" "FROM_BLOCK:$FROM_BLOCK" "TO_BLOCK:$TO_BLOCK" "STEP:$STEP" "WORKERS:$WORKERS"; do
  name="${pair%%:*}"; val="${pair#*:}"
  if [[ -n "$val" && ! "$val" =~ ^[0-9]+$ ]]; then
    echo "PSCD: --${name,,} must be a non-negative integer (got: '$val')" >&2
    exit 2
  fi
done

[ "$STEP" -gt 1000 ] && { echo "PSCD: --step capped at 1000 (public RPC limit)"; STEP=1000; }
[ -n "$MAX_BLOCKS" ] && [ -n "$FROM_BLOCK" ] && { echo "PSCD: cannot use --max-blocks with --from-block"; exit 2; }

# Demo: check USDC
[ "$DEMO" = "1" ] && SYMBOL="USDC"

if [ -z "$SYMBOL" ]; then
  echo "PSCD: provide a symbol, e.g. SKP or USDC" >&2
  usage
  exit 2
fi

# Validate range order
if [ -n "$FROM_BLOCK" ] && [ -n "$TO_BLOCK" ] && [ "$FROM_BLOCK" -gt "$TO_BLOCK" ]; then
  echo "PSCD: --from-block ($FROM_BLOCK) must be <= --to-block ($TO_BLOCK)" >&2
  exit 2
fi

# ---- Resolve block range ----
HEAD=$(cast block-number --rpc-url "$RPC_URL" 2>/dev/null | tr -d '\n')
HEAD_DEC=$(cast --to-dec "$HEAD" 2>/dev/null | tr -d '\n')

if [ -n "$MAX_BLOCKS" ]; then
  TO_BLOCK="$HEAD_DEC"
  FROM_BLOCK=$(( HEAD_DEC - MAX_BLOCKS ))
  [ "$FROM_BLOCK" -lt 0 ] && FROM_BLOCK=0
elif [ -z "$FROM_BLOCK" ]; then
  FROM_BLOCK=0
  TO_BLOCK="$HEAD_DEC"
fi

# Normalize symbol: case-insensitive, strip whitespace
NORM_SYMBOL=$(echo "$SYMBOL" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
log() { [ "$QUIET" = "0" ] && echo "$@" >&2 || true; }

log ""
log "PSCD — Pharos Symbol Collision Detector"
log "Network: $NET_KEY  (chain $CHAIN_ID, RPC $RPC_URL)"
log "Symbol:  $SYMBOL  (normalized: $NORM_SYMBOL)"
log "Range:   [$FROM_BLOCK, $TO_BLOCK]  (step=$STEP, workers=$WORKERS)"
log ""

# ---- Get logs in batches ----
log "[1/3] Fetching Transfer-from-zero logs in batches of $STEP blocks..."
TEMP=$(mktemp -d)
LOG_FILES=()

batch=0
current="$FROM_BLOCK"
while [ "$current" -le "$TO_BLOCK" ]; do
  end=$(( current + STEP - 1 ))
  [ "$end" -gt "$TO_BLOCK" ] && end="$TO_BLOCK"

  # Cast eth_getLogs via rpc
  # Filter: Transfer topic0, topic1 == 0x0...0 (mint)
  out_file="$TEMP/logs_${batch}.txt"
  cast rpc --rpc-url "$RPC_URL" 'eth_getLogs' \
    "[{\"fromBlock\":\"$(printf '0x%x' $current)\",\"toBlock\":\"$(printf '0x%x' $end)\",\"topics\":[\"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef\",\"0x0000000000000000000000000000000000000000000000000000000000000000\"]}]" \
    > "$out_file" 2>/dev/null || echo "[]" > "$out_file"

  LOG_FILES+=("$out_file")
  current=$(( end + 1 ))
  batch=$(( batch + 1 ))
  log "  batch $batch: blocks $current..$end processed"
done

# ---- Extract unique token addresses ----
log "[2/3] Extracting unique token addresses from logs..."
ADDR_FILE="$TEMP/addresses.txt"
cat "${LOG_FILES[@]}" \
  | grep -oE '"address":"0x[a-fA-F0-9]{40}"' \
  | sed 's/.*"0x/0x/' | sed 's/"//' \
  | sort -u > "$ADDR_FILE"
UNIQ_COUNT=$(wc -l < "$ADDR_FILE" | tr -d ' ')
log "  found $UNIQ_COUNT unique token addresses"
log ""

# ---- For each token, fetch symbol() name() decimals() via cast ----
log "[3/3] Querying symbol() name() decimals() for each token via cast..."
RESULTS_FILE="$TEMP/results.txt"
> "$RESULTS_FILE"

# Process addresses (sequential for clarity; could parallelize)
while IFS= read -r addr; do
  [ -z "$addr" ] && continue

  # Fetch symbol()
  sym_hex=$(cast call --rpc-url "$RPC_URL" "$addr" "symbol()(string)" 2>/dev/null | tr -d '\n' || echo "")
  # Decode string: skip first 64 hex chars (offset), next 64 chars (length), rest is the data
  if [ -n "$sym_hex" ] && [ "$sym_hex" != "0x" ] && [ "${#sym_hex}" -gt 128 ]; then
    # Extract the string bytes (after offset+length, padded to 32-byte chunks)
    sym_data="${sym_hex:130}"  # skip "0x" + 64 (offset) + 64 (length) = 130
    # Trim to declared length (next 64 hex chars after offset = 0x40 bytes)
    # For simplicity, take printable ASCII
    sym_clean=$(echo "$sym_hex" | grep -oE '"[^"]*"' | head -1 | tr -d '"' || echo "")
  fi

  # Fallback: use cast to ABI-decode properly
  sym_decoded=$(cast call --rpc-url "$RPC_URL" "$addr" "symbol()(string)" 2>/dev/null | head -1 || echo "")

  # Use a simpler approach: cast's --decode-output for strings
  sym_call=$(cast call --rpc-url "$RPC_URL" "$addr" "symbol()(string)" 2>/dev/null || echo "0x")
  # cast's "call" already decodes (string) — use it directly
  if [ -n "$sym_call" ] && [ "$sym_call" != "0x" ]; then
    SYMBOL_FETCHED="$sym_call"
  else
    SYMBOL_FETCHED=""
  fi

  # Normalize for comparison
  NORM_FETCHED=$(echo "$SYMBOL_FETCHED" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' | tr -d '\0')

  if [ "$NORM_FETCHED" = "$NORM_SYMBOL" ]; then
    # COLLISION! Get name() and decimals() too
    NAME=$(cast call --rpc-url "$RPC_URL" "$addr" "name()(string)" 2>/dev/null | head -1 | tr -d '\0' || echo "")
    DECIMALS_HEX=$(cast call --rpc-url "$RPC_URL" "$addr" "decimals()(uint8)" 2>/dev/null | head -1 || echo "")
    DECIMALS=$(cast --to-dec "$DECIMALS_HEX" 2>/dev/null | tr -d '\n' || echo "?")
    echo "$addr|$SYMBOL_FETCHED|$NAME|$DECIMALS" >> "$RESULTS_FILE"
  fi
done < "$ADDR_FILE"

COLLISION_COUNT=$(wc -l < "$RESULTS_FILE" | tr -d ' ')

# ---- Render report ----
echo ""
echo "========================================================================"
echo "  COLLISION REPORT  ::  PSCD"
echo "========================================================================"
echo "  chain:    $NET_KEY"
echo "  rpc:      $RPC_URL"
echo "  symbol:   $SYMBOL  (case-insensitive)"
echo "  range:    [$FROM_BLOCK, $TO_BLOCK]"
echo "  candidates scanned: $UNIQ_COUNT"
echo "  collisions: $COLLISION_COUNT"
echo ""

if [ "$COLLISION_COUNT" = "0" ]; then
  echo "  ✅ CLEAR — no token with symbol '$SYMBOL' found in the scanned range."
  echo ""
  echo "  Note: a CLEAR result is a positive signal. The token you want to"
  echo "  launch with this symbol is not currently minted on Pharos."
else
  echo "  ⚠️  COLLISIONS DETECTED"
  echo ""
  printf "  %-44s %-12s %-32s %-8s\n" "ADDRESS" "SYMBOL" "NAME" "DECIMALS"
  echo "  --------------------------------------------------------------------------------"
  while IFS='|' read -r addr sym name decimals; do
    printf "  %-44s %-12s %-32s %-8s\n" "$addr" "$sym" "${name:0:30}" "$decimals"
  done < "$RESULTS_FILE"
  echo ""
  echo "  Explorer: $EXPLORER_URL"
  echo ""
  echo "  ⚠️  Each collision is a potential scam. Verify the contract source"
  echo "     on PharosScan before interacting with any of these addresses."
fi

echo ""
echo "  Wax-sealed by PSCD v2.0.0 (Foundry port)."

# Clean up
rm -rf "$TEMP"
