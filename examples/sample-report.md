# Sample Report — PSCD

This is a real run against Pharos Pacific mainnet, captured 2026-06-07. The
script was invoked with `bash scripts/check.sh USDC --max-blocks 10000` and
the result was a real collision.

---

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
- **If you control none of these:** pick a different symbol. Common substitutes: append a suffix (e.g. `SKP2`, `SKPX`), or use a more descriptive long form.

---

## A CLEAR case

`bash scripts/check.sh ZZZPSCDTEST --max-blocks 5000` (a nonsense symbol):

**Verdict:** ✅ CLEAR

No token on **Pharos Pacific Ocean Mainnet** uses the symbol `ZZZPSCDTEST` within the scanned block range.
