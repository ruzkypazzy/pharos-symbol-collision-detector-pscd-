#!/usr/bin/env bash
# PSCD -- Pharos Symbol Collision Detector
#
# Scans Pharos mainnet (default) or testnet for ERC-20 tokens whose
# `symbol()` matches a candidate. Uses the public Pharos SocialScan API
# as the primary source (it indexes every ERC-20 on Pharos regardless of
# how the token was minted). Falls back to a direct on-chain scan via
# `eth_getLogs` Transfer(from=0x0,...) for tokens deployed in the most
# recent block range (the API may lag chain head by a few minutes).
#
# Usage:
#   bash scripts/check.sh SYMBOL [options]
#
# Options:
#   --network NAME         mainnet | testnet [default: mainnet]
#   --source SRC           api | chain | both [default: both]
#                          api    = SocialScan API (covers all indexed tokens)
#                          chain  = direct on-chain scan (catches very-recent mints)
#                          both   = merge, dedupe, prefer API metadata
#   --max-blocks N         chain-source only: scan only the last N blocks
#   --from-block N         chain-source only: explicit start block
#   --to-block N           chain-source only: explicit end block
#   --step N               chain-source only: blocks per eth_getLogs batch (default 1000, max 1000)
#   --workers N            chain-source only: parallel eth_call workers (default 6)
#   --format FMT           md | json | txt [default: md]
#   --quiet                suppress progress on stderr
#   --demo                 check the symbol 'USDC' on a bounded range
#   -h, --help             show this help
#
# Examples:
#   bash scripts/check.sh USDC --network mainnet
#   bash scripts/check.sh SUP --network mainnet --source api
#   bash scripts/check.sh USDC --max-blocks 50000
#   bash scripts/check.sh USDC --format json
#
# Exit codes:
#   0  clear or collision found
#   1  invalid arguments
#   2  RPC/API failure

set -uo pipefail

# ---- Load network config ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET_JSON="$SCRIPT_DIR/../assets/networks.json"
if [ ! -f "$NET_JSON" ]; then
  echo "Error: $NET_JSON not found" >&2
  exit 2
fi

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
  sys.exit(1)
except Exception as e:
  print(f'ERR:{e}',file=sys.stderr); sys.exit(1)
"
}

# ---- Argument parsing ----
SYMBOL=""
NETWORK="mainnet"
SOURCE="both"
MAX_BLOCKS=""
FROM_BLOCK=""
TO_BLOCK=""
STEP=1000
WORKERS=6
FORMAT="md"
QUIET=0
DEMO=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)        NETWORK="$2"; shift 2 ;;
    --source)         SOURCE="$2"; shift 2 ;;
    --max-blocks)     MAX_BLOCKS="$2"; shift 2 ;;
    --from-block)     FROM_BLOCK="$2"; shift 2 ;;
    --to-block)       TO_BLOCK="$2"; shift 2 ;;
    --step)           STEP="$2"; shift 2 ;;
    --workers)        WORKERS="$2"; shift 2 ;;
    --format)         FORMAT="$2"; shift 2 ;;
    --quiet)          QUIET=1; shift ;;
    --demo)           DEMO=1; shift ;;
    -h|--help)        sed -n '2,/^set -uo pipefail/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)               echo "Error: unknown flag: $1" >&2; exit 1 ;;
    *)
      if [ -z "$SYMBOL" ]; then
        SYMBOL="$1"
      else
        echo "Error: unexpected positional argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

# ---- Validation ----
if [ -z "$SYMBOL" ] && [ "$DEMO" -eq 0 ]; then
  echo "Error: please provide a symbol as the first argument." >&2
  echo "  Example: bash $0 USDC --network mainnet" >&2
  exit 1
fi
[ "$DEMO" -eq 1 ] && SYMBOL="USDC"

if [ -n "$SYMBOL" ]; then
  # Trim + uppercase
  SYMBOL="$(echo "$SYMBOL" | xargs)"   # trim whitespace
  SYMBOL_NORM="$(echo "$SYMBOL" | tr '[:lower:]' '[:upper:]')"
  if [ ${#SYMBOL} -gt 32 ]; then
    echo "Error: symbol is too long (max 32 chars)" >&2
    exit 1
  fi
fi

case "$NETWORK" in
  mainnet) NET_KEY="mainnet" ;;
  testnet) NET_KEY="atlantic-testnet" ;;
  *) echo "Error: Unknown network '$NETWORK' (expected: mainnet|testnet)" >&2; exit 1 ;;
