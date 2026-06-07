#!/usr/bin/env python3
"""
PSCD (Pharos Symbol Collision Detector)
=======================================

Scans Pharos Pacific mainnet (chain 1672) for ERC-20 tokens whose on-chain
`symbol()` matches a user-supplied candidate symbol. Reports COLLISIONS with
their addresses, names, decimals, and explorer links — or CLEAR if no
collision is found.

Two scan modes:
  - fast:  bounded range scan, default last 50,000 blocks (~30 hours).
  - full:  walks every block from 0 to current.

Detection strategy
------------------
1. Walk blocks `[from_block, to_block]` in batches of `step`.
2. For each batch, call `eth_getLogs` filtered to topic0 =
   `Transfer(address,address,uint256)` (`0xddf252ad…`).
3. Keep the log address (`emitting contract`) when topic1 == 0x000…000
   (Transfer-from-zero — the canonical mint). This catches tokens that
   pre-mint supply to a treasury/owner, which is the standard ERC-20 deploy
   pattern.
4. For each unique token address, call `eth_call(symbol())` (selector
   `0x95d89b41`) and ABI-decode the returned dynamic string.
5. Also call `name()` (`0x06fdde03`) and `decimals()` (`0x313ce567`) for
   the human-readable report.
6. Compare the user-supplied symbol (case-insensitive, whitespace-stripped)
   against every fetched symbol. Return matches.

Output
------
- Markdown (default): verdict + collision list with name, address, decimals,
  explorer link, deployer.
- JSON (`--format json`): same data structured for an AI agent.
- Plain text (`--format txt`): logs only.

RPC endpoints
-------------
Only Pharos public RPC: https://rpc.pharos.xyz
No third-party indexer used. The pharosscan.xyz indexer is Vercel-protected
and rejects bot fetches, so the RPC-only approach is more reliable.
"""
import argparse
import json
import math
import os
import sys
import time
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any, Dict, List, Optional, Set, Tuple

# ============ Constants ============

NETWORKS = {
    "mainnet": {
        "name": "Pharos Pacific Ocean Mainnet",
        "chainId": 1672,
        "rpcUrl": "https://rpc.pharos.xyz",
        "explorer": "https://www.pharosscan.xyz",
    },
    "testnet": {
        "name": "Pharos Atlantic Testnet",
        "chainId": 688689,
        "rpcUrl": "https://atlantic.dplabs-internal.com",
        "explorer": "https://atlantic.pharosscan.xyz",
    },
}

# Function selectors
SELECTOR_SYMBOL   = "0x95d89b41"   # symbol() -> string
SELECTOR_NAME     = "0x06fdde03"   # name() -> string
SELECTOR_DECIMALS = "0x313ce567"   # decimals() -> uint8

# Transfer event topic0
TOPIC_TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

# Zero address as topic (Transfer-from-zero = canonical mint)
ZERO_TOPIC = "0x0000000000000000000000000000000000000000000000000000000000000000"

DEFAULT_STEP = 1000      # blocks per eth_getLogs call
DEFAULT_WORKERS = 6      # parallel eth_call workers
DEFAULT_BATCH_TIMEOUT = 30


# ============ Low-level RPC ============

def rpc(url: str, method: str, params: list, attempt: int = 0) -> Any:
    """JSON-RPC POST. Retries on connection error / 5xx, 3x by default."""
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    headers = {"Content-Type": "application/json"}
    last_err = None
    for i in range(3):
        try:
            req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=DEFAULT_BATCH_TIMEOUT) as r:
                body = json.loads(r.read().decode("utf-8"))
            if "error" in body:
                raise RuntimeError(f"RPC error: {body['error']}")
            return body.get("result")
        except (urllib.error.URLError, TimeoutError, RuntimeError) as e:
            last_err = e
            time.sleep(0.5 * (2 ** i))
    raise RuntimeError(f"RPC {method} failed after 3 attempts: {last_err}")


def hex_to_int(h: str) -> int:
    if h is None:
        return 0
    return int(h, 16)


def int_to_hex(n: int) -> str:
    return "0x" + format(n, "x")


# ============ ABI decoders ============

