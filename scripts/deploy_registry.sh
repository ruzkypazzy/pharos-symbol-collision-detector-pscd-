#!/usr/bin/env bash
# deploy_registry.sh -- Deploy SymbolRegistry to a Pharos network.
#
# Usage:
#   bash scripts/deploy_registry.sh --network mainnet|testnet [--force]
#
# After deployment, writes the resulting address into assets/networks.json.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET_JSON="$SCRIPT_DIR/../assets/networks.json"
CONTRACT_SRC="$SCRIPT_DIR/../assets/contracts/SymbolRegistry.sol"

NETWORK=""
FORCE=0
RPC_URL_OVERRIDE=""
PRIVATE_KEY="${PRIVATE_KEY:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) NETWORK="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --rpc-url) RPC_URL_OVERRIDE="$2"; shift 2 ;;
    --private-key) PRIVATE_KEY="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo pipefail/p' "$0" | sed 's/^# \{0,1\}//' | head -20; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$NETWORK" ]; then
  echo "deploy_registry: --network required (mainnet|testnet)" >&2
  exit 2
fi

case "$NETWORK" in
  mainnet) NET_KEY="mainnet" ;;
  testnet) NET_KEY="atlantic-testnet" ;;
  *) echo "deploy_registry: unknown network '$NETWORK' (expected: mainnet|testnet)" >&2; exit 2 ;;
esac

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
CHAIN_ID=$(read_field chainId)
NATIVE_TOKEN=$(read_field nativeToken)
EXISTING_REGISTRY=$(python3 -c "
import json
d=json.load(open('$NET_JSON'))
for n in d['networks']:
  if n['name']=='$NET_KEY':
    print(n.get('contracts',{}).get('SymbolRegistry',''))
    break
")

if [ -n "$EXISTING_REGISTRY" ] && [ "$FORCE" -eq 0 ]; then
  echo "deploy_registry: SymbolRegistry already configured for '$NET_KEY':"
  echo "  $EXISTING_REGISTRY"
  echo "Pass --force to redeploy."
  exit 0
fi

if ! command -v forge >/dev/null 2>&1; then
  echo "Error: 'forge' not found. Install Foundry:" >&2
  echo "  curl -L https://foundry.paradigm.xyz | bash && foundryup" >&2
  exit 1
fi

if [ -z "$PRIVATE_KEY" ]; then
  echo "deploy_registry: \$PRIVATE_KEY env var is required" >&2
  exit 2
fi

DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY" 2>/dev/null)
if [ -z "$DEPLOYER" ]; then
  echo "deploy_registry: could not derive address from \$PRIVATE_KEY" >&2
  exit 1
fi

BAL=$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL" --ether 2>/dev/null | tr -d ' ')
echo ""
echo "==> Deploying SymbolRegistry to $NET_KEY (chain $CHAIN_ID)"
echo "    RPC:           $RPC_URL"
echo "    Deployer:      $DEPLOYER"
echo "    Balance:       $BAL $NATIVE_TOKEN"
echo ""

# Deploy via forge create (single-file contract, no constructor args)
# Use --broadcast to actually send the tx, and capture both the receipt JSON and stdout
DEPLOY_OUT=$(forge create "$CONTRACT_SRC:SymbolRegistry" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast 2>&1)
DEPLOY_EXIT=$?

# forge create prints "Deployer: ...\nDeployed to: 0x...\nTransaction hash: 0x..." to stdout
# when --broadcast is used (without --json). Use that output.

if [ $DEPLOY_EXIT -ne 0 ]; then
  echo "deploy_registry: forge create failed:" >&2
  echo "$DEPLOY_OUT" >&2
  exit 1
fi

DEPLOYED_TO=$(echo "$DEPLOY_OUT" | grep -oE "Deployed to:[[:space:]]*0x[a-fA-F0-9]{40}" | head -1 | sed 's/.*[[:space:]]//')
TX_HASH=$(echo "$DEPLOY_OUT" | grep -oE "Transaction hash:[[:space:]]*0x[a-fA-F0-9]{64}" | head -1 | sed 's/.*[[:space:]]//')

if [ -z "$DEPLOYED_TO" ]; then
  echo "deploy_registry: could not parse deployedTo from forge output:" >&2
  echo "$DEPLOY_OUT" >&2
  exit 1
fi

echo "==> Deployed!"
echo "    Address:       $DEPLOYED_TO"
echo "    Tx:            $TX_HASH"
echo "    Explorer:      $EXPLORER_URL/address/$DEPLOYED_TO"
echo ""

# Write back into networks.json
python3 - "$NET_KEY" "$DEPLOYED_TO" "$NET_JSON" <<'PY'
import json, sys
net_key, addr, net_json = sys.argv[1], sys.argv[2], sys.argv[3]
with open(net_json) as f:
    d = json.load(f)
for n in d["networks"]:
    if n["name"] == net_key:
        n.setdefault("contracts", {})["SymbolRegistry"] = addr
        break
with open(net_json, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PY

echo "==> Updated $NET_JSON with contracts.SymbolRegistry = $DEPLOYED_TO"
echo ""
echo "Next steps:"
echo "  1. Verify on PharosScan: $EXPLORER_URL/address/$DEPLOYED_TO"
echo "  2. Wait ~10 seconds for the indexer to pick up the source."
echo "  3. Register a claim: bash scripts/register_symbol.sh SKP --network $NETWORK"

exit 0