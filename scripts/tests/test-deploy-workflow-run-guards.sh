#!/usr/bin/env bash
# Verifica las guardas de origen confiable de los workflows de deploy encadenados por
# workflow_run en domain-scaffolder y mcp-scaffolder (issue #1828, MEF-ADR-0022).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

python3 - "$REPO_ROOT/agents/domain-scaffolder.md" "$REPO_ROOT/agents/mcp-scaffolder.md" <<'PY'
import re
import sys
from pathlib import Path

passed = failed = 0


def check(condition, description):
    global passed, failed
    if condition:
        passed += 1
        print(f"  PASS: {description}")
    else:
        failed += 1
        print(f"  FAIL: {description}")


ORIGIN = (
    "github.event_name != 'workflow_run' || (github.event.workflow_run.event == 'push' "
    "&& github.event.workflow_run.head_branch == 'main' "
    "&& github.event.workflow_run.head_repository.full_name == github.repository)"
)

for label, path, header in (
    ("domain", sys.argv[1], r"name: Deploy \{PascalCase\}\n"),
    ("mcp", sys.argv[2], r"name: Deploy MCP[^\n]*\n"),
):
    agent = Path(path).read_text()
    m = re.search(header + r".*?^```$", agent, re.MULTILINE | re.DOTALL)
    check(m is not None, f"[{label}] se encontro la plantilla de deploy")
    if m is None:
        continue
    tpl = m.group(0)
    alc = re.search(r"^  determinar-alcance:\n.*?(?=^  build-and-test:)", tpl, re.MULTILINE | re.DOTALL)
    check(alc is not None, f"[{label}] se encontro determinar-alcance")
    if alc:
        a = alc.group(0)
        check("RUN_EVENTO: ${{ github.event.workflow_run.event }}" in a, f"[{label}] CA-1 RUN_EVENTO por env")
        check("RUN_REPO: ${{ github.event.workflow_run.head_repository.full_name }}" in a, f"[{label}] CA-1 RUN_REPO por env")
        check('"$RUN_EVENTO" != "push"' in a and '"$RUN_REPO" != "$REPO"' in a, f"[{label}] CA-1 la guarda exige push y mismo repo")
        run = a.split("run: |", 1)[1]
        check("${{" not in run, f"[{label}] CA-3 el run: no contiene expresiones ${{{{ }}}}")
    for job, nxt in (("build-and-test", "deploy"), ("deploy", "smoke-tests")):
        j = re.search(rf"^  {job}:\n.*?(?=^  {nxt}:)", tpl, re.MULTILINE | re.DOTALL)
        check(j is not None, f"[{label}] se encontro {job}")
        if j:
            txt = j.group(0)
            check(ORIGIN in txt, f"[{label}] CA-2 {job} incluye la guarda de origen")
            check("needs.determinar-alcance.outputs.debe_desplegar == 'true'" in txt, f"[{label}] CA-2 {job} conserva debe_desplegar")
            if label == "domain" and job == "deploy":
                check("github.event_name != 'pull_request'" in txt, "[domain] CA-2 deploy conserva la exclusion de pull_request")

print(f"\nResumen: {passed} pass, {failed} fail")
raise SystemExit(1 if failed else 0)
PY
