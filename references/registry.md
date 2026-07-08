# SymbolRegistry Cast Reference

Every operation on the SymbolRegistry contract is a single direct `cast` call. No shell scripts, no Python helpers, no intermediate tools. This document gives the full cast invocation for every supported operation.

## Network Configuration

**Deployed on Pharos Pacific mainnet (chain 1672):**

| Field | Value |
|---|---|
| `SymbolRegistry` | `0x6A9Eb713a8055d6ee46aD01641021255f62E6190` |
| RPC URL | `https://rpc.pharos.xyz` |
| Chain ID | `1672` |
| Native currency | PHRS / PROS (1 PHRS = 1000 PROS) |
| Explorers | https://www.pharosscan.xyz |

**Testnet (Atlantic, chain 688689):** contract is not yet deployed. The fingerprint may also be referenced through `assets/networks.json` for future testnet deploys.

## Pre-flight (every write operation)

Before any `cast send`, the agent should verify:

1. **`$PRIVATE_KEY` is set** — passed via `--private-key $PRIVATE_KEY`. Foundry does NOT auto-read this env var — every cast command must include it explicitly.
2. **Derive the deployer address** — `cast wallet address --private-key $PRIVATE_KEY`.
3. **Confirm the network** with the user — Pacific mainnet or Atlantic testnet.
4. **Auto balance check** — `cast balance <deployer> --rpc-url https://rpc.pharos.xyz --ether`. Abort if below (operation cost + 0.001 deposit + gas buffer).

---

## Check if a symbol is claimed

`cast call 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 "isClaimed(string)(bool)" "SKP" --rpc-url https://rpc.pharos.xyz`

**Parameters**

| Name | Type | Description |
|---|---|---|
| symbol | string | The ASCII token symbol to check (case-insensitive, whitespace-trimmed) |

**Returns** `bool` — true if there's an active claim for the given symbol, false otherwise.

**Output**

```
true
```

or

```
false
```

**Error / Edge cases**

- The contract normalizes the symbol (uppercase, whitespace stripped) before lookup. `SKP`, `skp`, and ` SKP ` all match.
- This returns `false` even if there are historical (released) claims — `isClaimed()` only signals *active* claims.

---

## Get the full claim record

`cast call 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 "getClaim(string)((address,uint256,uint64,uint64,string,bool))" "SKP" --rpc-url https://rpc.pharos.xyz`

**Parameters**

| Name | Type | Description |
|---|---|---|
| symbol | string | The ASCII token symbol to look up |

**Returns** a tuple `(address, uint256, uint64, uint64, string, bool)`:

| Field | Type | Description |
|---|---|---|
| claimer | address | The address that filed the claim |
| deposit | uint256 | The locked deposit amount, in wei |
| timestamp | uint64 | The unix timestamp at which the claim was filed |
| blockNumber | uint64 | The block number at which the claim was filed |
| projectURI | string | An optional URI describing the project |
| active | bool | Whether the claim is currently active |

**Output**

```
(0xCC06503955C5808bCc6e285A868925cB0A0A8AC0, 1000000000000000, 1783488188, 11850158, "https://second-claim.example", true)
```

**Error / Edge cases**

- Returns a zero-valued tuple (`0x0000000000000000000000000000000000000000, 0, 0, 0, "", false`) for unclaimed symbols. Always run `isClaimed()` first to distinguish "never claimed" from "released".

---

## Count active claims by address

`cast call 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 "activeClaimCountOf(address)(uint256)" "0xADDRESS" --rpc-url https://rpc.pharos.xyz`

**Parameters**

| Name | Type | Description |
|---|---|---|
| claimer | address | The wallet address to inspect |

**Returns** `uint256` — the number of currently active claims held by that address.

**Output**

```
1
```

**Error / Edge cases**

- This counts only active claims. Released claims do not appear in the count.

---

## Query registry balance

`cast call 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 "totalHeld()(uint256)" --rpc-url https://rpc.pharos.xyz`

**Parameters** — none.

**Returns** `uint256` — the sum of all currently active deposits held by the registry, in wei.

**Output**

```
1000000000000000 [1e15]
```

