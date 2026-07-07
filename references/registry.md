# SymbolRegistry Operations

> The `SymbolRegistry` contract is the on-chain counterpart to the PSCD
> off-chain scanner. While `scripts/check.sh` discovers ERC-20 mints that
> already use a symbol, `SymbolRegistry` lets a developer file an explicit,
> refundable PHRS/PROS deposit to **claim** a symbol on-chain. Anyone can
> query the registry to see active claims.
>
> **Network Configuration**: RPC URLs and chain IDs are read from
> `assets/networks.json`. Contract addresses per network live under
> `networks[].contracts.SymbolRegistry`. If the address is missing, run
> `scripts/deploy_registry.sh --network <name>` first.
>
> **Private Key Configuration**: All write operations require
> `--private-key $PRIVATE_KEY`. Foundry does NOT auto-read this env var;
> you must always pass it explicitly.
>
> **Deposit**: minimum `0.001 ether` (in the chain's native token).
> Fully refundable by the original claimer via `release()`.

---

## Deploy SymbolRegistry (one-time per network)

### Overview
Deploys `SymbolRegistry.sol` to the specified Pharos network and writes the
resulting address back into `assets/networks.json` so other scripts can find
it. Idempotent: if the address is already configured for that network, the
script exits cleanly.

### Command Template

```bash
bash scripts/deploy_registry.sh --network mainnet|testnet
```

### Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `--network` | string | Yes | `mainnet` (Pacific, chain 1672) or `testnet` (Atlantic, chain 688689) |
| `--rpc-url` | string | No | Override RPC URL (default: from `assets/networks.json`) |
| `--private-key` | string | No | Deployer key (default: `$PRIVATE_KEY` env var) |
| `--force` | flag | No | Redeploy even if already configured |

### Output Parsing

| Field | Description |
|---|---|
| `deployedTo` | Deployed contract address |
| `txHash` | Deployment transaction hash |
| `network` | Network name as configured |

The script updates `assets/networks.json` so the next call to
`register_symbol.sh` or `query_registry.sh` finds the address automatically.

### Error Handling

| Error | Cause | Fix |
|---|---|---|
| `cast: command not found` | Foundry not installed | Run `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| `insufficient funds` | Wallet has no native token | Get faucet PHRS (testnet) or PROS (mainnet) |
| `nonce too low` | Pending tx from same key | Wait for prior tx or use a fresh wallet |
| `SymbolRegistry already configured` | Address exists in `networks.json` | Pass `--force` to redeploy |

> **Agent Guidelines**:
> 1. Confirm the user wants a fresh deploy before running with `--force`.
> 2. Default `defaultNetwork` in `assets/networks.json` is `atlantic-testnet`; switch to mainnet explicitly if the user says so.
> 3. After deploy, verify the contract on PharosScan (Atlantic or Pacific).
> 4. Record the `deployedTo` address and tx hash in your reply.

---

## Register a Symbol Claim

### Overview
Posts a refundable deposit and records an active claim for the candidate
symbol. The candidate is normalized (ASCII upper-case, whitespace stripped)
on-chain, so `usdc`, `USDC`, and ` USDC ` all map to the same claim slot.

### Command Template

```bash
bash scripts/register_symbol.sh SYMBOL \
  --network mainnet|testnet \
  --project-uri "https://yourproject.example" \
  --value 0.001ether
```

### Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `SYMBOL` | string | Yes | The token symbol to claim (1–32 chars). Case-insensitive on-chain. |
| `--network` | string | Yes | `mainnet` or `testnet` |
| `--project-uri` | string | No | Free-form project link. Recorded in the `SymbolRegistered` event. |
| `--value` | string | No | Deposit in native token. Default: `0.001ether`. |
| `--rpc-url` | string | No | Override RPC URL |
| `--private-key` | string | No | Sender key (default: `$PRIVATE_KEY` env var) |

### Output Parsing

| Field | Description |
|---|---|
| `txHash` | Transaction hash |
| `claimHash` | keccak256 of the normalized symbol (the on-chain claim slot) |
| `blockNumber` | Block the claim was registered in |
| `explorer` | PharosScan link to the tx |

### Error Handling

| Error | Cause | Fix |
|---|---|---|
| `BelowMinimumDeposit` (revert) | `--value` < 0.001 ether | Pass `--value 0.001ether` or higher |
| `AlreadyClaimed` (revert) | Symbol has an active claim | Query first with `query_registry.sh`; release if you own it |
| `PausedState` (revert) | Contract is paused by owner | Wait for owner to unpause or contact contract owner |
| `execution reverted` (generic) | Various | Inspect revert reason via `cast 4-byte-decode <selector>` if non-standard |
| `SymbolRegistry not configured for <network>` | Address missing in `networks.json` | Run `deploy_registry.sh --network <network>` first |
| `insufficient funds for gas` | Wallet empty | Top up native token balance |

> **Agent Guidelines**:
> 1. **Complete Write Operation Pre-checks** (see top-level `SKILL.md`):
>    - Confirm `$PRIVATE_KEY` is set
>    - Derive address via `cast wallet address --private-key $PRIVATE_KEY`
>    - Confirm network with the user
>    - Check native balance: `cast balance <deployer> --rpc-url <rpc> --ether`
> 2. Suggest `0.001ether` as the default deposit; allow user to over-deposit if they want to.
> 3. After success, surface the PharosScan tx link to the user.
> 4. Remind the user the deposit is refundable via `release()`.

---

## Query an On-Chain Claim

### Overview
Read-only. Checks whether a symbol has an active claim and returns the full
claim record. Use this **before** registering to avoid `AlreadyClaimed`
reverts.

### Command Template

```bash
bash scripts/query_registry.sh SYMBOL --network mainnet|testnet
```

### Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `SYMBOL` | string | Yes | Symbol to look up (normalized the same way as registration) |
| `--network` | string | Yes | `mainnet` or `testnet` |
| `--rpc-url` | string | No | Override RPC URL |

### Output Parsing

| Field | Type | Description |
|---|---|---|
| `claimed` | bool | True if there's an active claim |
| `claimer` | address | Address that filed the claim |
| `deposit` | string (wei) | Refundable deposit in wei |
| `timestamp` | uint64 | Unix timestamp of registration |
| `blockNumber` | uint64 | Block number of registration |
| `projectURI` | string | User-supplied project URI |
| `active` | bool | Always `true` here (inactive claims are filtered out) |

When `claimed` is false, only `claimed`, `network`, `candidate`, `symbolHash`,
`registryAddress`, and `explorer` are populated.

### Error Handling

| Error | Cause | Fix |
|---|---|---|
| `SymbolRegistry not configured for <network>` | Address missing | Deploy first |
| `execution reverted` | RPC or contract issue | Check explorer; the call is read-only and should not revert |
| Empty response | RPC timeout | Retry; if persistent, try a different RPC URL |

> **Agent Guidelines**:
> 1. This is a read-only call — no private key needed.
> 2. Always run this **before** `register_symbol.sh` to surface existing claims to the user.
> 3. Include the `claimer` address and `projectURI` (if any) in the user-facing reply so they can decide whether to negotiate.

---

## Release a Claim and Refund the Deposit

### Overview
Cancels the caller's active claim and refunds the deposit in full. Only the
original claimer can release their own claim.

### Command Template

```bash
bash scripts/release_symbol.sh SYMBOL --network mainnet|testnet
```

### Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `SYMBOL` | string | Yes | Symbol to release |
| `--network` | string | Yes | `mainnet` or `testnet` |
| `--rpc-url` | string | No | Override RPC URL |
| `--private-key` | string | No | Sender key (default: `$PRIVATE_KEY`) |

### Output Parsing

| Field | Description |
|---|---|
| `txHash` | Release transaction hash |
| `refund` | Amount refunded (in wei and PHRS/PROS) |
| `explorer` | PharosScan link |

### Error Handling

| Error | Cause | Fix |
|---|---|---|
| `NotClaimed` (revert) | No active claim exists for this symbol | Run `query_registry.sh` first |
| `NotClaimer` (revert) | Sender is not the original claimer | Use the wallet that originally registered |
| `PausedState` (revert) | Contract paused | Wait for owner to unpause |
| `TransferFailed` (revert) | Refund send failed (should not happen on Pharos) | Retry; if persistent, contact the contract owner |

> **Agent Guidelines**:
> 1. Always confirm with the user before releasing — the claim is forfeit.
> 2. After success, show the explorer link and the new balance delta.

---

## Query Claim History (Events)

### Overview
Reads the `SymbolRegistered` event log over a block range. Use this to audit
who has claimed what on Pharos over time.

### Command Template

```bash
bash scripts/registry_history.sh --network mainnet|testnet \
  --from-block N --to-block N --format json
```

### Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `--network` | string | Yes | `mainnet` or `testnet` |
| `--from-block` | uint | No | Default: last 100,000 blocks |
| `--to-block` | uint | No | Default: latest |
| `--format` | string | No | `json` (default) or `txt` |

### Output Parsing (JSON)

```json
{
  "network": "mainnet",
  "registryAddress": "0x...",
  "fromBlock": 11000000,
  "toBlock": 11100000,
  "registrations": [
    {
      "symbolHash": "0x...",
      "symbol": "USDC",
      "claimer": "0x...",
      "deposit": "1000000000000000",
      "timestamp": 1778000000,
      "blockNumber": 11000123,
      "projectURI": "https://..."
    }
  ]
}
```

### Error Handling

| Error | Cause | Fix |
|---|---|---|
| `SymbolRegistry not configured` | Address missing | Deploy first |
| RPC timeout on wide range | Public RPC rate limit | Narrow the block range or use a paid RPC |
| Empty `registrations` | No claims in range | Widen the range |

> **Agent Guidelines**:
> 1. Use this for audits: "show all claims filed in the last week."
> 2. Cross-reference `claimer` addresses with PSCD scanner output to see if a claim's owner is also an actual token deployer.

---

## Combined PSCD + Registry Workflow

When a user asks "is `SYMBOL` safe to launch on Pharos?", the agent should
combine both surfaces in one response:

1. **Scan** — `bash scripts/check.sh SYMBOL --max-blocks 100000 --format json`
   → returns existing ERC-20 mints with the symbol
2. **Registry check** — `bash scripts/query_registry.sh SYMBOL --network mainnet`
   → returns any active on-chain claim
3. **Reply**: report both. If scanner says COLLISION → "DO NOT launch this
   symbol, an existing token already uses it." If registry says claimed by
   someone else → "Someone else has already filed a claim; consider a
   different symbol or negotiate."
4. **If both clear** → "Safe to launch. Optionally, file an on-chain claim
   via `register_symbol.sh` to lock your intent."

This is the value-add of the dual-surface skill: off-chain reality
(deployed ERC-20s) + on-chain intent (registry claims), surfaced through
one Steward Agent invocation.