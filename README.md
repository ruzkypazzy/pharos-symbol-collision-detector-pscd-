# Pharos Symbol Collision Detector (PSCD)

> Pre-launch, name-collision detection for ERC-20 token symbols on Pharos.
> Pure off-chain scanner — bash + python3 + cast/curl against the public
> Pharos RPC. No on-chain contract, no private key, no gas.

[![license](https://img.shields.io/badge/license-MIT-green)]()
[![pharos](https://img.shields.io/badge/network-Pharos%20mainnet-blueviolet)]()
[![ai-agent](https://img.shields.io/badge/callable%20by-AI%20agent-purple)]()
[![binaries](https://img.shields.io/badge/requires-bash%20%7C%20python3%20%7C%20curl-orange)]()

## What is this?

PSCD is a Pharos Skill designed to be packaged as a **Service Agent** on
[Anvita Flow](https://flow.anvita.xyz). It walks the Pharos Pacific mainnet
or Atlantic testnet for ERC-20 contracts whose `symbol()` matches a candidate
ticker, and produces a structured collision report.

**There is no on-chain registry, no Solidity contract, no deploy step.** Every
operation is a bash script that calls the public Pharos JSON-RPC. The
Skill is index-only.

**Networks supported:**

| Network | Chain ID | RPC | Default? |
|---|---:|---|---|
| Pacific mainnet | 1672 | `https://rpc.pharos.xyz` | ✓ |
| Atlantic testnet | 688689 | `https://atlantic.dplabs-internal.com` | |

## Quick start

```bash
# Check if 'USDC' is taken on Pharos mainnet
bash scripts/check.sh USDC --network mainnet

# Check 'SKP' on the last 50,000 blocks only
bash scripts/check.sh SKP --network mainnet --max-blocks 50000

# Check 'USDC' on a custom block range
bash scripts/check.sh USDC --network mainnet --from-block 9000000 --to-block 9050000

# Get the result as JSON (for programmatic consumption)
bash scripts/check.sh USDC --format json

# Run on testnet
bash scripts/check.sh USDC --network testnet

# List every recent ERC-20 deployment, grouped by ticker
bash scripts/registry_history.sh --network mainnet --since-block 11700000
```

## Installation

The only requirement is `bash` (already pre-installed everywhere), `python3`,
and either `cast` (Foundry) or `curl`. All three are pre-installed in the
Anvita Flow hosted runtime.

```bash
# (Optional) Install Foundry for cast
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

`python3` is the only hard requirement; `curl` is the only RPC client needed
(scripts fall back to plain curl JSON-RPC if cast is absent).

## How it works

`check.sh` works in 4 steps:

1. **Get block range** (default: `0` to `latest`, overridable).
2. **Fetch all `Transfer(from=0x0,…)` events** in the range. This is a standard
   index of "new ERC-20 deployments" — every ERC-20 mints its initial supply
   to the deployer with a Transfer from the zero address.
3. **For each candidate token, call `symbol()`** to extract the ticker.
4. **Match against the query** (case-insensitive, normalized). Emit the
   verdict.

**Performance:** 50,000 blocks in ~5s. 100,000 blocks in ~10s. The full
chain (~12M blocks) in ~30 minutes.

`registry_history.sh` does the same scan but emits every ticker, not just
the matching one. Useful for "show me what launched recently."

## Output formats

Three output formats are supported:

- `--format md` (default) — human-readable markdown report
- `--format json` — structured for programmatic consumption
- `--format txt` — terse text

The markdown report includes:

- The verdict (`CLEAR` or `COLLISION`)
- Each colliding token's address, name, decimals, total supply, holder count
- An explorer link for each
- A recommendation (e.g. "pick `USDC2` instead")

See `examples/sample-report.md` for a real example.

## As an AI agent (Service Agent on Anvita Flow)

This Skill is meant to be hosted on Anvita Flow as a Service Agent. The
Steward Agent in Anvita On discovers PSCD via its `SKILL.md` Capability
Index and invokes the bash scripts.

**Pre-installed in the Anvita Flow hosted runtime:**

- `bash` (3.2+)
- `python3` (3.11+)
- `curl` (7+)
- `cast` (Foundry 1.7+)

If the Anvita Flow runtime doesn't have `cast`, the scripts auto-fallback
to plain `curl` JSON-RPC. The Skill works either way.

Example invocation from a Steward Agent:

```
User: "I want to launch a token called USDC on Pharos. Is it safe?"
Steward Agent: invokes Pharos Symbol Collision Detector Service Agent
  → bash scripts/check.sh USDC --network mainnet --format md
Agent: "USDC is already in use on Pharos Pacific mainnet. The existing
  contract is at 0xc879c018db60520f4355c26ed1a6d572cdac1815 with 17,388
  holders and 6,458,898.643751 total supply. Pick a different symbol
  (e.g. USDC2, USDCX, USDC-PROJ) before launching."
```

## Tests

### Smoke test (offline, no RPC calls)

```bash
bash tests/test_check_smoke.sh
```

21 tests covering:

- All argument validation paths (missing symbol, bad network, reversed range, etc.)
- SKILL.md content (no SETUP.md, no stale SymbolRegistry references, mentions off-chain scanner)
- networks.json structure (valid JSON, no stale `contracts` field)
- Required binaries (python3, bash)

## Limitations

- **No ERC-721 / ERC-1155 NFT collection support.**
- **Symbol normalization is ASCII upper-case + whitespace-strip only.** `USDC.e` ≠ `USDC`. Cyrillic homoglyphs not detected.
- **No off-chain impersonator checks** (e.g. Twitter, websites).
- **Tokens that don't implement the standard `symbol()` interface are skipped.**

## Repository layout

```
.
├── SKILL.md                          # Agent entry point + Capability Index
├── README.md                         # This file
├── foundry.toml                      # RPC + chain config
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
│   └── test_check_smoke.sh           # Offline smoke tests (21 cases)
└── examples/
    └── sample-report.md              # Real example invocations and outputs
```

## License

MIT — see `LICENSE`.