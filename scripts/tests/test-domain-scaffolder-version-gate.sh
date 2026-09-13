#!/usr/bin/env bash
# Verifica el presupuesto y diagnostico del gate por SHA del scaffold de dominios (#1273).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

python3 - "$REPO_ROOT/agents/domain-scaffolder.md" <<'PY'
import re
import sys
from pathlib import Path

agent = Path(sys.argv[1]).read_text()
start = agent.index("public class ApiFixture : IAsyncLifetime")
end = agent.index("**4. Crear `Fixtures/ServiceBusFixture.cs`", start)
fixture = agent[start:end]
ready_start = agent.index("- name: Esperar /api/ready")
ready_end = agent.index("- name: Smoke tests", ready_start)
ready = agent[ready_start:ready_end]
timeout_version = re.findall(
    r"TimeoutGatePorVersion\s*=\s*TimeSpan\.FromSeconds\((\d+)\)", fixture
)
timeout_ready = re.findall(r"(?m)^\s*TIMEOUT=(\d+)\s*$", ready)

checks = [
    (timeout_version == ["420"], "el gate por SHA fija un unico presupuesto de 420 s"),
    (
        "var deadline = DateTime.UtcNow + TimeoutGatePorVersion;" in fixture
        and "while (DateTime.UtcNow < deadline)" in fixture,
        "el presupuesto del gate por SHA se mide por reloj",
    ),
    ("TimeSpan.FromSeconds(5)" in fixture, "el gate por SHA conserva el intervalo de 5 s"),
    ("StringComparison.OrdinalIgnoreCase" in fixture, "el gate conserva la comparacion exacta case-insensitive del SHA"),
    ("catch (HttpRequestException)" in fixture, "el gate reintenta HttpRequestException"),
    (
        'var appHost = apiBaseAddress.Host;' in fixture
        and 'appHost[..^".azurewebsites.net".Length]' in fixture
        and '.scm.azurewebsites.net/api/vfs/LogFiles/StartupLogs/' in fixture
        and 'StartupLogs de Kudu: {startupLogsUrl}' in fixture,
        "el agotamiento deriva e informa la URL de StartupLogs de Kudu",
    ),
    (
        "TimeoutGatePorVersion.TotalSeconds" in fixture
        and "SHA esperado ({expectedSha})" in fixture
        and "Ultimo SHA visto:" in fixture,
        "el agotamiento informa presupuesto, SHA esperado y ultimo SHA observado",
    ),
    (
        fixture.count('Client.GetAsync("/api/health")') == 1
        and "if (string.IsNullOrWhiteSpace(expectedSha))" in fixture,
        "el fallback sin SHA hace una unica comprobacion de /api/health",
    ),
    ("GetAsync(startupLogsUrl" not in fixture, "StartupLogs es solo diagnostico y no se consulta"),
    (timeout_ready == ["120"], "/api/ready conserva un unico presupuesto independiente de 120 s"),
    ("Mismo timeout de 120s" not in ready and "no comparte el timeout del gate por SHA" in ready, "/api/ready no afirma compartir el timeout de /api/version"),
    (
        "Repos ya scaffoldeados antes del fix del issue #1273" in agent
        and "Actualiza manualmente `Fixtures/ApiFixture.cs`" in agent,
        "la nota de idempotencia prescribe el parche manual del fixture existente",
    ),
]

failed = 0
for condition, description in checks:
    print(f"  {'PASS' if condition else 'FAIL'}: {description}")
    failed += not condition

raise SystemExit(1 if failed else 0)
PY
