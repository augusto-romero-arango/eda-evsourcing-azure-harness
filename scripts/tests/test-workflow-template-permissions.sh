#!/usr/bin/env bash
# Guardrail (issue #1923): toda plantilla de workflow embebida en agents/*.md debe declarar
# `permissions` a nivel de workflow o en todos sus jobs (CodeQL actions/missing-workflow-permissions).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
passed = failed = 0
templates = 0

for agent in sorted((root / "agents").glob("*.md")):
    for block in re.findall(r"^```ya?ml\n(.*?)^```$", agent.read_text(), re.MULTILINE | re.DOTALL):
        if not re.search(r"^on:", block, re.MULTILINE) or not re.search(r"^jobs:", block, re.MULTILINE):
            continue
        templates += 1
        name = re.search(r"^name:\s*(.+)$", block, re.MULTILINE)
        label = f"{agent.name}: {name.group(1).strip() if name else '(sin name)'}"
        if re.search(r"^permissions:", block, re.MULTILINE):
            passed += 1
            print(f"  PASS: {label} declara permissions a nivel de workflow")
            continue
        jobs_part = block.split("\njobs:", 1)[1]
        starts = list(re.finditer(r"^  ([A-Za-z0-9_-]+):\s*$", jobs_part, re.MULTILINE))
        for i, m in enumerate(starts):
            end = starts[i + 1].start() if i + 1 < len(starts) else len(jobs_part)
            body = jobs_part[m.end():end]
            if re.search(r"^    permissions:", body, re.MULTILINE):
                passed += 1
                print(f"  PASS: {label} job {m.group(1)} declara permissions")
            else:
                failed += 1
                print(f"  FAIL: {label} job {m.group(1)} sin permissions y workflow sin permissions")

if templates == 0:
    failed += 1
    print("  FAIL: no se encontro ninguna plantilla de workflow en agents/*.md")

print(f"\nPlantillas: {templates}  Passed: {passed}  Failed: {failed}")
sys.exit(1 if failed else 0)
PY
