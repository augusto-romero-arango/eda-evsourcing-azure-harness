#!/usr/bin/env bash
# test-stage-metrics.sh -- Tests de las metricas por stage derivadas de la
# traza stream-json (issue #426).
#
# Contexto: con la traza cruda ya capturada (#425), el historico seguia
# registrando una sola cifra por agente (agents.<agente>.duration en
# segundos) -- no alcanza para saber si un issue tardo mas por mas turnos,
# mas tool calls, o cache que dejo de acertar. Este issue agrega dos
# funciones nuevas a _mefisto-common.sh:
#
#   - compute_stage_metrics <stream_file>: deriva del stream JSON crudo
#     turnos, duraciones (total/API/no-API), costo, tokens desglosados,
#     modelo, motivo de fin y un histograma de tool calls por nombre (count +
#     tiempo atribuido via emparejamiento tool_use.id <-> tool_use_id, ambos
#     fechados por el `timestamp` ISO-8601 de nivel superior de cada evento).
#     Imprime JSON compacto o el literal "null"; nunca aborta (CA-5).
#   - build_agents_history_json <wr_dur> <wr_metrics> <rv_dur> <rv_metrics>:
#     construye el objeto "agents" de una entrada de pipeline-history.jsonl,
#     agregando agents.<agente>.metrics SIN tocar "duration" (CA-2). Sin jq
#     degrada al formato plano de siempre (CA-5).
#
# Casos cubiertos:
#   [pre] Las dos funciones nuevas estan definidas en _mefisto-common.sh.
#   [A] Stream completo con varias tool calls -> todos los campos derivados
#       correctamente, incluido el histograma (count, suma y mediana del
#       tiempo atribuido por nombre de herramienta) (CA-1).
#   [B] Stream sin evento `result` (stage matado a mitad de corrida, sin
#       chance de escribirlo) -> "null", no aborta (CA-5).
#   [C] Stream vacio -> "null" (CA-5).
#   [D] Stream truncado a mitad de linea, con `result` valido despues de la
#       linea rota -> la linea truncada se ignora sin abortar; el resto de
#       las metricas se deriva igual (CA-1/CA-5).
#   [E] jq ausente -> degrada a "null" sin abortar (CA-5).
#   [F] `is_error:false` se preserva tal cual -- NO se convierte en null.
#       jq trata `false` igual que `null` para el operador `//`; usar ese
#       operador sobre un campo booleano lo rompe. Regresion especifica de
#       este bug (detectado y arreglado durante la implementacion).
#   [G] Milisegundos en los timestamps: el tiempo atribuido a una tool call
#       de duracion sub-segundo se calcula correcto (no se trunca la
#       fraccion, ver notas tecnicas del issue).
#   [H] Tool call sin `tool_result` emparejado (huerfana) -> cuenta en
#       `count` pero no contribuye a `duration_ms_sum`/`duration_ms_median`.
#   [I] build_agents_history_json: agrega "metrics" preservando "duration"
#       intacto (CA-2); con jq ausente degrada al formato plano legado
#       (mismas dos claves de siempre, sin "metrics") (CA-5).
#   [J] Integracion: la linea resultante es JSON valido de una sola linea
#       (CA-4) y conserva `agents.writer.duration` numerico ademas de
#       agregar `agents.writer.metrics`.
#
# Uso: .claude/scripts/tests/test-stage-metrics.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# shellcheck source=/dev/null
source "$REPO_ROOT/.claude/scripts/_mefisto-common.sh" 2>/dev/null

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq no disponible en este entorno, no se puede correr la suite"; exit 0; }

# -------- Bloque pre: funciones existen --------

echo "[pre] Las funciones nuevas estan definidas en _mefisto-common.sh"
for fn in compute_stage_metrics build_agents_history_json; do
    if declare -F "$fn" >/dev/null; then
        pass "$fn definida"
    else
        fail "$fn NO definida"
    fi
done

# -------- Bloque A: stream completo con tool calls --------

echo ""
echo "[A] Stream completo con varias tool calls -> todos los campos derivados (CA-1)"

