#!/usr/bin/env bash
# register_symbol.sh -- File a refundable PHRS/PROS deposit claim on SymbolRegistry.
#
# Usage:
#   bash scripts/register_symbol.sh SYMBOL [--network mainnet|testnet]
#                                          [--project-uri "..."]
#                                          [--value 0.001ether]
#                                          [--rpc-url ...] [--private-key ...]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET_JSON="$SCRIPT_DIR/../assets/networks.json"

NETWORK=""
PROJECT_URI=""
VALUE="0.001ether"
RPC_URL_OVERRIDE=""
PRIVATE_KEY="${PRIVATE_KEY:-}"
SYMBOL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) NETWORK="$2"; shift 2 ;;
    --project-uri) PROJECT_URI="$2"; shift 2 ;;
    --value) VALUE="$2"; shift 2 ;;
    --rpc-url) RPC_URL_OVERRIDE="$2"; shift 2 ;;
    --private-key) PRIVATE_KEY="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo pipefail/p' "$0" | sed 's/^# \{0,1\}//' | head -25; exit 0 ;;
    -*) echo "register_symbol: unknown flag: $1" >&2; exit 2 ;;
    *) SYMBOL="$1"; shift ;;
  esac
done

if [ -z "$SYMBOL" ]; then
  echo "register_symbol: SYMBOL argument is required (e.g. SKP, USDC)" >&2
  exit 2
fi

if [ -z "$NETWORK" ]; then
  echo "register_symbol: --network required (mainnet|testnet)" >&2
  exit 2
fi

case "$NETWORK" in
  mainnet) NET_KEY="mainnet" ;;
  testnet) NET_KEY="atlantic-testnet" ;;
  *) echo "register_symbol: unknown network '$NETWORK' (expected: mainnet|testnet)" >&2; exit 2 ;;
esac

if [ -z "$PRIVATE_KEY" ]; then
  echo "register_symbol: \$PRIVATE_KEY env var is required" >&2
  exit 2
fi

if ! command -v cast >/dev/null 2>&1; then
  echo "Error: 'cast' not found. Install Foundry:" >&2
  echo "  curl -L https://foundry.paradigm.xyz | bash && foundryup" >&2
  exit 1
fi

# Read network fields
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

if [ -z "$RPC_URL" ]; then
  echo "register_symbol: could not read rpcUrl for '$NET_KEY'" >&2
  exit 1
fi

if [ -z "$REGISTRY" ]; then
  echo "register_symbol: SymbolRegistry not configured for '$NET_KEY'." >&2
  echo "  Run: bash scripts/deploy_registry.sh --network $NETWORK" >&2
  exit 1
fi

DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY" 2>/dev/null)
if [ -z "$DEPLOYER" ]; then
  echo "register_symbol: could not derive address from \$PRIVATE_KEY" >&2
  exit 1
fi

BAL=$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL" --ether 2>/dev/null | tr -d ' ')

echo ""
echo "==> Registering symbol claim"
echo "    Network:       $NET_KEY"
echo "    Symbol:        $SYMBOL"
echo "    Registry:      $REGISTRY"
echo "    Sender:        $DEPLOYER"
echo "    Balance:       $BAL"
echo "    Deposit value: $VALUE"
echo "    Project URI:   ${PROJECT_URI:-<none>}"
echo ""

# Build cast send command
# register(string calldata symbol, string calldata projectURI) payable returns (bytes32)
SEND_OUT=$(cast send "$REGISTRY" \
  "register(string,string)" \
  "$SYMBOL" \
  "$PROJECT_URI" \
  --value "$VALUE" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --json 2>&1)
SEND_EXIT=$?

if [ $SEND_EXIT -ne 0 ]; then
  echo "register_symbol: cast send failed:" >&2
  echo "$SEND_OUT" >&2
  exit 1
fi

TX_HASH=$(echo "$SEND_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('transactionHash',''))" 2>/dev/null)
STATUS=$(echo "$SEND_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
BLOCK=$(echo "$SEND_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('blockNumber',''))" 2>/dev/null)

if [ "$STATUS" != "0x1" ] && [ "$STATUS" != "1" ]; then
  echo "register_symbol: tx reverted (status=$STATUS)" >&2
  echo "$SEND_OUT" >&2
  exit 1
fi

# Compute the claim hash on the client side for display
NORM_SYMBOL=$(echo "$SYMBOL" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
NORM_UPPER=$(echo "$NORM_SYMBOL" | tr '[:lower:]' '[:upper:]')
CLAIM_HASH=$(cast keccak "$NORM_UPPER" 2>/dev/null || echo "")

echo "==> Registered!"
echo "    Tx:            $TX_HASH"
echo "    Block:         $BLOCK"
echo "    Claim hash:    $CLAIM_HASH"
echo "    Explorer:      $EXPLORER_URL/tx/$TX_HASH"
echo ""
echo "Your deposit is refundable any time via:"
echo "    bash scripts/release_symbol.sh '$SYMBOL' --network $NETWORK"

exit 0