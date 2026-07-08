# Off-Chain Symbol Scanner

> The off-chain scanner (`scripts/check.sh`) walks Pharos mainnet (or testnet)
> via Foundry/cast to find ERC-20 tokens whose on-chain `symbol()` matches a
> candidate. This is the read-only counterpart to the on-chain
> `SymbolRegistry` (see `references/registry.md`).
>
> **Network Configuration**: RPC URLs and chain IDs are read from
> `assets/networks.json`. The scanner defaults to `mainnet` (Pacific, chain
> 1672) and falls back to `atlantic-testnet` (chain 688689) with `--network testnet`.
>
> **No private key required** — the scanner is purely read-only.
>
> **Range limit**: the Pharos public RPC rejects `eth_getLogs` calls covering
> more than 1,000 blocks. The script auto-batches into 1,000-block windows.

---

## Scan a Symbol for Collisions

### Overview
Walks a block range, collects every ERC-20 contract that emitted a
Transfer-from-zero event, queries `symbol()` on each, and reports any match
against the candidate.

### Command Template

```bash
bash scripts/check.sh SYMBOL [options]
```

### Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `SYMBOL` | string | Yes | Candidate symbol to check (1–32 chars). Case-insensitive, whitespace-stripped. |
| `--network` | string | No | `mainnet` (default) or `testnet` |
| `--max-blocks N` | int | No | Scan only the last N most-recent blocks (overrides `--from-block`/`--to-block`) |
| `--from-block N` | int | No | Explicit start block (default: 0) |
| `--to-block N` | int | No | Explicit end block (default: latest) |
| `--step N` | int | No | Blocks per `eth_getLogs` batch (default 1000, capped at 1000 by the RPC) |
| `--workers N` | int | No | Parallel `eth_call` workers for symbol/name/decimals lookup (default 6) |
| `--format FMT` | string | No | Output format: `md` (default), `json`, `txt` |
| `--quiet` | flag | No | Suppress progress on stderr |
| `--demo` | flag | No | Quick demo: `USDC` on last 5,000 blocks |
| `-h`, `--help` | flag | No | Show help |

### Output Parsing

JSON output (`--format json`):

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

`verdict` is one of:

| Verdict | Meaning |
|---|---|
| `CLEAR` | `tokens_seen > 0` and zero collisions in the range |
| `COLLISION` | One or more collisions found |
| `EMPTY` | Candidate symbol was empty / whitespace-only (script rejects before running) |

### Error Handling

| Error | Cause | Fix |
|---|---|---|
| `cast: command not found` | Foundry not installed | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| `--max-blocks` and `--from-block` both given | Mutually exclusive | Pass one or the other |
| `--format yaml` (or any value other than md/json/txt) | Invalid format | Use one of `md`, `json`, `txt` |
| `--max-blocks abc` | Non-numeric value | Pass a positive integer |
| `--from-block 100 --to-block 50` | Reversed range | Swap them so `from <= to` |
| `unknown network 'foo'` | Network not in `assets/networks.json` | Use `mainnet` or `testnet`, or add the network to the JSON |
| RPC error | Pharos RPC unreachable / rate-limited | Retry, or supply `--rpc-url` to a paid RPC |

> **Agent Guidelines**:
> 1. **No private key required** for this command — it's read-only.
> 2. For a thorough pre-launch check, use `--max-blocks 100000` (≈56 hours on Pharos's 2s blocks) or wider.
> 3. For fast interactive demos, use `--demo` (≈5s, last 5K blocks).
> 4. Always use `--format json` for agent-to-agent integration. Use `--format md` only for human-readable display.
> 5. `--quiet` silences stderr progress; keep stdout (the JSON) intact. Agents should always use `--quiet` to avoid polluting downstream parsers.

---

## Detection Algorithm (Internal)

This section is for **understanding the result**, not for invoking the script.

### Step 1 — Candidate token discovery
Walk the block range in 1,000-block windows. For each window, call `eth_getLogs` with:
- `topic[0]` = `keccak256("Transfer(address,address,uint256)")` = `0xddf252ad...`
- `topic[1]` = `0x000…0` (zero address) — `from` field of a Transfer-from-zero, which only happens at token mint

Filter server-side to just mint events. Collect unique emitting contracts.

### Step 2 — Symbol/name/decimals lookup
For each unique token, call `cast call <addr> "symbol()(string)"` (and `name()`, `decimals()`) in parallel using `xargs -P`. The script emits one row per token, then filters to collisions in pure bash (case-insensitive, whitespace-stripped).

### Step 3 — Normalization
Both the candidate and the on-chain `symbol()` are normalized before comparison:
- `tr '[:upper:]' '[:lower:]'` for case
- `tr -d '[:space:]'` for whitespace

So `usdc`, `USDC`, and ` USDC ` all match the same slot.

### Step 4 — Verdict
| Verdict | Condition |
|---|---|
| `CLEAR` | `tokens_seen > 0` AND `collisions == 0` |
| `COLLISION` | `collisions >= 1` |

A `CLEAR` result is a positive signal — no token in the scanned range uses the symbol. It is **not** a guarantee of uniqueness across the entire chain.

### Limitations

- **Tokens not detected by the scanner**:
  - Factory-created tokens that don't emit their own `Transfer` event (e.g. tokens created via a factory's `create2` won't be the `address` field of the log)
  - Tokens deployed without a public mint (no Transfer-from-zero event)
  - Upgradeable proxy tokens (the proxy address will be found, but the implementation is what the explorer shows)
  - Tokens with no `symbol()` function (`eth_call` reverts and the address is skipped)
- **Symbol comparison is exact-match, ASCII only.** `USDC.e` ≠ `USDC`. `USDC` ≠ `USDС` (Cyrillic). Whitespace inside the symbol is not stripped.
- **CLEAR is range-bounded.** Scanning only the last 5K blocks can miss old tokens. For pre-launch confidence, use `--max-blocks 100000` or scan the full chain.
- **The Pharos public RPC has a 1,000-block limit per `eth_getLogs` call** — the script auto-batches, but a paid RPC is recommended for very wide ranges.

### What's NOT covered

- ❌ ERC-721 / ERC-1155 NFT collections (Transfer event signature differs)
- ❌ Off-chain impersonators (Twitter handles, websites)
- ❌ Whether a collision is a scam or a legitimate bridged token (you must verify the source on PharosScan)

For on-chain claim recording (deposit + timestamp + intent), use `references/registry.md` instead.