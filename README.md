# Pharos Symbol Collision Detector (PSCD)

> Cast-only Skill: check, file, and release symbol claims on Pharos mainnet
> through a deployed `SymbolRegistry` contract. No bash scripts, no shell
> execution — every operation is a direct `cast` invocation.

[![solidity](https://img.shields.io/badge/contract-Solidity%200.8.24-blue)]()
[![license](https://img.shields.io/badge/license-MIT-green)]()
[![pharos](https://img.shields.io/badge/network-Pharos%20mainnet-blueviolet)]()
[![ai-agent](https://img.shields.io/badge/callable%20by-AI%20agent-purple)]()
[![binaries](https://img.shields.io/badge/requires-only%20cast-orange)]()

## What is this?

PSCD is a Pharos Skill designed to be packaged as a **Service Agent** on
[Anvita Flow](https://flow.anvita.xyz). It exposes a deployed
`SymbolRegistry` Solidity contract on Pharos Pacific mainnet (chain 1672) that
lets developers record a refundable PHRS/PROS deposit claim for a token
symbol and check whether anyone has already claimed it.

**Deployed contract:**
```
SymbolRegistry = 0x6A9Eb713a8055d6ee46aD01641021255f62E6190
```
[View on PharosScan](https://www.pharosscan.xyz/address/0x6A9Eb713a8055d6ee46aD01641021255f62E6190)

**The Skill is intentionally a thin wrapper around `cast` calls.** Every operation
is a single direct invocation — no bash scripts, no scripts/ directory mounting,
no shell execution required. This makes it compatible with hosted AI agent
runtimes that only expose the `cast` binary (like Anvita Flow's hosted runtime).

## Operations

All operations are single `cast` calls against the deployed contract:

### Read operations (no private key required)

```bash
RPC=https://rpc.pharos.xyz
REG=0x6A9Eb713a8055d6ee46aD01641021255f62E6190

# Check if a symbol has an active claim
cast call $REG "isClaimed(string)(bool)" "SKP" --rpc-url $RPC
# => true / false

# Get the full claim record (claimer, deposit, timestamp, block, URI, active)
cast call $REG "getClaim(string)((address,uint256,uint64,uint64,string,bool))" "SKP" --rpc-url $RPC
# => (0xAddress, 1000000000000000, 1783488188, 11850158, "https://...", true)

# Count active claims by an address
cast call $REG "activeClaimCountOf(address)(uint256)" "0xADDRESS" --rpc-url $RPC
# => uint256

# Total PHRS held by the contract (sum of active deposits)
cast call $REG "totalHeld()(uint256)" --rpc-url $RPC
# => uint256 (in wei)
```

### Write operations (require `$PRIVATE_KEY`)

```bash
RPC=https://rpc.pharos.xyz
REG=0x6A9Eb713a8055d6ee46aD01641021255f62E6190

# File a claim with a refundable 0.001 PHRS/PROS deposit
cast send $REG "register(string,string)" "MYTOK" "https://myproj.example" \
  --value 0.001ether \
  --private-key $PRIVATE_KEY \
  --rpc-url $RPC

# Release your claim and refund the deposit in full
cast send $REG "release(string)" "MYTOK" \
  --private-key $PRIVATE_KEY \
  --rpc-url $RPC

# Owner only: pause new registrations
cast send $REG "pause()" --private-key $PRIVATE_KEY --rpc-url $RPC

# Owner only: unpause
cast send $REG "unpause()" --private-key $PRIVATE_KEY --rpc-url $RPC
```

## Installation

The only requirement is `cast` from Foundry:

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

That's it. No bash scripts to clone. No Python. No jq.

For write operations you also need a Pharos wallet with native PHRS (testnet) or PROS (mainnet) for gas + the 0.001 refundable deposit.

## Networks

| Network | Chain ID | RPC | Contract |
|---|---:|---|---|
| Pacific mainnet | 1672 | `https://rpc.pharos.xyz` | `0x6A9Eb713a8055d6ee46aD01641021255f62E6190` (deployed) |
| Atlantic testnet | 688689 | `https://atlantic.dplabs-internal.com` | (not yet deployed) |

The deployed contract address is also recorded in `assets/networks.json`.

## As an AI agent (Service Agent on Anvita Flow)

This Skill is meant to be hosted on Anvita Flow as a Service Agent. The
Steward Agent in Anvita On discovers PSCD via its `SKILL.md` Capability
Index and invokes it like any other Service Agent.

Because every operation is a direct `cast` invocation, the Steward Agent
can run it without needing to mount any bash scripts or install any toolchains
beyond `cast`, which is already pre-installed in the Anvita Flow hosted runtime.

Example invocation from a Steward Agent:

```
User: "I want to launch a token called SKP on Pharos. Is it safe?"
Steward Agent: invokes Pharos Symbol Collision Detector Service Agent
  → cast call 0x6A9Eb713... "isClaimed(string)(bool)" "SKP" --rpc-url https://rpc.pharos.xyz
Agent: "SKP is already claimed on Pharos. Active claimer is 0xCC06...
  with a 0.001 PROS deposit, filed at unix 1783488188. Pick a different
  symbol (e.g. SKP2, SKPX, SKP-PROJ) before launching."
```

See `SKILL.md` for the Capability Index and `references/registry.md` for the
structured cast-command reference.

## Tests

### Smart contract (forge)

```bash
forge build       # compile
forge test        # 14 unit tests
```

### Bash smoke (offline)

```bash
bash tests/test_check_smoke.sh
```

Tests cover: deploy helper `--help`, missing args, bad network, reversed
block range, invalid numeric flags, bad format, and JSON schema validation
of `assets/networks.json`.

## Repository layout

```
.
├── SKILL.md                          # Agent entry point + cast-only Capability Index
├── README.md                         # This file
├── foundry.toml                      # Forge config
├── foundry.lock
├── LICENSE                           # MIT
├── assets/
│   ├── contracts/
│   │   └── SymbolRegistry.sol        # Solidity source (deployed at 0x6A9Eb713...)
│   └── networks.json                 # RPC + chain config + contract addresses
├── references/
│   ├── registry.md                   # Cast-command reference for every operation
│   └── methodology.md                # Detection algorithm + design notes
├── scripts/
│   └── deploy_registry.sh            # Optional: forge-based one-time deploy helper
├── tests/
│   ├── test_check_smoke.sh           # Offline smoke tests
│   └── SymbolRegistry.t.sol          # 14 forge unit tests
└── examples/
    └── sample-report.md              # Example cast invocations and outputs
```

## Limitations

- **No off-chain chain scan in this Skill version.** This Skill is scoped to the on-chain registry. For off-chain scanning of all ERC-20s on Pharos, use a separate indexer or block explorer.
- **No ERC-721 / ERC-1155 NFT collection support.**
- **Symbol normalization is ASCII upper-case + whitespace-strip only.** `USDC.e` ≠ `USDC`. Cyrillic homoglyphs not detected.
- **The contract has no proxy/upgrade.** Code on mainnet is final.

## License

MIT — see `LICENSE`.