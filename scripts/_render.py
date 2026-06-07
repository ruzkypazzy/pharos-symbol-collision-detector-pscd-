#!/usr/bin/env python3
"""
PSCD render helper — converts the JSON result of check.py into Markdown,
plain text, or HTML. Used by the bash script for inline rendering when the
Python module is on a different code path.

Not normally called directly. Run scripts/check.sh instead.
"""
import json
import sys
from typing import Any, Dict, List


def render_markdown(r: Dict[str, Any]) -> str:
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
    elif v == "CLEAR":
        lines.append("## All clear")
        lines.append("")
        lines.append(f"No token on **{r['network']}** uses the symbol `{r['candidate']}` within the scanned block range.")
    return "\n".join(lines) + "\n"


def main() -> int:
    raw = sys.stdin.read().strip()
    if not raw:
        print("PSCD: empty input (no JSON to render)", file=sys.stderr)
        return 1
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"PSCD: invalid JSON: {e}", file=sys.stderr)
        return 1
    sys.stdout.write(render_markdown(data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
