# SETUP

This file tells the Anvita Flow runtime how to invoke the PSCD Skill.

## Skill type

**Bash-script Skill** — the runtime must:
1. Mount the `scripts/` directory from the uploaded package into an executable PATH
2. Provide Foundry (`cast`, `forge`) on PATH
3. Provide `python3` (standard library only) on PATH
4. Make `jq` available (optional, only needed for JSON pretty-printing)
5. Make `curl` available (used internally by scripts)

## Runtime requirements

- `bash` 4+
- `cast` (from Foundry) on PATH
- `forge` (from Foundry) on PATH — needed only for one-time deploy scripts
- `python3` (3.10+ recommended, stdlib only)
- `curl`
- `jq` (optional, for `--format json` pretty output)

## Entry points

The Skill exposes **6 bash commands** (all in `scripts/`):

### Read-only commands (no private key required)

1. **Off-chain collision scan** — walks Pharos mainnet/testnet for ERC-20 tokens matching a candidate symbol
   ```bash
   bash scripts/check.sh SYMBOL [--network mainnet|testnet] [--max-blocks N] [--from-block N --to-block N] [--format md|json|txt] [--demo]
   ```
   - `SYMBOL` (positional, required) — candidate token symbol, 1-32 chars
   - Output: structured report (CLEAR / COLLISION verdict + colliding token details)
   - Default range: last 100,000 blocks
   - Default network: mainnet (Pacific, chain 1672)

2. **On-chain registry query** — reads whether a symbol has an active claim
   ```bash
   bash scripts/query_registry.sh SYMBOL --network mainnet|testnet [--format json|txt]
   ```
   - Reads the deployed `SymbolRegistry` contract from `assets/networks.json`
   - Output: full claim record or `claimed: false`

3. **Claim history audit** — reads `SymbolRegistered` events over a block range
   ```bash
   bash scripts/registry_history.sh --network mainnet|testnet [--from-block N --to-block N] [--format json|txt]
   ```
   - Batches eth_getLogs over 1,000-block windows in parallel
   - Decodes SymbolRegistered event ABI to surface symbol/claimer/deposit/timestamp/projectURI

### Write commands (require `$PRIVATE_KEY` env var)

4. **Deploy the registry contract** (one-time per network)
   ```bash
   bash scripts/deploy_registry.sh --network mainnet|testnet [--force]
   ```
   - Requires Foundry's `forge` and `--broadcast`
   - Writes the deployed address back to `assets/networks.json`

5. **Register a symbol claim** (refundable 0.001 native token deposit)
   ```bash
   bash scripts/register_symbol.sh SYMBOL --network mainnet|testnet [--project-uri "..."] [--value 0.001ether]
   ```
   - Requires `PRIVATE_KEY` env var
   - Requires native PHRS (testnet) or PROS (mainnet) for gas + deposit

6. **Release a claim and refund the deposit**
   ```bash
   bash scripts/release_symbol.sh SYMBOL --network mainnet|testnet
   ```
   - Requires `PRIVATE_KEY` env var
   - Refunds the original deposit to the caller

## Environment variables

| Variable | Required for | Notes |
|----------|--------------|-------|
| `PRIVATE_KEY` | All write commands (deploy, register, release) | Foundry does NOT auto-read this — must be passed as `--private-key $PRIVATE_KEY` to every cast command |
| `RPC_URL` | Optional override | If set, overrides the network's default RPC from `assets/networks.json` |

## Network configuration

All network endpoints, chain IDs, and deployed contract addresses are stored in `assets/networks.json`. Scripts read this file at startup — no hardcoded URLs anywhere.

Currently configured:
- **Pacific mainnet** (chain 1672): SymbolRegistry = `0x6A9Eb713a8055d6ee46aD01641021255f62E6190`
- **Atlantic testnet** (chain 688689): SymbolRegistry = (not yet deployed — wallet had insufficient PHRS at deploy time)

To deploy the testnet registry:
```bash
# Get faucet PHRS first, then:
bash scripts/deploy_registry.sh --network testnet
```

## How the runtime should mount this Skill

1. Extract the uploaded zip's top-level folder (`Pharos-Symbol-Collision-Detector-PSCD/`) into a known location
2. Add that folder's `scripts/` subdirectory to PATH
3. Set the working directory to that folder (so `assets/networks.json` is found relative to the scripts)
4. Install Foundry via `curl -L https://foundry.paradigm.xyz | bash && foundryup` if not already present
5. For write operations, the user's `$PRIVATE_KEY` env var must be available to the cast subprocess

## Recommended test invocation (read-only)

```bash
# Quick smoke test — should run in ~5 seconds
bash scripts/check.sh --demo

# Check the on-chain registry for a known claimed symbol
bash scripts/query_registry.sh SKP --network mainnet
```

## Reference docs

- `references/methodology.md` — structured per-operation docs for the off-chain scanner
- `references/registry.md` — structured per-operation docs for the on-chain registry
- `SKILL.md` — Capability Index that maps user intents to bash invocations
- `assets/networks.json` — network + contract configuration
- `assets/contracts/SymbolRegistry.sol` — Solidity source for the on-chain registry