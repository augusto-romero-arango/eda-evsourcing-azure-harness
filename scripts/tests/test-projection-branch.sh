#!/usr/bin/env bash
# test-projection-branch.sh — Tests de la rama read-side de scripts/tdd-pipeline.sh
# para issues tipo:projection (issue #371).
#
# Valida:
#   A) Deteccion de tipo:projection desde el JSON del issue -> agentes read-side
#   B) tipo:feature/refactor sin el label -> agentes write-side intactos (CA-2)
#   C) Carve-out de coverage: FunctionEndpoint.cs de una query GET (Obtener{X}/
#      Listar{X}s) se excluye del gate de 95% solo bajo tipo:projection (CA-3).
#      Ejercita la funcion real (coverage_classify_file de
#      scripts/_pipeline-common.sh), no una copia local -- ver el comentario de
#      classify_function_endpoint mas abajo
#   D) Deteccion de Stage 2b (smoke-test-writer) para Functions read-side sin
#      sufijo "Function" en su carpeta (CA-1)
#   E) Coherencia entre este test y los scripts reales (deteccion de drift):
#      scripts/tdd-pipeline.sh para lo que sigue inline en el pipeline, y
#      scripts/_pipeline-common.sh para el carve-out de clasificacion
#
# Uso: scripts/tests/test-projection-branch.sh
# Exit code: 0 si todos los escenarios pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TDD_SCRIPT="$REPO_ROOT/scripts/tdd-pipeline.sh"
COMMON_SCRIPT="$REPO_ROOT/scripts/_pipeline-common.sh"

source "$COMMON_SCRIPT"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

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
    local issue_labels
    issue_labels=$(echo "$issue_json" \
        | python3 -c "import sys,json; print('\n'.join(l['name'] for l in json.load(sys.stdin).get('labels') or []))" 2>/dev/null \
        || echo "")
    if echo "$issue_labels" | grep -qx 'tipo:projection'; then
        stage1_agent="projection-test-writer"
        stage2_agent="projection-implementer"
        stage1_label="Projection Test Writer"
        stage2_label="Projection Implementer"
    fi
    echo "$stage1_agent|$stage2_agent|$stage1_label|$stage2_label"
}

