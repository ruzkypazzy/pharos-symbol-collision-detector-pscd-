#!/usr/bin/env python3
"""Parse SymbolRegistered event logs from a JSON array or RPC response.

Usage: registry_history_parse.py <response_file> <format> [network] [registry] [from_block] [to_block]
"""
import json
import sys


def hex_int(x):
    if not x:
        return 0
    return int(x, 16)


def hex_addr(x):
    return "0x" + x[-40:]


def parse_logs(logs):
    out = []
    for L in logs:
        topics = L.get("topics", []) or []
        data = L.get("data", "0x") or "0x"
        if len(topics) < 3:
            continue
        symbol_hash = topics[0]
        claimer = hex_addr(topics[2])
        raw = bytes.fromhex(data[2:] if data.startswith("0x") else data)

        # SymbolRegistered ABI for non-indexed args (string, uint256, uint64, uint64, string).
        # Solidity encodes this as:
        #   [0..32]    offset to symbol (first dynamic)
        #   [32..96]   deposit (uint256), timestamp (uint64), blockNumber (uint64)
        #   [96..128]  offset to projectURI (second dynamic)
        #   [sym_offset..]   symbol data: length(32) + bytes
        #   [uri_offset..]   projectURI data: length(32) + bytes
        # (The first dynamic's offset is placed BEFORE the fixed values, and the second
        # dynamic's offset is placed AFTER the fixed values. This is Solidity's specific
        # ABI layout for tuple-with-multiple-dynamics.)

        sym_offset = int.from_bytes(raw[0:32], "big")
        deposit = int.from_bytes(raw[32:64], "big")
        ts = int.from_bytes(raw[64:96], "big")
        blk_event = int.from_bytes(raw[96:128], "big")
        uri_offset = int.from_bytes(raw[128:160], "big")

        sym_len = int.from_bytes(raw[sym_offset:sym_offset + 32], "big")
        sym = raw[sym_offset + 32:sym_offset + 32 + sym_len].decode("utf-8", errors="replace")

        uri_len = int.from_bytes(raw[uri_offset:uri_offset + 32], "big")
        uri = raw[uri_offset + 32:uri_offset + 32 + uri_len].decode("utf-8", errors="replace")

        out.append({
            "symbolHash": symbol_hash,
            "symbol": sym,
            "claimer": claimer,
            "deposit_wei": str(deposit),
            "timestamp": ts,
            "blockNumber": int(L.get("blockNumber", "0x0"), 16),
            "txHash": L.get("transactionHash", ""),
            "projectURI": uri,
        })
    return out


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: parse.py <response_file> <format> ...")
    response_file = sys.argv[1]
    fmt = sys.argv[2]
    net_key = sys.argv[3] if len(sys.argv) > 3 else ""
    registry = sys.argv[4] if len(sys.argv) > 4 else ""
    from_block = int(sys.argv[5]) if len(sys.argv) > 5 else 0
    to_block = int(sys.argv[6]) if len(sys.argv) > 6 else 0

    with open(response_file) as f:
        raw = f.read()

    try:
        body = json.loads(raw)
    except json.JSONDecodeError as e:
        if fmt == "json":
            print(json.dumps({"error": f"failed to parse RPC response: {e}"}))
        else:
            print("(failed to parse RPC response)")
        sys.exit(0)

    # Body may be either an RPC response {"result":[...]} or a bare logs array
    if isinstance(body, list):
        logs = body
    else:
        err = body.get("error")
        if err:
            if fmt == "json":
                print(json.dumps({"error": err}))
            else:
                print(f"RPC error: {err}")
            sys.exit(0)
        logs = body.get("result", []) or []

    if not isinstance(logs, list):
        if fmt == "json":
            print(json.dumps({"error": "result was not a list"}))
        else:
            print("(unexpected response shape)")
        sys.exit(0)

    registrations = parse_logs(logs)

    if fmt == "json":
        out = {
            "network": net_key,
            "registryAddress": registry,
            "fromBlock": from_block,
            "toBlock": to_block,
            "registrations": registrations,
        }
        print(json.dumps(out, indent=2, ensure_ascii=False))
    else:
        print(f"Registry history: {net_key}  address={registry}")
        print(f"Range: {from_block} -> {to_block}")
        print()
        if not registrations:
            print("(no registrations in range)")
            return
        print(f"{'BLOCK':>10}  {'SYMBOL':<12}  {'CLAIMER':<44}  PROJECT_URI")
        for r in registrations:
            block = r["blockNumber"]
            sym = r["symbol"]
            claimer = r["claimer"]
            uri = r["projectURI"]
            print(f"{block:>10}  {sym:<12}  {claimer:<44}  {uri}")


if __name__ == "__main__":
    main()