cat > "$TMP/a-stream.jsonl" <<'EOF'
{"type":"system","subtype":"init","session_id":"abc","model":"claude-sonnet-5"}
{"type":"assistant","timestamp":"2026-07-27T22:09:34.000Z","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"Voy a investigar."}]}}
{"type":"assistant","timestamp":"2026-07-27T22:09:34.500Z","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{}}]}}
{"type":"user","timestamp":"2026-07-27T22:09:34.700Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"contenido"}]}}
{"type":"assistant","timestamp":"2026-07-27T22:09:35.000Z","message":{"content":[{"type":"tool_use","id":"toolu_2","name":"Read","input":{}}]}}
{"type":"user","timestamp":"2026-07-27T22:09:35.900Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"ok"}]}}
{"type":"assistant","timestamp":"2026-07-27T22:09:36.000Z","message":{"content":[{"type":"tool_use","id":"toolu_3","name":"Write","input":{}}]}}
{"type":"user","timestamp":"2026-07-27T22:09:37.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_3","content":"ok"}]}}
{"type":"result","num_turns":4,"duration_ms":9451,"duration_api_ms":5289,"total_cost_usd":0.0234,"is_error":false,"stop_reason":"end_turn","terminal_reason":null,"usage":{"input_tokens":1200,"output_tokens":340,"cache_read_input_tokens":900,"cache_creation_input_tokens":100}}
EOF

A_OUT=$(compute_stage_metrics "$TMP/a-stream.jsonl")

assert_field() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc (esperado '$expected', obtenido '$actual')"
    fi
}

assert_field "A-1: turns" "4" "$(echo "$A_OUT" | jq -r '.turns')"
assert_field "A-2: duration_ms" "9451" "$(echo "$A_OUT" | jq -r '.duration_ms')"
assert_field "A-3: duration_api_ms" "5289" "$(echo "$A_OUT" | jq -r '.duration_api_ms')"
assert_field "A-4: non_api_ms derivado (9451-5289)" "4162" "$(echo "$A_OUT" | jq -r '.non_api_ms')"
assert_field "A-5: cost_usd" "0.0234" "$(echo "$A_OUT" | jq -r '.cost_usd')"
assert_field "A-6: tokens.input" "1200" "$(echo "$A_OUT" | jq -r '.tokens.input')"
assert_field "A-7: tokens.output" "340" "$(echo "$A_OUT" | jq -r '.tokens.output')"
assert_field "A-8: tokens.cache_read" "900" "$(echo "$A_OUT" | jq -r '.tokens.cache_read')"
assert_field "A-9: tokens.cache_creation" "100" "$(echo "$A_OUT" | jq -r '.tokens.cache_creation')"
assert_field "A-10: model (desde system/init)" "claude-sonnet-5" "$(echo "$A_OUT" | jq -r '.model')"
assert_field "A-11: is_error" "false" "$(echo "$A_OUT" | jq -r '.is_error')"
assert_field "A-12: stop_reason" "end_turn" "$(echo "$A_OUT" | jq -r '.stop_reason')"
assert_field "A-13: terminal_reason" "null" "$(echo "$A_OUT" | jq -r '.terminal_reason')"

# Histograma: Read aparece 2 veces (200ms y 900ms), Write 1 vez (1000ms)
assert_field "A-14: tool_calls[Read].count" "2" "$(echo "$A_OUT" | jq -r '.tool_calls[] | select(.name=="Read") | .count')"
assert_field "A-15: tool_calls[Read].duration_ms_sum (200+900)" "1100" "$(echo "$A_OUT" | jq -r '.tool_calls[] | select(.name=="Read") | .duration_ms_sum')"
assert_field "A-16: tool_calls[Read].duration_ms_median" "550" "$(echo "$A_OUT" | jq -r '.tool_calls[] | select(.name=="Read") | .duration_ms_median')"
assert_field "A-17: tool_calls[Write].count" "1" "$(echo "$A_OUT" | jq -r '.tool_calls[] | select(.name=="Write") | .count')"
assert_field "A-18: tool_calls[Write].duration_ms_sum" "1000" "$(echo "$A_OUT" | jq -r '.tool_calls[] | select(.name=="Write") | .duration_ms_sum')"

if echo "$A_OUT" | jq -e '. as $r | ($r | tostring) | length > 0' >/dev/null 2>&1 && echo "$A_OUT" | jq -c . >/dev/null 2>&1; then
    pass "A-19: la salida es JSON valido"
else
    fail "A-19: la salida no es JSON valido: $A_OUT"
fi

# -------- Bloque B: sin evento result --------

echo ""
echo "[B] Stream sin evento result -> \"null\", no aborta (CA-5)"

printf '{"type":"assistant","timestamp":"2026-07-27T22:09:34.000Z","message":{"content":[{"type":"text","text":"trabajando"}]}}\n' > "$TMP/b-stream.jsonl"

