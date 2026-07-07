---
name: Pharos-Symbol-Collision-Detector-PSCD-
description: |
  Use this skill when a developer asks whether a candidate token symbol is
  safe to launch on Pharos. PSCD combines two surfaces: (1) it scans Pharos
  Pacific mainnet via Foundry/cast for ERC-20 mints that already use the
  symbol, and (2) it queries / writes to a deployed SymbolRegistry contract
  (same source, deployed to mainnet AND testnet) for refundable on-chain
  claims. Use it whenever the user mentions "symbol", "ticker", "token
  collision", "is X taken on Pharos", "register a symbol on-chain", or wants
  to launch a new ERC-20 on Pharos and verify uniqueness first.
version: 3.0.0
author: ruzkypazzy
requires: read, write
bins: [bash, cast, forge, python3, jq, curl]
network: pharos
tags: [pharos, security, erc20, tokens, symbol, collision, scam-detection, mainnet, testnet, foundry, registry, on-chain]
agents: [claude, codex, cursor, gemini, openclaw]
---

# Pharos Symbol Collision Detector (PSCD)

## When to use

Use this skill when the user:

- Asks "is `SYMBOL` taken on Pharos?" / "is `USDC` already used on Pharos?"
- Wants to verify a token symbol is unique before mainnet launch
- Says "scan Pharos for token `SYMBOL` collisions"
- Wants to **file an on-chain claim** for a symbol on Pharos (refundable PHRS/PROS deposit)
- Wants to **check if a symbol is already claimed on-chain**
- Wants to **release** their own claim and recover the deposit
- Says "register my token symbol on Pharos"
- Asks for a security check before deploying a new ERC-20

Do NOT use this skill for ERC-721 / ERC-1155 collections (only ERC-20 is covered), or for off-chain impersonator checks (Twitter, websites).

## What it does

PSCD combines two complementary surfaces behind one Skill:

| Surface | Type | Network | What it answers |
|---|---|---|---|
| **Off-chain scanner** (`scripts/check.sh`) | Read-only | Pharos Pacific mainnet (1672) — default; also works on Atlantic testnet | "Does an ERC-20 token ALREADY use my candidate symbol?" |
| **On-chain registry** (`SymbolRegistry.sol` + `scripts/registry_*.sh`) | Read + write | Deployed to both mainnet AND testnet | "Has anyone filed an explicit on-chain claim for my candidate symbol?" AND "Let me register mine." |

The off-chain scanner discovers tokens that already exist on-chain (deployed
ERC-20s). The on-chain registry records developer intent and provides a
verifiable timestamp. Together they cover both **reality** (existing
contracts) and **intent** (filed claims).

## How to use

### Quick test (no API keys, no deploy)

```bash
# Off-chain scan only — checks if USDC is already used as an ERC-20 symbol
bash scripts/check.sh --demo

# Format options
bash scripts/check.sh SKP --max-blocks 50000 --format json   # machine-readable
bash scripts/check.sh SKP --max-blocks 50000 --format md     # human-readable
bash scripts/check.sh SKP --max-blocks 50000 --format txt     # plain text
```

### Full workflow (off-chain + on-chain)

```bash
# 1. Install Foundry (one-time)
curl -L https://foundry.paradigm.xyz | bash && foundryup

# 2. Set your deployer key (one-time)
export PRIVATE_KEY=0xYourPrivateKeyHere
export DEPLOYER=$(cast wallet address --private-key $PRIVATE_KEY)

# 3. Deploy the on-chain registry to a network (one-time per network)
bash scripts/deploy_registry.sh --network mainnet    # or testnet

# 4. Verify the contract on PharosScan
#    (the script prints the address + tx; verify after ~10 seconds)

# 5. Run the off-chain scan
bash scripts/check.sh USDC --max-blocks 50000 --format json

# 6. Check on-chain claims
bash scripts/query_registry.sh USDC --network mainnet

# 7. If both clear, file your own claim
bash scripts/register_symbol.sh SKP --network mainnet --project-uri "https://skp.example"

# 8. Audit claim history
bash scripts/registry_history.sh --network mainnet --from-block 11000000

# 9. Release the claim later (refund the deposit)
bash scripts/release_symbol.sh SKP --network mainnet
```

### As a callable AI Agent service

The Skill is meant to be hosted on Anvita Flow as a Service Agent. When a
user asks their Steward Agent "is USDC safe to use on Pharos?", the agent
invokes PSCD, which runs the scanner and queries the registry, then returns
a structured report:

```text
User: "I want to launch a token called USDC-PROJ on Pharos. Check if it's safe."
Steward Agent: invokes Pharos Symbol Collision Detector
  -> check.sh USDC-PROJ --max-blocks 100000
  -> query_registry.sh USDC-PROJ --network mainnet
Agent replies: "Off-chain scanner says CLEAR (no ERC-20 uses 'USDC-PROJ' on
  Pharos mainnet in the last 100K blocks). Registry says CLEAR (no active
  claim). You're safe to launch."
```

