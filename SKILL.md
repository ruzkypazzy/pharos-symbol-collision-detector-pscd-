---
name: pharos-symbol-collision-detector
description: |
  Use this skill when the user wants to know whether a token symbol is already
  taken on the Pharos Pacific mainnet before launching a new ERC-20. PSCD scans
  on-chain for any token contract whose symbol() matches the candidate and
  returns CLEAR (no match) or COLLISION (with addresses, names, decimals, and
  explorer links). Operates as both a CLI tool and an in-agent tool callable by
  Claude Code, Codex, or OpenClaw via this SKILL.md.
version: 1.1.0
author: ruzkypazzy
requires: read
bins: [python3]
network: pharos
tags: [pharos, security, erc20, tokens, symbol, collision, scam-detection, mainnet, testnet]
agents: [claude, codex, gemini, openclaw]
---

# Pharos Symbol Collision Detector (PSCD)

## When to use

Use this skill when the user:

- Says "is `SYMBOL` taken on Pharos?" or "check if `SYMBOL` exists"
- Asks "is my token name unique on Pharos?"
- Wants to verify a token symbol before mainnet launch
- Asks "is `USDC`/`SKP`/`MOON` already used on Pharos?"
- Says "scan Pharos for token `SYMBOL` collisions"

## What it does

Given a candidate token symbol, PSCD:

1. Scans Pharos Pacific mainnet (chain 1672) for ERC-20 mint events
2. Fetches `symbol()`, `name()`, `decimals()` for each unique token
3. Normalizes both candidate and on-chain symbols (case-insensitive, strip whitespace)
4. Returns one of:
   - **CLEAR** — no token uses the symbol
   - **COLLISION** — one or more tokens share the symbol (with full details)
   - **EMPTY** — the candidate was empty

## How to use

### From the CLI

```bash
git clone https://github.com/ruzkypazzy/Pharos-Symbol-Collision-Detector-PSCD-
cd Pharos-Symbol-Collision-Detector-PSCD-

# Bounded fast scan (~5s, last 5,000 blocks of mainnet)
bash scripts/check.sh SYMBOL --max-blocks 5000

# Custom block range — "check from block X to block Y"
bash scripts/check.sh SYMBOL --from-block 9000000 --to-block 9050000

# Full mainnet scan (~3 minutes, scans all 9.6M blocks)
bash scripts/check.sh SYMBOL

# Demo: check USDC
bash scripts/check_demo.sh
```

### Custom block range (from-block / to-block)

Both the bash wrapper and the Python entry point accept explicit `--from-block N` and `--to-block N`. The wrapper validates that `--from-block <= --to-block` and that all numeric flags are non-negative integers. Pair with `--step` (default 1000) to control RPC call density, and `--workers` (default 6) for parallel symbol lookup.

```bash
# Last week's worth of blocks on Pharos (Pharos is 2s blocks → 302,400 blocks/week)
bash scripts/check.sh SKP --from-block 9300000 --to-block 9602400

# From a specific deployment height to today
bash scripts/check.sh SKP --from-block 8000000

# Pin a fixed window for reproducible audits
bash scripts/check.sh USDC --from-block 9500000 --to-block 9550000 --format json
```

### As JSON for programmatic consumption

```bash
bash scripts/check.sh SYMBOL --format json
```

Output schema:
```json
{
  "network": "Pharos Pacific Ocean Mainnet",
  "chainId": 1672,
  "candidate": "USDC",
  "normalized": "USDC",
  "from_block": 9596769,
  "to_block": 9606769,
  "blocks": 10001,
  "tokens_seen": 5,
  "tokens_ok": 5,
  "verdict": "COLLISION",
  "verdict_msg": "1 token(s) on Pharos Pacific Ocean Mainnet use symbol 'USDC'",
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

### In an AI agent workflow

```python
import subprocess, json

def check_symbol(symbol: str) -> dict:
    """Return CLEAR / COLLISION / EMPTY for a token symbol on Pharos mainnet."""
    result = subprocess.run(
        ["bash", "scripts/check.sh", symbol, "--format", "json", "--quiet"],
        capture_output=True, text=True
    )
    return json.loads(result.stdout)
```

Use it:
- Before `deployContract` (ERC-20) to verify the symbol is unique
- In a token-launch workflow as a pre-flight check
- To investigate "is `USDC` real?" type questions
- To audit a project's token list

## Output format guide

When responding to the user, format the JSON result as:

- **CLEAR**: `"✅ No token on Pharos Pacific Mainnet uses the symbol 'X' in the scanned range (last N blocks)."`
- **COLLISION**: `"⚠️ N token(s) on Pharos Pacific Mainnet use the symbol 'X':"` + a list of `{address, name, decimals, explorer link}`.
- **EMPTY**: `"Please provide a symbol to check (e.g. 'SKP' or 'USDC')."`

Always include the `from_block` and `to_block` in the response so the user knows how thorough the scan was.

## Scan modes

| Mode | Range | Speed | Use when |
|---|---|---|---|
| `fast` (default for demo) | last 5,000 blocks | ~5s | interactive demos |
| `bounded` | `--max-blocks N` | N/1000s | pre-launch checks |
| `custom` | `--from-block X --to-block Y` | (Y-X)/1000s | reproducible audits, fixed windows, "from block X to block Y" requests |
| `full` | entire chain | ~3 min | first-time audit |

For production use, always run with `--max-blocks 100000` or larger to catch recently-deployed duplicates.

## Edge cases

- **Non-ERC-20 contracts emitting Transfer:** skipped (their `symbol()` reverts)
- **Tokens with empty symbol:** reported but won't match a non-empty candidate
- **Case differences:** handled — `usdc` and `USDC` are treated as identical
- **Whitespace:** stripped before comparison
- **Symbol longer than 32 chars:** ABI decoder handles 0-32 byte strings; longer strings will be truncated by the on-chain contract itself
- **Decimal = 0:** unusual but supported; some governance tokens have 0 decimals

## Tech notes

- Uses raw JSON-RPC to `https://rpc.pharos.xyz` — no third-party indexer
- `eth_getLogs` is filtered server-side to `Transfer` events with `topic1 = 0x0…0` (mint)
- Batched 1,000 blocks per call to stay within rate limits
- 6 parallel `eth_call` workers for symbol/name/decimals lookup
- PUSH-data-aware: not needed (no bytecode analysis)
- No private keys, no signing, no writes — read-only