# Carve-out de coverage del Stage 4 (issue #371). Desde el #416 la funcion de
# clasificacion vive en scripts/_pipeline-common.sh como coverage_classify_file
# y es sourceable, asi que el Escenario C ejercita la FUNCION REAL en vez de
# reimplementarla. Este wrapper solo adapta el orden de los argumentos a los
# asserts C1..C7 y aporta el worktree que pide la firma.
#
# La reimplementacion que vivia aqui declaraba "cualquier cambio aqui debe
# acompanarse de un cambio en el script real" y aun asi derivo en silencio: se
# quedo sin el patron *Projection.cs que le sumo el #414 al original, de modo
# que clasificaba un TurnoProjection.cs como "not_evaluated" cuando el gate
# real ya exigia "logic" -- y ningun escenario de coherencia por grep lo noto,
# porque el grep verifica que una linea siga presente, no que la logica de al
# lado siga dando el mismo resultado. Es exactamente el modo de fallo que
# motivo el #416; con la funcion ya sourceable, dejar la copia seria conservar
# el defecto teniendo la solucion al lado.
#
# Ninguno de los casos C1..C7 llega a leer disco (todos resuelven por
# basename/dirname antes de las ramas que abren archivos), pero se pasa un
# directorio real para que un caso futuro que si lea no dependa de una ruta
# inexistente.
classify_function_endpoint() {
    local is_projection="$1" filepath="$2"
    coverage_classify_file "$filepath" "$TMP_DIR" "$is_projection"
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

# El match es sobre el NOMBRE completo del label (grep -qx), no un substring del
# JSON: un label que solo contiene 'tipo:projection' como prefijo no debe activar
# la rama read-side (mismo criterio anclado que _resolve_from_labels).
ISSUE_JSON_PREFIJO='{"labels":[{"id":"LA_1","name":"tipo:projection-experimental","description":"","color":"0052CC"}],"number":996,"state":"OPEN","title":"w"}'
RESULT_B3=$(detect_stage_agents "$ISSUE_JSON_PREFIJO")
assert_eq "B4: label con prefijo tipo:projection- no activa la rama read-side" "test-writer" "${RESULT_B3%%|*}"

# La deteccion parsea el JSON, no su serializacion: si gh emitiera el JSON con
# espacios/indentacion, un grep sobre el texto crudo fallaria en silencio y
# despacharia los agentes write-side sobre un issue read-side.
ISSUE_JSON_INDENTADO=$(echo "$ISSUE_JSON_PROJECTION" | python3 -m json.tool)
RESULT_B4=$(detect_stage_agents "$ISSUE_JSON_INDENTADO")
assert_eq "B5: JSON indentado sigue activando la rama read-side" "projection-test-writer" "${RESULT_B4%%|*}"

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
assert_eq "C5: carpeta Obtener{X}Function (comando) no entra al carve-out" "logic" \
    "$(classify_function_endpoint true "src/Foo.Bar/ObtenerCodigoFunction/FunctionEndpoint.cs")"
assert_eq "C6: ListarEventosDe{Aggregate} (receta b2, MEF-ADR-0035) -> excluded" "excluded" \
    "$(classify_function_endpoint true "src/Foo.Bar/ListarEventosDeTurno/FunctionEndpoint.cs")"
assert_eq "C7: CommandHandler bajo tipo:projection sigue exigiendo 95% (gate intacto)" "logic" \
    "$(classify_function_endpoint true "src/Foo.Bar/CrearTurnoFunction/CommandHandler/CrearTurnoCommandHandler.cs")"

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
echo "Escenario E: coherencia entre este test y los scripts reales"

assert_script_contains() {
    local name="$1" needle="$2" target="${3:-$TDD_SCRIPT}"
    if grep -qF -- "$needle" "$target"; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    cadena ausente en $target: $needle"
        FAIL=$((FAIL + 1))
    fi
}

assert_script_contains "E1: deteccion por nombre exacto del label (grep -qx sobre ISSUE_LABELS)" "grep -qx 'tipo:projection'"
assert_script_contains "E1b: los labels se extraen parseando el JSON, no grepeando su texto" \
    "json.load(sys.stdin).get('labels')"
assert_script_contains "E2: seleccion de projection-test-writer" 'STAGE1_AGENT="projection-test-writer"'
assert_script_contains "E3: seleccion de projection-implementer" 'STAGE2_AGENT="projection-implementer"'
# E4/E4b: la funcion de clasificacion se movio a scripts/_pipeline-common.sh
# (issue #416, coverage_classify_file) -- el needle ahora se busca ahi, no en
# TDD_SCRIPT.
assert_script_contains "E4: carve-out de coverage_classify_file (regex Obtener/Listar)" \
    "grep -qE '^(Obtener|Listar)[A-Za-z0-9]*\$'" "$COMMON_SCRIPT"
assert_script_contains "E4b: carve-out excluye carpetas con sufijo Function (comandos)" \
    '[ "${query_dir%Function}" = "$query_dir" ]' "$COMMON_SCRIPT"
assert_script_contains "E5: SMOKE_FILES suma el patron read-side bajo IS_PROJECTION" '/(Obtener|Listar)[A-Za-z0-9]*/FunctionEndpoint\.cs$'
assert_script_contains "E6: reviewer y smoke-test-writer se mantienen (sin STAGE variable en run_agent)" 'run_agent "3" "reviewer"'
# El campo "stage" de status.json es lo que /work-status parsea para saber que
# agente corrio: si el estado "passed" lo escribiera hardcodeado como
# 1-test-writer, un run read-side reportaria el agente equivocado.
assert_script_contains "E7: update_status de Stage 1 usa el agente resuelto" 'update_status "1-${STAGE1_AGENT}"'
assert_script_contains "E8: update_status de Stage 2 usa el agente resuelto" 'update_status "2-${STAGE2_AGENT}"'

echo
echo "─── Resumen ───"
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
