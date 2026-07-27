#!/usr/bin/env bash
# test-projection-branch.sh — Tests de la rama read-side de scripts/tdd-pipeline.sh
# para issues tipo:projection (issue #371).
#
# Valida:
#   A) Deteccion de tipo:projection desde el JSON del issue -> agentes read-side
#   B) tipo:feature/refactor sin el label -> agentes write-side intactos (CA-2)
#   C) Carve-out de coverage: FunctionEndpoint.cs de una query GET (Obtener{X}/
#      Listar{X}s) se excluye del gate de 95% solo bajo tipo:projection (CA-3)
#   D) Deteccion de Stage 2b (smoke-test-writer) para Functions read-side sin
#      sufijo "Function" en su carpeta (CA-1)
#   E) Coherencia entre este test y scripts/tdd-pipeline.sh (deteccion de drift)
#
# Uso: scripts/tests/test-projection-branch.sh
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

# Reproduccion de la deteccion de tipo:projection y la seleccion de agentes de
# scripts/tdd-pipeline.sh (bloque post-fetch del issue). Cualquier cambio aqui
# debe acompanarse de un cambio en el script real (Escenario E).
detect_stage_agents() {
    local issue_json="$1"
    local stage1_agent="test-writer" stage2_agent="implementer"
    local stage1_label="Test Writer" stage2_label="Implementer"
    if echo "$issue_json" | grep -q '"name":"tipo:projection"'; then
        stage1_agent="projection-test-writer"
        stage2_agent="projection-implementer"
        stage1_label="Projection Test Writer"
        stage2_label="Projection Implementer"
    fi
    echo "$stage1_agent|$stage2_agent|$stage1_label|$stage2_label"
}

# Reproduccion del carve-out de coverage de classify_file() (Stage 4, issue
# #371). Cualquier cambio aqui debe acompanarse de un cambio en el script real.
classify_function_endpoint() {
    local is_projection="$1" filepath="$2"
    local basename dirname dirbasename
    basename=$(basename "$filepath")
    dirname=$(dirname "$filepath")
    dirbasename=$(basename "$dirname")
    if [ "$is_projection" = true ] && [ "$basename" = "FunctionEndpoint.cs" ] \
       && echo "$dirbasename" | grep -qE '^(Obtener|Listar)[A-Za-z0-9]*$'; then
        echo "excluded"; return
    fi
    case "$basename" in
        *CommandHandler.cs|*AggregateRoot.cs|*Validator.cs|FunctionEndpoint.cs)
            echo "logic"; return ;;
    esac
    echo "not_evaluated"
}

# Reproduccion de la deteccion de SMOKE_FILES (Stage 2b, issue #371).
detect_smoke_files() {
    local is_projection="$1" diff_files="$2"
    if [ "$is_projection" = true ]; then
        echo "$diff_files" | grep -E 'Function/|/(Obtener|Listar)[A-Za-z0-9]*/FunctionEndpoint\.cs$' || true
    else
        echo "$diff_files" | grep -E 'Function/' || true
    fi
}

# ─── Escenario A: tipo:projection detectado -> trio read-side ──────────────
echo "Escenario A: label tipo:projection -> projection-test-writer/projection-implementer"
ISSUE_JSON_PROJECTION='{"labels":[{"id":"LA_1","name":"tipo:projection","description":"","color":"0052CC"},{"id":"LA_2","name":"estado:listo","description":"","color":"5319E7"}],"number":999,"state":"OPEN","title":"x"}'
RESULT_A=$(detect_stage_agents "$ISSUE_JSON_PROJECTION")
assert_eq "A1: STAGE1_AGENT=projection-test-writer" "projection-test-writer" "${RESULT_A%%|*}"
assert_eq "A2: STAGE2_AGENT=projection-implementer" "projection-implementer" "$(echo "$RESULT_A" | cut -d'|' -f2)"
assert_eq "A3: STAGE1_LABEL=Projection Test Writer" "Projection Test Writer" "$(echo "$RESULT_A" | cut -d'|' -f3)"
assert_eq "A4: STAGE2_LABEL=Projection Implementer" "Projection Implementer" "$(echo "$RESULT_A" | cut -d'|' -f4)"

# ─── Escenario B: tipo:feature/refactor sin el label -> write-side intacto (CA-2) ─
echo "Escenario B: sin label tipo:projection -> test-writer/implementer (comportamiento actual intacto)"
ISSUE_JSON_FEATURE='{"labels":[{"id":"LA_1","name":"tipo:feature","description":"","color":"1D76DB"},{"id":"LA_2","name":"estado:listo","description":"","color":"5319E7"}],"number":998,"state":"OPEN","title":"y"}'
RESULT_B=$(detect_stage_agents "$ISSUE_JSON_FEATURE")
assert_eq "B1: STAGE1_AGENT=test-writer" "test-writer" "${RESULT_B%%|*}"
assert_eq "B2: STAGE2_AGENT=implementer" "implementer" "$(echo "$RESULT_B" | cut -d'|' -f2)"

