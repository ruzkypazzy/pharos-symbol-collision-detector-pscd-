# PSCD Methodology

## How symbol collisions are detected

### 1. Candidate token discovery

PSCD walks the Pharos Pacific mainnet block range `[from_block, to_block]` in batches of 1,000 blocks. For each batch, it calls:

```json
{
  "method": "eth_getLogs",
  "params": [{
    "fromBlock": "0x...",
    "toBlock":   "0x...",
    "topics": [
      "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
      "0x0000000000000000000000000000000000000000000000000000000000000000"
    ]
  }]
}
```

- `topic[0]` = keccak256 of `Transfer(address,address,uint256)` — the canonical ERC-20 event
- `topic[1]` = `0x000…0` (zero address) — the `from` field of a Transfer-from-zero, which only happens at token mint

This filters server-side to just mint events. Each log's `address` field is the emitting contract (i.e. the token). We collect the unique set across all batches.

### 2. Symbol/name/decimals lookup

For each unique token address, three parallel `eth_call` requests:

| Function | Selector | Returns |
|---|---|---|
| `symbol()` | `0x95d89b41` | string |
| `name()`   | `0x06fdde03` | string |
| `decimals()` | `0x313ce567` | uint8 |

The 32-byte ABI-encoded return values are decoded in the Python client:

- **string** = `[offset(32)][length(32)][bytes(length)]`
- **uint8** = `0x00…XX` (last byte is the value)

### 3. Normalization

Both the candidate and the on-chain `symbol()` are normalized before comparison:

```python
normalize(s) = s.strip().upper()
```

This means:
- `"usdc"` and `"USDC"` are identical
- `"  USDC  "` and `"USDC"` are identical
- Unicode case folding is NOT performed (Python's `.upper()` handles ASCII only by default; we keep it simple to avoid locale issues)

### 4. Matching

For each normalized on-chain symbol, compare against the normalized candidate. If equal, that token is a **collision candidate**. All collisions are returned.

### 5. Verdict

| Verdict | When |
|---|---|
| `CLEAR` | `tokens_seen > 0` and zero matches |
| `COLLISION` | one or more matches |
| `EMPTY` | candidate is empty / whitespace-only |

## Limitations

### Tokens not detected

- **Factory-created tokens** (e.g. Uniswap-V2-style pair tokens, custom launchpads) that don't emit their own `Transfer` event won't be found. They appear as nested logs inside the parent factory's logs but with the factory as the emitter.
- **Upgradeable proxy tokens** — the proxy's address emits the events, not the implementation. PSCD will find the proxy address, and `symbol()` will be called on the proxy (which delegates to the implementation), so it still works. But the *implementation* contract is what the explorer shows; the user should be aware that the proxy address is the correct one.
- **Tokens deployed before the first scanned block** — out of scope, by design.
- **Tokens with no `symbol()` function** (e.g. some NFTs) — `eth_call` reverts, the contract is skipped, no error reported in the final output.

### Symbol comparison limitations

- **Exact match only.** `USDC.e` vs `USDC` are different. `USDC` vs `USDс` (Cyrillic с) are different (whitelisted Unicode is not handled).
- **Case folding is ASCII-only.** Some Latin-extended letters may not match across cases.
- **Whitespace inside the symbol** is not stripped (e.g. `"US DC"` would not match `"USDC"`).

### Performance

| Range | RPC calls | Wall time |
|---|---:|---:|
| 1,000 blocks | ~1 | ~1s |
| 10,000 blocks | ~10 | ~10s |
| 100,000 blocks | ~100 | ~100s |
| Full mainnet (~9.6M blocks) | ~9,600 | ~3 min |

For each unique token, 3 more `eth_call` requests are made (parallelized, 6 workers). On Pharos mainnet, ~5-50 unique tokens are seen per 50k blocks (very few tokens are deployed compared to e.g. Ethereum).

## Future improvements

- **`eth_getCode` pre-filter:** skip contracts that don't have any bytecode in the standard ERC-20 range. Saves a few `eth_call` reverts.
- **Contract creation receipts:** also walk `eth_getBlockByNumber(n, true)` for `transactions.to == null` and grab `receipt.contractAddress` from those. This catches tokens deployed without a public mint.
- **Bridge detection:** cross-reference collision addresses against known bridge contracts (LayerZero, Wormhole, etc.) and tag them.
- **Time-of-deployment:** show when each collision was first deployed, so the user can see if the collision predates their own project.
