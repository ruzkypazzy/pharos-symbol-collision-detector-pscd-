# PSCD Sample Reports

This file shows real example outputs from the on-chain `SymbolRegistry`
contract on Pharos Pacific mainnet. Every example is a single direct
`cast` invocation against the deployed contract.

**Deployed contract:** `SymbolRegistry = 0x6A9Eb713a8055d6ee46aD01641021255f62E6190`
**Network:** Pharos Pacific mainnet (chain 1672), RPC `https://rpc.pharos.xyz`

---

## 1. Check a candidate symbol that IS claimed

```
User: "Is `SKP` safe to launch on Pharos?"
Agent: invokes Pharos Symbol Collision Detector Service Agent
```

### Step 1 — Check if claimed

```bash
cast call 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 \
  "isClaimed(string)(bool)" "SKP" \
  --rpc-url https://rpc.pharos.xyz
```

### Output

```
true
```

### Step 2 — Get the full claim record

```bash
cast call 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 \
  "getClaim(string)((address,uint256,uint64,uint64,string,bool))" "SKP" \
  --rpc-url https://rpc.pharos.xyz
```

### Output

```
(0xCC06503955C5808bCc6e285A868925cB0A0A8AC0, 1000000000000000, 1783488188, 11850158, "https://second-claim.example", true)
```

Fields decoded:
| Field | Value |
|---|---|
| claimer | `0xCC06503955C5808bCc6e285A868925cB0A0A8AC0` |
| deposit | `1000000000000000` wei = 0.001 PROS |
| timestamp (unix) | `1783488188` |
| blockNumber | `11850158` |
| projectURI | `https://second-claim.example` |
| active | `true` |

### What the agent should reply to the user

> **SKP is already claimed on the Pharos SymbolRegistry.**
> Active claimer: `0xCC06...`
> Deposit: 0.001 PROS
> Filed at unix `1783488188` (block `11850158`)
> Project URI: `https://second-claim.example`
>
> **This does NOT prevent you from deploying an ERC-20 with the ticker `SKP`** —
> Pharos does not enforce ticker uniqueness, and PSCD is a visibility layer, not
> a deployment gate. The existing claim will be publicly visible to anyone who
> checks before interacting with your contract.
>
> Pick a different symbol (e.g. `SKP2`, `SKPX`, `SKP-PROJ`) before launching.

---

## 2. Check a candidate symbol that is NOT claimed

```
User: "Is `ZZPSCDTEST` safe to launch on Pharos?"
```

### Step 1 — Check if claimed

```bash
cast call 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 \
  "isClaimed(string)(bool)" "ZZPSCDTEST" \
  --rpc-url https://rpc.pharos.xyz
```

### Output

```
false
```

### Step 2 — (Optional) Get claim record

```bash
cast call 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 \
  "getClaim(string)((address,uint256,uint64,uint64,string,bool))" "ZZPSCDTEST" \
  --rpc-url https://rpc.pharos.xyz
```

### Output

```
(0x0000000000000000000000000000000000000000, 0, 0, 0, "", false)
```

The zero-valued tuple confirms the symbol is **not registered**. The user is free to file a claim.

### What the agent should reply

> **ZZPSCDTEST is currently unclaimed on the Pharos SymbolRegistry.** You can proceed to register it if you want to lock in an on-chain first-mover marker.

### Step 3 — (Optional) Register the claim

After the user confirms the network (Pacific mainnet, $PRIVATE_KEY is set, balance checked):

```bash
cast send 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 \
  "register(string,string)" "ZZPSCDTEST" "https://your-project.example" \
  --value 0.001ether \
  --private-key $PRIVATE_KEY \
  --rpc-url https://rpc.pharos.xyz
```

### Output

```
transactionHash: "0xabcd1234..."
```

The 0.001 PROS deposit is locked. The user can release it at any time via `release(string)` for a full refund.

---

## 3. Release a claim and refund the deposit

```
User: "I want to release my SKP claim and get my deposit back."
```

### Step 1 — Confirm the calling wallet is the original claimer

```bash
cast call 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 \
  "getClaim(string)((address,uint256,uint64,uint64,string,bool))" "SKP" \
  --rpc-url https://rpc.pharos.xyz
```

### Output

```
(0xCC06503955C5808bCc6e285A868925cB0A0A8AC0, 1000000000000000, 1783488188, 11850158, "https://second-claim.example", true)
```

Confirm `0xCC065039...` matches the wallet derived from `$PRIVATE_KEY`:

```bash
cast wallet address --private-key $PRIVATE_KEY
```

If the addresses match, proceed with the release. If not, inform the user they need to use the wallet that originally registered.

### Step 2 — Release

```bash
cast send 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 \
  "release(string)" "SKP" \
  --private-key $PRIVATE_KEY \
  --rpc-url https://rpc.pharos.xyz
```

### Output

```
transactionHash: "0xdef45678..."
```

### Verify the release

```bash
cast call 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 \
  "isClaimed(string)(bool)" "SKP" \
  --rpc-url https://rpc.pharos.xyz
```

### Output

```
false
```

The deposit is refunded in full to the original claimer; the claim record is cleared.

---

## 4. Read-only inspection

```
User: "How many active claims does my wallet have? How much PROS is the registry holding?"
```

```bash
MY_ADDR=$(cast wallet address --private-key $PRIVATE_KEY)

cast call 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 \
  "activeClaimCountOf(address)(uint256)" "$MY_ADDR" \
  --rpc-url https://rpc.pharos.xyz
```

```
3
```

```bash
cast call 0x6A9Eb713a8055d6ee46aD01641021255f62E6190 \
  "totalHeld()(uint256)" \
  --rpc-url https://rpc.pharos.xyz
```

```
1000000000000000 [1e15]
```

(The wei value `1000000000000000` is 0.001 PROS.)
