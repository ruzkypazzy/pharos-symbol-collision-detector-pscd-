---
name: Pharos-Symbol-Collision-Detector
description: |
  Use this skill whenever a developer on Pharos is about to launch an ERC-20
  token and needs to know if the candidate ticker is already taken on the
  chain. PSCD scans the Pharos Pacific mainnet (and Atlantic testnet) for
  ERC-20 contracts whose `symbol()` matches the candidate, and produces a
  structured collision report. All operations are bash + python3 + cast/curl
  against the public RPC; no on-chain registry or contract is required.
version: 4.1.0
author: ruzkypazzy
requires: read, write
bins: [bash, python3, curl, cast]
network: pharos
tags: [pharos, security, erc20, tokens, symbol, collision, scanner, mainnet, testnet]
agents: [claude, codex, cursor, gemini, openclaw]
---

# Pharos Symbol Collision Detector (PSCD)

## When to use

Use this skill when the user:

- Wants to know if a token symbol is safe to launch on Pharos
- Says "is `USDC` already used on Pharos?" or "does `SKP` exist on Pharos?"
- Wants a list of every ERC-20 currently deployed with a given symbol
- Wants a pre-launch check before deploying a new ERC-20
- Asks "has anyone already deployed a token with this ticker?"
- Wants to audit the recent history of ERC-20 deployments on Pharos

Do NOT use this skill for ERC-721 / ERC-1155 NFT collections, off-chain
impersonator checks, or non-Pharos chains.

## What it does

PSCD is a pure off-chain scanner. It reads the Pharos public RPC (no auth, no
private key, no on-chain contract) and walks a configurable block range,
extracting every contract creation in the range, calling `symbol()` on each
candidate ERC-20, and matching against the user's ticker.

**Two operations are exposed:**

| Operation | Script | What it does |
|---|---|---|
| **check** | `scripts/check.sh SYMBOL [opts]` | Walks a block range, finds every ERC-20 with matching `symbol()`, reports collision or clear |
| **history** | `scripts/registry_history.sh --network mainnet [--since-block N]` | Streams all ERC-20 deployments in a range, grouped by ticker |

Both are read-only. No wallet, no private key, no gas, no on-chain contract.

## Capability Index

| User Need | Capability | Detailed Instructions |
|---|---|---|
| "Is `USDC` taken on Pharos?" | `bash scripts/check.sh USDC --network mainnet` | → `references/methodology.md#quick-check-default` |
| "Scan only the last 50,000 blocks for `SKP`" | `bash scripts/check.sh SKP --network mainnet --max-blocks 50000` | → `references/methodology.md#bounded-scan` |
| "Scan a custom range" | `bash scripts/check.sh USDC --from-block 9000000 --to-block 9050000` | → `references/methodology.md#explicit-block-range` |
| "Get the report as JSON" | `bash scripts/check.sh USDC --format json` | → `references/methodology.md#output-formats` |
| "Run on testnet" | `bash scripts/check.sh USDC --network testnet` | → `references/methodology.md#testnet` |
| "List every recent ERC-20 deployment" | `bash scripts/registry_history.sh --network mainnet` | → `references/methodology.md#history-scan` |

## Required binaries

Only four binaries, all pre-installed in the Anvita Flow hosted runtime:

```
bash    # shell
python3 # JSON parsing in the scripts
curl    # JSON-RPC POST requests
cast    # (optional) used as a fallback RPC client
```

If `cast` is missing but `curl` is present, the scripts auto-fallback to
plain `curl` JSON-RPC calls. This means the Skill works on systems that have
*only* bash + python3 + curl.

## Network Configuration

| Network | Chain ID | RPC | Explorer |
|---|---:|---|---|
| Pacific mainnet (default) | 1672 | `https://rpc.pharos.xyz` | https://www.pharosscan.xyz |
| Atlantic testnet | 688689 | `https://atlantic.dplabs-internal.com` | https://atlantic.pharosscan.xyz |

Both are public, read-only, no auth.

## How `check.sh` works (the actual algorithm)

1. **Get block range.** Default: `0` to `latest`. Override with `--max-blocks`, `--from-block`, `--to-block`.
2. **Fetch all `Transfer` events from address(0) → X in the range.** This emits a `Transfer` from the zero-address whenever a new ERC-20 mints the initial supply to a deployer. This is a much cheaper index of "deployments" than walking every block for contract creations, and it's a standard pattern used by Etherscan / PharoScan's token tracker.
3. **For each candidate token, call `symbol()`.** If the returned symbol matches the user's query (case-insensitive, normalized), it's a collision.
4. **Also call `name()`, `decimals()`, `totalSupply()`** to enrich the report.
5. **Emit the verdict:** `CLEAR` (no matches) or `COLLISION` (one or more matches, list each with explorer link).
6. **Output format** is `--format md` (default), `--format json`, or `--format txt`.

**Performance:** scanning 50,000 blocks finishes in ~5 seconds on Pharos Pacific mainnet. 100,000 blocks in ~10 seconds. The full chain (~12M blocks) in ~30 minutes.

## How `registry_history.sh` works

