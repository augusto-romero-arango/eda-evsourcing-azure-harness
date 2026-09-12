#!/usr/bin/env bash
# Verifica el contrato CI de PRs de la plantilla deploy-{kebab}.yml (issue #1248).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

python3 - "$REPO_ROOT/agents/domain-scaffolder.md" <<'PY'
import re
import sys
from pathlib import Path

agent = Path(sys.argv[1]).read_text()
passed = failed = 0


def check(condition, description):
    global passed, failed
    if condition:
        passed += 1
        print(f"  PASS: {description}")
    else:
        failed += 1
        print(f"  FAIL: {description}")


workflow = re.search(r"name: Deploy \{PascalCase\}\n.*?^```$", agent, re.MULTILINE | re.DOTALL)
check(workflow is not None, "se encontro la plantilla deploy-{kebab}.yml")
if workflow is None:
    raise SystemExit(1)

template = workflow.group(0)
dependencies = [
    "src/<RootNamespace>.{PascalCase}/**",
    "src/<RootNamespace>.{PascalCase}.DomainEvents/**",
    "src/<RootNamespace>.PublicEvents/**",
    "src/<RootNamespace>.PrivateEvents/**",
    "global.json",
    ".github/workflows/deploy-{kebab}.yml",
]

push = re.search(r"  push:\n.*?(?=^  pull_request:)", template, re.MULTILINE | re.DOTALL)
pull_request = re.search(r"  pull_request:\n.*?(?=^  workflow_run:)", template, re.MULTILINE | re.DOTALL)
check(push is not None, "la plantilla conserva el trigger push")
check(pull_request is not None, "la plantilla declara el trigger pull_request")
if push and pull_request:
    for dependency in dependencies:
        check(
            f"- '{dependency}'" in push.group(0) and f"- '{dependency}'" in pull_request.group(0),
            f"push y pull_request vigilan {dependency}",
        )

build = re.search(r"^  build-and-test:\n.*?(?=^  deploy:)", template, re.MULTILINE | re.DOTALL)
check(build is not None, "la plantilla conserva el unico job build-and-test")
if build:
    build_text = build.group(0)
    check(
        "if: needs.determinar-alcance.outputs.debe_desplegar == 'true'" in build_text,
        "build-and-test se ejecuta para el alcance del PR sin excluir pull_request",
    )
    check("dotnet restore <SolutionFile>" in build_text, "el PR restaura la solucion")
    check(
        "dotnet build <SolutionFile> --no-restore --configuration Release" in build_text,
        "el PR compila Release",
    )
    check(
        'for proj in tests/<RootNamespace>.*.Tests/; do' in build_text,
        "el PR ejecuta todos los proyectos unitarios y de contrato",
    )
    check(".SmokeTests/" not in build_text, "el glob de test no selecciona proyectos .SmokeTests")

safe_condition = "if: github.event_name != 'pull_request' && needs.determinar-alcance.outputs.debe_desplegar == 'true'"
deploy = re.search(r"^  deploy:\n.*?(?=^  smoke-tests:)", template, re.MULTILINE | re.DOTALL)
smoke = re.search(r"^  smoke-tests:\n.*", template, re.MULTILINE | re.DOTALL)
check(deploy is not None and safe_condition in deploy.group(0), "deploy queda omitido en pull_request")
check(smoke is not None and safe_condition in smoke.group(0), "smoke-tests queda omitido en pull_request")
if deploy:
    check("uses: azure/login@v3" in deploy.group(0), "OIDC permanece dentro del job excluido en PR")
    check("- name: Publish" in deploy.group(0), "publish permanece dentro del job excluido en PR")
    check("uses: Azure/functions-action@v1" in deploy.group(0), "deploy a Azure permanece dentro del job excluido en PR")

check("workflow_run:\n    workflows: ['Infra CD']" in template, "se conserva workflow_run posterior a Infra CD")
check("workflow_dispatch:" in template, "se conserva workflow_dispatch")
check(
    "Repos ya scaffoldeados antes del fix del issue #1248" in agent,
    "la nota de idempotencia explica como portar el cambio a workflows existentes",
)

print(f"\nResumen: {passed} pass, {failed} fail")
raise SystemExit(1 if failed else 0)
PY
