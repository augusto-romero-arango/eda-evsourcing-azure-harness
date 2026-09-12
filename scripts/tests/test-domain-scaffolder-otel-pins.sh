#!/usr/bin/env bash
# Verifica que domain-scaffolder cierre el contrato de pines OpenTelemetry antes del commit (#1230).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT="$REPO_ROOT/agents/domain-scaffolder.md"
PASS=0
FAIL=0

pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() {
    local texto="$1" esperado="$2" descripcion="$3"
    case "$texto" in *"$esperado"*) pass "$descripcion" ;; *) fail "$descripcion" ;; esac
}

agent="$(< "$AGENT")"

echo '[receta] pines canonicos del write-side'
contains "$agent" '<PackageReference Include="OpenTelemetry.Extensions.Hosting" Version="1.13.1" />' \
    'la receta de Function App fija OpenTelemetry.Extensions.Hosting 1.13.1'
contains "$agent" '<PackageReference Include="OpenTelemetry.Exporter.InMemory" Version="1.13.1" />' \
    'la receta de tests fija OpenTelemetry.Exporter.InMemory 1.13.1'

echo '[verificacion] guard cerrado antes del build'
contains "$agent" '**Pines OpenTelemetry del write-side (MEF-ADR-0003, MEF-ADR-0038, CA-1/CA-2):**' \
    'el Paso 7 declara la verificacion de pines'
contains "$agent" 'local paquete="$1"' 'la verificacion recibe el paquete'
contains "$agent" 'local version_esperada="$2"' 'la verificacion recibe el pin esperado'
contains "$agent" 'local archivo="$3"' 'la verificacion recibe el archivo afectado'
contains "$agent" 'se esperaba exactamente una referencia con pin $version_esperada en $archivo' \
    'los duplicados fallan con paquete, pin y archivo'
contains "$agent" 'se esperaba el pin $version_esperada en $archivo' \
    'los mismatches fallan con paquete, pin y archivo'
contains "$agent" '    "OpenTelemetry.Extensions.Hosting" \' \
    'el guard verifica el paquete de produccion'
contains "$agent" '    "OpenTelemetry.Exporter.InMemory" \' \
    'el guard verifica el paquete de tests'
contains "$agent" '"$REPO_ROOT/src/<RootNamespace>.{PascalCase}/<RootNamespace>.{PascalCase}.csproj" || exit 1' \
    'el guard de produccion detiene el scaffold'
contains "$agent" '"$REPO_ROOT/tests/<RootNamespace>.{PascalCase}.Tests/<RootNamespace>.{PascalCase}.Tests.csproj" || exit 1' \
    'el guard de tests detiene el scaffold'

echo
printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