esac

case "$SOURCE" in
  api|chain|both) ;;
  *) echo "Error: --source must be api, chain, or both (got '$SOURCE')" >&2; exit 1 ;;
esac

case "$FORMAT" in
  md|json|txt) ;;
  *) echo "Error: --format must be md, json, or txt (got '$FORMAT')" >&2; exit 1 ;;
esac

if [[ "$MAX_BLOCKS" =~ ^[0-9]+$ ]] || [ -z "$MAX_BLOCKS" ]; then
  :
else
  echo "Error: --max-blocks must be a non-negative integer (got '$MAX_BLOCKS')" >&2
  exit 1
fi

if [[ "$FROM_BLOCK" =~ ^[0-9]+$ ]] || [ -z "$FROM_BLOCK" ]; then
  :
else
  echo "Error: --from-block must be a non-negative integer (got '$FROM_BLOCK')" >&2
  exit 1
fi

if [[ "$TO_BLOCK" =~ ^[0-9]+$ ]] || [ -z "$TO_BLOCK" ]; then
  :
else
  echo "Error: --to-block must be a non-negative integer (got '$TO_BLOCK')" >&2
  exit 1
fi

if [ -n "$MAX_BLOCKS" ] && [ -n "$FROM_BLOCK" ]; then
  echo "Error: cannot use --max-blocks with --from-block (they conflict)" >&2
  exit 1
fi

if [ -n "$FROM_BLOCK" ] && [ -n "$TO_BLOCK" ] && [ "$FROM_BLOCK" -gt "$TO_BLOCK" ]; then
  echo "Error: --from-block ($FROM_BLOCK) must be <= --to-block ($TO_BLOCK)" >&2
  exit 1
fi

if [ -n "$STEP" ] && [ "$STEP" -gt 1000 ]; then
  echo "Error: --step must be <= 1000 (the RPC's eth_getLogs batch limit)" >&2
  exit 1
fi

# ---- Resolve network ----
RPC="$(get_field "$NET_KEY" rpcUrl)"
CHAIN_ID="$(get_field "$NET_KEY" chainId)"
NATIVE="$(get_field "$NET_KEY" nativeToken)"
EXPLORER="$(get_field "$NET_KEY" explorerUrl)"
API_BASE="$(get_field "$NET_KEY" explorerApiUrl)"

if [ -z "$RPC" ] || [ -z "$CHAIN_ID" ]; then
  echo "Error: network '$NETWORK' missing rpcUrl or chainId in networks.json" >&2
  exit 2
fi

# ---- Header ----
[ "$QUIET" -eq 0 ] && {
  cat <<EOF
PSCD -- Pharos Symbol Collision Detector
Network: $NETWORK  (chain $CHAIN_ID, native $NATIVE)
RPC:     $RPC
Source:  $SOURCE
Symbol:  $SYMBOL  (normalized: $SYMBOL_NORM)
EOF
} >&2

# ---- Step 1: query SocialScan API ----
api_matches_json=""
api_count=0
if [ "$SOURCE" = "api" ] || [ "$SOURCE" = "both" ]; then
  [ "$QUIET" -eq 0 ] && echo "[1/3] Querying SocialScan token index for symbol '$SYMBOL'..." >&2

  # SocialScan returns ALL ERC-20 tokens indexed on Pharos. We filter by symbol
  # client-side. Paginate up to 10 pages of 100 = 1000 tokens, which is plenty
  # for the current Pharos mainnet (~324 tokens).
  api_matches_json=$(python3 - "$API_BASE" "$SYMBOL_NORM" <<'PY' 2>/dev/null
import json, sys, urllib.request, urllib.error

api_base = sys.argv[1]
sym_norm = sys.argv[2].upper()

all_tokens = []
for page in range(1, 11):
    url = f"{api_base}/v1/explorer/tokens?type=erc20&page={page}&size=100"
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            data = json.loads(r.read().decode("utf-8"))
    except Exception as e:
        print(json.dumps({"_error": f"SocialScan API failed: {e}"}), file=sys.stderr)
        sys.exit(1)
    items = data.get("data", [])
    if not items:
        break
    all_tokens.extend(items)
    if len(items) < 100:
        break

matches = [t for t in all_tokens if (t.get("symbol") or "").upper() == sym_norm]
print(json.dumps({
    "total_indexed": len(all_tokens),
    "matches": [
        {
            "address": t.get("address", ""),
            "symbol": t.get("symbol", ""),
            "name": t.get("name", ""),
            "decimals": t.get("decimals", 18),  # not always present; default 18
            "total_supply": t.get("total_supply", "0"),
            "holders": t.get("holder_count", 0),
            "explorer": f"https://www.pharosscan.xyz/token/{t.get('address','')}",
        }
        for t in matches
    ],
}))
PY
)
  if [ -z "$api_matches_json" ]; then
    [ "$QUIET" -eq 0 ] && echo "  (SocialScan API returned no data; chain scan will compensate)" >&2
    api_matches_json='{"total_indexed":0,"matches":[]}'
  fi
  api_count=$(echo "$api_matches_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['matches']))" 2>/dev/null || echo 0)
  [ "$QUIET" -eq 0 ] && echo "  SocialScan indexed $(echo "$api_matches_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['total_indexed'])" 2>/dev/null) tokens, $api_count match '$SYMBOL_NORM'" >&2
