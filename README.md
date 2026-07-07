# Pharos Symbol Collision Detector (PSCD)

> Two surfaces, one Skill. Scans Pharos for ERC-20 symbol collisions and
> lets developers file refundable on-chain claims before they launch.

[![foundry](https://img.shields.io/badge/built%20with-Foundry-orange)]()
[![solidity](https://img.shields.io/badge/contract-Solidity%200.8.24-blue)]()
[![license](https://img.shields.io/badge/license-MIT-green)]()
[![pharos](https://img.shields.io/badge/network-Pharos%20mainnet%20%2B%20testnet-blueviolet)]()
[![ai-agent](https://img.shields.io/badge/callable%20by-AI%20agent-purple)]()

## What is this?

PSCD is a Pharos Skill designed to be packaged as a **Service Agent** on
[Anvita Flow](https://flow.anvita.xyz). It protects ERC-20 token developers
from launching with a symbol that's already taken, by combining:

1. **Off-chain scanner** — walks Pharos Pacific mainnet via `cast`,
   finds ERC-20 mints via Transfer-from-zero events, and reports which
   tokens share a candidate symbol. Read-only, no funds at risk.
2. **On-chain registry** — a `SymbolRegistry` Solidity contract (same source
   deployed to both Pacific mainnet and Atlantic testnet) that lets a
   developer file a refundable PHRS/PROS deposit claim. Anyone can query
   active claims; the original claimer can release and get the deposit back.

Together they cover both **reality** (existing ERC-20s) and **intent**
(filed claims).

## Architecture

```
                   ┌─────────────────────────────────────────┐
                   │       PSCD Service Agent                │
                   │       (Anvita Flow hosted)              │
                   └────────────────────┬────────────────────┘
                                        │
              ┌─────────────────────────┴─────────────────────────┐
              │                                                    │
              ▼                                                    ▼
   ┌────────────────────────┐                      ┌──────────────────────────────┐
   │ Off-chain scanner      │                      │ On-chain SymbolRegistry      │
   │ scripts/check.sh       │                      │ SymbolRegistry.sol           │
   │ (read-only, cast RPC)  │                      │ + scripts/register_*.sh     │
   └──────────┬─────────────┘                      └──────────┬───────────────────┘
              │                                                │
              ▼                                                ▼
      Pharos Pacific Mainnet                          Pharos Pacific Mainnet
      chain 1672, RPC:                                + Pharos Atlantic Testnet
      https://rpc.pharos.xyz                          chain 688689, RPC:
                                                      https://atlantic.dplabs-internal.com
```

## Quick start (30 seconds, no API keys)

```bash
git clone https://github.com/ruzkypazzy/Pharos-Symbol-Collision-Detector-PSCD-.git
cd Pharos-Symbol-Collision-Detector-PSCD-

# Install Foundry if you don't have it
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Run the off-chain scanner demo (no deploy, no key needed)
bash scripts/check.sh --demo
```

## Full installation

```bash
git clone https://github.com/ruzkypazzy/Pharos-Symbol-Collision-Detector-PSCD-.git
cd Pharos-Symbol-Collision-Detector-PSCD-
chmod +x scripts/*.sh

# 1. Foundry (mandatory)
curl -L https://foundry.paradigm.xyz | bash && foundryup

# 2. python3 (standard library only)
python3 --version   # 3.10+ recommended

# 3. jq (optional, for pretty JSON)
# macOS:   brew install jq
# Ubuntu:  sudo apt-get install -y jq

# 4. Set up your wallet (only needed for on-chain ops)
export PRIVATE_KEY=0xYourPrivateKeyHere
export DEPLOYER=$(cast wallet address --private-key $PRIVATE_KEY)
```

## Deploy the on-chain registry

```bash
# Deploy to Atlantic testnet first (free PHRS)
bash scripts/deploy_registry.sh --network testnet

# Or deploy to Pacific mainnet (costs ~0.05 PROS)
bash scripts/deploy_registry.sh --network mainnet

# The script writes the address back to assets/networks.json
# Verify on PharosScan after ~10 seconds
```

## Usage examples

### Off-chain scanner

```bash
# Check if 'USDC' is taken (last 5K blocks, ~5s)
bash scripts/check.sh USDC --max-blocks 5000

# Wider scan, full JSON output
bash scripts/check.sh SKP --max-blocks 100000 --format json

# Custom block range
bash scripts/check.sh SKP --from-block 9000000 --to-block 9050000

# Run the demo (USDC, last 5K blocks, markdown)
bash scripts/check.sh --demo
```

### On-chain registry

```bash
# Check if 'SKP' is already claimed
bash scripts/query_registry.sh SKP --network mainnet

# File your own claim (deposit 0.001 PROS, refundable)
bash scripts/register_symbol.sh SKP --network mainnet \
  --project-uri "https://skp.example"

# Audit recent claims
bash scripts/registry_history.sh --network mainnet \
  --from-block 11000000 --to-block 11500000

# Release your claim and refund the deposit
bash scripts/release_symbol.sh SKP --network mainnet
```

### Combined safety check (the recommended pattern)

Before launching an ERC-20, run BOTH surfaces:

```bash
SYMBOL=USDC-PROJ

# 1. Off-chain: is it already used?
bash scripts/check.sh $SYMBOL --max-blocks 100000 --format json

# 2. On-chain: has anyone filed a claim?
bash scripts/query_registry.sh $SYMBOL --network mainnet

# 3. (If both clear) Lock in your intent
bash scripts/register_symbol.sh $SYMBOL --network mainnet \
  --project-uri "https://myproject.example"
```

## As an AI agent (Service Agent on Anvita Flow)

This Skill is designed to be hosted on [Anvita Flow](https://flow.anvita.xyz)
as a Service Agent. The Steward Agent in Anvita On discovers PSCD via its
`SKILL.md` Capability Index and invokes it like any other Service Agent.

Example invocation from a Steward Agent:

```
User: "Is USDC safe to use on Pharos?"
Steward Agent: invokes "Pharos Symbol Collision Detector" Service Agent
  -> runs check.sh USDC --max-blocks 100000
  -> runs query_registry.sh USDC --network mainnet
Agent: "USDC is COLLISION on Pharos mainnet. There's an existing ERC-20
  at 0xc879c018db60520f4355c26ed1a6d572cdac1815 using this symbol.
  Choose a different ticker (e.g. USDC-PROJ, USDC2) before launching."
```

See `SKILL.md` for the Capability Index and `references/` for the structured
operation docs.

## Scripts

| Script | Purpose | Network | Needs key? |
|---|---|---|---|
| `check.sh` | Off-chain ERC-20 collision scanner | mainnet (default), testnet | No |
| `deploy_registry.sh` | One-time: deploy SymbolRegistry contract | mainnet OR testnet | Yes |
| `query_registry.sh` | Look up an on-chain claim | mainnet OR testnet | No |
| `register_symbol.sh` | File a refundable claim | mainnet OR testnet | Yes |
| `release_symbol.sh` | Cancel a claim, refund deposit | mainnet OR testnet | Yes |
| `registry_history.sh` | Audit all claims in a block range | mainnet OR testnet | No |

## Networks

| Network | Chain ID | RPC | Default for | Deploy registry? |
|---|---:|---|---|---|
| Pacific mainnet | 1672 | `https://rpc.pharos.xyz` | Off-chain scanner | Yes |
| Atlantic testnet | 688689 | `https://atlantic.dplabs-internal.com` | Testing | Yes (free) |

The same SymbolRegistry contract source compiles to a single bytecode and is
deployed independently to each network. Addresses are stored under
`networks[].contracts.SymbolRegistry` in `assets/networks.json`.

## Tests

### Smart contract (forge)

```bash
forge build       # compile
forge test        # 14 unit tests
```

### Bash scripts (offline smoke)

```bash
bash tests/test_check_smoke.sh
```

Tests cover: `--help` works, missing args rejected, bad network rejected,
invalid numeric flags rejected, reversed block ranges rejected, missing
cast error is clear.

## License

MIT — see `LICENSE`.

<!-- cache-refresh -->
