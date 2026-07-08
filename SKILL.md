---
name: Pharos-Symbol-Collision-Detector
description: |
  Use this skill when a developer asks whether a candidate token symbol is
  safe to launch on Pharos, or wants to file/check an on-chain claim for a
  symbol. PSCD exposes a deployed SymbolRegistry contract on Pharos Pacific
  mainnet that lets developers record a refundable PHRS/PROS deposit claim
  for a token symbol and check whether anyone has already claimed it. All
  operations are direct cast calls to the contract — no bash scripts,
  no scripts/ directory mounting required.
version: 4.0.0
author: ruzkypazzy
requires: read, write
bins: [cast]
network: pharos
tags: [pharos, security, erc20, tokens, symbol, collision, registry, on-chain, mainnet]
agents: [claude, codex, cursor, gemini, openclaw]
---

# Pharos Symbol Collision Detector (PSCD)

## When to use

Use this skill when the user:

- Wants to check whether a token symbol is safe to launch on Pharos
- Asks "is `SYMBOL` taken on Pharos?" or "is `USDC` already used on Pharos?"
- Wants to **file an on-chain claim** for a symbol on Pharos (refundable 0.001 PHRS/PROS deposit)
- Wants to **check if a symbol is already claimed on-chain**
- Wants to **release** their own claim and recover the deposit
- Says "register my token symbol on Pharos"
- Asks for a pre-launch check before deploying a new ERC-20

Do NOT use this skill for ERC-721 / ERC-1155 collections, off-chain impersonator checks, or non-Pharos chains.

## What it does

PSCD is a cast-only Skill that wraps a deployed `SymbolRegistry` Solidity contract on Pharos Pacific mainnet. Every operation is a single direct `cast` invocation — no scripts to mount, no shell execution, no tool installation.

**Deployed contract on Pharos Pacific mainnet (chain 1672):**
```
SymbolRegistry = 0x6A9Eb713a8055d6ee46aD01641021255f62E6190
```

| Operation | cast command |
|-----------|--------------|
| Check if a symbol is claimed | `cast call <REGISTRY> "isClaimed(string)(bool)" "SYMBOL" --rpc-url https://rpc.pharos.xyz` |
| Get full claim record | `cast call <REGISTRY> "getClaim(string)((address,uint256,uint64,uint64,string,bool))" "SYMBOL" --rpc-url https://rpc.pharos.xyz` |
| Count active claims by address | `cast call <REGISTRY> "activeClaimCountOf(address)(uint256)" "0xADDRESS" --rpc-url https://rpc.pharos.xyz` |
| Total PHRS held by the contract | `cast call <REGISTRY> "totalHeld()(uint256)" --rpc-url https://rpc.pharos.xyz` |
| File a claim (write) | `cast send <REGISTRY> "register(string,string)" "SYMBOL" "https://your-project.example" --value 0.001ether --private-key $PRIVATE_KEY --rpc-url https://rpc.pharos.xyz` |
| Release a claim (write) | `cast send <REGISTRY> "release(string)" "SYMBOL" --private-key $PRIVATE_KEY --rpc-url https://rpc.pharos.xyz` |
| Pause contract (owner-only) | `cast send <REGISTRY> "pause()" --private-key $PRIVATE_KEY --rpc-url https://rpc.pharos.xyz` |
| Unpause contract (owner-only) | `cast send <REGISTRY> "unpause()" --private-key $PRIVATE_KEY --rpc-url https://rpc.pharos.xyz` |

## Capability Index

| User Need | Capability | Detailed Instructions |
|---|---|---|
| "Is `USDC` taken on Pharos?" | `cast call <REGISTRY> "isClaimed(string)(bool)" "USDC" --rpc-url https://rpc.pharos.xyz` | → `references/registry.md#check-if-a-symbol-is-claimed` |
| "Get the claim record for `SKP`" | `cast call <REGISTRY> "getClaim(string)((address,uint256,uint64,uint64,string,bool))" "SKP" --rpc-url https://rpc.pharos.xyz` | → `references/registry.md#get-the-full-claim-record` |
| "How many symbols has address X claimed?" | `cast call <REGISTRY> "activeClaimCountOf(address)(uint256)" "0xADDRESS" --rpc-url https://rpc.pharos.xyz` | → `references/registry.md#count-active-claims-by-address` |
| "How much PHRS does the registry hold?" | `cast call <REGISTRY> "totalHeld()(uint256)" --rpc-url https://rpc.pharos.xyz` | → `references/registry.md#query-registry-balance` |
| "Register `MYTOK` for my project" | `cast send <REGISTRY> "register(string,string)" "MYTOK" "https://myproj.example" --value 0.001ether --private-key $PRIVATE_KEY --rpc-url https://rpc.pharos.xyz` | → `references/registry.md#register-a-symbol-claim` |
| "Release my claim on `MYTOK`" | `cast send <REGISTRY> "release(string)" "MYTOK" --private-key $PRIVATE_KEY --rpc-url https://rpc.pharos.xyz` | → `references/registry.md#release-a-claim-and-refund-the-deposit` |

## Network Configuration

The deployed contract address lives in `assets/networks.json`. Scripts and references read from this file. Currently configured:

