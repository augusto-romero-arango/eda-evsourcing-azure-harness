#!/usr/bin/env bash
# test-mcp-smoke-trigger.sh — Tests del disparo del Stage 2b (smoke-test-writer)
# de scripts/tdd-pipeline.sh ante tools MCP nuevas o modificadas (issue #791).
#
# Valida:
#   A) Deteccion de SMOKE_FILES: un *Tool.cs bajo src/{NS}.Mcp.{Proposito}/
#      dispara el Stage 2b tanto en la rama write-side (IS_PROJECTION=false)
#      como en la read-side (IS_PROJECTION=true) -- la deteccion MCP es
#      ortogonal al tipo write-side/read-side del issue (CA-1).
#   B) Negativo: un *Tool.cs FUERA de src/*.Mcp.*/ no dispara por el patron MCP
#      (CA-2). Los patrones vigentes (Function/, Obtener/Listar read-side)
#      siguen intactos -- cubiertos en detalle por test-projection-branch.sh;
#      aqui solo se verifica que sumar la alternativa MCP no los rompe (CA-4).
#   C) Resolucion de SMOKE_TEST_PROJECT: para un archivo MCP cae en
#      tests/{NS}.Mcp.{Proposito}.SmokeTests, via el mismo mecanismo que la
#      resolucion por dominio -- sin rama de resolucion aparte (CA-2).
#   D) Coherencia entre este test y scripts/tdd-pipeline.sh (deteccion de
#      drift, mismo criterio que test-projection-branch.sh Escenario E).
#
# Uso: scripts/tests/test-mcp-smoke-trigger.sh
# Exit code: 0 si todos los escenarios pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TDD_SCRIPT="$REPO_ROOT/scripts/tdd-pipeline.sh"

PASS=0
FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    esperado: $expected"
        echo "    obtenido: $actual"
        FAIL=$((FAIL + 1))
    fi
}

NS="Foo.Bar"

# Reproduccion de la deteccion de SMOKE_FILES, la resolucion de
# SMOKE_TEST_PROJECT y la deteccion de IS_MCP_SMOKE de scripts/tdd-pipeline.sh
# (Stage 2b, issue #791). Cualquier cambio aqui debe acompanarse de un cambio
# en el script real (Escenario D).
detect_smoke_files() {
    local is_projection="$1" diff_files="$2" ns="$3"
    local mcp_pattern="src/${ns}\.Mcp\.[^/]+/.*Tool\.cs\$"
    if [ "$is_projection" = true ]; then
        echo "$diff_files" | grep -E "Function/|/(Obtener|Listar)[A-Za-z0-9]*/FunctionEndpoint\.cs\$|${mcp_pattern}" || true
    else
        echo "$diff_files" | grep -E "Function/|${mcp_pattern}" || true
    fi
}

resolve_smoke_test_project() {
    local smoke_files="$1" ns="$2"
    local domain
    domain=$(echo "$smoke_files" | head -1 | sed "s|src/${ns}\.\([^/]*\)/.*|\1|")
    echo "tests/${ns}.${domain}.SmokeTests"
}

is_mcp_smoke() {
    local smoke_files="$1" ns="$2"
    local mcp_pattern="src/${ns}\.Mcp\.[^/]+/.*Tool\.cs\$"
    echo "$smoke_files" | head -1 | grep -qE "$mcp_pattern" && echo true || echo false
}

# ─── Escenario A: *Tool.cs bajo src/{NS}.Mcp.{Proposito}/ dispara Stage 2b ──
echo "Escenario A: tool MCP nueva/modificada dispara SMOKE_FILES"
DIFF_MCP=$'src/Foo.Bar.Mcp.Consultas/X/ListarXTool.cs\nsrc/Foo.Bar.Mcp.Consultas/Infraestructura/XApi.cs'

SMOKE_A1=$(detect_smoke_files false "$DIFF_MCP" "$NS")
assert_eq "A1: write-side (sin tipo:projection) detecta la tool MCP" "true" \
    "$(echo "$SMOKE_A1" | grep -qF 'ListarXTool.cs' && echo true || echo false)"

SMOKE_A2=$(detect_smoke_files true "$DIFF_MCP" "$NS")
assert_eq "A2: read-side (tipo:projection) tambien detecta la tool MCP" "true" \
    "$(echo "$SMOKE_A2" | grep -qF 'ListarXTool.cs' && echo true || echo false)"