(0.001 PHRS / PROS, formatted by Foundry in scientific notation. The raw wei value is on the left.)

**Error / Edge cases**

- Funds returned to a claimer via `release()` are removed from this total.
- The contract's owner can also `emergencyWithdrawal()` all funds, but only when the contract is paused.

---

## Register a symbol claim

`cast send 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 "register(string,string)" "MYTOK" "https://myproj.example" --value 0.001ether --private-key $PRIVATE_KEY --rpc-url https://rpc.pharos.xyz`

**Parameters**

| Name | Type | Description |
|---|---|---|
| symbol | string | The ASCII token symbol to claim (case-insensitive, whitespace-trimmed, ≤16 chars) |
| projectURI | string | Any string URI (URL, IPFS CID, plain description). Can be empty. |

**Payable** — the call MUST include `--value 0.001ether` (or more). The exact amount is locked and refundable on `release()`.

**Returns** — the transaction hash on success.

**Output**

```
transactionHash: "0x..."
```

**Error / Edge cases**

- `BelowMinimumDeposit()` — value too low. Pass `--value 0.001ether` or higher.
- `AlreadyClaimed()` — symbol is already actively claimed. Use `isClaimed()` first to check.
- `PausedState()` — contract is paused; wait for owner to unpause.
- On success, the cast command also emits a `SymbolRegistered(symbol, claimer, deposit, projectURI, timestamp, blockNumber)` event you can read back via `--json` and `cast receipt`.

---

## Release a claim and refund the deposit

`cast send 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 "release(string)" "MYTOK" --private-key $PRIVATE_KEY --rpc-url https://rpc.pharos.xyz`

**Parameters**

| Name | Type | Description |
|---|---|---|
| symbol | string | The ASCII symbol of the claim to release (must match the exact registered value, normalized) |

**Returns** — the transaction hash on success.

**Output**

```
transactionHash: "0x..."
```

The full deposit is transferred back to the original claimer. The claim is cleared.

**Error / Edge cases**

- `NotClaimed()` — symbol has no active claim.
- `NotClaimer()` — caller is not the original claimer. Only the wallet that registered can release.
- `PausedState()` — contract is paused.
- `TransferFailed()` — refund send failed. Retry; if persistent, contact the owner via `emergencyWithdrawal()`.

---

## Owner-only operations

These require the owner's private key. The current owner is `0xCC06503955C5808bCc6e285A868925cB0A0A8AC0`.

### Pause new registrations

`cast send 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 "pause()" --private-key $PRIVATE_KEY --rpc-url https://rpc.pharos.xyz`

Halts `register()` and `release()`. Read operations still work. Use during incident response or maintenance.

### Unpause

`cast send 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 "unpause()" --private-key $PRIVATE_KEY --rpc-url https://rpc.pharos.xyz`

Resumes normal operations.

### Emergency withdrawal (owner-only)

`cast send 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 "emergencyWithdrawal()" --private-key $PRIVATE_KEY --rpc-url https://rpc.pharos.xyz`

The owner sweeps ALL held funds to themselves. **Only callable while the contract is paused.** This is the global-refund escape hatch — once swept, individual claimers must contact the owner for refunds. Use only in extreme circumstances.

---

## Quick copy-paste

```bash
RPC=https://rpc.pharos.xyz
REG=0x6A9Eb713a8055d6ee46aD01641021255f62E6190

# Read everything in one go:
cast call $REG "isClaimed(string)(bool)" "SKP" --rpc-url $RPC
cast call $REG "getClaim(string)((address,uint256,uint64,uint64,string,bool))" "SKP" --rpc-url $RPC
cast call $REG "activeClaimCountOf(address)(uint256)" "$(cast wallet address --private-key $PRIVATE_KEY)" --rpc-url $RPC
cast call $REG "totalHeld()(uint256)" --rpc-url $RPC

# File a claim:
cast send $REG "register(string,string)" "MYTOK" "https://myproj.example" \
  --value 0.001ether --private-key $PRIVATE_KEY --rpc-url $RPC

# Release a claim:
cast send $REG "release(string)" "MYTOK" --private-key $PRIVATE_KEY --rpc-url $RPC
```