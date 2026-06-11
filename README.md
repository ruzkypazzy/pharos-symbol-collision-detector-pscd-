# PSCD — Pharos Symbol Collision Detector

> **Is your token's symbol already taken?** PSCD scans Pharos Pacific mainnet for ERC-20 tokens that share a candidate symbol. One prompt, one verdict.

```
$ bash scripts/check.sh SKP
```

## What it does

Given a candidate symbol (e.g. `SKP`, `USDC`, `MOON`), PSCD:

1. **Scans** Pharos Pacific mainnet (chain 1672) block-by-block for `Transfer(address(0), …)` mint events — these mark ERC-20 token deployments.
2. **Looks up** each unique token contract's `symbol()`, `name()`, and `decimals()` via `eth_call`.
3. **Compares** the user-supplied symbol (case-insensitive, whitespace-stripped) against every on-chain symbol.
4. **Reports** one of three verdicts:
   - ✅ **CLEAR** — no token uses the symbol
   - ⚠️ **COLLISION** — one or more tokens use it (with addresses, names, decimals, and explorer links)
   - — **EMPTY** — you didn't provide a symbol

## Why it matters

Every Pharos ERC-20 launch needs a unique symbol. A collision means:
- Users get confused sending the wrong token
- Phishing tokens can impersonate yours
- Bridges and DEXs may treat them as the same
- It pollutes the on-chain identity of your project

PSCD gives you a single tool call to verify the symbol is yours before mainnet launch.

## Install

### 1. Install Foundry (the engine the skill is built on)

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Verify with `cast --version`. This gives you `cast`, `forge`, `anvil`, and `chisel` on your `$PATH`.

### 2. Install jq (used to parse JSON)

```bash
# macOS
brew install jq
# Debian/Ubuntu/Termux
apt install -y jq
# Alpine
apk add jq
```

Verify with `jq --version`.

### 3. Get the skill

```bash
git clone https://github.com/ruzkypazzy/Pharos-Symbol-Collision-Detector-PSCD-
cd Pharos-Symbol-Collision-Detector-PSCD-
chmod +x scripts/*.sh
```

That's it. No `pip install`, no `npm install`, no `forge build`, no compile. The skill is one or more bash scripts that use `cast` (from Foundry) for every RPC read. The `assets/networks.json` file already knows the Pharos Pacific Mainnet and Atlantic Testnet endpoints.
## Use

### CLI (bash — zero Python deps)

```bash
# Demo: check USDC on the last 5,000 blocks of mainnet
bash scripts/check_demo.sh

# Custom: check SKP across the entire mainnet (slow — ~3 minutes)
bash scripts/check.sh SKP --network mainnet

# Bounded: last 50,000 blocks (~30 hours of Pharos)
bash scripts/check.sh USDC --max-blocks 50000

# JSON output (for an AI agent to consume)
bash scripts/check.sh MYTKN --format json

# Testnet
bash scripts/check.sh SKP --network testnet
```

### CLI (Python — same engine, richer diagnostics)

```bash
python3 scripts/check.py USDC --max-blocks 5000 --format md
```

### In an AI agent

```bash
# Copy SKILL.md into your agent's skill directory, then ask:
> "is SKP taken on Pharos?"

# The agent auto-loads SKILL.md and runs:
bash scripts/check.sh SKP --format json
```

## Tech

- **Language:** bash + Python 3.8+
- **RPC:** `https://rpc.pharos.xyz` (Pacific mainnet, chain 1672)
- **No third-party APIs** — pharosscan.xyz's indexer is Vercel-protected, so we use raw RPC
- **No backend, no DB, no auth**
- **Tests:** 26/26 unit tests passing — covers ABI decoding, symbol normalization, scan batching, verdict logic, markdown rendering
- **License:** MIT

## Sample output

```
# PSCD — Pharos Symbol Collision Detector

**Verdict:** ⚠️ COLLISION

1 token uses USDC

## Inputs

- **Network:** Pharos Pacific Ocean Mainnet (chain 1672)
- **Candidate symbol:** `USDC` (normalized: `USDC`)
- **Block range:** 9,596,769 → 9,606,769 (10,001 blocks scanned)
- **Tokens seen in range:** 5 (with readable symbol: 5)

## 1 collision(s) found

| # | Symbol | Name | Decimals | Address | Explorer |
|---|---|---|---|---|---|
| 1 | `USDC` | USDC | 6 | `0xc879c018…ac1815` | [view ↗](https://www.pharosscan.xyz/token/0xc879c018db60520f4355c26ed1a6d572cdac1815) |

### What to do

- **If you control this contract:** you already have a collision. Rename your token before mainnet launch.
- **If you don't:** this is an impersonator. Do not interact with it; report it via pharosscan.
- **If you control none of these:** pick a different symbol. Common substitutes: append a suffix (e.g. `SKP2`, `SKPX`).
```

## Why this is unique on Pharos

- ❌ No other Pharos tool (including the official Agent Center Skill Engine) detects ERC-20 symbol collisions
- ❌ pharosscan.xyz is Vercel-protected and rejects bot fetches, so third-party indexers can't be relied on
- ✅ PSCD uses raw JSON-RPC — works today, no indexer dependency
- ✅ 3 output formats (Markdown, JSON, plain text) — JSON is consumable by Claude Code, Codex, OpenClaw
- ✅ Both bash and Python entry points — install path that fits your environment

## How it works (under the hood)

1. **Detect candidate tokens:** `eth_getLogs` filtered to `Transfer` events with `topic1 = 0x0…0` (Transfer-from-zero = canonical mint). Batched by 1,000 blocks per call to stay within RPC rate limits.

2. **Fetch metadata:** parallel `eth_call` requests for `symbol()` (`0x95d89b41`), `name()` (`0x06fdde03`), and `decimals()` (`0x313ce567`). 6 workers by default.

3. **ABI-decode** the dynamic-string return values. Handles 0-32 char symbols, unicode (incl. emoji), and 18/6/8 decimal places.

4. **Normalize** both candidate and on-chain symbols: strip whitespace, uppercase.

5. **Match** and emit a structured result.

## Performance

| Range | Blocks | Time | Tokens scanned |
|---|---:|---:|---:|
| Demo (5,000 blocks) | 5K | ~5s | 1-3 |
| Bounded (50,000 blocks) | 50K | ~32s | 5-15 |
| Full mainnet | 9.6M | ~3 min | 100-500+ |

The bottleneck is `eth_getLogs` round-trips (1 RPC call per 1000 blocks). The candidate-fetch step is parallel and fast.

## Roadmap

- [ ] Add creator-address lookup via the contract creation tx
- [ ] Add `eth_getCode` filter to skip non-ERC-20 contracts (some NFTs and staking pools emit Transfer but have no `symbol()`)
- [ ] Atlantic testnet support (RPC already wired)
- [ ] Live demo on GitHub Pages
