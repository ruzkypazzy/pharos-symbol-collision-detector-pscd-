#!/usr/bin/env bash
# PSCD bash wrapper — calls the Python scorer and pipes the result.
# Zero Python deps. Requires: bash, python3, curl.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NETWORK="mainnet"
MAX_BLOCKS=""
FROM_BLOCK=""
TO_BLOCK=""
FORMAT="md"
QUIET=""
DEMO=""
SYMBOL=""

usage() {
  cat <<USAGE
PSCD — Pharos Symbol Collision Detector (bash wrapper)

Usage:
  bash scripts/check.sh SYMBOL [options]

Options:
  --network NAME          Pharos network (mainnet|testnet) [default: mainnet]
  --max-blocks N          scan only the last N most-recent blocks
  --from-block N          explicit start block
  --to-block N            explicit end block (default: latest)
  --format FMT            md | json | txt [default: md]
  --quiet                 suppress progress on stderr
  --demo                  demo: check the symbol 'USDC' on a bounded range
  -h, --help              show this help

Examples:
  bash scripts/check.sh SKP --network mainnet
  bash scripts/check.sh USDC --max-blocks 50000
  bash scripts/check.sh MYTKN --format json
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --network) NETWORK="$2"; shift 2 ;;
    --max-blocks) MAX_BLOCKS="$2"; shift 2 ;;
    --from-block) FROM_BLOCK="$2"; shift 2 ;;
    --to-block) TO_BLOCK="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --quiet) QUIET="--quiet"; shift ;;
    --demo) DEMO="--demo"; shift ;;
    -*) echo "unknown flag: $1" >&2; usage; exit 2 ;;
    *) SYMBOL="$1"; shift ;;
  esac
done

if [[ -z "$SYMBOL" && -z "$DEMO" ]]; then
  echo "PSCD: provide a symbol, e.g. SKP or USDC" >&2
  usage
  exit 2
fi

ARGS=(--network "$NETWORK" --format "$FORMAT")
if [[ -n "$MAX_BLOCKS" ]]; then ARGS+=(--max-blocks "$MAX_BLOCKS"); fi
if [[ -n "$FROM_BLOCK" ]]; then ARGS+=(--from-block "$FROM_BLOCK"); fi
if [[ -n "$TO_BLOCK" ]];   then ARGS+=(--to-block "$TO_BLOCK");   fi
if [[ -n "$QUIET" ]];      then ARGS+=("$QUIET");                fi
if [[ -n "$DEMO" ]];       then ARGS+=("$DEMO");                 fi
if [[ -n "$SYMBOL" ]];     then ARGS+=("$SYMBOL");               fi

exec python3 "$SCRIPT_DIR/check.py" "${ARGS[@]}"