def decode_abi_string(raw: str) -> str:
    """Decode an ABI-encoded dynamic string returned by a view function.

    Layout (post-0x prefix):
      0x00..0x20    offset (uint256) — usually 0x20
      0x20..0x40    length (uint256) — string length in bytes
      0x40..(0x40+length*2)  UTF-8 bytes, hex-encoded
    """
    if not raw or raw == "0x" or len(raw) < 130:
        return ""
    body = raw[2:]  # strip 0x
    # First 32 bytes = offset, second 32 bytes = length
    try:
        offset = int(body[0:64], 16)
        length = int(body[64:128], 16)
        if length == 0:
            return ""
        # data starts at byte 64 + offset, length * 2 hex chars
        data_start = 64 + offset * 2
        data_end = data_start + length * 2
        raw_bytes = bytes.fromhex(body[data_start:data_end])
        return raw_bytes.decode("utf-8", errors="replace")
    except (ValueError, IndexError):
        return ""


def decode_abi_uint8(raw: str) -> int:
    """Decode an ABI-encoded uint8 (decimals)."""
    if not raw or raw == "0x":
        return 18
    try:
        return int(raw[-2:], 16) if len(raw) >= 4 else int(raw, 16)
    except ValueError:
        return 18


# ============ Token metadata fetch ============

def fetch_token_meta(url: str, address: str) -> Dict[str, Any]:
    """Fetch symbol, name, decimals for a token contract via eth_call.
    Returns {"symbol": str, "name": str, "decimals": int, "ok": bool, "error": str|None}.
    """
    out: Dict[str, Any] = {"symbol": "", "name": "", "decimals": 18, "ok": False, "error": None}
    try:
        sym_raw = rpc(url, "eth_call", [{"to": address, "data": SELECTOR_SYMBOL}, "latest"])
        out["symbol"] = decode_abi_string(sym_raw).strip()
    except Exception as e:
        out["error"] = f"symbol(): {e}"
        return out
    try:
        name_raw = rpc(url, "eth_call", [{"to": address, "data": SELECTOR_NAME}, "latest"])
        out["name"] = decode_abi_string(name_raw).strip()
    except Exception:
        pass  # name is optional
    try:
        dec_raw = rpc(url, "eth_call", [{"to": address, "data": SELECTOR_DECIMALS}, "latest"])
        out["decimals"] = decode_abi_uint8(dec_raw)
    except Exception:
        pass
    out["ok"] = True
    return out


def fetch_token_meta_parallel(url: str, addresses: List[str], max_workers: int = DEFAULT_WORKERS) -> Dict[str, Dict]:
    """Fetch metadata for many addresses in parallel."""
    result: Dict[str, Dict] = {}
    with ThreadPoolExecutor(max_workers=max_workers) as ex:
        futs = {ex.submit(fetch_token_meta, url, a): a for a in addresses}
        for f in as_completed(futs):
            addr = futs[f]
            try:
                result[addr.lower()] = f.result()
            except Exception as e:
                result[addr.lower()] = {"symbol": "", "name": "", "decimals": 18, "ok": False, "error": str(e)}
    return result


# ============ Symbol normalization ============

def normalize_symbol(s: str) -> str:
    """Normalize: strip whitespace, uppercase."""
    return (s or "").strip().upper()


# ============ Block scan ============

def scan_token_addrs(url: str, from_block: int, to_block: int, step: int = DEFAULT_STEP, progress: bool = True) -> Set[str]:
    """Walk [from_block, to_block] in batches; return set of unique token addresses
    that emitted Transfer-from-zero (mint) events in that range.
    """
    addrs: Set[str] = set()
    b = from_block
    total = to_block - from_block + 1
    scanned = 0
    t0 = time.time()
    while b <= to_block:
        upper = min(b + step - 1, to_block)
        try:
            logs = rpc(url, "eth_getLogs", [{
                "fromBlock": int_to_hex(b),
                "toBlock":   int_to_hex(upper),
                "topics":    [TOPIC_TRANSFER, ZERO_TOPIC],
            }]) or []
        except Exception as e:
            if progress:
                print(f"[pscd] eth_getLogs failed for {b}..{upper}: {e}", file=sys.stderr)
            b = upper + 1
            scanned += step
            continue
        for log in logs:
            addr = (log.get("address") or "").lower()
            if addr:
                addrs.add(addr)
        scanned += (upper - b + 1)
        if progress:
            pct = 100.0 * scanned / max(total, 1)
            elapsed = time.time() - t0
            rate = scanned / elapsed if elapsed > 0 else 0
            eta = (total - scanned) / rate if rate > 0 else 0
            print(f"[pscd] scanned {scanned:,}/{total:,} blocks ({pct:.1f}%) — {len(addrs)} tokens so far — ETA {eta:.0f}s", file=sys.stderr)
        b = upper + 1
    return addrs


# ============ Main check ============