| Network | Chain ID | RPC | SymbolRegistry |
|---|---:|---|---|
| Pacific mainnet | 1672 | `https://rpc.pharos.xyz` | `0x6A9Eb713a8055d6ee46aD01641021255f62E6190` |
| Atlantic testnet | 688689 | `https://atlantic.dplabs-internal.com` | (not deployed yet) |

## Prerequisites

Only one binary required: **`cast`** (from the Foundry toolkit).

```bash
# Install Foundry if not present
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

That's it. No bash scripts, no Python, no jq, no curl. The Skill works with the cast binary that's already pre-installed in the Anvita Flow runtime.

For write operations, you also need:
- A Pharos-compatible wallet's private key
- Native PHRS (testnet) or PROS (mainnet) for gas + the 0.001 deposit

Pass the private key as `--private-key $PRIVATE_KEY` to every `cast send` command. Foundry does NOT auto-read this env var — you must always pass it explicitly.

## Write Operation Pre-checks

Per Pharos Skill Engine convention, every `cast send` (write) operation should follow these pre-checks:

1. **Private Key Check** — `--private-key` / `$PRIVATE_KEY` is set; the address derives to a valid 20-byte hex.
2. **Derive Public Address** — `cast wallet address --private-key $PRIVATE_KEY`.
3. **Network Confirmation** — confirm with the user which network (Pacific mainnet vs Atlantic testnet).
4. **Automatic Balance Check** — `cast balance <deployer> --rpc-url <rpc> --ether`; abort if below the operation cost + gas buffer.

## Outputs

### `isClaimed(string)` returns `bool`
```
> cast call 0x6A9Eb713... "isClaimed(string)(bool)" "SKP" --rpc-url https://rpc.pharos.xyz
true
```

### `getClaim(string)` returns a tuple `(address, uint256, uint64, uint64, string, bool)`
```
> cast call 0x6A9Eb713... "getClaim(string)((address,uint256,uint64,uint64,string,bool))" "SKP" --rpc-url https://rpc.pharos.xyz
(0xCC06503955C5808bCc6e285A868925cB0A0A8AC0, 1000000000000000 [1e15], 1783488188, 11850158, "https://second-claim.example", true)
```
Fields: `claimer`, `deposit (wei)`, `timestamp (unix)`, `blockNumber`, `projectURI`, `active`.

### `totalHeld()` returns `uint256` (wei)
```
> cast call 0x6A9Eb713... "totalHeld()(uint256)" --rpc-url https://rpc.pharos.xyz
1000000000000000 [1e15]
```

### `register(string, string)` returns `bytes32` (the claim hash)
```
> cast send 0x6A9Eb713... "register(string,string)" "MYTOK" "https://..." --value 0.001ether --private-key $PRIVATE_KEY --rpc-url https://rpc.pharos.xyz
transactionHash: "0x..."
```

## General Error Handling

| Error / Revert | Cause | Fix |
|---|---|---|
| `BelowMinimumDeposit()` | `--value` < 0.001 ether | Pass `--value 0.001ether` or higher |
| `AlreadyClaimed()` | Symbol has an active claim | Surface the existing claim to the user; do not auto-override |
| `PausedState()` | Contract is paused by owner | Wait for owner to unpause |
| `NotClaimed()` | Trying to release a non-existent claim | Run `isClaimed()` first |
| `NotClaimer()` | Sender is not the original claimer | Use the wallet that originally registered |
| `TransferFailed()` | Refund send failed | Retry; contact contract owner if persistent |

## Security Reminders

- **Private Key Protection** — only pass via `--private-key $PRIVATE_KEY` to cast. Never paste keys in chat, README, or git history.
- **All write operations require network confirmation.** Confirm with the user which network before sending.
- **The contract has no proxy/upgrade.** Code on mainnet is final. The owner has a `pause()` and `emergencyWithdrawal()` for safety only — they cannot steal individual claims.

## Limitations

- **No on-chain symbol uniqueness enforcement.** The registry records developer intent. A user can still deploy an ERC-20 with a claimed symbol — PSCD's registry will surface the claim but cannot prevent deployment.
- **Symbol normalization is ASCII upper-case + whitespace-strip only.** `USDC.e` ≠ `USDC`. Cyrillic homoglyphs not detected.
- **No off-chain chain scan in this Skill version.** This Skill is intentionally scoped to on-chain registry operations. For off-chain scanning of all ERC-20s (including those without active on-chain claims), use a separate indexer or block explorer.
- **No ERC-721 / ERC-1155 NFT collection support.**

## Repository layout

```
.
├── SKILL.md                          # This file — agent entry point
├── README.md                         # Human-friendly overview
├── foundry.toml                      # Forge config (src = assets/contracts)
├── foundry.lock
├── LICENSE                           # MIT
├── assets/
│   ├── contracts/
│   │   └── SymbolRegistry.sol        # Solidity source (also deployed at 0x6A9Eb713...)
│   └── networks.json                 # RPC + chain config per network + contract addresses
├── references/
│   ├── registry.md                   # Cast-command reference for every operation
│   └── methodology.md                # Detection algorithm + design notes
├── scripts/
│   └── deploy_registry.sh            # Optional: forge-based one-time deploy helper
├── tests/
│   ├── test_check_smoke.sh           # Offline smoke tests for the deploy helper
│   └── SymbolRegistry.t.sol          # 14 forge unit tests for the contract
└── examples/
    └── sample-report.md              # Example cast invocations and outputs
```

## License

MIT — see `LICENSE`.