B_OUT=$(compute_stage_metrics "$TMP/b-stream.jsonl")
RC=$?
if [ "$RC" -eq 0 ] && [ "$B_OUT" = "null" ]; then
    pass "B-1: sin evento result, la funcion retorna exit 0 y \"null\""
else
    fail "B-1: se esperaba exit 0 y 'null', se obtuvo rc=$RC salida='$B_OUT'"
fi

# -------- Bloque C: stream vacio --------

echo ""
echo "[C] Stream vacio -> \"null\" (CA-5)"

: > "$TMP/c-stream.jsonl"
C_OUT=$(compute_stage_metrics "$TMP/c-stream.jsonl")
RC=$?
if [ "$RC" -eq 0 ] && [ "$C_OUT" = "null" ]; then
    pass "C-1: stream vacio, exit 0 y 'null'"
else
    fail "C-1: se esperaba exit 0 y 'null', se obtuvo rc=$RC salida='$C_OUT'"
fi

# -------- Bloque D: stream truncado a mitad de linea, con result valido despues --------

echo ""
echo "[D] Stream truncado a mitad de linea, con result valido despues -> se ignora sin abortar (CA-1/CA-5)"

{
    printf '{"type":"assistant","timestamp":"2026-07-27T22:09:34.000Z","message":{"content":[{"type":"tool_use","id":"toolu_9","name":"Bash","input":{"command":"ls'
    printf '\n'
    printf '{"type":"result","num_turns":1,"duration_ms":100,"duration_api_ms":80,"is_error":false,"stop_reason":"end_turn"}\n'
} > "$TMP/d-stream.jsonl"

(
    set -euo pipefail
    D_OUT=$(compute_stage_metrics "$TMP/d-stream.jsonl")
    echo "$D_OUT" > "$TMP/d-out.txt"
)
RC=$?

if [ "$RC" -eq 0 ]; then
    pass "D-1: stream truncado no aborta el pipeline (set -euo pipefail activo)"
else
    fail "D-1: se esperaba exit 0, se obtuvo $RC"
fi

D_OUT=$(cat "$TMP/d-out.txt" 2>/dev/null)
if echo "$D_OUT" | jq -e '.turns == 1 and .duration_ms == 100' >/dev/null 2>&1; then
    pass "D-2: el result valido posterior a la linea rota si se deriva"
else
    fail "D-2: no se derivaron las metricas del result valido: $D_OUT"
fi

if echo "$D_OUT" | jq -e '.tool_calls | length == 0' >/dev/null 2>&1; then
    pass "D-3: la tool call de la linea truncada no aparece en el histograma"
else
    fail "D-3: la linea truncada dejo rastro en tool_calls: $D_OUT"
fi

# -------- Bloque E: jq ausente --------

echo ""
echo "[E] jq ausente -> degrada a \"null\" sin abortar (CA-5)"

E_PATH_SIN_JQ="$TMP/bin-sin-jq"
mkdir -p "$E_PATH_SIN_JQ"

(
    set -euo pipefail
    PATH="$E_PATH_SIN_JQ:/bin"
    E_OUT=$(compute_stage_metrics "$TMP/a-stream.jsonl")
    echo "$E_OUT" > "$TMP/e-out.txt"
)
RC=$?