Streams every `Transfer(from=0x0)` event in a range, groups by ticker, and
emits a per-ticker count + first-seen block + sample token. Useful for
"show me everything that has launched on Pharos recently."

**Public RPC limit:** Pharos's public RPC rejects `eth_getLogs` requests
spanning more than 1,000 blocks. The script auto-batches the range into
1,000-block windows and parallelizes 4 ways via `xargs -P 4`.

## Output formats

### Markdown (default)

```markdown
# Symbol Collision Report: USDC

- Network:    Pharos Pacific mainnet (chain 1672)
- RPC:        https://rpc.pharos.xyz
- Range:      blocks 0 → 11,978,422
- Verdict:    **COLLISION**
- Tokens seen: 8,723
- Collisions: 1

## COLLISION 1/1

| Field | Value |
|---|---|
| Address | 0xc879c018db60520f4355c26ed1a6d572cdac1815 |
| Symbol | USDC |
| Name | USDC |
| Decimals | 6 |
| Total supply | 6,458,898.643751 |
| Holders | 17,388 |
| Explorer | https://www.pharosscan.xyz/token/0xc879c018db60520f4355c26ed1a6d572cdac1815 |

## Recommendation

USDC is already in use on Pharos Pacific mainnet. Do not deploy a new ERC-20
with the ticker USDC — wallets and explorers will display both identically
and end users will be unable to distinguish them. Pick a different symbol
(USDC2, USDCX, USDCPROJ) before launching.
```

### JSON

```json
{
  "network": "mainnet",
  "chainId": 1672,
  "rpc": "https://rpc.pharos.xyz",
  "candidate": "USDC",
  "normalized": "usdc",
  "from_block": 0,
  "to_block": 11978422,
  "tokens_seen": 8723,
  "verdict": "COLLISION",
  "verdict_msg": "1 token(s) on mainnet use the symbol 'USDC'",
  "collisions": [
    {
      "address": "0xc879c018db60520f4355c26ed1a6d572cdac1815",
      "symbol": "USDC",
      "name": "USDC",
      "decimals": 6,
      "total_supply": "6458898643751",
      "holders": 17388,
      "ok": true,
      "explorer": "https://www.pharosscan.xyz/token/0xc879c018db60520f4355c26ed1a6d572cdac1815"
    }
  ]
}
```

## General Error Handling

| Error | Cause | Fix |
|---|---|---|
| `provide a symbol` | No `SYMBOL` argument | Pass the candidate ticker as the first arg |
| `Unknown network` | `--network foo` | Use `mainnet` or `testnet` |
| `--from-block > --to-block` | Reversed range | Swap or use `--max-blocks` |
| `must be a non-negative integer` | Non-numeric block number | Use a positive integer |
| `--format yaml` | Invalid format | Use `md`, `json`, or `txt` |
| `cannot use --max-blocks with --from-block` | Mutually exclusive | Pick one or the other |
| `RPC returned no logs` | No `Transfer(0x0,…)` events in the range | The range is too narrow or no tokens minted in it; widen it |
| `timeout` | RPC endpoint slow | Retry, or reduce `--max-blocks` |

## Response format (agent → user)

When the user asks "is `SYMBOL` taken on Pharos?", invoke `check.sh SYMBOL
--network mainnet --format md`. The script returns a complete markdown
report. **Do not rephrase the verdict — quote it directly.**

Always include:

1. The verdict line (**CLEAR** or **COLLISION**)
2. For COLLISION: the explorer link to each matching contract
3. For COLLISION: a recommendation to pick a different symbol (suggest `SYMBOL2`, `SYMBOLX`, `SYMBOL-PROJ`)
4. For CLEAR: the actual range scanned, so the user knows how confident to be

## What PSCD does NOT do

- **ERC-721 / ERC-1155 NFT collections.** Use a different indexer.
- **Off-chain impersonator checks** (e.g. typo-squatted Twitter handles, fake websites). PSCD is on-chain only.
- **Pharos contracts that don't follow the standard ERC-20 interface.** Tokens with non-standard `symbol()` (returns bytes, panics) are skipped and not reported.
- **Symbol normalization beyond ASCII upper-case + whitespace-strip.** `UЅDC` (Cyrillic) is a different ticker from `USDC`. Tell the user to check Unicode homoglyphs separately.
- **Cross-chain symbol scans.** PSCD is Pharos-only.

## Repository layout

```
.
├── SKILL.md                          # This file — agent entry point
├── README.md                         # Human-friendly overview
├── foundry.toml                      # RPC + chain config (also documents the chain)
├── foundry.lock
├── LICENSE                           # MIT
├── assets/
│   └── networks.json                 # RPC + chain config per network
├── references/
│   └── methodology.md                # Detection algorithm + design notes
├── scripts/
│   ├── check.sh                      # Off-chain ERC-20 symbol scanner
│   ├── registry_history.sh           # All recent ERC-20 deployments, grouped
│   └── _registry_history_parse.py    # Python helper for batched log parsing
├── tests/
│   └── test_check_smoke.sh           # Offline smoke tests
└── examples/
    └── sample-report.md              # Real example invocations and outputs
```

## License

MIT — see `LICENSE`.