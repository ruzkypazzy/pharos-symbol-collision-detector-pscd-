#!/usr/bin/env bash
# PSCD one-shot demo: checks 'USDC' on the last 50,000 blocks of Pharos mainnet.
# Bounded range so the demo finishes in <60 seconds.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==============================================="
echo " PSCD — Pharos Symbol Collision Detector demo"
echo "==============================================="
echo " candidate:  USDC"
echo " network:   Pharos Pacific Ocean Mainnet (1672)"
echo " range:     last 5,000 blocks (~3 hours, fast demo)"
echo " output:    Markdown"
echo "==============================================="
echo

bash "$SCRIPT_DIR/check.sh" USDC --network mainnet --max-blocks 5000 --format md