assert_eq "A3: no incluye el archivo de infraestructura (no es *Tool.cs)" "false" \
    "$(echo "$SMOKE_A1" | grep -qF 'XApi.cs' && echo true || echo false)"

# ─── Escenario B: *Tool.cs fuera de src/*.Mcp.*/ no dispara por el patron MCP ─
echo "Escenario B: Tool.cs fuera de un servidor MCP no dispara (CA-2)"
DIFF_NO_MCP="src/Foo.Bar/CatalogoTurnos/CatalogoTurnosTool.cs"
SMOKE_B1=$(detect_smoke_files false "$DIFF_NO_MCP" "$NS")
assert_eq "B1: *Tool.cs fuera de .Mcp. no aparece en SMOKE_FILES" "" "$SMOKE_B1"

# Los patrones vigentes (Function/, Obtener/Listar read-side) siguen intactos
# -- cubiertos en detalle por test-projection-branch.sh; aqui solo se verifica
# que sumar la alternativa MCP no los rompe.
DIFF_FEATURE="src/Foo.Bar/CrearTurnoFunction/FunctionEndpoint.cs"
SMOKE_B2=$(detect_smoke_files false "$DIFF_FEATURE" "$NS")
assert_eq "B2: patron Function/ (write-side) sigue intacto" "true" \
    "$(echo "$SMOKE_B2" | grep -qF 'CrearTurnoFunction/FunctionEndpoint.cs' && echo true || echo false)"

DIFF_PROJECTION="src/Foo.Bar/ObtenerTurno/FunctionEndpoint.cs"
SMOKE_B3=$(detect_smoke_files true "$DIFF_PROJECTION" "$NS")
assert_eq "B3: patron read-side Obtener/Listar sigue intacto" "true" \
    "$(echo "$SMOKE_B3" | grep -qF 'ObtenerTurno/FunctionEndpoint.cs' && echo true || echo false)"

# ─── Escenario C: resolucion de SMOKE_TEST_PROJECT para un archivo MCP ──────
echo "Escenario C: SMOKE_TEST_PROJECT resuelve al proyecto del servidor MCP"
PROJECT_C1=$(resolve_smoke_test_project "$SMOKE_A1" "$NS")
assert_eq "C1: src/Foo.Bar.Mcp.Consultas/... -> tests/Foo.Bar.Mcp.Consultas.SmokeTests" \
    "tests/Foo.Bar.Mcp.Consultas.SmokeTests" "$PROJECT_C1"

assert_eq "C2: IS_MCP_SMOKE=true para el archivo de Escenario A" "true" "$(is_mcp_smoke "$SMOKE_A1" "$NS")"
assert_eq "C3: IS_MCP_SMOKE=false para el archivo de dominio (Escenario B2)" "false" "$(is_mcp_smoke "$SMOKE_B2" "$NS")"

# ─── Escenario D: coherencia con el script real ─────────────────────────────
echo "Escenario D: coherencia entre este test y scripts/tdd-pipeline.sh"

assert_script_contains() {
    local name="$1" needle="$2"
    if grep -qF -- "$needle" "$TDD_SCRIPT"; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    cadena ausente en $TDD_SCRIPT: $needle"
        FAIL=$((FAIL + 1))
    fi
}

assert_script_contains "D1: MCP_TOOL_PATTERN con el naming Mcp.{Proposito}/{X}Tool.cs" \
    'MCP_TOOL_PATTERN="src/${HARNESS_NAMESPACE_PREFIX}\.Mcp\.[^/]+/.*Tool\.cs$"'
assert_script_contains "D2: SMOKE_FILES write-side suma la alternativa MCP" \
    'grep -E "Function/|${MCP_TOOL_PATTERN}"'
assert_script_contains "D3: SMOKE_FILES read-side suma la alternativa MCP" \
    'grep -E "Function/|/(Obtener|Listar)[A-Za-z0-9]*/FunctionEndpoint\.cs$|${MCP_TOOL_PATTERN}"'
assert_script_contains "D4: deteccion de IS_MCP_SMOKE por el mismo patron" \
    'echo "$SMOKE_FILES" | head -1 | grep -qE "$MCP_TOOL_PATTERN" && IS_MCP_SMOKE=true'
assert_script_contains "D5: el prompt del caso MCP remite a MEF-ADR-0048 y no a Functions HTTP" \
    'MEF-ADR-0048), no la de Functions HTTP.'

echo
echo "─── Resumen ───"
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
