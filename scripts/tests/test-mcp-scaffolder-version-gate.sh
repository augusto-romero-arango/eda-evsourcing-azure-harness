#!/usr/bin/env bash
# Verifica el presupuesto y diagnostico del gate por SHA del scaffold MCP (#1274).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

python3 - "$REPO_ROOT/agents/mcp-scaffolder.md" <<'PY'
import sys
from pathlib import Path

agent = Path(sys.argv[1]).read_text()
warmup_start = agent.index("- name: Warmup Function App")
warmup_end = agent.index("- name: Azure Authentication", warmup_start)
warmup = agent[warmup_start:warmup_end]
version_start = warmup.index('if [ -n "$expected_sha" ]; then')
ready_start = warmup.index('echo "Esperando que ${{ inputs.base_url }}/api/ready responda 200..."')
version = warmup[version_start:ready_start]
ready = warmup[ready_start:]

checks = [
    ("TIMEOUT_VERSION=420" in version, "el gate por SHA fija el presupuesto de 420 s"),
    (
        "INICIO=$SECONDS" in version
        and "while (( SECONDS - INICIO < TIMEOUT_VERSION )); do" in version,
        "el presupuesto del gate por SHA se mide por reloj",
    ),
    (
        "INTERVALO_VERSION=5" in version
        and "espera=$(( restante < INTERVALO_VERSION ? restante : INTERVALO_VERSION ))" in version
        and 'sleep "$espera"' in version,
        "el gate por SHA usa un intervalo de 5 s acotado por el tiempo restante",
    ),
    (
        'curl -s --max-time "$timeout_peticion" "${{ inputs.base_url }}/api/version"' in version
        and "timeout_peticion=$(( restante < 15 ? restante : 15 ))" in version,
        "cada peticion de version tiene timeout acotado dentro del presupuesto",
    ),
    (
        '[[ "$body" == *"$expected_sha"* ]]' in version
        and "Version OK tras ${intentos} intento(s) (${transcurrido}s)" in version,
        "el exito exige el SHA y reporta intentos y segundos reales",
    ),
    (
        "en 420s" in version
        and "Ultimo cuerpo observado:" in version
        and "StartupLogs de Kudu:" in version
        and 'startup_logs_url="https://${app_name}.scm.azurewebsites.net/api/vfs/LogFiles/StartupLogs/"' in version,
        "el agotamiento informa presupuesto, SHA, ultimo cuerpo y URL manual de Kudu",
    ),
    (
        "app_host=\"${{ inputs.base_url }}\"" in version
        and "app_name=\"${app_host%.azurewebsites.net}\"" in version,
        "la URL de StartupLogs se deriva de inputs.base_url",
    ),
    ("GetAsync(startup_logs_url" not in version and "curl" not in version.split("startup_logs_url", 1)[1], "Kudu es solo diagnostico y no se consulta"),
    ("seq 1 60" not in version and "i*2" not in version, "el gate por SHA no vuelve al bucle 60 x 2"),
    (
        "for i in $(seq 1 60); do" in ready
        and '--max-time 15 "${{ inputs.base_url }}/api/ready"' in ready
        and "Reintentando en 2s" in ready
        and "sleep 2" in ready
        and "Timeout: /api/ready no respondio 200 en 120s" in ready,
        "/api/ready conserva su presupuesto y timeout independientes",
    ),
]

failed = 0
for condition, description in checks:
    print(f"  {'PASS' if condition else 'FAIL'}: {description}")
    failed += not condition

raise SystemExit(1 if failed else 0)
PY