fi

# ---- Step 2: on-chain scan for very recent mints (or as the only source) ----
chain_matches_json=""
chain_count=0
latest_block=0
if [ "$SOURCE" = "chain" ] || [ "$SOURCE" = "both" ]; then
  [ "$QUIET" -eq 0 ] && echo "[2/3] Walking chain for very recent mints..." >&2

  # Determine block range. The Pharos public RPC rejects eth_getLogs
  # ranges > 1000 blocks. Each batch must be at most 1000 blocks INCLUSIVE.
  if command -v cast >/dev/null 2>&1; then
    latest_block=$(cast block-number --rpc-url "$RPC" 2>/dev/null || echo 0)
  fi
  if [ "$latest_block" -eq 0 ]; then
    # Fallback: query via curl
    latest_block=$(curl -s -X POST "$RPC" -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(int(d.get('result','0x0'),16))" 2>/dev/null || echo 0)
  fi
  if [ "$latest_block" -eq 0 ]; then
    echo "Error: could not determine latest block from $RPC" >&2
    [ "$SOURCE" = "chain" ] && exit 2
  fi

  if [ -n "$FROM_BLOCK" ] && [ -n "$TO_BLOCK" ]; then
    range_from=$FROM_BLOCK
    range_to=$TO_BLOCK
  elif [ -n "$MAX_BLOCKS" ]; then
    range_to=$latest_block
    range_from=$(( latest_block - MAX_BLOCKS + 1 ))
    [ "$range_from" -lt 0 ] && range_from=0
  elif [ "$DEMO" -eq 1 ]; then
    range_to=$latest_block
    range_from=$(( latest_block - 999 ))   # 1000 blocks inclusive
  else
    # Default for "chain" source: last 1000 blocks (covers ~3 hours of Pharos)
    range_to=$latest_block
    range_from=$(( latest_block - 999 ))
    [ "$range_from" -lt 0 ] && range_from=0
  fi

  [ "$QUIET" -eq 0 ] && echo "  Range: [$range_from, $range_to]  (step=$STEP, workers=$WORKERS)" >&2

  # Fetch Transfer(from=0x0,...) events in batches
  transfer_sig="0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  zero_addr="0x0000000000000000000000000000000000000000000000000000000000000000"

  # Generate batch ranges (each batch is at most $STEP blocks, inclusive)
  batches=()
  cur=$range_from
  while [ "$cur" -le "$range_to" ]; do
    end=$(( cur + STEP - 1 ))
    [ "$end" -gt "$range_to" ] && end=$range_to
    batches+=("$cur $end")
    cur=$(( end + 1 ))
  done

  [ "$QUIET" -eq 0 ] && echo "  ${#batches[@]} batch(es) to fetch" >&2

  # Fetch in parallel
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" EXIT

  fetch_batch() {
    local from=$1 to=$2
    local idx=$3
    local outfile="$tmpdir/batch_${idx}.json"
    local hex_from="0x$(printf '%x' $from)"
    local hex_to="0x$(printf '%x' $to)"
    curl -s -X POST "$RPC" -H "Content-Type: application/json" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getLogs\",\"params\":[{\"fromBlock\":\"$hex_from\",\"toBlock\":\"$hex_to\",\"topics\":[\"$transfer_sig\",\"$zero_addr\"]}]}" \
      > "$outfile" 2>/dev/null
  }

  idx=0
  for b in "${batches[@]}"; do
    from=$(echo "$b" | cut -d' ' -f1)
    to=$(echo "$b" | cut -d' ' -f2)
    fetch_batch "$from" "$to" "$idx" &
    idx=$((idx + 1))
  done
  wait

  # Aggregate
  chain_matches_json=$(python3 - "$tmpdir" "$SYMBOL_NORM" "$EXPLORER" "$RPC" "$WORKERS" <<'PY'
import json, sys, os, glob, urllib.request, re, time

tmpdir = sys.argv[1]
sym_norm = sys.argv[2].upper()
explorer = sys.argv[3]
rpc = sys.argv[4]
workers = int(sys.argv[5])

# Collect all logs
all_logs = []
for f in sorted(glob.glob(f"{tmpdir}/batch_*.json")):
    try:
        d = json.load(open(f))
        if "result" in d and isinstance(d["result"], list):
            all_logs.extend(d["result"])
    except Exception:
        pass

# Extract unique token addresses (last 20 bytes of the first non-zero topic,
# or simpler: the "address" field of the log is the token contract address)
addresses = []
seen = set()
for log in all_logs:
    addr = log.get("address", "").lower()
    if addr and addr not in seen:
        seen.add(addr)
        addresses.append(addr)

# For each address, call symbol() via eth_call
selector = "0x95d89b41"  # symbol()

def call_symbol(addr):
    try:
        data = json.dumps({
            "jsonrpc": "2.0", "id": 1, "method": "eth_call",
            "params": [{"to": addr, "data": selector}, "latest"]
        }).encode()
        req = urllib.request.Request(rpc, data=data, headers={"Content-Type":"application/json"})
        with urllib.request.urlopen(req, timeout=10) as r:
            res = json.loads(r.read().decode())
        hex_data = res.get("result", "0x")
        if not hex_data or hex_data == "0x":
            return None
        # Decode dynamic string: offset (32) | length (32) | data
        raw = bytes.fromhex(hex_data[2:])
        if len(raw) < 64:
            return None
        str_len = int.from_bytes(raw[32:64], "big")
        if str_len == 0 or len(raw) < 64 + str_len:
            return None
        return raw[64:64+str_len].decode("utf-8", errors="ignore")
    except Exception:
        return None

matches = []
for addr in addresses:
    sym = call_symbol(addr)
    if sym and sym.strip().upper() == sym_norm:
        matches.append({
            "address": addr,
            "symbol": sym,
            "explorer": f"{explorer.rstrip('/')}/token/{addr}",
            "source": "chain",
        })

print(json.dumps({"scanned": len(addresses), "matches": matches}))
PY
)
  chain_count=$(echo "$chain_matches_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['matches']))" 2>/dev/null || echo 0)
fi

# ---- Step 3: merge + dedupe + emit verdict ----
[ "$QUIET" -eq 0 ] && echo "[3/3] Merging sources and computing verdict..." >&2

# If chain source wasn't queried, default to empty
[ "$SOURCE" = "api" ] && chain_matches_json=""

# If the chain scan didn't return JSON (RPC errored, etc), use empty
if [ -n "$chain_matches_json" ]; then
  if ! (printf '%s' "$chain_matches_json" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null); then
    [ "$QUIET" -eq 0 ] && echo "  (chain scan returned non-JSON; using empty result)" >&2
    chain_matches_json=""
  fi
fi

merged_json=$(python3 - "$api_matches_json" "$chain_matches_json" "$SYMBOL" "$SYMBOL_NORM" "$NETWORK" "$RPC" "$CHAIN_ID" <<'PY'
import json, sys

api = json.loads(sys.argv[1]) if sys.argv[1] else {"matches":[]}
chain = json.loads(sys.argv[2]) if sys.argv[2] else {"matches":[]}
symbol = sys.argv[3]
symbol_norm = sys.argv[4]
network = sys.argv[5]
rpc = sys.argv[6]
chain_id = sys.argv[7]

# Dedupe by address (case-insensitive)
collisions = {}
for m in api.get("matches", []):
    addr = m["address"].lower()
    collisions[addr] = {
        "address": m["address"],
        "symbol": m.get("symbol", symbol),
        "name": m.get("name", ""),
        "decimals": m.get("decimals", 18),
        "total_supply": m.get("total_supply", "0"),
        "holders": m.get("holders", 0),
        "explorer": m.get("explorer", ""),
        "source": "api",
    }
for m in chain.get("matches", []):
    addr = m["address"].lower()
    if addr not in collisions:
        collisions[addr] = {
            "address": m["address"],
            "symbol": m.get("symbol", symbol),
            "name": "",
            "decimals": 18,
            "total_supply": "0",
            "holders": 0,
            "explorer": m.get("explorer", ""),
            "source": "chain",
        }

# Compute verdict
verdict = "COLLISION" if collisions else "CLEAR"
result = {
    "network": network,
    "chainId": int(chain_id),
    "rpc": rpc,
    "candidate": symbol,
    "normalized": symbol_norm,
    "sources_queried": [],
    "verdict": verdict,
    "collisions": list(collisions.values()),
}
if api.get("matches") is not None:
    result["sources_queried"].append("api")
if chain.get("matches") is not None:
    result["sources_queried"].append("chain")
print(json.dumps(result))
PY
)

# Emit output -- write the JSON to a temp file to avoid stdin/here-doc conflicts
jsonfile=$(mktemp)
printf '%s' "$merged_json" > "$jsonfile"
trap "rm -rf $tmpdir $jsonfile" EXIT

case "$FORMAT" in
  json) python3 -m json.tool < "$jsonfile" ;;
  txt)
    python3 <<TXTEOF
