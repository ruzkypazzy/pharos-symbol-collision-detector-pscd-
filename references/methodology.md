# Detection Methodology

This document explains how the Pharos Symbol Collision Detector (PSCD) reasons about symbol collisions, what guarantees the on-chain registry provides, and where its scope ends.

## What PSCD protects against

PSCD is a **pre-launch, name-collision detector** for ERC-20 token symbols on Pharos. The problem it solves:

> Two teams independently choose the same ticker symbol (e.g. "USDC") and deploy ERC-20 contracts on Pharos. End-users cannot tell which is the "real" one. Wallets, explorers, and DEXs all show the symbol legibly, so a malicious deployer can squat an existing brand.

PSCD provides a **voluntary, on-chain, timestamped marker** of which team first laid claim to a given symbol. The registry records:

- which address holds the claim
- when the claim was filed (Unix timestamp + block number)
- how much deposit the claimant locked
- a project URI for the claimant's project

The deposit is the anti-spam mechanism. It is large enough to make bulk squatting uneconomic but small enough to be returned in full when a legitimate project releases the symbol after a re-brand or pivot.

## What PSCD does not protect against

**Important scope boundaries the agent must communicate clearly:**

### 1. PSCD cannot prevent ERC-20 deployment with a conflicting symbol

Any developer can deploy an ERC-20 contract on Pharos using any ticker they choose — including one already claimed on the registry. The registry is a **visibility layer**, not a deployment gate. Two ERC-20s with the same symbol can exist on Pharos; PSCD only tells you that someone has a registered claim.

The agent should always phrase results as:

> "`SKP` already has an on-chain claim on the Pharos SymbolRegistry. **This does not prevent you from deploying an ERC-20 with that ticker**, but the existing claimant will be publicly visible to anyone who checks."

### 2. PSCD does not scan all existing ERC-20s off-chain

This Skill version is scoped to **on-chain registry operations only**. It does NOT enumerate ERC-20 contracts on Pharos, parse their `name()`/`symbol()`, and surface every existing deployment of, say, "USDC". For off-chain scanning of historical deployments, use a separate indexer or block explorer.

If the user needs an exhaustive chain scan, **refer them to that other tool, do not attempt it from PSCD.**

### 3. No ERC-721 / ERC-1155 NFT collection support

The contract reserves ERC-20 ticker space. NFT collections can use any name they like and are out of scope.

### 4. Symbol normalization is intentional and minimal

`_normalize(string)` does two things:

1. Trims leading and trailing whitespace.
2. Converts all ASCII letters to upper case.

That's it. Specifically **not done**:

- No Unicode NFKC / case-fold (so Cyrillic "А" stays different from Latin "A").
- No dot-tolerance (so `USDC.e` is a different ticker than `USDC`).
- No zero-width-stripping, no emoji removal, no grapheme clustering.

The intent is to handle obvious typo variations (`skp` vs `SKP`) while still treating visually-distinct variants as separate symbols. If the user needs stricter normalization, they can submit a contract improvement proposal.

## Operational flow for the agent

When a user asks "is `SYMBOL` safe to launch on Pharos?", the agent should:

1. **Confirm the network.** Pacific mainnet (`https://rpc.pharos.xyz`) or Atlantic testnet (`https://atlantic.dplabs-internal.com`).
2. **Run the `isClaimed` cast call:**
   ```
   cast call 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 "isClaimed(string)(bool)" "SYMBOL" --rpc-url <RPC>
   ```
3. **If `false`:** respond that the symbol is currently unclaimed; advise the user can proceed to register.
4. **If `true`:** call `getClaim` for the full record:
   ```
   cast call 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 "getClaim(string)((address,uint256,uint64,uint64,string,bool))" "SYMBOL" --rpc-url <RPC>
   ```
   and surface the claimer, deposit, timestamp, and projectURI. **Never** represent the existing claim as a "block" — it is a public marker only.
5. **For registering:** run pre-flight checks (private key, balance, network confirmation), then issue the `register(string, string)` `cast send` with `--value 0.001ether`.
6. **For releasing:** verify the calling wallet is the original claimer, then issue the `release(string)` `cast send`.

## How claims are recorded

The contract uses a `mapping(string => Claim) claims;` keyed by the **normalized** symbol. Each `Claim` struct stores:

```solidity
struct Claim {
    address claimer;
    uint256 deposit;
    uint64 timestamp;
    uint64 blockNumber;
    string projectURI;
    bool active;
}
```

`register()` creates a new `Claim` with `active = true` and emits `SymbolRegistered(symbol, claimer, deposit, projectURI, timestamp, blockNumber)`.

`release()` deletes the `Claim` (resets all fields) and emits `SymbolReleased(symbol, claimer, refund)`.

The 0.001 PHRS/PROS deposit is held in the contract's `totalHeld` accumulator. The owner can `emergencyWithdrawal()` to sweep all held funds, but **only while the contract is paused** — preventing an owner from unilaterally seizing unchallenged claims during normal operation.

## How disputes are intended to work

PSCD is **not** a dispute-resolution system. It is a first-to-file marker with an anti-spam deposit. The intended workflow is:

1. Team A deploys ERC-20 with `USDC` and registers the claim.
2. Team B arrives and wants to deploy `USDC` too.
3. Team B sees the existing claim and (one of):
   - **Picks a different symbol** (recommended).
   - **Contacts the original claimer** through the projectURI and negotiates.
   - **Deploys anyway**, knowing the existing claim is publicly visible.

PSCD does not adjudicate. It makes the situation legible.

## Why on-chain, not off-chain

Off-chain symbol registries fail because:

- They have no trustless timestamp.
- They can be retroactively edited by the registry operator.
- They don't follow the chain the token lives on.

By making the registry itself a contract, PSCD inherits:

- Pharos consensus for the timestamp + ordering.
- An auditable, immutable history of all claims and releases.
- A direct incentive alignment: the 0.001 deposit is held by the contract, refundable on good-faith release, and only swept by the owner under explicit pause conditions.

## Security model

| Threat | Mitigation |
|---|---|
| Sybil squatting | 0.001 PHRS/PROS per symbol makes bulk squatting costly |
| Owner theft | `emergencyWithdrawal()` requires paused state; emits `EmergencyWithdrawal` event |
| Front-running an existing claim | Symbols are stored by their normalized form; first-to-register wins |
| Silent denial of refund | `release()` always transfers the full deposit; `TransferFailed()` is a revert reason |
| Past-tense impersonation | Claims are first-to-file; timestamp is part of the stored record |

The owner (`0xCC06503955C5808bCc6e285A868925cB0A0A8AC0`) can pause and sweep, but only as a global recovery — there's no `setClaimer(address)` or `forceRelease(symbol)` that could be used to evict one specific claim while leaving others intact.

## Future work (not in this Skill version)

- ERC-721 collection name registry
- Off-chain chain scanner (warm storage of all `name()`/`symbol()` mappings across Pharos)
- Multi-chain registry federation (PSCD + Polygon + Ethereum + Base)
- Deployed dispute-resolution mechanism (independent arbiter contract)