## What PSCD does NOT do

- ❌ Does not check for similar-but-not-identical symbols (e.g. `USDC.e` vs `USDC`) — exact match only
- ❌ Does not check for off-chain (Twitter, website) impersonators
- ❌ Does not verify whether a collision is a scam or a legitimate bridged token
- ❌ Does not check ERC-721 / ERC-1155 NFT collections (only ERC-20 via `Transfer` event)
- ❌ Does not enumerate tokens deployed via factory contracts (factory-created tokens may not emit their own Transfer event)

## Install

```bash
git clone https://github.com/ruzkypazzy/Pharos-Symbol-Collision-Detector-PSCD-
cp -r Pharos-Symbol-Collision-Detector-PSCD- ~/.pharos/skills/pscd/
```

Or via OpenClaw:
```bash
npx skills add ruzkypazzy/Pharos-Symbol-Collision-Detector-PSCD-
```

## Prerequisites

```bash
# Python 3.10+ is required
python3 --version
```

The skill uses only the Python standard library (`urllib.request`,
`json`, `concurrent.futures`). No third-party packages, no Foundry,
no `pip install` step.

The skill is **read-only** — no private key is required or accepted.

## Network Configuration

Network RPC URLs and chain IDs are sourced from
`assets/networks.json` (canonical Pharos Skill Engine schema). To
add a new network, append a new object to the `networks` array and
update `defaultNetwork` if needed.

## Capability Index

| User Need | Capability | Detailed Instructions |
|---|---|---|
| "Is the symbol USDC taken on Pharos?" | Scan a block range for matching `symbol()` returns | Run `python3 -m pscd --symbol USDC --from-block 0 --to-block latest --rpc-url https://rpc.pharos.xyz`; the skill emits CLEAR or COLLISION with per-match detail |
| "Check Cyrillic homoglyph spoofs" | Unicode-normalize the symbol before comparison | PSCD applies NFKC normalization + zero-width-space stripping; matches `USDC` against `USDС` (Cyrillic) and `U​SDC` (zero-width space) |
| "Custom block range scan" | `--from-block` / `--to-block` flags | Default scans all blocks on the chain; bounded scans use the public Pharos RPC's `eth_getLogs` with 1,000-block batches and 6 parallel `eth_call` workers |
| "Per-collision trading card" | Markdown report per match | Output is a "trading card" with the suspect address, deployer, deployment block, on-chain symbol, and a one-line verdict (`COLLISION — likely scam` / `COLLISION — verify contract source`) |
| "False-positive check (legit bridge)" | Cross-reference with bridge registry | PSCD flags known-bridge addresses differently from unknown deployers; the verdict line in the trading card reflects the bridge status |

## General Error Handling

| Error Scenario | CLI Error Signature | Handling |
|---|---|---|
| Block range too large for `eth_getLogs` | Pharos RPC returns `param error; The block range is too large` | PSCD auto-falls back to 1,000-block batches with `eth_getBlockByNumber` + internal-tx walking; the user does not need to retry |
| RPC rate-limited (HTTP 429) | Backoff response from RPC | Built-in exponential backoff (0.4s, 0.8s, 1.6s, 3.2s) with 4 retry attempts |
| Symbol contains non-printable chars | Symbol field contains null bytes / zero-width space | Symbol is NFKC-normalized + zero-width-stripped before comparison; the comparison still works on the cleaned form |
| Network not in networks.json | `--rpc-url` not recognized | Exit with a list of valid networks; default to atlantic-testnet |
| Empty result (no matches) | `verdict: CLEAR` | Normal case — emit the "no match found" report, no error |

## Security Reminders

- **Private Key Protection** — the skill is read-only and never
  accepts a private key. Do not paste keys into chat.
- **Network Confirmation** — before any future write-skill
  integration, confirm the network with the user.
- **No External API** — the skill does not call any third-party
  service. All data is fetched directly from the Pharos RPC.

## Write Operation Pre-checks

This skill is **read-only** and never submits a transaction, so the
full 4-step write pre-check is not applicable. If a future version
adds a "submit symbol claim" path, the pre-checks must include:

1. **Private Key Check** — `--private-key` / `$PRIVATE_KEY` must be
   set; warn if the key has zero balance.
2. **Derive Public Address** — `cast wallet address`; confirm the
   key is for the intended network.
3. **Network Confirmation** — prompt the user with "You are about
   to write to Pacific mainnet. Continue? (y/N)".
4. **Automatic Balance Check** — `cast balance`; if below the
   operation cost + gas, abort with a clear error.
