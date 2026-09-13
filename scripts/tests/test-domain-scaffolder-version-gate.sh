#!/usr/bin/env bash
# Verifica el presupuesto y diagnostico del gate por SHA del scaffold de dominios (#1273).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

python3 - "$REPO_ROOT/agents/domain-scaffolder.md" <<'PY'
import sys
from pathlib import Path

agent = Path(sys.argv[1]).read_text()
start = agent.index("public class ApiFixture : IAsyncLifetime")
end = agent.index("**4. Crear `Fixtures/ServiceBusFixture.cs`", start)
fixture = agent[start:end]
ready_start = agent.index("- name: Esperar /api/ready")
ready_end = agent.index("- name: Smoke tests", ready_start)
ready = agent[ready_start:ready_end]

checks = [
    ("TimeSpan.FromSeconds(420)" in fixture, "el gate por SHA usa 420 s medidos por reloj"),
    ("TimeSpan.FromSeconds(120)" not in fixture, "el gate por SHA no conserva el presupuesto de 120 s"),
    ("TimeSpan.FromSeconds(5)" in fixture, "el gate por SHA conserva el intervalo de 5 s"),
    ("StringComparison.OrdinalIgnoreCase" in fixture, "el gate conserva la comparacion exacta case-insensitive del SHA"),
    ("catch (HttpRequestException)" in fixture, "el gate reintenta HttpRequestException"),
    (".scm.azurewebsites.net/api/vfs/LogFiles/StartupLogs/" in fixture, "el diagnostico deriva la URL de StartupLogs de Kudu"),
    ("SHA esperado ({expectedSha})" in fixture and "Ultimo SHA visto:" in fixture, "el agotamiento informa SHA esperado y ultimo SHA observado"),
    ("TIMEOUT=120" in ready, "/api/ready conserva su presupuesto independiente de 120 s"),
    ("Mismo timeout de 120s" not in ready and "no comparte el timeout del gate por SHA" in ready, "/api/ready no afirma compartir el timeout de /api/version"),
]

failed = 0
for condition, description in checks:
    print(f"  {'PASS' if condition else 'FAIL'}: {description}")
    failed += not condition

raise SystemExit(1 if failed else 0)
PY