def check_symbol(network: str, candidate: str, from_block: int, to_block: int, step: int, max_workers: int, progress: bool) -> Dict[str, Any]:
    """Run the full check. Return a structured dict suitable for any output format."""
    net = NETWORKS[network]
    url = net["rpcUrl"]
    explorer = net["explorer"]
    target = normalize_symbol(candidate)

    # 1. Scan blocks for token addresses
    token_addrs = scan_token_addrs(url, from_block, to_block, step=step, progress=progress)

    # 2. Fetch metadata for each
    if progress:
        print(f"[pscd] fetching symbol/name/decimals for {len(token_addrs)} candidates…", file=sys.stderr)
    metas = fetch_token_meta_parallel(url, list(token_addrs), max_workers=max_workers)

    # 3. Find collisions
    collisions: List[Dict[str, Any]] = []
    for addr, meta in metas.items():
        sym_norm = normalize_symbol(meta.get("symbol", ""))
        if sym_norm == target and target:
            collisions.append({
                "address":  addr,
                "symbol":   meta.get("symbol", ""),
                "name":     meta.get("name", ""),
                "decimals": meta.get("decimals", 18),
                "ok":       meta.get("ok", False),
                "error":    meta.get("error"),
                "explorer": f"{explorer}/token/{addr}",
            })

    # 4. Compose result
    if not target:
        verdict = "EMPTY"
        verdict_msg = "candidate symbol is empty"
    elif not collisions:
        verdict = "CLEAR"
        verdict_msg = f"no token on {net['name']} uses symbol '{candidate}' (in scanned range)"
    else:
        verdict = "COLLISION"
        verdict_msg = f"{len(collisions)} token(s) on {net['name']} use symbol '{candidate}'"

    return {
        "network":     net["name"],
        "chainId":     net["chainId"],
        "candidate":   candidate,
        "normalized":  target,
        "from_block":  from_block,
        "to_block":    to_block,
        "blocks":      to_block - from_block + 1,
        "tokens_seen": len(token_addrs),
        "tokens_ok":   sum(1 for m in metas.values() if m.get("ok")),
        "verdict":     verdict,
        "verdict_msg": verdict_msg,
        "collisions":  collisions,
    }


# ============ CLI ============

def main() -> int:
    ap = argparse.ArgumentParser(
        description="PSCD — Pharos Symbol Collision Detector. "
                    "Scans Pharos mainnet for tokens that share a candidate symbol.",
    )
    ap.add_argument("symbol", help="candidate symbol to check, e.g. 'SKP' or 'USDC'")
    ap.add_argument("--network", choices=NETWORKS.keys(), default="mainnet",
                    help="Pharos network (default: mainnet)")
    ap.add_argument("--from-block", type=int, default=None,
                    help="start block (default: 0 for full, current-50000 for fast)")
    ap.add_argument("--to-block", type=int, default=None,
                    help="end block (default: current block)")
    ap.add_argument("--max-blocks", type=int, default=None,
                    help="scan at most N most-recent blocks (sets from-block = current-N)")
    ap.add_argument("--step", type=int, default=DEFAULT_STEP,
                    help=f"blocks per eth_getLogs call (default: {DEFAULT_STEP})")
    ap.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                    help=f"parallel eth_call workers (default: {DEFAULT_WORKERS})")
    ap.add_argument("--format", choices=["md", "json", "txt"], default="md",
                    help="output format (default: md)")
    ap.add_argument("--quiet", action="store_true", help="suppress progress on stderr")
    ap.add_argument("--demo", action="store_true",
                    help="score a known busy symbol on mainnet (USDC) for the demo")
    args = ap.parse_args()

    net = NETWORKS[args.network]
    url = net["rpcUrl"]
    progress = not args.quiet

    if args.demo:
        args.symbol = "USDC"
        if args.network == "mainnet" and args.from_block is None and args.to_block is None and args.max_blocks is None:
            args.max_blocks = 50000  # bounded for demo

    if args.to_block is None:
        if progress:
            print(f"[pscd] querying {url} for current block…", file=sys.stderr)
        args.to_block = hex_to_int(rpc(url, "eth_blockNumber", []))
        if progress:
            print(f"[pscd] current block: {args.to_block:,}", file=sys.stderr)

    if args.from_block is None:
        if args.max_blocks is not None:
            args.from_block = max(0, args.to_block - args.max_blocks)
        else:
            args.from_block = 0

    result = check_symbol(
        network=args.network,
        candidate=args.symbol,
        from_block=args.from_block,
        to_block=args.to_block,
        step=args.step,
        max_workers=args.workers,
        progress=progress,
    )

    if args.format == "json":
        print(json.dumps(result, indent=2))
        return 0

    if args.format == "txt":
        # Plain log format
        print(f"PSCD v1.0 — Pharos Symbol Collision Detector")
        print(f"  network:    {result['network']}")
        print(f"  chain:      {result['chainId']}")
        print(f"  candidate:  {result['candidate']!r}  (normalized: {result['normalized']!r})")
        print(f"  block range: {result['from_block']:,} .. {result['to_block']:,}  ({result['blocks']:,} blocks)")
        print(f"  tokens seen: {result['tokens_seen']:,}  (ok: {result['tokens_ok']:,})")
        print(f"  verdict:    {result['verdict']} — {result['verdict_msg']}")
        for c in result["collisions"]:
            print(f"    - {c['address']}  symbol={c['symbol']!r}  name={c['name']!r}  decimals={c['decimals']}  {c['explorer']}")
        return 0

    # Markdown (default)
    return render_markdown(result)


