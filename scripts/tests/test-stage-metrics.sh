#!/usr/bin/env bash
# test-stage-metrics.sh -- Tests de las metricas por stage derivadas de la
# traza stream-json en el lado publicado (issue #646, porte de
# compute_stage_metrics/build_agents_history_json del interno #426).
#
# Contexto: con la traza cruda ya capturada en tdd-pipeline.sh (#645), el
# historico no derivaba ninguna cifra por stage mas alla de una duracion en
# segundos -- no alcanza para saber si un issue tardo mas por mas turnos, mas
# tool calls, o cache que dejo de acertar. Este issue agrega a
# _pipeline-common.sh:
#
#   - compute_stage_metrics <stream_file>: porte esencialmente literal del
#     interno -- turnos, duraciones (total/API/no-API), costo, tokens
#     desglosados, modelo, motivo de fin y un histograma de tool calls por
#     nombre. Imprime JSON compacto o "null"; nunca aborta (CA-4).
#   - build_agents_history_json <key> <agent> <dur> <metrics> [...]:
#     GENERALIZADO a N grupos variables (a diferencia del interno, especifico
#     a writer/reviewer) -- tdd-pipeline.sh tiene hasta 7 claves variables.
#     Cada grupo agrega una clave con {duration, metrics}; <agent> se inyecta
#     como metrics.agent (distingue projection-test-writer de test-writer
#     bajo la misma clave "test-writer", CA-1). Sin jq degrada a un objeto
#     plano con solo "duration" por clave (CA-4).
#
# A diferencia del test interno equivalente, este NO reexamina exhaustivamente
# compute_stage_metrics linea por linea (es un porte literal, ya cubierto por
# .claude/scripts/tests/test-stage-metrics.sh) -- se enfoca en que el porte
# compila/corre igual, y en la generalizacion de build_agents_history_json
# (N grupos variables, no solo writer/reviewer) y su cableado en
# tdd-pipeline.sh (CA-1 a CA-6).
#
# Casos cubiertos:
#   [pre] compute_stage_metrics y build_agents_history_json estan definidas
#       en scripts/_pipeline-common.sh.
#   [A] compute_stage_metrics: stream completo -> turnos/tokens/modelo/tool
#       calls derivados (smoke test del porte).
#   [B] compute_stage_metrics: sin evento result / stream vacio / jq ausente
#       -> "null", nunca aborta (CA-4).
#   [C] build_agents_history_json con 2 grupos (paridad con el interno):
#       agrega metrics preservando duration, agent se inyecta en
#       metrics.agent.
#   [D] build_agents_history_json: metrics null -> no se inventa un campo
#       "agent" (CA-1 nota: el campo vive DENTRO del esquema de metrics, no
#       hay donde anidarlo si metrics es null).
#   [E] build_agents_history_json: agent="" no agrega el campo aunque metrics
#       si sea un objeto (clave que siempre usa el mismo agente, ej reviewer).
#   [F] build_agents_history_json: N>2 grupos (generalizacion, CA-2 -- claves
#       nuevas solo aparecen cuando el caller las incluye).
#   [G] build_agents_history_json: sin jq degrada a plano, SOLO "duration"
#       por clave, sin "metrics" ni "agent" (CA-4/CA-5).
#   [H] Integracion: la linea de historial resultante es JSON valido de una
#       sola linea (CA-4/CA-6) y conserva duration numerico ademas de agregar
#       metrics.
#   [L] Cableado en tdd-pipeline.sh (CA-1 a CA-5):
#       - compute_stage_metrics se invoca al cierre de cada run_agent.
#       - build_agents_history_json alimenta las dos entradas de historial
#         (completed y la de abort).
#       - las metricas se cosechan por stage (case "$stage"), no por nombre
#         de agente -- el stage "merge" reusa el agente "implementer" y con
#         un case por agente pisaria las metricas del implementer de Stage 2.
#       - coverage-gate no pasa por el builder (su forma no cambia).
#       - cada invocacion deja su JSON individual en .claude/pipeline/metrics/
#         del consumidor.
#
# Uso: scripts/tests/test-stage-metrics.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq no disponible en este entorno, no se puede correr la suite"; exit 0; }

