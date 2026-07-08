#!/usr/bin/env bash
# registry_history.sh -- Read SymbolRegistered events from SymbolRegistry.
#
# Usage:
#   bash scripts/registry_history.sh --network mainnet|testnet
#                                    [--from-block N] [--to-block N]
#                                    [--format json|txt]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET_JSON="$SCRIPT_DIR/../assets/networks.json"

NETWORK=""
FROM_BLOCK=""
TO_BLOCK=""
FORMAT="json"
RPC_URL_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) NETWORK="$2"; shift 2 ;;
    --from-block) FROM_BLOCK="$2"; shift 2 ;;
    --to-block) TO_BLOCK="$2"; shift 2 ;;
    --rpc-url) RPC_URL_OVERRIDE="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo pipefail/p' "$0" | sed 's/^# \{0,1\}//' | head -20; exit 0 ;;
    -*) echo "registry_history: unknown flag: $1" >&2; exit 2 ;;
    *) echo "registry_history: unexpected positional: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$NETWORK" ]; then
  echo "registry_history: --network required" >&2
  exit 2
fi

case "$NETWORK" in
  mainnet) NET_KEY="mainnet" ;;
  testnet) NET_KEY="atlantic-testnet" ;;
  *) echo "registry_history: unknown network '$NETWORK'" >&2; exit 2 ;;
esac

case "$FORMAT" in
  json|txt) ;;
  *) echo "registry_history: --format must be json or txt" >&2; exit 2 ;;
esac

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
REGISTRY=$(python3 -c "
import json
d=json.load(open('$NET_JSON'))
for n in d['networks']:
  if n['name']=='$NET_KEY':
    print(n.get('contracts',{}).get('SymbolRegistry',''))
    break
")

if [ -z "$REGISTRY" ]; then
  echo "registry_history: SymbolRegistry not configured for '$NET_KEY'." >&2
  echo "  Run: bash scripts/deploy_registry.sh --network $NETWORK" >&2
  exit 1
fi

# Default range: last 100,000 blocks
HEAD_HEX=$(curl -sL -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  "$RPC_URL" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',''))")
HEAD_DEC=$(cast --to-dec "$HEAD_HEX" 2>/dev/null | tr -d '\n')

if [ -z "$TO_BLOCK" ]; then
  TO_BLOCK="$HEAD_DEC"
fi
if [ -z "$FROM_BLOCK" ]; then
  FROM_BLOCK=$(( HEAD_DEC - 100000 ))
  [ "$FROM_BLOCK" -lt 0 ] && FROM_BLOCK=0
fi

# SymbolRegistered(bytes32 indexed symbolHash, string symbol, address indexed claimer, uint256 deposit, uint64 timestamp, uint64 blockNumber, string projectURI)
# topic0 = keccak("SymbolRegistered(bytes32,string,address,uint256,uint64,uint64,string)")
TOPIC0=$(cast keccak "SymbolRegistered(bytes32,string,address,uint256,uint64,uint64,string)" 2>/dev/null)
ADDRESS_TOPIC="0x000000000000000000000000${REGISTRY:2}"

# Pharos public RPC limits eth_getLogs to 1000 blocks per call — batch over the range
TEMP=$(mktemp -d)
ALL_LOGS_FILE="$TEMP/all_logs.json"
echo "[]" > "$ALL_LOGS_FILE"
CURRENT="$FROM_BLOCK"
BATCH_COUNT=0
BATCH_LIST=""
while [ "$CURRENT" -le "$TO_BLOCK" ]; do
  END=$(( CURRENT + 999 ))
  [ "$END" -gt "$TO_BLOCK" ] && END="$TO_BLOCK"
  BATCH_LIST="$BATCH_LIST $CURRENT $END"
  CURRENT=$(( END + 1 ))
  BATCH_COUNT=$(( BATCH_COUNT + 1 ))
done

# Fetch all batches in parallel via xargs.
# xargs spawns a NEW bash, so we inline the curl call into the bash -c body.
PREFIXED=""
i=0
batch_arr=($BATCH_LIST)
while [ $i -lt ${#batch_arr[@]} ]; do
  PREFIXED="$PREFIXED $REGISTRY $TOPIC0 $RPC_URL ${batch_arr[$i]} ${batch_arr[$((i+1))]}"
  i=$((i+2))
done
echo "$PREFIXED" | xargs -n 5 -P 4 bash -c '
  REGISTRY="$1"; TOPIC0="$2"; RPC_URL="$3"; START="$4"; END="$5"
  FROM_HEX=$(printf "0x%x" "$START")
  END_HEX=$(printf "0x%x" "$END")
  RESP=$(curl -sL --max-time 15 -X POST -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getLogs\",\"params\":[{\"fromBlock\":\"$FROM_HEX\",\"toBlock\":\"$END_HEX\",\"address\":\"$REGISTRY\",\"topics\":[\"$TOPIC0\"]}],\"id\":1}" \
    "$RPC_URL" 2>/dev/null)
  if [ -n "$RESP" ] && echo "$RESP" | grep -q "\"result\""; then
    echo "$RESP"
  else
    # Emit empty array so this batch contributes zero logs (silent fail)
    echo "{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":[]}"
  fi
' _ > "$TEMP/all_raw.jsonl" 2>/dev/null

# Convert JSONL to combined JSON array
python3 - "$TEMP/all_raw.jsonl" "$ALL_LOGS_FILE" <<'PY' 2>/dev/null
import json, sys
src, dst = sys.argv[1], sys.argv[2]
all_logs = []
try:
    with open(src) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                body = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(body, dict): continue
            err = body.get("error")
            if err: continue
            logs = body.get("result", [])
            if isinstance(logs, list):
                all_logs.extend(logs)
except FileNotFoundError:
    pass
with open(dst, "w") as f:
    json.dump(all_logs, f)
PY

# Call the dedicated python parser helper
RESPONSE_FILE="$TEMP/response.json"
cat "$ALL_LOGS_FILE" > "$RESPONSE_FILE"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/_registry_history_parse.py" "$RESPONSE_FILE" "$FORMAT" "$NET_KEY" "$REGISTRY" "$FROM_BLOCK" "$TO_BLOCK"

# Cleanup
rm -rf "$TEMP"
exit 0