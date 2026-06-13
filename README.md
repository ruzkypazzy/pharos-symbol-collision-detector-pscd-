# Pharos Symbol Collision Detector

> Is your token's symbol already taken? Scans Pharos mainnet for ERC-20 mints that share a candidate symbol.

[![foundry](https://img.shields.io/badge/built%20with-Foundry-orange)]()
[![bash](https://img.shields.io/badge/script-bash-blue)]()
[![license](https://img.shields.io/badge/license-MIT-green)]()
[![pharos](https://img.shields.io/badge/network-Pharos-blueviolet)]()
[![ai-agent](https://img.shields.io/badge/callable%20by-AI%20agent-purple)]()

## What it is

This is a **skill built for the Pharos network** — a self-contained, deterministic bash script that runs on top of the [Pharos](https://pharos.network) EVM chains. It is **not** an AI agent itself, and not a chatbot. It is a single bash script that:

- takes input from the caller via CLI flags,
- reads live on-chain data from Pharos via `cast` (Foundry),
- runs its own scoring/heuristic logic in pure bash,
- prints a structured report (text, JSON, or markdown) to stdout.

Scans Pharos Pacific mainnet (chain 1672) for ERC-20 tokens that share a candidate symbol. Returns CLEAR, COLLISION, or EMPTY. Uses Transfer-from-zero mint events to discover token deployments, then queries each token's symbol() / name() / decimals() via eth_call.

## Use it from an AI agent

This skill is designed to be **called by an AI agent** (a Claude Code / Codex / Cursor agent, the Pharos Agent Center, or any custom LLM agent). The agent reads `SKILL.md` to discover the skill's flags, fills them in based on the user's request, and runs the bash script in its sandbox. The agent's job is just to translate "score this wallet for MEV risk" into `bash scripts/detect.sh --wallet 0x... --blocks 5000`.

Typical agent-side flow:

```text
User -> Agent: "Score wallet 0xabc... for MEV exposure on Pharos"
Agent -> looks up SKILL.md for Pharos Symbol Collision Detector
Agent -> picks the right flag combo: --SYMBOL 0xabc... 
Agent -> runs: bash scripts/check.sh USDC
Agent -> reads the output, presents it to the user in a friendly form
```

The script prints structured output to stdout and human-readable progress to stderr, so the agent can parse the stdout cleanly (with `jq`) without being polluted by progress messages.

## Install

You need three things: **Foundry** (for `cast`), **jq** (for JSON pretty-printing), and **git** (to clone the repo).

```bash
# 1. Install Foundry (gives you cast, forge, anvil, chisel)
curl -L https://foundry.paradigm.xyz | bash
foundryup
# Reload your shell so the new commands are on PATH:
exec $SHELL
cast --version   # should print 1.x or higher

# 2. Install jq (optional — only needed for --format json pretty-printing)
# macOS:   brew install jq
# Ubuntu:  sudo apt-get install -y jq
# Alpine:  apk add jq
jq --version

# 3. Clone this repo
git clone https://github.com/ruzkypazzy/Pharos-Symbol-Collision-Detector-PSCD-.git
cd Pharos-Symbol-Collision-Detector-PSCD-
chmod +x scripts/*.sh tests/*.sh
```

## Quick test (30 seconds, no API keys needed)

```bash
bash scripts/check.sh --demo
```

The first time you run this, the script may take a few seconds to fetch block data over RPC. Subsequent runs are cached by the RPC provider.

## Usage

```bash
# Check if 'SKP' is already used on mainnet (last 50,000 blocks)
bash scripts/check.sh SKP --network mainnet --max-blocks 50000

# Scan a specific block range
bash scripts/check.sh USDC --from-block 9000000 --to-block 9880000

# Run the demo (last 50K blocks, no symbol)
bash scripts/check.sh --demo
```

### All flags

```
SYMBOL --network mainnet|testnet --max-blocks N --from-block N --to-block N --format md|json|txt --workers N
```

## Networks

The skill is built to run against the Pharos EVM chains. The chain config is stored in `assets/networks.json` and read at startup — no hardcoded URLs in the script.

| Network | Chain ID | RPC URL | Default |
|---|---:|---|:---:|
| mainnet (Pacific Ocean) | 1672 | `https://rpc.pharos.xyz` | ✓ |
| atlantic-testnet | 688689 | `https://atlantic.dplabs-internal.com` |  |

The script defaults to mainnet. Pass `--network testnet` to use the testnet instead. You can also override the RPC URL directly with `--rpc-url https://your-rpc.example.com`.

## Set it up in an AI agent

Three install paths for any AI agent that wants to call this skill.

### Path A — Pharos Agent Center (for the official Pharos LLM agent)

The Pharos Agent Center is the official agent runtime for the Pharos network. It reads `SKILL.md` from any skill repo to discover capabilities, dependencies, and required flags.

1. **Copy the skill into the Agent Center's skills directory:**
   ```bash
   # After cloning this repo:
   cp -r scripts assets SKILL.md README.md foundry.toml LICENSE \
     ~/.pharos/agent-center/skills/Pharos-Symbol-Collision-Detector-PSCD-/
   ```

2. **Reload the Agent Center's skill registry:**
   ```bash
   pharos-agent reload-skills
   # or restart the Agent Center daemon
   ```

3. **Invoke from the agent's chat UI** (or via the Agent Center's CLI / API):
   ```text
   User: "Is symbol USDC already used on Pharos"
   Agent Center: loads Pharos Symbol Collision Detector, runs:
     bash ~/.pharos/agent-center/skills/Pharos-Symbol-Collision-Detector-PSCD-/scripts/check.sh USDC --network mainnet
   ```

### Path B — `npx skills add` (for Claude Code, Cursor, Codex, generic MCP agents)

```bash
npx skills add https://github.com/ruzkypazzy/Pharos-Symbol-Collision-Detector-PSCD- --skill Pharos-Symbol-Collision-Detector-PSCD-
```

The agent's `skills` plugin will discover the SKILL.md, surface the skill in its tool list, and let the LLM pick the right flags when the user asks.

### Path C — Manual copy (any agent that reads `~/.claude/skills/`)

```bash
mkdir -p ~/.claude/skills/Pharos-Symbol-Collision-Detector-PSCD-
cp -r scripts assets SKILL.md README.md foundry.toml LICENSE ~/.claude/skills/Pharos-Symbol-Collision-Detector-PSCD-/
```

Restart the agent. It will pick up the new skill on next tool discovery.

### Path D — Direct invocation (shell agents, cron jobs, CI pipelines)

```bash
bash scripts/check.sh --demo
```

No agent needed — just shell + Foundry.

### What the agent says to invoke this skill

| Caller says | Script invocation |
|---|---|
| Check if symbol `USDC` is already used on Pharos | `bash scripts/check.sh USDC --max-blocks 50000` |
| Scan last 50K Pharos blocks for symbol `SKP` | `bash scripts/check.sh SKP --max-blocks 50000 --network mainnet` |
| Run the symbol-collision demo | `bash scripts/check.sh --demo` |
| "Run the demo" | `bash scripts/check.sh --demo` |

The agent should read the script's `--help` output to discover all available flags, then build the right command line for the user's request.

## Framework

| Layer | Tech | Purpose |
|---|---|---|
| Engine | **bash 4+** | Script host (single file per skill) |
| RPC client | **Foundry / cast** | All chain reads — block, tx, receipt, eth_call, eth_getLogs |
| Chain config | **JSON** (`assets/networks.json`) | Network endpoints + chain IDs |
| Data format | **JSON** | Cast's native output; jq used only for pretty-printing |
| Runtime | Any POSIX shell, Foundry 1.0+ | Tested on Linux + macOS |

## Dependencies

**Required:**
- [Foundry](https://getfoundry.sh) (gives you `cast`, `forge`, `anvil`)
- `bash` 4+ (preinstalled on macOS, Ubuntu 20+, most Linux)

**Optional:**
- `jq` — only required if you pass `--format json` for pretty-printed output
- `git` — only required if you're cloning the repo (you already have it)

## Tests

Each repo ships with a bash smoke test that verifies:
1. `--help` works (no cast required)
2. The script prints a useful error when args are missing
3. The script prints a clear error when cast is not installed
4. The script rejects unknown flags and bad network names
5. (If applicable) `from-block > to-block` is detected and rejected

```bash
bash tests/test_*.sh
```

The test runs offline — no RPC calls, no API keys. It exercises the help text, arg parser, and error paths.

## Repository layout

```
Pharos-Symbol-Collision-Detector-PSCD-/
├── SKILL.md              # Skill contract (Capability Index, Error Handling, Security Reminders)
├── README.md             # This file
├── foundry.toml          # Minimal config so cast can find the project root
├── LICENSE               # MIT
├── assets/
│   └── networks.json     # mainnet + testnet chain config (read by every script)
├── scripts/
│   └── check.sh          # The single bash script that does the work
└── tests/
    └── test_*.sh         # Offline smoke test (no cast required)
```

## License

MIT — see `LICENSE`.

---
