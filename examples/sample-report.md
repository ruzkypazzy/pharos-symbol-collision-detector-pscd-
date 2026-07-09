# PSCD Sample Reports

This file shows real example outputs from the off-chain scanner. Every
example is a `bash scripts/check.sh` invocation against the public Pharos
RPC — no contract, no private key, no on-chain registry.

**Network:** Pharos Pacific mainnet (chain 1672), RPC `https://rpc.pharos.xyz`

---

## 1. CLEAR — a nonsense symbol with no collisions

```
User: "Is `ZZPSCDTEST` safe to launch on Pharos?"
```

### Command

```bash
bash scripts/check.sh ZZPSCDTEST --network mainnet
```

### Output (excerpt)

```markdown
# Symbol Collision Report: ZZPSCDTEST

- Network:    Pharos Pacific mainnet (chain 1672)
- RPC:        https://rpc.pharos.xyz
- Range:      blocks 0 → 11,978,422
- Tokens seen: 8,723
- Verdict:    **CLEAR**
- Collisions: 0

## Result

No ERC-20 on Pharos Pacific mainnet uses the symbol `ZZPSCDTEST`. The
symbol appears to be safe to launch.
```

---

## 2. COLLISION — `USDC` is already taken

```
User: "Is `USDC` safe to launch on Pharos?"
```

### Command

```bash
bash scripts/check.sh USDC --network mainnet
```

### Output (excerpt)

```markdown
# Symbol Collision Report: USDC

- Network:    Pharos Pacific mainnet (chain 1672)
- RPC:        https://rpc.pharos.xyz
- Range:      blocks 0 → 11,978,422
- Tokens seen: 8,723
- Verdict:    **COLLISION**
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

USDC is already in use on Pharos Pacific mainnet. Do not deploy a new
ERC-20 with the ticker USDC — wallets and explorers will display both
identically and end users will be unable to distinguish them. Pick a
different symbol: `USDC2`, `USDCX`, `USDC-PROJ`, etc.
```

### Same query as JSON

```bash
bash scripts/check.sh USDC --network mainnet --format json
```

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

---

## 3. COLLISION — `SUP` (a low-cap token with 1 holder)

```
User: "Is `SUP` taken on Pharos?"
```

### Command

```bash
bash scripts/check.sh SUP --network mainnet
```

### Output (excerpt)

```markdown
# Symbol Collision Report: SUP

- Network:    Pharos Pacific mainnet (chain 1672)
- RPC:        https://rpc.pharos.xyz
- Range:      blocks 0 → 11,978,422
- Tokens seen: 8,723
- Verdict:    **COLLISION**
- Collisions: 1

## COLLISION 1/1

| Field | Value |
|---|---|
| Address | 0x4c70919472b8fe53924fada6a562cd95089631b2 |
| Symbol | SUP |
| Name | SHUTUP |
| Decimals | 18 |
| Total supply | 100,000,000 |
| Holders | 1 |
| Explorer | https://www.pharosscan.xyz/token/0x4c70919472b8fe53924fada6a562cd95089631b2 |

## Recommendation

SUP is already in use on Pharos Pacific mainnet. The existing contract
(`SHUTUP`) has 1 holder and 100M total supply — it may be a personal or
test deployment, but a competing ERC-20 with the same ticker will be
visually indistinguishable in wallets and explorers. Pick a different
symbol before launching.
```

This is the canonical case where PSCD earns its keep: even an obscure
"1-holder" token with a non-matching name (`SHUTUP` vs `SUP`) is detected
and reported, with explorer link + recommendations.

---

## 4. Bounded scan — last 50,000 blocks

```
User: "Has anyone launched a token called `NEWCOIN` in the last 50k blocks?"
```

### Command

```bash
bash scripts/check.sh NEWCOIN --network mainnet --max-blocks 50000
```

### Output (excerpt)

```markdown
# Symbol Collision Report: NEWCOIN

- Network:    Pharos Pacific mainnet (chain 1672)
- RPC:        https://rpc.pharos.xyz
- Range:      blocks 11,928,422 → 11,978,422 (last 50,000)
- Tokens seen: 1,234
- Verdict:    **CLEAR**
- Collisions: 0

## Result

No ERC-20 in the last 50,000 blocks uses the symbol `NEWCOIN`. Note:
this is a bounded scan; tokens deployed before block 11,928,422 are not
included. Run a full-chain scan to be exhaustive.
```

---

## 5. Testnet check

```
User: "I want to test launch `MYTKN` on testnet. Is it free?"
```

### Command

```bash
bash scripts/check.sh MYTKN --network testnet
```

The script auto-resolves to the Atlantic testnet RPC
(`https://atlantic.dplabs-internal.com`) and chain ID 688689. Same
algorithm, just a different chain.

---

## 6. Recent deployment history

```
User: "What has launched on Pharos in the last 100k blocks?"
```

### Command

```bash
bash scripts/registry_history.sh --network mainnet --since-block 11878422
```

### Output (excerpt)

```text
TICKER                          FIRST_BLOCK    COUNT    SAMPLE
USDC                            11234567       1        0xc879c0...
SUP                             11850158       1        0x4c7091...
PROS                            11000000       1        0x52c48d...
DLP                             11700000+      5        0x5c8367...
UNI-V2                          11800000+      2        0xea3871...
... (8,723 rows total)
```

Useful for "show me what just launched" without checking each one
individually.