assert_field() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc (esperado '$expected', obtenido '$actual')"
    fi
}

# -------- Bloque pre: funciones existen --------

echo "[pre] Las funciones estan definidas en scripts/_pipeline-common.sh"
for fn in compute_stage_metrics build_agents_history_json; do
    if declare -F "$fn" >/dev/null; then
        pass "$fn definida"
    else
        fail "$fn NO definida"
    fi
done

# -------- Bloque A: compute_stage_metrics, smoke test del porte --------

echo ""
echo "[A] compute_stage_metrics: stream completo -> campos derivados (smoke test del porte)"

cat > "$TMP/a-stream.jsonl" <<'EOF'
{"type":"system","subtype":"init","session_id":"abc","model":"claude-sonnet-5"}
{"type":"assistant","timestamp":"2026-08-16T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{}}]}}
{"type":"user","timestamp":"2026-08-16T10:00:00.400Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}}
{"type":"result","num_turns":2,"duration_ms":1000,"duration_api_ms":700,"total_cost_usd":0.01,"is_error":false,"stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":10,"cache_creation_input_tokens":0}}
EOF

A_OUT=$(compute_stage_metrics "$TMP/a-stream.jsonl")
assert_field "A-1: turns" "2" "$(echo "$A_OUT" | jq -r '.turns')"
assert_field "A-2: model (desde system/init)" "claude-sonnet-5" "$(echo "$A_OUT" | jq -r '.model')"
assert_field "A-3: non_api_ms derivado" "300" "$(echo "$A_OUT" | jq -r '.non_api_ms')"
assert_field "A-4: tool_calls[Read].count" "1" "$(echo "$A_OUT" | jq -r '.tool_calls[0].count')"
assert_field "A-5: tool_calls[Read].duration_ms_sum" "400" "$(echo "$A_OUT" | jq -r '.tool_calls[0].duration_ms_sum')"
if [ "$(printf '%s' "$A_OUT" | wc -l | tr -d ' ')" = "0" ] && echo "$A_OUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
    pass "A-6: la salida es un objeto JSON valido en una sola linea"
else
    fail "A-6: la salida no es un objeto JSON de una sola linea: $A_OUT"
fi

# -------- Bloque B: degradaciones a "null" (CA-4) --------

echo ""
echo "[B] compute_stage_metrics degrada a \"null\" sin abortar (CA-4)"

printf '{"type":"assistant","message":{"content":[{"type":"text","text":"trabajando"}]}}\n' > "$TMP/b-sin-result.jsonl"
B1_OUT=$(compute_stage_metrics "$TMP/b-sin-result.jsonl")
RC=$?
if [ "$RC" -eq 0 ] && [ "$B1_OUT" = "null" ]; then
    pass "B-1: sin evento result -> exit 0 y 'null'"
else
    fail "B-1: se esperaba exit 0 y 'null', se obtuvo rc=$RC salida='$B1_OUT'"
fi

: > "$TMP/b-vacio.jsonl"
B2_OUT=$(compute_stage_metrics "$TMP/b-vacio.jsonl")
RC=$?
if [ "$RC" -eq 0 ] && [ "$B2_OUT" = "null" ]; then
    pass "B-2: stream vacio -> exit 0 y 'null'"
else
    fail "B-2: se esperaba exit 0 y 'null', se obtuvo rc=$RC salida='$B2_OUT'"
fi

E_PATH_SIN_JQ="$TMP/bin-sin-jq"
mkdir -p "$E_PATH_SIN_JQ"
(
    set -euo pipefail
    PATH="$E_PATH_SIN_JQ:/bin"
    B3_OUT=$(compute_stage_metrics "$TMP/a-stream.jsonl")
    echo "$B3_OUT" > "$TMP/b3-out.txt"
)
RC=$?
B3_OUT=$(cat "$TMP/b3-out.txt" 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$B3_OUT" = "null" ]; then
    pass "B-3: jq ausente -> exit 0 y 'null'"
else
    fail "B-3: se esperaba exit 0 y 'null' sin jq, se obtuvo rc=$RC salida='$B3_OUT'"
fi

# -------- Bloque C: build_agents_history_json con 2 grupos (paridad con el interno) --------

echo ""
echo "[C] build_agents_history_json con 2 grupos: agrega metrics, agent va en metrics.agent"

C_OUT=$(build_agents_history_json \
    "test-writer" "projection-test-writer" "125" "$A_OUT" \
    "reviewer" "reviewer" "300" "null")

assert_field "C-1: preserva test-writer.duration" "125" "$(echo "$C_OUT" | jq -r '.["test-writer"].duration')"
assert_field "C-2: preserva reviewer.duration" "300" "$(echo "$C_OUT" | jq -r '.reviewer.duration')"
assert_field "C-3: agrega test-writer.metrics.turns" "2" "$(echo "$C_OUT" | jq -r '.["test-writer"].metrics.turns')"
assert_field "C-4: agent real distingue projection-test-writer bajo la clave test-writer (CA-1)" "projection-test-writer" "$(echo "$C_OUT" | jq -r '.["test-writer"].metrics.agent')"
assert_field "C-5: reviewer.metrics es null cuando ese stage no corrio" "null" "$(echo "$C_OUT" | jq -r '.reviewer.metrics')"

# -------- Bloque D: metrics null -> no inventa un campo "agent" --------

echo ""
echo "[D] metrics null -> no hay donde anidar agent, el campo no aparece"

D_OUT=$(build_agents_history_json "implementer" "projection-implementer" "" "")
if echo "$D_OUT" | jq -e '.implementer.metrics == null' >/dev/null 2>&1 \
   && ! echo "$D_OUT" | jq -e '.implementer | has("agent")' >/dev/null 2>&1; then
    pass "D-1: metrics null y sin campo agent a nivel de entrada"
else
    fail "D-1: forma inesperada con metrics null: $D_OUT"
fi

# -------- Bloque E: agent="" no agrega el campo aunque metrics si sea un objeto --------

echo ""
echo "[E] agent vacio no agrega metrics.agent (clave con un solo agente posible, ej reviewer)"

E_OUT=$(build_agents_history_json "reviewer" "" "300" "{\"turns\":5}")
if echo "$E_OUT" | jq -e '.reviewer.metrics.turns == 5' >/dev/null 2>&1 \
   && ! echo "$E_OUT" | jq -e '.reviewer.metrics | has("agent")' >/dev/null 2>&1; then
    pass "E-1: agent vacio -- metrics conserva sus campos, sin agregar 'agent'"
else
    fail "E-1: forma inesperada con agent vacio: $E_OUT"
fi

# -------- Bloque F: N>2 grupos (generalizacion, CA-2) --------

echo ""
echo "[F] N grupos variables (CA-2: el caller decide cuantas claves incluir)"

F_OUT=$(build_agents_history_json \
    "test-writer" "test-writer" "60" "null" \
    "implementer" "implementer" "90" "null" \
    "smoke-test-writer" "smoke-test-writer" "40" "null" \
    "reviewer" "reviewer" "120" "null" \
    "scaffolder" "domain-scaffolder" "300" "null" \
    "patch-test-writer" "test-writer" "30" "null" \
    "patch-implementer" "implementer" "20" "null")

F_KEY_COUNT=$(echo "$F_OUT" | jq 'keys | length')
assert_field "F-1: las 7 claves estan presentes" "7" "$F_KEY_COUNT"
assert_field "F-2: scaffolder.duration" "300" "$(echo "$F_OUT" | jq -r '.scaffolder.duration')"
assert_field "F-3: patch-implementer.duration" "20" "$(echo "$F_OUT" | jq -r '.["patch-implementer"].duration')"

# -------- Bloque G: sin jq degrada a plano (CA-4/CA-5) --------

echo ""
echo "[G] build_agents_history_json sin jq: solo duration, sin metrics ni agent"

G_OUT=$(PATH="$E_PATH_SIN_JQ:/bin" build_agents_history_json \
    "test-writer" "projection-test-writer" "125" "$A_OUT" \
    "implementer" "" "" "")
if echo "$G_OUT" | grep -qF '"test-writer":{"duration":125}' \
   && echo "$G_OUT" | grep -qF '"implementer":{"duration":null}' \
   && ! echo "$G_OUT" | grep -q "metrics" \
   && ! echo "$G_OUT" | grep -q "agent"; then
    pass "G-1: sin jq, degrada a plano (solo duration, sin metrics ni agent)"
else
    fail "G-1: el degrade sin jq no coincide con lo esperado: $G_OUT"
fi

# -------- Bloque H: integracion -- linea de historial valida --------

echo ""
echo "[H] Integracion: la linea de historial resultante es JSON valido de una sola linea (CA-4/CA-6)"

HISTORY_LINE="{\"issue\":\"646\",\"title\":\"Test\",\"pipeline\":\"tdd\",\"started\":\"20260816-100000\",\"finished\":\"2026-08-16T10:10:00\",\"state\":\"completed\",\"agents\":$C_OUT,\"tests\":10,\"pr\":\"https://github.com/x/y/pull/1\"}"

if [ "$(echo "$HISTORY_LINE" | wc -l)" -eq 1 ] && echo "$HISTORY_LINE" | jq -e '.' >/dev/null 2>&1; then
    pass "H-1: la entrada es JSON valido de una sola linea"
else
    fail "H-1: la entrada no es JSON valido de una sola linea: $HISTORY_LINE"
fi
assert_field "H-2: agents.test-writer.duration sigue siendo numerico" "125" "$(echo "$HISTORY_LINE" | jq -r '.agents["test-writer"].duration')"
assert_field "H-3: agents.test-writer.metrics.turns presente (campo nuevo)" "2" "$(echo "$HISTORY_LINE" | jq -r '.agents["test-writer"].metrics.turns')"

# -------- Bloque L: cableado en tdd-pipeline.sh --------

echo ""
echo "[L] Cableado en tdd-pipeline.sh (CA-1 a CA-5)"

PIPE="$REPO_ROOT/scripts/tdd-pipeline.sh"

if grep -q "compute_stage_metrics" "$PIPE"; then
    pass "L-1: el pipeline invoca compute_stage_metrics al cerrar cada stage"
else
    fail "L-1: el pipeline NO invoca compute_stage_metrics"
fi

if [ "$(grep -c "build_agents_history_json" "$PIPE")" -ge 2 ]; then
    pass "L-2: build_agents_history_json alimenta las dos entradas de historial (completed y la de abort)"
else
    fail "L-2: build_agents_history_json no se usa en las dos entradas de historial"
fi

if grep -q 'run_agent "merge" "implementer"' "$PIPE"; then
    pass "L-3: existe el stage merge reusando el nombre de agente 'implementer' (premisa de L-4)"
else
    fail "L-3: cambio el stage merge -- revisar si L-4 sigue teniendo sentido"
fi

if grep -qE '2\)\s+AGENT_IM_METRICS_JSON="\$metrics_json"' "$PIPE" \
   && ! grep -qE 'implementer\).*AGENT_IM_METRICS_JSON="\$metrics_json"' "$PIPE"; then
    pass "L-4: las metricas se cosechan por stage, no por nombre de agente (el merge no pisa al implementer de Stage 2)"
else
    fail "L-4: las metricas se cosechan por nombre de agente -- un merge fallido pisaria las del implementer de Stage 2"
fi

if grep -q 'coverage-gate' "$PIPE" && grep -qF '\"coverage-gate\":{\"duration\"' "$PIPE"; then
    pass "L-5: coverage-gate conserva su forma propia (duration/result/gaps/patch_applied), no pasa por el builder"
else
    fail "L-5: no se encontro la forma esperada de coverage-gate"
fi

if grep -qF 'PIPELINE_DIR_ABS/metrics/tdd-' "$PIPE"; then
    pass "L-6: cada invocacion respalda su JSON individual en .claude/pipeline/metrics/ (CA-5)"
else
    fail "L-6: no se encontro el respaldo por stage en .claude/pipeline/metrics/"
fi

if grep -qF 'mkdir -p "$PIPELINE_DIR/metrics"' "$PIPE"; then
    pass "L-7: el pipeline crea .claude/pipeline/metrics/ al arrancar"
else
    fail "L-7: falta el mkdir -p de .claude/pipeline/metrics/"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