ISSUE_JSON_NO_LABELS='{"labels":[],"number":997,"state":"OPEN","title":"z"}'
RESULT_B2=$(detect_stage_agents "$ISSUE_JSON_NO_LABELS")
assert_eq "B3: sin labels -> test-writer/implementer (default)" "test-writer|implementer|Test Writer|Implementer" "$RESULT_B2"

# ─── Escenario C: carve-out de coverage del endpoint GET delgado (CA-3) ─────
echo "Escenario C: FunctionEndpoint.cs de query GET se excluye solo bajo tipo:projection"
assert_eq "C1: Obtener{X} bajo tipo:projection -> excluded" "excluded" \
    "$(classify_function_endpoint true "src/Foo.Bar/ObtenerTurno/FunctionEndpoint.cs")"
assert_eq "C2: Listar{X}s bajo tipo:projection -> excluded" "excluded" \
    "$(classify_function_endpoint true "src/Foo.Bar/ListarTurnos/FunctionEndpoint.cs")"
assert_eq "C3: comando (carpeta con sufijo Function) sigue siendo logic" "logic" \
    "$(classify_function_endpoint true "src/Foo.Bar/CrearTurnoFunction/FunctionEndpoint.cs")"
assert_eq "C4: el mismo Obtener{X} FUERA de tipo:projection sigue siendo logic (CA-2)" "logic" \
    "$(classify_function_endpoint false "src/Foo.Bar/ObtenerTurno/FunctionEndpoint.cs")"

# ─── Escenario D: Stage 2b detecta Functions read-side sin sufijo (CA-1) ────
echo "Escenario D: SMOKE_FILES detecta Functions GET de query bajo tipo:projection"
DIFF_PROJECTION=$'src/Foo.Bar/ObtenerTurno/FunctionEndpoint.cs\nsrc/Foo.Bar/ListarTurnos/FunctionEndpoint.cs\nsrc/Foo.Bar.ReadModels/TurnoView.cs'
SMOKE_D1=$(detect_smoke_files true "$DIFF_PROJECTION")
assert_eq "D1: detecta ObtenerTurno/FunctionEndpoint.cs" "true" \
    "$(echo "$SMOKE_D1" | grep -qF 'ObtenerTurno/FunctionEndpoint.cs' && echo true || echo false)"
assert_eq "D2: detecta ListarTurnos/FunctionEndpoint.cs" "true" \
    "$(echo "$SMOKE_D1" | grep -qF 'ListarTurnos/FunctionEndpoint.cs' && echo true || echo false)"
assert_eq "D3: no incluye el read model (no es un Function endpoint)" "false" \
    "$(echo "$SMOKE_D1" | grep -qF 'TurnoView.cs' && echo true || echo false)"

DIFF_FEATURE=$'src/Foo.Bar/CrearTurnoFunction/FunctionEndpoint.cs\nsrc/Foo.Bar/CrearTurnoFunction/CommandHandler/CrearTurnoCommandHandler.cs'
SMOKE_D2=$(detect_smoke_files false "$DIFF_FEATURE")
assert_eq "D4: write-side (sin tipo:projection) sigue detectando *Function/ (CA-2)" "true" \
    "$(echo "$SMOKE_D2" | grep -qF 'CrearTurnoFunction/FunctionEndpoint.cs' && echo true || echo false)"

# ─── Escenario E: coherencia con el script real ─────────────────────────────
echo "Escenario E: coherencia entre este test y scripts/tdd-pipeline.sh"

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

assert_script_contains "E1: deteccion del label tipo:projection" 'grep -q '"'"'"name":"tipo:projection"'"'"
assert_script_contains "E2: seleccion de projection-test-writer" 'STAGE1_AGENT="projection-test-writer"'
assert_script_contains "E3: seleccion de projection-implementer" 'STAGE2_AGENT="projection-implementer"'
assert_script_contains "E4: carve-out classify_file (regex Obtener/Listar)" "grep -qE '^(Obtener|Listar)[A-Za-z0-9]*\$'"
assert_script_contains "E5: SMOKE_FILES suma el patron read-side bajo IS_PROJECTION" '/(Obtener|Listar)[A-Za-z0-9]*/FunctionEndpoint\.cs$'
assert_script_contains "E6: reviewer y smoke-test-writer se mantienen (sin STAGE variable en run_agent)" 'run_agent "3" "reviewer"'

echo
echo "─── Resumen ───"
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