## Capability Index

| User Need | Capability | Detailed Instructions |
|---|---|---|
| "Is `USDC` taken on Pharos?" | Off-chain scan: `bash scripts/check.sh USDC --max-blocks 100000 --format json` | → `references/methodology.md` |
| "Scan last N blocks for symbol X" | Off-chain scan with bounded range | → `references/methodology.md#scan-modes` |
| "Scan a specific block range" | Off-chain scan with `--from-block`/`--to-block` | → `references/methodology.md#custom-block-range` |
| "Run a quick demo" | `bash scripts/check.sh --demo` (USDC, last 5K blocks, ~5s) | → `references/methodology.md` |
| "Is `USDC` already claimed on-chain?" | `bash scripts/query_registry.sh USDC --network mainnet` | → `references/registry.md#query-an-on-chain-claim` |
| "Register my symbol on-chain" | `bash scripts/register_symbol.sh SKP --network mainnet --project-uri "..."` | → `references/registry.md#register-a-symbol-claim` |
| "Release my claim and refund my deposit" | `bash scripts/release_symbol.sh SKP --network mainnet` | → `references/registry.md#release-a-claim-and-refund-the-deposit` |
| "Show all symbols claimed recently" | `bash scripts/registry_history.sh --network mainnet` | → `references/registry.md#query-claim-history-events` |
| "Deploy the registry contract" | `bash scripts/deploy_registry.sh --network mainnet` (one-time per network) | → `references/registry.md#deploy-symbolregistry-one-time-per-network` |
| "Check on testnet instead" | Pass `--network testnet` to any of the above | → references |
| "How much does it cost?" | Min deposit `0.001 ether` (PHRS or PROS); refundable; the registry contract itself is owner-deployed once | → `references/registry.md#register-a-symbol-claim` |
| "Full safety check before launch" | Run scanner + registry query + (optionally) register if clear | → `references/registry.md#combined-pscd--registry-workflow` |

## Outputs

### Off-chain scanner (`check.sh`)

`--format json` (default for agents):

```json
{
  "network": "mainnet",
  "chainId": 1672,
  "rpc": "https://rpc.pharos.xyz",
  "candidate": "USDC",
  "normalized": "usdc",
  "from_block": 9596769,
  "to_block": 9606769,
  "blocks": 10001,
  "tokens_seen": 5,
  "verdict": "COLLISION",
  "verdict_msg": "1 token(s) on mainnet use the symbol 'USDC'",
  "collisions": [
    {
      "address": "0xc879c018db60520f4355c26ed1a6d572cdac1815",
      "symbol": "USDC",
      "name": "USDC",
      "decimals": 6,
      "ok": true,
      "explorer": "https://www.pharosscan.xyz/token/0xc879c018db60520f4355c26ed1a6d572cdac1815"
    }
  ]
}
```

### On-chain registry (`query_registry.sh`)

`--format json`:

```json
{
  "network": "mainnet",
  "registryAddress": "0x...",
  "candidate": "SKP",
  "normalized": "skp",
  "symbolHash": "0x...",
  "claimed": true,
  "claimer": "0x...",
  "deposit_wei": "1000000000000000",
  "timestamp": 1778000000,
  "blockNumber": 11000123,
  "projectURI": "https://skp.example"
}
```

## Prerequisites

### Required tools

```bash
# Foundry (cast, forge) — MANDATORY. cast is the only RPC client.
curl -L https://foundry.paradigm.xyz | bash && foundryup

# python3 (standard library only — for JSON parsing in the bash scripts)
python3 --version   # 3.10+ recommended

# bash 4+, curl, jq (optional, for pretty JSON)
```

### Wallet (for on-chain operations only)

```bash
# Private key as env var. Foundry does NOT auto-read this — always pass --private-key $PRIVATE_KEY.
export PRIVATE_KEY=0xYourPrivateKeyHere
export DEPLOYER=$(cast wallet address --private-key $PRIVATE_KEY)
```

> **Security Warning:** Never commit your private key. Never paste it in chat.
> Always use `$PRIVATE_KEY` env var and pass it explicitly to each cast command.

### Networks

| Network | Chain ID | RPC URL | Use for |
|---|---:|---|---|
| Pacific mainnet | 1672 | `https://rpc.pharos.xyz` | Scanner (default). Registry deployment supported. |
| Atlantic testnet | 688689 | `https://atlantic.dplabs-internal.com` | Free PHRS for testing. Registry deployment supported. |

## Network Configuration

Network RPC URLs, chain IDs, explorer URLs, and deployed contract addresses
are stored in `assets/networks.json`. The Agent layer and the bash scripts
read from this file — no hardcoded URLs anywhere else. To deploy the
registry to a new network, append a new object with the network's fields
and run `scripts/deploy_registry.sh`.

## Scan modes

