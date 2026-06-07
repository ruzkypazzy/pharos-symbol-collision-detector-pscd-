#!/usr/bin/env bash
# PSCD bash wrapper — calls the Python scorer and pipes the result.
# Zero Python deps. Requires: bash, python3, curl.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NETWORK="mainnet"
MAX_BLOCKS=""
FROM_BLOCK=""
TO_BLOCK=""
STEP=""
WORKERS=""
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
  # Quick check (full chain, ~3 min)
  bash scripts/check.sh SKP --network mainnet

  # Bounded to last 50,000 blocks (~32s)
  bash scripts/check.sh USDC --max-blocks 50000

  # Custom block range — "check from block X to block Y"
  bash scripts/check.sh SKP --from-block 9000000 --to-block 9050000

  # JSON output for an AI agent
  bash scripts/check.sh MYTKN --format json

  # Tune concurrency / step
  bash scripts/check.sh SKP --workers 10 --step 500
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --network) NETWORK="$2"; shift 2 ;;
    --max-blocks) MAX_BLOCKS="$2"; shift 2 ;;
    --step)      STEP="$2";      shift 2 ;;
    --workers)   WORKERS="$2";   shift 2 ;;
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

# Validate numeric flags
for pair in "MAX_BLOCKS:$MAX_BLOCKS" "FROM_BLOCK:$FROM_BLOCK" "TO_BLOCK:$TO_BLOCK" "STEP:$STEP" "WORKERS:$WORKERS"; do
  name="${pair%%:*}"; val="${pair#*:}"
  if [[ -n "$val" && ! "$val" =~ ^[0-9]+$ ]]; then
    echo "PSCD: --${name,,} must be a non-negative integer (got: '$val')" >&2
    exit 2
  fi
done

# Validate range order
if [[ -n "$FROM_BLOCK" && -n "$TO_BLOCK" && "$FROM_BLOCK" -gt "$TO_BLOCK" ]]; then
  echo "PSCD: --from-block ($FROM_BLOCK) must be <= --to-block ($TO_BLOCK)" >&2
  exit 2
fi

ARGS=(--network "$NETWORK" --format "$FORMAT")
if [[ -n "$MAX_BLOCKS" ]]; then ARGS+=(--max-blocks "$MAX_BLOCKS"); fi
if [[ -n "$FROM_BLOCK" ]]; then ARGS+=(--from-block "$FROM_BLOCK"); fi
if [[ -n "$TO_BLOCK" ]];   then ARGS+=(--to-block "$TO_BLOCK");   fi
if [[ -n "$STEP" ]];       then ARGS+=(--step "$STEP");          fi
if [[ -n "$WORKERS" ]];    then ARGS+=(--workers "$WORKERS");    fi
if [[ -n "$QUIET" ]];      then ARGS+=("$QUIET");                fi
if [[ -n "$DEMO" ]];       then ARGS+=("$DEMO");                 fi
if [[ -n "$SYMBOL" ]];     then ARGS+=("$SYMBOL");               fi

exec python3 "$SCRIPT_DIR/check.py" "${ARGS[@]}"