# ============ Markdown render ============

def render_markdown(r: Dict[str, Any]) -> int:
    """Render the result as Markdown. Returned to caller as process exit code."""
    v = r["verdict"]
    badge = {"CLEAR": "✅ CLEAR", "COLLISION": "⚠️ COLLISION", "EMPTY": "— EMPTY"}.get(v, v)
    lines: List[str] = []
    lines.append(f"# PSCD — Pharos Symbol Collision Detector")
    lines.append("")
    lines.append(f"**Verdict:** {badge}")
    lines.append("")
    lines.append(f"{r['verdict_msg']}")
    lines.append("")
    lines.append("## Inputs")
    lines.append("")
    lines.append(f"- **Network:** {r['network']} (chain {r['chainId']})")
    lines.append(f"- **Candidate symbol:** `{r['candidate']}` (normalized: `{r['normalized']}`)")
    lines.append(f"- **Block range:** {r['from_block']:,} → {r['to_block']:,} ({r['blocks']:,} blocks scanned)")
    lines.append(f"- **Tokens seen in range:** {r['tokens_seen']:,} (with readable symbol: {r['tokens_ok']:,})")
    lines.append("")
    if v == "COLLISION":
        lines.append(f"## {len(r['collisions'])} collision(s) found")
        lines.append("")
        lines.append("| # | Symbol | Name | Decimals | Address | Explorer |")
        lines.append("|---|---|---|---|---|---|")
        for i, c in enumerate(r["collisions"], 1):
            lines.append(f"| {i} | `{c['symbol']}` | {c['name'] or '—'} | {c['decimals']} | `{c['address'][:10]}…{c['address'][-6:]}` | [view ↗]({c['explorer']}) |")
        lines.append("")
        lines.append("### What to do")
        lines.append("")
        lines.append("- **If you control one of these contracts:** you already have a collision. Rename your token before mainnet launch.")
        lines.append("- **If you don't:** one of these is an impersonator / scam. Do not interact with it; report it to the Pharos team via the contract page on pharosscan.")
        lines.append("- **If you control none of these:** pick a different symbol. Common substitutes: append a suffix (e.g. `SKP2`, `SKPX`), or use a more descriptive long form.")
    elif v == "CLEAR":
        lines.append("## All clear")
        lines.append("")
        lines.append(f"No token on **{r['network']}** uses the symbol `{r['candidate']}` within the scanned block range.")
        lines.append("")
        lines.append("### Caveats")
        lines.append("")
        lines.append(f"- Only blocks **{r['from_block']:,} → {r['to_block']:,}** were scanned. Tokens deployed before that are not in the result. For a full check, re-run with `--max-blocks` set to the latest block number (≈{r['to_block']:,}).")
        lines.append("- The check only matches `symbol()` strings. Two tokens with the same name but different symbols are NOT a collision.")
        lines.append("- Tokens whose `symbol()` call reverts (e.g. non-ERC-20 contracts accidentally emitting Transfer) are skipped.")
    elif v == "EMPTY":
        lines.append("## Empty candidate")
        lines.append("")
        lines.append("The candidate symbol was empty. Please provide a symbol to check.")
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append(f"Generated by [PSCD](https://github.com/ruzkypazzy/Pharos-Symbol-Collision-Detector-PSCD-) · RPC-only · MIT")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n[pscd] interrupted", file=sys.stderr)
        sys.exit(130)
    except Exception as e:
        print(f"[pscd] fatal: {e}", file=sys.stderr)
        sys.exit(1)
