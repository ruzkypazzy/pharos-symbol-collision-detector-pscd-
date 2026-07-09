# Detection Methodology

This document explains how the Pharos Symbol Collision Detector (PSCD) reasons about ERC-20 symbol collisions, what guarantees it provides, and where its scope ends.

## What PSCD protects against

PSCD is a **pre-launch, name-collision detector** for ERC-20 token symbols on Pharos. The problem it solves:

> Two teams independently choose the same ticker symbol (e.g. "USDC") and deploy ERC-20 contracts on Pharos. End-users cannot tell which is the "real" one. Wallets, explorers, and DEXs all show the symbol legibly, so a malicious deployer can squat an existing brand.

PSCD walks the Pharos public RPC, finds every ERC-20 currently deployed with the candidate symbol, and surfaces a structured collision report so the developer can pick a different symbol before launching.

## What PSCD does NOT protect against

**Important scope boundaries the agent must communicate clearly:**

### 1. PSCD cannot prevent ERC-20 deployment with a conflicting symbol

Any developer can deploy an ERC-20 contract on Pharos using any ticker they choose — including one already in use. PSCD is a **visibility layer**, not a deployment gate. Two ERC-20s with the same symbol can exist on Pharos; PSCD only tells you whether anyone else has already claimed the ticker.

The agent should always phrase results as:

> "`USDC` is already in use on Pharos Pacific mainnet. **This does not prevent you from deploying an ERC-20 with that ticker**, but the existing contract will be publicly visible to anyone who checks before interacting with yours."

### 2. PSCD only sees tokens that follow the standard ERC-20 interface

Tokens that don't implement `symbol()`, or that panic on `symbol()`, or that have a non-standard symbol encoding, are skipped. This is rare but possible — for example, tokens that hide their symbol until after a `reveal()` call.

### 3. No ERC-721 / ERC-1155 NFT collection support

PSCD only walks ERC-20 `Transfer` events. NFT collections use a different event signature (`Transfer` is shared but with indexed token IDs, not values) and are out of scope. The agent should not use PSCD for NFT name checks.

### 4. Symbol normalization is intentional and minimal

`_normalize(string)` does two things:

1. Trims leading and trailing whitespace.
2. Converts all ASCII letters to upper case.

That's it. Specifically **not done**:

- No Unicode NFKC / case-fold (so Cyrillic "А" stays different from Latin "A").
- No dot-tolerance (so `USDC.e` is a different ticker than `USDC`).
- No zero-width-stripping, no emoji removal, no grapheme clustering.

The intent is to handle obvious typo variations (`usdc` vs `USDC`) while still treating visually-distinct variants as separate symbols.

## The `check.sh` algorithm

### Inputs

- `SYMBOL` — the candidate ticker (required, first positional)
- `--network mainnet|testnet` — default: `mainnet`
- `--max-blocks N` — scan only the last N blocks
- `--from-block N` -- `--to-block N` — explicit block range
- `--step N` — RPC batch size (default 1000, max 1000)
- `--workers N` — parallel `eth_call` workers (default 6)
- `--format md|json|txt` — output format (default `md`)
- `--demo` — convenience preset: `USDC` on a small range

### Step 1: Resolve block range

```bash
# Default: 0 to latest
if [ --max-blocks ]: to_block = latest, from_block = latest - N
if [ --from-block --to-block ]: use them directly
```

### Step 2: Fetch `Transfer(from=0x0,...)` events

```bash
# JSON-RPC over HTTPS
curl -X POST $RPC \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"eth_getLogs",
    "params":[{
      "fromBlock":"0x...",
      "toBlock":"0x...",
      "topics":[
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
        "0x0000000000000000000000000000000000000000000000000000000000000000"
      ]
    }]
  }'
```

This emits a `Transfer` from the zero-address whenever an ERC-20 mints the initial supply. This is the standard index used by Etherscan / Pharoscan for their "new tokens" list.

**RPC limit:** Pharos's public RPC rejects `eth_getLogs` requests spanning more than 1,000 blocks. The script auto-batches the range into 1,000-block windows and parallelizes 4 ways via `xargs -P 4`.

### Step 3: Extract token addresses

The `to` field of each `Transfer(from=0x0,...)` event is the new token's address. Deduplicate.

### Step 4: For each candidate, call `symbol()`

```bash
cast call $ADDR "symbol()(string)" --rpc-url $RPC
# or, with curl:
curl -X POST $RPC -d '{"jsonrpc":"2.0","method":"eth_call",
       "params":[{"to":"0x...","data":"0x95d89b41"}, "latest"]}' 
```

`0x95d89b41` is the function selector for `symbol()`.

If the call returns:
- a `string` that matches the query (after normalization) → **CANDIDATE** for collision
- revert / empty / non-string → skip

### Step 5: Enrich the match

For each candidate, also call:
- `name()(string)` — `0x06fdde03`
- `decimals()(uint8)` — `0x313ce567`
- `totalSupply()(uint256)` — `0x18160ddd`

These enrich the report and help the user distinguish the "real" token from imposters.

### Step 6: Emit the verdict

```
verdict = len(collisions) > 0 ? "COLLISION" : "CLEAR"
```

Output is rendered in the chosen format (md/json/txt). For COLLISION, the report includes a per-token table with explorer links and a recommendation to pick a different symbol.

## Performance

| Block range | Approx time | RPC calls |
|---:|---:|---:|
| 1,000 | <1s | 1 batch + N `eth_call`s |
| 10,000 | ~1s | 10 batches + N `eth_call`s |
| 50,000 | ~5s | 50 batches + N `eth_call`s |
| 100,000 | ~10s | 100 batches + N `eth_call`s |
| 1,000,000 | ~2min | 1000 batches + N `eth_call`s |
| Full chain (~12M blocks) | ~30min | 12000 batches + N `eth_call`s |

`N` is the number of `Transfer(from=0x0,...)` events in the range. For Pharos Pacific mainnet, this is currently ~2,500-3,000 per 100,000 blocks.

## The `registry_history.sh` algorithm

Same `Transfer(from=0x0,...)` index, but emits **every** ticker seen in the range, not just the matching one. Output is a per-ticker count + first-seen block + a sample address. Useful for "show me what launched recently on Pharos."

**Use case:** "Has anyone launched a token called `ZKSYNC` on Pharos in the last 30 days?"

```bash
bash scripts/registry_history.sh --network mainnet --since-block 11700000 | head -50
```

## Security model

| Threat | PSCD mitigation |
|---|---|
| Deploying a token with an in-use symbol | Pre-launch visibility report; recommendation to pick a different symbol |
| Hidden symbol (e.g. `symbol()` returns empty initially) | Out of scope — not a security issue, just a deployment pattern |
| Front-running an existing token's brand | No protection — once you deploy, you're on-chain |
| Unicode homoglyph squatting (`UЅDC` vs `USDC`) | Not detected — explicit limitation |

## Future work (not in this Skill version)

- ERC-721 collection name registry
- Multi-chain symbol scanner (Polygon, Base, Ethereum) via cross-chain indexers
- Deeper normalization (Unicode NFKC, dot-tolerance, homoglyph detection)
- An on-chain `SymbolRegistry` contract for first-mover claims with refundable deposits
- Cross-ticker fuzzy matching (Levenshtein, OCR-confusable)