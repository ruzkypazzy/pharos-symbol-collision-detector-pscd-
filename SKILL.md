---
name: pharos-symbol-collision-detector
description: |
  Use this skill when the user wants to know whether a token symbol is already
  taken on the Pharos Pacific mainnet before launching a new ERC-20. PSCD scans
  on-chain for any token contract whose symbol() matches the candidate and
  returns CLEAR (no match) or COLLISION (with addresses, names, decimals, and
  explorer links). Operates as both a CLI tool and an in-agent tool callable by
  Claude Code, Codex, or OpenClaw via this SKILL.md.
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
