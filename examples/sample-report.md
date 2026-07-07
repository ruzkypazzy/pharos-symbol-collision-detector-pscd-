# PSCD Sample Reports

This file shows real example outputs from both surfaces of PSCD.

---

## 1. Off-chain scanner — COLLISION

A real run against Pharos Pacific mainnet in the block range
`9,596,769 → 9,606,769`, captured for documentation.

### Command

```bash
bash scripts/check.sh USDC --from-block 9596769 --to-block 9606769 --format json
```

### Output

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

### What to do

- **If you control this contract:** you already have a collision. Rename your token before mainnet launch.
- **If you don't:** this is an impersonator. Do not interact with it; report it via pharosscan.
- **If you control none:** pick a different symbol. Common substitutes: append a suffix (e.g. `USDC2`, `USDCX`).

---

## 2. Off-chain scanner — CLEAR

A nonsense symbol with no collisions.

### Command

```bash
bash scripts/check.sh ZZPSCDTEST --max-blocks 5000 --format md
```

### Output

```markdown
# PSCD -- Pharos Symbol Collision Detector

**Verdict:** ✅ CLEAR

No token on mainnet uses the symbol 'ZZPSCDTEST' in the scanned range.

## Inputs

- **Network:** mainnet (chain 1672)
- **Candidate symbol:** `ZZPSCDTEST` (normalized: `zzpscdtest`)
- **Block range:** 11758597 → 11763597
- **Tokens seen in range:** 2

## Result

No token on **mainnet** uses the symbol `ZZPSCDTEST` within the scanned block range.

A CLEAR result is a positive signal: the symbol you want to launch is not
currently minted on Pharos within the scanned range.
```

---

## 3. On-chain registry — empty claim

### Command

```bash
bash scripts/query_registry.sh SKP --network mainnet
```

### Output

```json
{
  "network": "mainnet",
  "registryAddress": "0xYourRegistryAddress",
  "candidate": "SKP",
  "normalized": "skp",
  "symbolHash": "0x...",
  "explorer": "https://www.pharosscan.xyz/address/0xYourRegistryAddress",
  "claimed": false
}
```

---

## 4. On-chain registry — active claim

### Command

```bash
bash scripts/query_registry.sh USDC --network mainnet
```

### Output

```json
{
  "network": "mainnet",
  "registryAddress": "0xYourRegistryAddress",
  "candidate": "USDC",
  "normalized": "usdc",
  "symbolHash": "0x...",
  "explorer": "https://www.pharosscan.xyz/address/0xYourRegistryAddress",
  "claimed": true,
  "claimer": "0xabcdef...",
  "deposit_wei": "1000000000000000",
  "timestamp": 1778000000,
  "blockNumber": 11000123,
  "projectURI": "https://myproject.example",
  "active": true
}
```

---

## 5. Combined safety check — recommended pattern

Before launching `USDC-PROJ` on Pharos:

```bash
SYMBOL=USDC-PROJ

# Off-chain: any existing ERC-20 using this symbol?
bash scripts/check.sh $SYMBOL --max-blocks 100000 --format json
# => {"verdict":"CLEAR", ...}

# On-chain: any active claim?
bash scripts/query_registry.sh $SYMBOL --network mainnet
# => {"claimed":false, ...}

# Both clear — file your claim to lock in intent
bash scripts/register_symbol.sh $SYMBOL \
  --network mainnet \
  --project-uri "https://myproject.example" \
  --value 0.001ether
# => {"txHash":"0x...", "claimHash":"0x..."}
```

The agent's reply to the user:

> ✅ Off-chain scanner says CLEAR (no ERC-20 on Pharos mainnet uses `USDC-PROJ` in the last 100K blocks). Registry says NOT CLAIMED. Safe to launch. Optionally file an on-chain claim via `register_symbol.sh` to record your intent.