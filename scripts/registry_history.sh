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

FROM_HEX=$(printf '0x%x' "$FROM_BLOCK")
TO_HEX=$(printf '0x%x' "$TO_BLOCK")

# Fetch via direct curl (cast rpc has JSON encoding issues on some RPCs)
RESPONSE=$(curl -sL --max-time 60 -X POST -H "Content-Type: application/json" \
  --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getLogs\",\"params\":[{\"fromBlock\":\"$FROM_HEX\",\"toBlock\":\"$TO_HEX\",\"address\":\"$REGISTRY\",\"topics\":[\"$TOPIC0\"]}],\"id\":1}" \
  "$RPC_URL")

if [ "$FORMAT" = "json" ]; then
  echo "$RESPONSE" | python3 - "$NET_KEY" "$REGISTRY" "$FROM_BLOCK" "$TO_BLOCK" <<'PY'
import json, sys
raw = sys.stdin.read()
net_key, registry, from_block, to_block = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
try:
    body = json.loads(raw)
except json.JSONDecodeError as e:
    print(json.dumps({"error": f"failed to parse RPC response: {e}"}))
    sys.exit(0)
err = body.get("error")
if err:
    print(json.dumps({"error": err}))
    sys.exit(0)
logs = body.get("result", []) or []
def parse_hex_int(x):
    if not x: return 0
    return int(x, 16)
def hex_addr(x):
    # topics/address fields are 32-byte left-padded; strip leading zeros
    return "0x" + x[-40:]
def decode_string(data_hex):
    # ABI-encoded dynamic string: offset(32) | length(32) | bytes(length)
    if not data_hex or data_hex == "0x":
        return ""
    raw = bytes.fromhex(data_hex[2:] if data_hex.startswith("0x") else data_hex)
    if len(raw) < 64:
        return ""
    # Skip offset, read length
    length = int.from_bytes(raw[32:64], "big")
    return raw[64:64+length].decode("utf-8", errors="replace")
out = {
    "network": net_key,
    "registryAddress": registry,
    "fromBlock": from_block,
    "toBlock": to_block,
    "registrations": [],
}
for L in logs:
    topics = L.get("topics", []) or []
    data = L.get("data", "0x") or "0x"
    if len(topics) < 3:
        continue
    symbol_hash = topics[0]
    claimer = hex_addr(topics[2])
    # data layout: string symbol | uint256 deposit | uint64 timestamp | uint64 blockNumber | string projectURI
    # Each fixed element is 32 bytes, strings are dynamic (offset+len+bytes)
    raw = bytes.fromhex(data[2:] if data.startswith("0x") else data)
    # Strings: first 32 bytes = offset (relative to start of data)
    sym_offset = int.from_bytes(raw[0:32], "big")
    # string at sym_offset: length(32) | bytes(length)
    sym_len = int.from_bytes(raw[sym_offset:sym_offset+32], "big")
    sym = raw[sym_offset+32:sym_offset+32+sym_len].decode("utf-8", errors="replace")
    # After symbol string ends, the next fixed elements start. Their offsets are from
    # the start of data, not from sym_offset. The fixed elements are uint256, uint64, uint64, then string (offset).
    # For simplicity, find them by their position assuming the symbol was at sym_offset.
    after_sym = sym_offset + 32 + ((sym_len + 31) // 32) * 32
    deposit = int.from_bytes(raw[after_sym:after_sym+32], "big")
    ts = int.from_bytes(raw[after_sym+32:after_sym+64], "big")
    blk = int.from_bytes(raw[after_sym+64:after_sym+96], "big")
    uri_offset = int.from_bytes(raw[after_sym+96:after_sym+128], "big")
    # URI string is at uri_offset from start of data
    uri_len = int.from_bytes(raw[uri_offset:uri_offset+32], "big")
    uri = raw[uri_offset+32:uri_offset+32+uri_len].decode("utf-8", errors="replace")
    out["registrations"].append({
        "symbolHash": symbol_hash,
        "symbol": sym,
        "claimer": claimer,
        "deposit_wei": str(deposit),
        "timestamp": ts,
        "blockNumber": int(L.get("blockNumber", "0x0"), 16),
        "txHash": L.get("transactionHash", ""),
        "projectURI": uri,
    })
print(json.dumps(out, indent=2, ensure_ascii=False))
PY
else
  echo "Registry history: $NET_KEY  address=$REGISTRY"
  echo "Range: $FROM_BLOCK -> $TO_BLOCK"
  echo ""
  echo "$RESPONSE" | python3 - "$NET_KEY" <<'PY'
import json, sys
raw = sys.stdin.read()
try:
    body = json.loads(raw)
except json.JSONDecodeError:
    print("(failed to parse RPC response)")
    sys.exit(0)
err = body.get("error")
if err:
    print(f"RPC error: {err}")
    sys.exit(0)
logs = body.get("result", []) or []
if not logs:
    print("(no registrations in range)")
    sys.exit(0)
def hex_addr(x):
    return "0x" + x[-40:]
def decode_string(data_hex):
    if not data_hex or data_hex == "0x": return ""
    raw = bytes.fromhex(data_hex[2:] if data_hex.startswith("0x") else data_hex)
    if len(raw) < 64: return ""
    length = int.from_bytes(raw[32:64], "big")
    return raw[64:64+length].decode("utf-8", errors="replace")
print(f"{'BLOCK':>10}  {'SYMBOL':<12}  {'CLAIMER':<44}  PROJECT_URI")
for L in logs:
    topics = L.get("topics", []) or []
    data = L.get("data", "0x") or "0x"
    if len(topics) < 3: continue
    claimer = hex_addr(topics[2])
    raw = bytes.fromhex(data[2:] if data.startswith("0x") else data)
    sym_offset = int.from_bytes(raw[0:32], "big")
    sym_len = int.from_bytes(raw[sym_offset:sym_offset+32], "big")
    sym = raw[sym_offset+32:sym_offset+32+sym_len].decode("utf-8", errors="replace")
    after_sym = sym_offset + 32 + ((sym_len + 31) // 32) * 32
    uri_offset = int.from_bytes(raw[after_sym+96:after_sym+128], "big")
    uri_len = int.from_bytes(raw[uri_offset:uri_offset+32], "big")
    uri = raw[uri_offset+32:uri_offset+32+uri_len].decode("utf-8", errors="replace")
    block = int(L.get("blockNumber", "0x0"), 16)
    print(f"{block:>10}  {sym:<12}  {claimer:<44}  {uri}")
PY
fi

exit 0