E_OUT=$(cat "$TMP/e-out.txt" 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$E_OUT" = "null" ]; then
    pass "E-1: sin jq en PATH, exit 0 y 'null'"
else
    fail "E-1: se esperaba exit 0 y 'null', se obtuvo rc=$RC salida='$E_OUT'"
fi

# -------- Bloque F: is_error:false se preserva --------

echo ""
echo "[F] is_error:false se preserva tal cual (no se convierte en null)"

cat > "$TMP/f-stream.jsonl" <<'EOF'
{"type":"result","num_turns":1,"duration_ms":100,"duration_api_ms":90,"is_error":false,"stop_reason":"end_turn"}
EOF

F_OUT=$(compute_stage_metrics "$TMP/f-stream.jsonl")
F_IS_ERROR=$(echo "$F_OUT" | jq -r '.is_error')
if [ "$F_IS_ERROR" = "false" ]; then
    pass "F-1: is_error:false se preserva (jq trata false igual que null en el operador //; usarlo sobre un booleano lo rompe)"
else
    fail "F-1: is_error deberia ser 'false', se obtuvo '$F_IS_ERROR': $F_OUT"
fi

# -------- Bloque G: milisegundos en los timestamps --------

echo ""
echo "[G] Milisegundos en los timestamps -> el tiempo atribuido no se trunca (CA-1, notas tecnicas)"

cat > "$TMP/g-stream.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-07-27T22:09:35.169Z","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Grep","input":{}}]}}
{"type":"user","timestamp":"2026-07-27T22:09:35.253Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}}
{"type":"result","num_turns":1,"duration_ms":200,"duration_api_ms":150,"is_error":false}
EOF

G_OUT=$(compute_stage_metrics "$TMP/g-stream.jsonl")
assert_field "G-1: duracion sub-segundo de tool call (253ms-169ms=84ms)" "84" "$(echo "$G_OUT" | jq -r '.tool_calls[0].duration_ms_sum')"

# -------- Bloque H: tool call sin tool_result emparejado --------

echo ""
echo "[H] Tool call huerfana (sin tool_result) -> cuenta en count, no en duration_ms_sum"

cat > "$TMP/h-stream.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-07-27T22:09:34.000Z","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}]}}
{"type":"result","num_turns":1,"duration_ms":100,"duration_api_ms":80,"is_error":false}
EOF

H_OUT=$(compute_stage_metrics "$TMP/h-stream.jsonl")
assert_field "H-1: count incluye la tool call huerfana" "1" "$(echo "$H_OUT" | jq -r '.tool_calls[0].count')"
assert_field "H-2: duration_ms_sum es null (sin tool_result para emparejar)" "null" "$(echo "$H_OUT" | jq -r '.tool_calls[0].duration_ms_sum')"
assert_field "H-3: duration_ms_median es null" "null" "$(echo "$H_OUT" | jq -r '.tool_calls[0].duration_ms_median')"

# -------- Bloque I: build_agents_history_json --------

echo ""
echo "[I] build_agents_history_json: agrega metrics preservando duration (CA-2); sin jq degrada al formato plano (CA-5)"

I_OUT=$(build_agents_history_json "125" "$A_OUT" "210" "null")
assert_field "I-1: preserva writer.duration" "125" "$(echo "$I_OUT" | jq -r '.writer.duration')"
assert_field "I-2: preserva reviewer.duration" "210" "$(echo "$I_OUT" | jq -r '.reviewer.duration')"
assert_field "I-3: agrega writer.metrics.turns" "4" "$(echo "$I_OUT" | jq -r '.writer.metrics.turns')"
assert_field "I-4: reviewer.metrics es null cuando no corrio ese stage" "null" "$(echo "$I_OUT" | jq -r '.reviewer.metrics')"

I_NOJQ_OUT=$(PATH="$E_PATH_SIN_JQ:/bin" build_agents_history_json "125" "" "" "")
if echo "$I_NOJQ_OUT" | grep -qF '"writer":{"duration":125}' && ! echo "$I_NOJQ_OUT" | grep -q "metrics"; then
    pass "I-5: sin jq, degrada al formato plano legado (mismas dos claves, sin 'metrics')"
else
    fail "I-5: el degrade sin jq no coincide con el formato legado: $I_NOJQ_OUT"
fi

# -------- Bloque J: integracion -- linea de historial valida y retrocompatible --------

echo ""
echo "[J] Integracion: la linea de historial resultante es JSON valido de una sola linea (CA-4)"

HISTORY_LINE="{\"issue\":\"426\",\"title\":\"Test\",\"pipeline\":\"mefisto-tooling\",\"started\":\"20260727-220000\",\"finished\":\"2026-07-27T22:10:00\",\"state\":\"completed\",\"agents\":$I_OUT,\"pr\":\"https://github.com/x/y/pull/1\"}"

if [ "$(echo "$HISTORY_LINE" | wc -l)" -eq 1 ]; then
    pass "J-1: la entrada ocupa una sola linea"
else
    fail "J-1: la entrada ocupa mas de una linea"
fi

if echo "$HISTORY_LINE" | jq -e '.' >/dev/null 2>&1; then
    pass "J-2: la entrada es JSON valido"
else
    fail "J-2: la entrada no es JSON valido: $HISTORY_LINE"
fi

assert_field "J-3: agents.writer.duration sigue siendo numerico (campo legado intacto)" "125" "$(echo "$HISTORY_LINE" | jq -r '.agents.writer.duration')"
assert_field "J-4: agents.writer.metrics.turns esta presente (campo nuevo)" "4" "$(echo "$HISTORY_LINE" | jq -r '.agents.writer.metrics.turns')"

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