| Mode | Range | Speed | Use when |
|---|---|---|---|
| `demo` | last 5,000 blocks (~3h) | ~5s | Interactive demo, smoke test |
| `bounded` | `--max-blocks N` | N/1000s of seconds | Pre-launch checks |
| `custom` | `--from-block X --to-block Y` | (Y-X)/1000s | Reproducible audits, fixed windows |
| `full` | entire chain | ~3–5 min | First-time audit |

For production use, always run with `--max-blocks 100000` or larger.

## General Error Handling

| Error Scenario | CLI Signature | Handling |
|---|---|---|
| Block range too large for `eth_getLogs` | RPC returns "block range too large" | PSCD auto-batches to 1000-block windows |
| RPC rate-limited | HTTP 429 from RPC | Retry once after 2s; if persistent, suggest a paid RPC |
| Symbol contains non-printable chars | `cast keccak` produces unexpected hash | PSCD normalizes to ASCII upper-case + strip whitespace on-chain; off-chain comparison is the same |
| Symbol > 32 bytes | ABI truncation in `symbol()` | On-chain registry truncates to 32 bytes; off-chain scanner queries whatever the contract returns |
| Already claimed on-chain | `AlreadyClaimed()` revert | Surface the existing claim to the user; do NOT auto-override |
| Private key missing | `$PRIVATE_KEY` env var unset | Prompt user to set it; do not invent one |
| Insufficient balance | `insufficient funds for gas` | Tell user the required amount and where to get faucet PHRS/PROS |
| Contract not deployed on this network | `SymbolRegistry not configured for ...` | Tell user to run `scripts/deploy_registry.sh --network <name>` first |

## Security Reminders

- **Private Key Protection** — the scripts accept a private key only via
  `--private-key $PRIVATE_KEY` or the `$PRIVATE_KEY` env var. Never paste
  a key into chat, README, or git history.
- **Off-chain scanner is read-only** — it cannot send transactions. Safe to
  run on any wallet.
- **On-chain registry is write-capable** — only the claimer can release their
  own claim. The owner can pause the contract and run an emergency
  withdrawal to refund all claimers manually, but cannot steal individual
  claims.
- **Network Confirmation** — before any write operation (`register`,
  `release`, `deploy`), confirm with the user which network they're using.
  Mainnet operations spend real PROS.

## Write Operation Pre-checks

Per Pharos Skill Engine convention, every write operation must pass these
checks before sending:

1. **Private Key Check** — `--private-key` / `$PRIVATE_KEY` is set; the
   address derives to a valid 20-byte hex.
2. **Derive Public Address** — `cast wallet address --private-key $PRIVATE_KEY`.
3. **Network Confirmation** — confirm with the user which network.
4. **Automatic Balance Check** — `cast balance <deployer> --rpc-url <rpc> --ether`;
   abort with a clear error if below the operation cost + gas buffer.

The bash scripts do all four checks automatically and refuse to send if any
fails. The Agent should call these scripts via the standard interface and
trust the pre-checks.

## Repository layout

```
.
├── SKILL.md                              # This file — agent entry point
├── README.md                             # Human-friendly overview
├── foundry.toml                          # Forge config (src = assets/contracts)
├── LICENSE                               # MIT
├── assets/
│   ├── contracts/
│   │   └── SymbolRegistry.sol            # The on-chain registry contract
│   └── networks.json                     # RPC + chain config per network
├── references/
│   ├── methodology.md                    # Scanner internals (off-chain detection)
│   └── registry.md                       # Registry operations (agent-readable format)
├── scripts/
│   ├── check.sh                          # Off-chain symbol-collision scanner
│   ├── deploy_registry.sh                # One-time: deploy SymbolRegistry
│   ├── register_symbol.sh                # File an on-chain claim
│   ├── release_symbol.sh                 # Cancel a claim, refund deposit
│   ├── query_registry.sh                 # Look up an on-chain claim
│   └── registry_history.sh               # Audit all claims in a block range
├── tests/
│   ├── test_check_smoke.sh               # Offline smoke test for check.sh
│   └── SymbolRegistry.t.sol              # 14 forge tests for the contract
└── examples/
    └── sample-report.md                  # Example output for both surfaces
```

## Limitations

- **Tokens not detected by the scanner**: factory-created tokens that don't
  emit their own Transfer event; upgradeable proxy tokens (the proxy
  address will be found, but the implementation is what the explorer shows);
  tokens with no `symbol()` function (revert and are skipped).
- **Symbol comparison is exact-match, ASCII only.** `USDC.e` ≠ `USDC`.
  `USDC` ≠ `USDС` (Cyrillic).
- **On-chain registry does not enforce uniqueness of the off-chain
  symbol.** It records developer intent. A user can still deploy an ERC-20
  with a registered symbol — PSCD's scanner will surface it as a COLLISION.
  The registry is a coordination layer, not a gatekeeper.

## License

MIT — see `LICENSE`.