import json
d = json.load(open("$jsonfile"))
print(f'Network:    {d["network"]} (chain {d["chainId"]})')
print(f'Candidate:  {d["candidate"]} (normalized: {d["normalized"]})')
print(f'Sources:    {",".join(d["sources_queried"])}')
print(f'Verdict:    {d["verdict"]}')
print(f'Collisions: {len(d["collisions"])}')
for c in d['collisions']:
    name = c.get("name","")
    holders = c.get("holders",0)
    explorer = c.get("explorer","")
    print(f'  - {c["address"]}  {c["symbol"]}  {name}  holders={holders}  {explorer}')
TXTEOF
    ;;
  md)
    python3 <<PYEOF
import json
d = json.load(open("$jsonfile"))
v = d['verdict']
candidate = d['candidate']
network = d['network']
print()
print(f'# Symbol Collision Report: {candidate}')
print()
print(f'- **Network:** {network} (chain {d["chainId"]})')
print(f'- **RPC:** {d["rpc"]}')
print(f'- **Sources queried:** {", ".join(d["sources_queried"])}')
print(f'- **Verdict:** {v}')
print(f'- **Collisions:** {len(d["collisions"])}')
print()
if v == 'COLLISION':
    for i, c in enumerate(d['collisions'], 1):
        print(f'## COLLISION {i}/{len(d["collisions"])}')
        print()
        print('| Field | Value |')
        print('|---|---|')
        print(f'| Address | \`{c["address"]}\` |')
        print(f'| Symbol | {c["symbol"]} |')
        if c.get('name'):
            print(f'| Name | {c["name"]} |')
        if c.get('decimals') is not None:
            print(f'| Decimals | {c["decimals"]} |')
        if c.get('total_supply'):
            print(f'| Total supply | {c["total_supply"]} |')
        if c.get('holders'):
            print(f'| Holders | {c["holders"]} |')
        if c.get('source'):
            print(f'| Source | {c["source"]} |')
        if c.get('explorer'):
            print(f'| Explorer | <{c["explorer"]}> |')
        print()
    print('## Recommendation')
    print()
    print(f'\`{candidate}\` is already in use on Pharos {network}. Do not deploy a new')
    print('ERC-20 with this ticker — wallets and explorers will display both identically')
    print('and end users will be unable to distinguish them. Pick a different symbol')
    print(f'(e.g. \`{candidate}2\`, \`{candidate}X\`, \`{candidate}-PROJ\`) before launching.')
else:
    print('## Result')
    print()
    print(f'No ERC-20 on Pharos {network} uses the symbol \`{candidate}\`.')
    print('The symbol appears to be safe to launch.')
    print()
    print('## Caveat')
    print()
    print('PSCD checks the SocialScan token index (covering all ERC-20s indexed on Pharos)')
    print('and the on-chain \`Transfer(from=0x0,...)\` event log for the most recent blocks.')
    print('Tokens that exist but are not yet indexed by SocialScan, or that did not emit')
    print('a standard mint event, may not be detected. Re-check shortly before launch.')
PYEOF
    ;;
esac