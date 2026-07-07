#!/usr/bin/env bash
# release_symbol.sh -- Release a symbol claim and refund the deposit.
#
# Usage:
#   bash scripts/release_symbol.sh SYMBOL [--network mainnet|testnet]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET_JSON="$SCRIPT_DIR/../assets/networks.json"

NETWORK=""
RPC_URL_OVERRIDE=""
PRIVATE_KEY="${PRIVATE_KEY:-}"
SYMBOL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) NETWORK="$2"; shift 2 ;;
    --rpc-url) RPC_URL_OVERRIDE="$2"; shift 2 ;;
    --private-key) PRIVATE_KEY="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo pipefail/p' "$0" | sed 's/^# \{0,1\}//' | head -15; exit 0 ;;
    -*) echo "release_symbol: unknown flag: $1" >&2; exit 2 ;;
    *) SYMBOL="$1"; shift ;;
  esac
done

if [ -z "$SYMBOL" ]; then
  echo "release_symbol: SYMBOL argument is required" >&2
  exit 2
fi

if [ -z "$NETWORK" ]; then
  echo "release_symbol: --network required (mainnet|testnet)" >&2
  exit 2
fi

case "$NETWORK" in
  mainnet) NET_KEY="mainnet" ;;
  testnet) NET_KEY="atlantic-testnet" ;;
  *) echo "release_symbol: unknown network '$NETWORK'" >&2; exit 2 ;;
esac

if [ -z "$PRIVATE_KEY" ]; then
  echo "release_symbol: \$PRIVATE_KEY env var is required" >&2
  exit 2
fi

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
  echo "release_symbol: SymbolRegistry not configured for '$NET_KEY'." >&2
  echo "  Run: bash scripts/deploy_registry.sh --network $NETWORK" >&2
  exit 1
fi

DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY" 2>/dev/null)
if [ -z "$DEPLOYER" ]; then
  echo "release_symbol: could not derive address from \$PRIVATE_KEY" >&2
  exit 1
fi

echo ""
echo "==> Releasing symbol claim"
echo "    Network:  $NET_KEY"
echo "    Symbol:   $SYMBOL"
echo "    Registry: $REGISTRY"
echo "    Sender:   $DEPLOYER"
echo ""

SEND_OUT=$(cast send "$REGISTRY" \
  "release(string)" \
  "$SYMBOL" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --json 2>&1)
SEND_EXIT=$?

if [ $SEND_EXIT -ne 0 ]; then
  echo "release_symbol: cast send failed:" >&2
  echo "$SEND_OUT" >&2
  exit 1
fi

TX_HASH=$(echo "$SEND_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('transactionHash',''))" 2>/dev/null)
STATUS=$(echo "$SEND_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)

if [ "$STATUS" != "0x1" ] && [ "$STATUS" != "1" ]; then
  echo "release_symbol: tx reverted (status=$STATUS)" >&2
  echo "$SEND_OUT" >&2
  exit 1
fi

echo "==> Released!"
echo "    Tx:        $TX_HASH"
echo "    Explorer:  $EXPLORER_URL/tx/$TX_HASH"
echo ""
echo "The deposit has been refunded to $DEPLOYER."

exit 0