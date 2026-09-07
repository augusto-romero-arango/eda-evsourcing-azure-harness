#!/usr/bin/env bash
# test-runtime-opencode.sh -- Tests del adaptador de runtime OpenCode
# (MEF-ADR-0049, issue #860): src/internal/scripts/lib/runtime-opencode.sh +
# runtime-opencode.jq.
#
# Ninguno de estos tests invoca el CLI real de OpenCode -- todo corre contra
# una CLI `opencode` FALSA (stub bash) puesta primero en el PATH, que
# reproduce fixtures de .claude/scripts/tests/fixtures/runtime-opencode/
# *-1.18.29.jsonl (capturados con corridas reales minimas; su procedencia,
# la version del CLI y la regla de "no editar un fixture viejo" estan en el
# README.md de ese directorio) y devuelve el exit code que le indique el
# escenario (mismo espiritu que test-runtime-claude.sh, pero aqui la CLI
# falsa tiene que ser un binario real llamado `opencode`: runtime_opencode_
# build_cmd invoca literalmente ese nombre).
#
# Casos cubiertos:
#   [pre] Los archivos nuevos existen, tienen sintaxis valida y el programa
#         jq corre sin errores.
#   [A] CA-1: runtime_opencode_build_cmd compone `opencode run --agent <id>
#       --dir <cwd> --format json --auto [-m <modelo>] "<mensaje>"` -- flags
#       fijos siempre presentes, -m solo si se recibe modelo no vacio,
#       --system-file inyectado como PREFIJO del mensaje (nunca un flag), el
#       mensaje viaja como UN elemento del array (sin eval, paridad con
#       run_agent_with_watchdog), y el modelo opaco (con "/" y espacios)
#       reenviado literal.
#   [B] CA-2: runtime_opencode_translate mapea text->message, tool_use
#       (segun state.status)->tool.started/tool.completed sintetizados desde
#       la MISMA linea (OpenCode 1.18.29 no separa tool_use/tool_result como
#       Claude), y descarta en silencio cualquier tipo no reconocido (nunca
#       expone el wire format al JSONL neutral) contandolo por el canal de
#       diagnostico (`raw_ignored`), con membresia EXACTA: un tipo futuro que
#       sea subcadena de uno conocido tampoco cuenta como reconocido.
#   [C] CA-3: clasificacion completa -- exito (exit 0 + texto visible) >
#       rate_limit (exit != 0 con "429" + "rate limit"/"usage limit" en
#       stderr, patron conservador del issue #965: OpenCode no expone un
#       evento estructurado equivalente al `rate_limit_event` de Claude) >
#       nonzero_exit (exit != 0, detalle de stderr) > no_result (stream
#       vacio) > protocol_invalid (linea no-JSON) > no_result (exit 0 sin
#       texto visible). El TIMEOUT del watchdog no se ejercita aqui via
#       translate directo (lo sintetiza el runner, ver seccion [F]).
#   [D] CA-4: el terminal preserva session_id/tokens/cost_usd cuando el wire
#       format los trae (SUMANDO todos los step_finish, que reportan por paso
#       y no acumulado); turns/denials/ttft_ms/
#       api_duration_ms SIEMPRE null (el wire format no tiene equivalente);
#       model degrada siempre al parametro pedido (el wire format no lo
#       trae en ninguna version verificada).
#   [E] CA-5: ninguna ruta/variable de credenciales
#       (~/.local/share/opencode/auth.json, OPENAI_API_KEY,
#       ANTHROPIC_API_KEY) aparece en runtime-opencode.sh/.jq, y un secreto
#       puesto en el entorno del test no aparece ni en el argv que compone
#       build_cmd ni en el JSONL que produce una corrida real contra el stub.
#   [F] CA-6: runner real (mefisto-run-agent.sh --runtime opencode) contra la
#       CLI falsa: exito, fallo con exit 1, timeout, stream vacio, JSON
#       malformado, exit 0 sin texto visible, modelo heredado (sin -m en la
#       linea capturada), modelo opaco con "/" y espacios, y prefijo de
#       --system-file presente al inicio del mensaje. Cada caso valida el
#       JSONL contra run-events.schema.json y exactamente un terminal.
#
# Uso: .claude/scripts/tests/test-runtime-opencode.sh
# Exit code: 0 si todos los checks pasan, 1 si alguno falla.
# Bash 3.2 + jq 1.7 (MEF-ADR-0049 CA-6): sin arrays asociativos.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INTERNAL_SCRIPTS="$REPO_ROOT/src/internal/scripts"
LIB_DIR="$INTERNAL_SCRIPTS/lib"
CONTRACT_DIR="$REPO_ROOT/src/internal/contract"
RUNNER="$INTERNAL_SCRIPTS/mefisto-run-agent.sh"
OPENCODE_LIB="$LIB_DIR/runtime-opencode.sh"
OPENCODE_JQ="$LIB_DIR/runtime-opencode.jq"
SCHEMA_FILE="$CONTRACT_DIR/run-events.schema.json"
JSONSCHEMA_LITE="$LIB_DIR/jsonschema-lite.jq"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/runtime-opencode"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# translate_fixture <fixture.jsonl> [model] [exit_code] [stderr_file] -- corre
# runtime_opencode_translate directo (sin pasar por el runner) contra un
# fixture, imprime el JSONL.
translate_fixture() {
    local fixture="$1" model="${2:-}" exit_code="${3:-}" stderr_file="${4:-}"
    runtime_opencode_translate "$FIXTURES_DIR/$fixture" "opencode" "$model" "$exit_code" "$stderr_file"
}

# validate_event_line <json-line> -- mismo patron que test-runtime-claude.sh:
# valida contra definitions[.type].
validate_event_line() {
    local line="$1"
    local ev_type
    ev_type="$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)"
    if [ -z "$ev_type" ]; then
        echo "linea sin campo 'type' (o JSON invalido)"
        return 1
    fi
    local known
    known="$(jq --arg t "$ev_type" '(.types | index($t)) != null' "$SCHEMA_FILE" 2>/dev/null)"
    if [ "$known" != "true" ]; then
        echo "type '$ev_type' no esta en el vocabulario cerrado de 'types'"
        return 1
    fi
    local sub_schema errors
    sub_schema="$(jq -c --arg t "$ev_type" '.definitions[$t]' "$SCHEMA_FILE" 2>/dev/null)"
    errors="$(jq -n --argjson schema "$sub_schema" --argjson instance "$line" -f "$JSONSCHEMA_LITE" 2>&1)"
    if [ -z "$errors" ] || [ "$(printf '%s' "$errors" | jq 'length' 2>/dev/null)" = "0" ]; then
        return 0
    fi
    printf '%s' "$errors" | jq -r '.[]'
    return 1
}

count_terminals() {
    jq -c 'select(.type == "run.completed" or .type == "run.failed")' "$1" 2>/dev/null | wc -l | tr -d ' '
}

check_all_lines_valid() {
    local name="$1" file="$2"
    local bad=0 line reason
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if ! reason="$(validate_event_line "$line")"; then
            bad=1
            echo "    linea invalida: $reason"
        fi
    done < "$file"
    if [ "$bad" -eq 0 ]; then
        pass "$name: todas las lineas validan contra el schema"
    else
        fail "$name: alguna linea no valido (ver arriba)"
    fi
}

echo "[pre] Archivos nuevos existen, sintaxis valida"

for f in "$OPENCODE_LIB" "$OPENCODE_JQ"; do
    if [ -f "$f" ]; then
        pass "existe: ${f#"$REPO_ROOT"/}"
    else
        fail "no existe: ${f#"$REPO_ROOT"/}"
    fi
done

if bash -n "$OPENCODE_LIB" 2>/dev/null; then
    pass "sintaxis bash valida: ${OPENCODE_LIB#"$REPO_ROOT"/}"
else
    fail "sintaxis bash invalida: ${OPENCODE_LIB#"$REPO_ROOT"/}"
fi

# shellcheck source=/dev/null
source "$OPENCODE_LIB" 2>/dev/null
for fn in runtime_opencode_build_cmd runtime_opencode_translate; do
    if declare -F "$fn" >/dev/null 2>&1; then
        pass "$fn definida"
    else
        fail "$fn NO definida"
    fi
done

if OUT="$(translate_fixture success-1.18.29.jsonl "" 0)" && [ -n "$OUT" ]; then
    pass "runtime-opencode.jq corre sin errores (stderr silenciado, exit 0)"
else
    fail "runtime-opencode.jq fallo al correr contra success-1.18.29.jsonl"
fi

# ============================================================================
echo ""
echo "[A] CA-1: runtime_opencode_build_cmd compone el argv completo, sin eval"

PROMPT_PLAIN="$TMP/prompt-plain.txt"
printf 'Instrucciones de prueba.' > "$PROMPT_PLAIN"
SYSTEM_FILE="$TMP/system.txt"
printf 'You are running in non-interactive print mode.' > "$SYSTEM_FILE"

MEFISTO_RUNTIME_CMD=()
runtime_opencode_build_cmd "writer" "$TMP" "$PROMPT_PLAIN" "openai/gpt-5" "$SYSTEM_FILE"

if [ "${MEFISTO_RUNTIME_CMD[0]}" = "opencode" ] && [ "${MEFISTO_RUNTIME_CMD[1]}" = "run" ]; then
    pass "A-1: el argv arranca con 'opencode run'"
else
    fail "A-1: el argv no arranca con 'opencode run': ${MEFISTO_RUNTIME_CMD[*]}"
fi

contains_pair() {
    # contains_pair <flag> <valor> -- true si el array MEFISTO_RUNTIME_CMD
    # trae <flag> inmediatamente seguido de <valor>.
    local flag="$1" value="$2" i
    for ((i=0; i<${#MEFISTO_RUNTIME_CMD[@]}-1; i++)); do
        if [ "${MEFISTO_RUNTIME_CMD[$i]}" = "$flag" ] && [ "${MEFISTO_RUNTIME_CMD[$((i+1))]}" = "$value" ]; then
            return 0
        fi
    done
    return 1
}

contains_elem() {
    local needle="$1" e
    for e in "${MEFISTO_RUNTIME_CMD[@]}"; do
        [ "$e" = "$needle" ] && return 0
    done
    return 1
}

if contains_pair "--agent" "writer"; then
    pass "A-2: --agent writer presente"
else
    fail "A-2: falta --agent writer: ${MEFISTO_RUNTIME_CMD[*]}"
fi

if contains_pair "--dir" "$TMP"; then
    pass "A-3: --dir <cwd> presente"
else
    fail "A-3: falta --dir $TMP: ${MEFISTO_RUNTIME_CMD[*]}"
fi

if contains_pair "--format" "json" && contains_elem "--auto"; then
    pass "A-4: --format json --auto presente"
else
    fail "A-4: falta --format json --auto: ${MEFISTO_RUNTIME_CMD[*]}"
fi

if contains_pair "-m" "openai/gpt-5"; then
    pass "A-5: -m openai/gpt-5 presente cuando se recibe modelo no vacio"
else
    fail "A-5: falta -m openai/gpt-5: ${MEFISTO_RUNTIME_CMD[*]}"
fi

LAST_IDX=$(( ${#MEFISTO_RUNTIME_CMD[@]} - 1 ))
MESSAGE="${MEFISTO_RUNTIME_CMD[$LAST_IDX]}"
EXPECTED_MESSAGE="You are running in non-interactive print mode."$'\n\n'"Instrucciones de prueba."
if [ "$MESSAGE" = "$EXPECTED_MESSAGE" ]; then
    pass "A-6: el mensaje final es '<system-file>\\n\\n<prompt>' como UN elemento del array"
else
    fail "A-6: el mensaje no coincide: '$MESSAGE'"
fi

# Modelo vacio (heredar, CA-1 de #858): NUNCA debe verse -m en el argv.
MEFISTO_RUNTIME_CMD=()
runtime_opencode_build_cmd "writer" "$TMP" "$PROMPT_PLAIN" "" ""
if ! contains_elem "-m"; then
    pass "A-7: modelo vacio (heredar) -> ningun -m en el argv"
else
    fail "A-7: modelo vacio pero el argv trae -m: ${MEFISTO_RUNTIME_CMD[*]}"
fi
LAST_IDX=$(( ${#MEFISTO_RUNTIME_CMD[@]} - 1 ))
if [ "${MEFISTO_RUNTIME_CMD[$LAST_IDX]}" = "Instrucciones de prueba." ]; then
    pass "A-8: --system-file vacio -> el mensaje es SOLO el prompt, sin prefijo"
else
    fail "A-8: el mensaje trae un prefijo espurio: '${MEFISTO_RUNTIME_CMD[$LAST_IDX]}'"
fi

# El prompt puede traer backticks/$()/comillas -- sin eval, viajan literales.
PROMPT_DANGEROUS="$TMP/prompt-dangerous.txt"
printf 'Linea con `comando`, $(echo pwned) y "comillas".' > "$PROMPT_DANGEROUS"
MEFISTO_RUNTIME_CMD=()
runtime_opencode_build_cmd "writer" "$TMP" "$PROMPT_DANGEROUS" "" ""
LAST_IDX=$(( ${#MEFISTO_RUNTIME_CMD[@]} - 1 ))
if [ "${MEFISTO_RUNTIME_CMD[$LAST_IDX]}" = 'Linea con `comando`, $(echo pwned) y "comillas".' ]; then
    pass "A-9: backticks/\$()/comillas del prompt viajan literales, sin re-interpretarse (sin eval)"
else
    fail "A-9: el prompt se corrompio: '${MEFISTO_RUNTIME_CMD[$LAST_IDX]}'"
fi

# Modelo opaco con '/' y espacios -- el adaptador nunca lo interpreta, solo lo reenvia.
MEFISTO_RUNTIME_CMD=()
runtime_opencode_build_cmd "writer" "$TMP" "$PROMPT_PLAIN" "openai/gpt-4.1 mini" ""
if contains_pair "-m" "openai/gpt-4.1 mini"; then
    pass "A-10: modelo opaco con '/' y espacios reenviado literal"
else
    fail "A-10: el modelo opaco no llego intacto: ${MEFISTO_RUNTIME_CMD[*]}"
fi

# ============================================================================
echo ""
echo "[B] CA-2: mapeo de eventos (text->message, tool_use->tool.started+tool.completed, tipos ignorados)"

B_OUT="$TMP/b-tool.jsonl"
translate_fixture success-tool-1.18.29.jsonl "" 0 > "$B_OUT"

if jq -e 'select(.type=="message") | .role == "assistant" and .text == "- `archivo-demo.txt`"' "$B_OUT" >/dev/null 2>&1; then
    pass "B-1: el bloque 'text' se tradujo a message{role:assistant}"
else
    fail "B-1: el mensaje traducido no coincide: $(jq -c 'select(.type=="message")' "$B_OUT")"
fi

if jq -e 'select(.type=="tool.started") | .tool == "glob" and .input_summary == null' "$B_OUT" >/dev/null 2>&1; then
    pass "B-2: el tool_use (status completed) sintetizo tool.started{tool:'glob', input_summary:null}"
else
    fail "B-2: no se encontro el tool.started esperado: $(jq -c 'select(.type=="tool.started")' "$B_OUT")"
fi

if jq -e 'select(.type=="tool.completed") | .tool == "glob" and .ok == true and .duration_ms == 92' "$B_OUT" >/dev/null 2>&1; then
    pass "B-3: el mismo tool_use sintetizo tool.completed{tool:'glob', ok:true, duration_ms:92} (state.time.end - state.time.start)"
else
    fail "B-3: no se encontro el tool.completed esperado: $(jq -c 'select(.type=="tool.completed")' "$B_OUT")"
fi

STARTED_TS="$(jq -r 'select(.type=="tool.started") | .ts' "$B_OUT")"
COMPLETED_TS="$(jq -r 'select(.type=="tool.completed") | .ts' "$B_OUT")"
FIRST_MSG_TS="$(jq -r 'select(.type=="message") | .ts' "$B_OUT" | head -n1)"
if [ "$STARTED_TS" \< "$COMPLETED_TS" ] || [ "$STARTED_TS" = "$COMPLETED_TS" ]; then
    if [ "$COMPLETED_TS" \< "$FIRST_MSG_TS" ] || [ "$COMPLETED_TS" = "$FIRST_MSG_TS" ]; then
        pass "B-4: orden temporal tool.started <= tool.completed <= message (mismo orden del stream)"
    else
        fail "B-4: tool.completed no precede al message: started=$STARTED_TS completed=$COMPLETED_TS message=$FIRST_MSG_TS"
    fi
else
    fail "B-4: tool.started no precede a tool.completed: started=$STARTED_TS completed=$COMPLETED_TS"
fi

if [ "$(grep -c '"type":"step_start"' "$B_OUT")" = "0" ] && [ "$(grep -c '"type":"step_finish"' "$B_OUT")" = "0" ]; then
    pass "B-5: step_start/step_finish nunca se re-emiten como linea propia (tipos reconocidos pero no traducidos)"
else
    fail "B-5: el adaptador re-emitio un evento step_start/step_finish espurio"
fi

if [ "$(grep -c '"type":"run.started"' "$B_OUT")" = "0" ]; then
    pass "B-6: runtime_opencode_translate nunca emite 'run.started' (responsabilidad exclusiva del runner)"
else
    fail "B-6: el adaptador emitio 'run.started' -- viola la interfaz de #858"
fi

# tool_use con status "error" -> tool.completed{ok:false}.
B_ERR_FIXTURE="$TMP/tool-error.jsonl"
cat > "$B_ERR_FIXTURE" <<'EOF'
{"type":"step_start","timestamp":1788666719871,"sessionID":"ses_err","part":{"id":"prt_1","messageID":"msg_1","sessionID":"ses_err","type":"step-start"}}
{"type":"tool_use","timestamp":1788666720782,"sessionID":"ses_err","part":{"type":"tool","tool":"read","callID":"call_1","state":{"status":"error","input":{"filePath":"/no/existe.txt"},"error":"File not found","time":{"start":1788666720768,"end":1788666720779}},"id":"prt_2","sessionID":"ses_err","messageID":"msg_1"}}
{"type":"step_finish","timestamp":1788666720829,"sessionID":"ses_err","part":{"id":"prt_3","reason":"tool-calls","messageID":"msg_1","sessionID":"ses_err","type":"step-finish","tokens":{"total":10,"input":8,"output":2},"cost":0}}
{"type":"text","timestamp":1788666724629,"sessionID":"ses_err","part":{"id":"prt_4","messageID":"msg_2","sessionID":"ses_err","type":"text","text":"El archivo no existe.","time":{"start":1788666723957,"end":1788666724623}}}
{"type":"step_finish","timestamp":1788666724691,"sessionID":"ses_err","part":{"id":"prt_5","reason":"stop","messageID":"msg_2","sessionID":"ses_err","type":"step-finish","tokens":{"total":20,"input":15,"output":5},"cost":0}}
EOF
B_ERR_OUT="$TMP/b-tool-error.jsonl"
runtime_opencode_translate "$B_ERR_FIXTURE" "opencode" "" 0 > "$B_ERR_OUT"
if jq -e 'select(.type=="tool.completed") | .ok == false' "$B_ERR_OUT" >/dev/null 2>&1; then
    pass "B-7: tool_use con state.status=='error' -> tool.completed{ok:false}"
else
    fail "B-7: no se tradujo el error de tool como ok:false: $(jq -c 'select(.type=="tool.completed")' "$B_ERR_OUT")"
fi

# Tipo de evento nunca visto (forward-compat, CA-2): se descarta en silencio,
# nunca aparece en el JSONL neutral (el diagnostico raw_ignored vive solo en
# el stderr del propio programa jq, ver cabecera de runtime-opencode.jq).
B_UNKNOWN_FIXTURE="$TMP/unknown-type.jsonl"
cat > "$B_UNKNOWN_FIXTURE" <<'EOF'
{"type":"step_start","timestamp":1000,"sessionID":"ses_u","part":{"type":"step-start"}}
{"type":"reasoning_delta","timestamp":1001,"sessionID":"ses_u","part":{"text":"pensando..."}}
{"type":"text","timestamp":1002,"sessionID":"ses_u","part":{"text":"listo"}}
{"type":"step_finish","timestamp":1003,"sessionID":"ses_u","part":{"tokens":{"input":1,"output":1},"cost":0}}
EOF
B_UNKNOWN_OUT="$TMP/b-unknown.jsonl"
runtime_opencode_translate "$B_UNKNOWN_FIXTURE" "opencode" "" 0 > "$B_UNKNOWN_OUT"
if [ "$(grep -c 'reasoning_delta' "$B_UNKNOWN_OUT")" = "0" ] && [ "$(jq -c 'select(.type=="message")' "$B_UNKNOWN_OUT" | wc -l | tr -d ' ')" = "1" ]; then
    pass "B-8: un tipo de evento desconocido ('reasoning_delta') se descarta sin filtrarse al JSONL neutral"
else
    fail "B-8: el tipo desconocido se filtro al JSONL neutral: $(cat "$B_UNKNOWN_OUT")"
fi

# `raw_ignored` (CA-2): el conteo vive SOLO en el canal de diagnostico del
# propio programa jq (run-events.schema.json fija additionalProperties:false
# sobre el terminal y este issue no lo modifica), asi que hay que invocar el
# programa a mano, sin el `2>/dev/null` con el que lo silencia
# runtime_opencode_translate. Los dos tipos que se esperan contados incluyen
# uno ('step') que es SUBCADENA de un tipo conocido ('step_start'): con una
# membresia por subcadena se lo tragaria como reconocido y el diagnostico
# mentiria por lo bajo.
B_IGNORED_FIXTURE="$TMP/raw-ignored.jsonl"
cat > "$B_IGNORED_FIXTURE" <<'EOF'
{"type":"step_start","timestamp":1000,"sessionID":"ses_i","part":{"type":"step-start"}}
{"type":"step","timestamp":1001,"sessionID":"ses_i","part":{"text":"tipo futuro, subcadena de step_start"}}
{"type":"reasoning_delta","timestamp":1002,"sessionID":"ses_i","part":{"text":"pensando..."}}
{"type":"text","timestamp":1003,"sessionID":"ses_i","part":{"text":"listo"}}
{"type":"step_finish","timestamp":1004,"sessionID":"ses_i","part":{"tokens":{"input":1,"output":1},"cost":0}}
EOF
B_IGNORED_ERR="$TMP/raw-ignored.stderr"
B_IGNORED_OUT="$TMP/raw-ignored.out.jsonl"
jq -R -s -c \
    --arg runtime "opencode" --arg model_param "" --arg exit_code "0" \
    --rawfile stderr_text /dev/null \
    -f "$OPENCODE_JQ" "$B_IGNORED_FIXTURE" > "$B_IGNORED_OUT" 2> "$B_IGNORED_ERR"
if grep -q 'raw_ignored=2' "$B_IGNORED_ERR"; then
    pass "B-9: raw_ignored=2 por el canal de diagnostico (membresia EXACTA: 'step' no lo absorbe 'step_start')"
else
    fail "B-9: el diagnostico no reporto raw_ignored=2: $(cat "$B_IGNORED_ERR")"
fi
if ! grep -q 'raw_ignored' "$B_IGNORED_OUT"; then
    pass "B-10: raw_ignored NUNCA aparece en el JSONL neutral (el terminal es additionalProperties:false)"
else
    fail "B-10: raw_ignored se filtro al JSONL neutral: $(cat "$B_IGNORED_OUT")"
fi

# ============================================================================
echo ""
echo "[C] CA-3: clasificacion completa"

C_SUCCESS="$TMP/c-success.jsonl"; translate_fixture success-1.18.29.jsonl "" 0 > "$C_SUCCESS"
if jq -e 'select(.type=="run.completed") | .status == "success" and .error == null' "$C_SUCCESS" >/dev/null 2>&1; then
    pass "C-1: exit 0 + al menos un message -> run.completed{status:success}"
else
    fail "C-1: el fixture de exito no produjo el terminal esperado: $(jq -c 'select(.type=="run.completed" or .type=="run.failed")' "$C_SUCCESS")"
fi

C_NONZERO="$TMP/c-nonzero.jsonl"; translate_fixture success-1.18.29.jsonl "" 1 > "$C_NONZERO"
if jq -e 'select(.type=="run.failed") | .status == "failed" and .error.kind == "nonzero_exit"' "$C_NONZERO" >/dev/null 2>&1; then
    pass "C-2: exit != 0 (incluso con texto visible en el stream) -> run.failed{error.kind:nonzero_exit} (gana sobre el contenido)"
else
    fail "C-2: no se clasifico el exit 1 como nonzero_exit: $(jq -c 'select(.type=="run.failed")' "$C_NONZERO")"
fi

STDERR_FILE="$TMP/stderr.log"; printf 'ruido previo\nOpenAI: rate limit exceeded\n' > "$STDERR_FILE"
C_STDERR="$TMP/c-stderr.jsonl"; translate_fixture success-1.18.29.jsonl "" 1 "$STDERR_FILE" > "$C_STDERR"
if jq -e 'select(.type=="run.failed") | .error.kind == "nonzero_exit" and (.error.detail | contains("rate limit exceeded"))' "$C_STDERR" >/dev/null 2>&1; then
    pass "C-3: exit != 0 con stderr -> el detalle incluye las ultimas lineas de stderr (sin '429': nonzero_exit, no rate_limit)"
else
    fail "C-3: no se clasifico como se esperaba: $(jq -c 'select(.type=="run.failed")' "$C_STDERR")"
fi

# issue #965: patron conservador -- hace falta "429" JUNTO con "rate limit"
# (evidencia real: anomalyco/opencode#42029, `Error: 429: {"type":
# "FreeUsageLimitError","message":"...Rate limit exceeded..."}`).
STDERR_RL="$TMP/stderr-ratelimit.log"
printf 'Error: 429: {"type":"FreeUsageLimitError","message":"Error from provider (Console): Rate limit exceeded. Please try again later."}\n' > "$STDERR_RL"
C_RATELIMIT="$TMP/c-ratelimit.jsonl"; translate_fixture success-1.18.29.jsonl "" 1 "$STDERR_RL" > "$C_RATELIMIT"
if jq -e 'select(.type=="run.failed") | .error.kind == "rate_limit" and .resets_at == null' "$C_RATELIMIT" >/dev/null 2>&1; then
    pass "C-3b: '429' + 'Rate limit exceeded' en stderr -> run.failed{error.kind:rate_limit, resets_at:null} (issue #965)"
else
    fail "C-3b: no se clasifico la ventana agotada como se esperaba: $(jq -c 'select(.type=="run.failed")' "$C_RATELIMIT")"
fi

C_EMPTY="$TMP/c-empty.jsonl"; translate_fixture empty-1.18.29.jsonl "" 0 > "$C_EMPTY"
if jq -e 'select(.type=="run.failed") | .error.kind == "no_result"' "$C_EMPTY" >/dev/null 2>&1; then
    pass "C-4: stream vacio -> run.failed{error.kind:no_result}"
else
    fail "C-4: no se clasifico el stream vacio como no_result: $(jq -c 'select(.type=="run.failed")' "$C_EMPTY")"
fi

C_MALFORMED="$TMP/c-malformed.jsonl"; translate_fixture malformed-1.18.29.jsonl "" 0 > "$C_MALFORMED"
if jq -e 'select(.type=="run.failed") | .error.kind == "protocol_invalid"' "$C_MALFORMED" >/dev/null 2>&1; then
    pass "C-5: linea no-JSON -> run.failed{error.kind:protocol_invalid}"
else
    fail "C-5: no se clasifico la linea malformada como protocol_invalid: $(jq -c 'select(.type=="run.failed")' "$C_MALFORMED")"
fi

C_NOTEXT="$TMP/c-notext.jsonl"; translate_fixture no-visible-text-1.18.29.jsonl "" 0 > "$C_NOTEXT"
if jq -e 'select(.type=="run.failed") | .error.kind == "no_result"' "$C_NOTEXT" >/dev/null 2>&1; then
    pass "C-6: exit 0 sin ningun texto visible del asistente -> run.failed{error.kind:no_result}"
else
    fail "C-6: no se clasifico la ausencia de texto como no_result: $(jq -c 'select(.type=="run.failed")' "$C_NOTEXT")"
fi

for f in "$C_SUCCESS" "$C_NONZERO" "$C_STDERR" "$C_EMPTY" "$C_MALFORMED" "$C_NOTEXT"; do
    T=$(count_terminals "$f")
    if [ "$T" = "1" ]; then
        pass "C-7 ($(basename "$f")): exactamente 1 evento terminal"
    else
        fail "C-7 ($(basename "$f")): se contaron $T eventos terminales (se esperaba 1)"
    fi
done

# ============================================================================
echo ""
echo "[D] CA-4: el terminal SUMA los step_finish de session_id/tokens/cost_usd; turns/denials/ttft_ms/api_duration_ms siempre null; model degrada al parametro"

D_OUT="$TMP/d-full.jsonl"; translate_fixture success-tool-1.18.29.jsonl "" 0 > "$D_OUT"
TERM="$(jq -c 'select(.type=="run.completed")' "$D_OUT")"
assert_field() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc (esperado '$expected', obtenido '$actual')"
    fi
}
assert_field "D-1: session_id (del ultimo step_finish/evento con sessionID)" "ses_f8b28e18effew6dRCNC6Tm8NHq" "$(echo "$TERM" | jq -r '.session_id')"
assert_field "D-2: tokens.input = SUMA de los dos step_finish (6127+6167), no el ultimo" "12294" "$(echo "$TERM" | jq -r '.tokens.input')"
assert_field "D-3: tokens.output = SUMA de los dos step_finish (17+10), no el ultimo" "27" "$(echo "$TERM" | jq -r '.tokens.output')"
assert_field "D-4: cost_usd = SUMA de los step_finish (incluso si el total es 0)" "0" "$(echo "$TERM" | jq -r '.cost_usd')"

# Cada `step_finish` reporta lo de SU paso, no un acumulado: quedarse con el
# ultimo reportaria el costo del cierre de la corrida como el de la corrida
# entera, y mefisto-metrics-report.sh lo propaga a cost_usd_total. Con costos
# distintos por paso el error se vuelve visible (el fixture real trae 0 en
# ambos, que no distingue suma de "ultimo").
D_COST_FIXTURE="$TMP/multi-cost.jsonl"
cat > "$D_COST_FIXTURE" <<'EOF'
{"type":"step_finish","timestamp":1000,"sessionID":"ses_c","part":{"type":"step-finish","reason":"tool-calls","tokens":{"input":100,"output":10},"cost":0.25}}
{"type":"text","timestamp":1001,"sessionID":"ses_c","part":{"type":"text","text":"listo"}}
{"type":"step_finish","timestamp":1002,"sessionID":"ses_c","part":{"type":"step-finish","reason":"stop","tokens":{"input":200,"output":20},"cost":0.5}}
EOF
D_COST_OUT="$TMP/d-multi-cost.jsonl"
runtime_opencode_translate "$D_COST_FIXTURE" "opencode" "" 0 > "$D_COST_OUT"
TERM_COST="$(jq -c 'select(.type=="run.completed")' "$D_COST_OUT")"
assert_field "D-4b: cost_usd suma pasos con costo distinto (0.25+0.5)" "0.75" "$(echo "$TERM_COST" | jq -r '.cost_usd')"
assert_field "D-4c: tokens.input suma pasos (100+200)" "300" "$(echo "$TERM_COST" | jq -r '.tokens.input')"
assert_field "D-4d: tokens.output suma pasos (10+20)" "30" "$(echo "$TERM_COST" | jq -r '.tokens.output')"
assert_field "D-5: turns siempre null (sin equivalente en el wire format)" "null" "$(echo "$TERM" | jq -r '.turns')"
assert_field "D-6: denials siempre null (sin equivalente en el wire format)" "null" "$(echo "$TERM" | jq -r '.denials')"
assert_field "D-7: ttft_ms siempre null (sin equivalente en el wire format)" "null" "$(echo "$TERM" | jq -r '.ttft_ms')"
assert_field "D-8: api_duration_ms siempre null (sin equivalente en el wire format)" "null" "$(echo "$TERM" | jq -r '.api_duration_ms')"
assert_field "D-9: model sin parametro -> null (el wire format nunca lo trae)" "null" "$(echo "$TERM" | jq -r '.model')"

D_MODEL_OUT="$TMP/d-model.jsonl"; translate_fixture success-tool-1.18.29.jsonl "openai/gpt-5" 0 > "$D_MODEL_OUT"
assert_field "D-10: model degrada siempre al parametro pedido (opaco, reenviado literal)" "openai/gpt-5" "$(jq -r 'select(.type=="run.completed") | .model' "$D_MODEL_OUT")"

D_EMPTY_OUT="$TMP/d-empty.jsonl"; translate_fixture empty-1.18.29.jsonl "" 0 > "$D_EMPTY_OUT"
TERM_EMPTY="$(jq -c 'select(.type=="run.failed")' "$D_EMPTY_OUT")"
assert_field "D-11: session_id ausente (stream vacio) -> null" "null" "$(echo "$TERM_EMPTY" | jq -r '.session_id')"
assert_field "D-12: tokens.input ausente -> null (nunca 0)" "null" "$(echo "$TERM_EMPTY" | jq -r '.tokens.input')"
assert_field "D-13: cost_usd ausente -> null (nunca 0)" "null" "$(echo "$TERM_EMPTY" | jq -r '.cost_usd')"

# ============================================================================
echo ""
echo "[E] CA-5: ninguna ruta/variable de credenciales aparece en el adaptador ni se filtra al argv/JSONL"

for pattern in "auth\.json" "OPENAI_API_KEY" "ANTHROPIC_API_KEY"; do
    if grep -Eqi "$pattern" "$OPENCODE_LIB" "$OPENCODE_JQ"; then
        fail "E-1 ($pattern): aparece en runtime-opencode.sh/.jq"
    else
        pass "E-1 ($pattern): no aparece en runtime-opencode.sh/.jq"
    fi
done

SECRET_OPENAI="sk-fake-secret-value-xyz-789"
SECRET_ANTHROPIC="sk-ant-fake-secret-value-abc-123"
(
    export OPENAI_API_KEY="$SECRET_OPENAI"
    export ANTHROPIC_API_KEY="$SECRET_ANTHROPIC"
    MEFISTO_RUNTIME_CMD=()
    runtime_opencode_build_cmd "writer" "$TMP" "$PROMPT_PLAIN" "" "$SYSTEM_FILE"
    printf '%s\0' "${MEFISTO_RUNTIME_CMD[@]}" > "$TMP/e-argv.bin"
)
if ! grep -qa "$SECRET_OPENAI" "$TMP/e-argv.bin" && ! grep -qa "$SECRET_ANTHROPIC" "$TMP/e-argv.bin"; then
    pass "E-2: build_cmd no incorpora OPENAI_API_KEY/ANTHROPIC_API_KEY del entorno en el argv que compone"
else
    fail "E-2: el argv compuesto por build_cmd contiene un secreto del entorno"
fi

E_EV="$TMP/e-events.jsonl"
(
    export OPENAI_API_KEY="$SECRET_OPENAI"
    export ANTHROPIC_API_KEY="$SECRET_ANTHROPIC"
    export PATH="$TMP/e-bin:$PATH"
    mkdir -p "$TMP/e-bin"
    cat > "$TMP/e-bin/opencode" <<STUBEOF
#!/usr/bin/env bash
cat "$FIXTURES_DIR/success-1.18.29.jsonl"
exit 0
STUBEOF
    chmod +x "$TMP/e-bin/opencode"
    unset MEFISTO_RUNTIME
    "$RUNNER" --runtime opencode --agent test-agent --cwd "$TMP" \
        --prompt-file "$PROMPT_PLAIN" --event-log "$E_EV" >/dev/null 2>&1
)
if [ -f "$E_EV" ] && ! grep -qa "$SECRET_OPENAI" "$E_EV" && ! grep -qa "$SECRET_ANTHROPIC" "$E_EV"; then
    pass "E-3: el JSONL producido por una corrida real (secretos en el entorno) nunca los reproduce"
else
    fail "E-3: el JSONL contiene un secreto del entorno: $(cat "$E_EV" 2>/dev/null)"
fi

# ============================================================================
echo ""
echo "[F] CA-6: runner real (mefisto-run-agent.sh --runtime opencode) contra la CLI falsa"

WORKDIR="$TMP/wt-f"; mkdir -p "$WORKDIR"
PROMPT_FILE="$TMP/prompt-f.txt"; echo "prompt" > "$PROMPT_FILE"
STUB_BIN="$TMP/bin-stub"; mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/opencode" <<'STUBEOF'
#!/usr/bin/env bash
# NUL-separado (no newline-separado): el mensaje final del argv trae saltos
# de linea EMBEBIDOS (system-file + "\n\n" + prompt, CA-1), y un separador de
# newline lo partiria en varios campos espurios.
if [ -n "${MEFISTO_OPENCODE_STUB_ARGS_FILE:-}" ]; then
    : > "$MEFISTO_OPENCODE_STUB_ARGS_FILE"
    for a in "$@"; do
        printf '%s\0' "$a" >> "$MEFISTO_OPENCODE_STUB_ARGS_FILE"
    done
fi
if [ -n "${MEFISTO_OPENCODE_STUB_SLEEP:-}" ]; then
    sleep "$MEFISTO_OPENCODE_STUB_SLEEP"
fi
if [ -n "${MEFISTO_OPENCODE_STUB_FIXTURE:-}" ] && [ -f "$MEFISTO_OPENCODE_STUB_FIXTURE" ]; then
    cat "$MEFISTO_OPENCODE_STUB_FIXTURE"
fi
if [ -n "${MEFISTO_OPENCODE_STUB_STDERR:-}" ]; then
    printf '%s\n' "$MEFISTO_OPENCODE_STUB_STDERR" >&2
fi
exit "${MEFISTO_OPENCODE_STUB_EXIT:-0}"
STUBEOF
chmod +x "$STUB_BIN/opencode"

# read_nul_args <file> -- rellena el array global NUL_ARGS con los campos
# NUL-separados de <file>. A diferencia de un split por linea, preserva
# intactos los saltos de linea EMBEBIDOS del mensaje final (system-file +
# "\n\n" + prompt, CA-1).
read_nul_args() {
    NUL_ARGS=()
    local field
    while IFS= read -r -d '' field; do
        NUL_ARGS+=("$field")
    done < "$1"
}

nul_args_contains() {
    local needle="$1" e
    for e in "${NUL_ARGS[@]}"; do
        [ "$e" = "$needle" ] && return 0
    done
    return 1
}

# nul_args_pair_value <flag> -- imprime por stdout el elemento de NUL_ARGS
# inmediatamente posterior a <flag>; vacio (exit 1) si <flag> no aparece.
nul_args_pair_value() {
    local flag="$1" i
    for ((i=0; i<${#NUL_ARGS[@]}-1; i++)); do
        if [ "${NUL_ARGS[$i]}" = "$flag" ]; then
            printf '%s' "${NUL_ARGS[$((i+1))]}"
            return 0
        fi
    done
    return 1
}

ORIG_PATH="$PATH"
export PATH="$STUB_BIN:$PATH"
unset MEFISTO_RUNTIME

run_opencode_scenario() {
    # run_opencode_scenario <event_log> [args del runner...]
    local ev="$1"; shift
    "$RUNNER" --runtime opencode --agent test-agent --cwd "$WORKDIR" \
        --prompt-file "$PROMPT_FILE" --event-log "$ev" "$@" >/dev/null 2>&1
    echo $?
}

check_scenario() {
    local desc="$1" ev="$2" expected_exit="$3" expected_status="$4" expected_error_kind="$5" rc="$6"

    if [ "$rc" = "$expected_exit" ]; then
        pass "$desc: exit $rc"
    else
        fail "$desc: exit $rc (esperaba $expected_exit)"
    fi

    if [ ! -s "$ev" ]; then
        fail "$desc: --event-log vacio o inexistente"
        return
    fi

    check_all_lines_valid "$desc" "$ev"

    local terms
    terms=$(count_terminals "$ev")
    if [ "$terms" = "1" ]; then
        pass "$desc: exactamente 1 evento terminal en --event-log"
    else
        fail "$desc: se contaron $terms eventos terminales (se esperaba 1)"
    fi

    local last_status last_kind
    last_status="$(jq -r 'select(.type=="run.completed" or .type=="run.failed") | .status' "$ev" 2>/dev/null | tail -n1)"
    if [ "$last_status" = "$expected_status" ]; then
        pass "$desc: status='$last_status'"
    else
        fail "$desc: status='$last_status' (esperaba '$expected_status')"
    fi

    if [ -n "$expected_error_kind" ]; then
        last_kind="$(jq -r 'select(.type=="run.completed" or .type=="run.failed") | .error.kind // empty' "$ev" 2>/dev/null | tail -n1)"
        if [ "$last_kind" = "$expected_error_kind" ]; then
            pass "$desc: error.kind='$last_kind'"
        else
            fail "$desc: error.kind='$last_kind' (esperaba '$expected_error_kind')"
        fi
    fi
}

F_EV="$TMP/f-success.jsonl"
RC=$(MEFISTO_OPENCODE_STUB_FIXTURE="$FIXTURES_DIR/success-1.18.29.jsonl" MEFISTO_OPENCODE_STUB_EXIT=0 run_opencode_scenario "$F_EV")
check_scenario "exito" "$F_EV" 0 "success" "" "$RC"

F_EV="$TMP/f-fail1.jsonl"
RC=$(MEFISTO_OPENCODE_STUB_FIXTURE="$FIXTURES_DIR/success-1.18.29.jsonl" MEFISTO_OPENCODE_STUB_EXIT=1 run_opencode_scenario "$F_EV")
check_scenario "fallo con exit 1" "$F_EV" 1 "failed" "nonzero_exit" "$RC"

F_EV="$TMP/f-timeout.jsonl"
RC=$(MEFISTO_OPENCODE_STUB_FIXTURE="$FIXTURES_DIR/success-1.18.29.jsonl" MEFISTO_OPENCODE_STUB_SLEEP=3600 run_opencode_scenario "$F_EV" --timeout 1)
check_scenario "timeout (stub que duerme)" "$F_EV" 124 "timeout" "timeout" "$RC"

F_EV="$TMP/f-empty.jsonl"
RC=$(MEFISTO_OPENCODE_STUB_EXIT=0 run_opencode_scenario "$F_EV")
check_scenario "stream vacio" "$F_EV" 1 "failed" "no_result" "$RC"

F_EV="$TMP/f-malformed.jsonl"
RC=$(MEFISTO_OPENCODE_STUB_FIXTURE="$FIXTURES_DIR/malformed-1.18.29.jsonl" MEFISTO_OPENCODE_STUB_EXIT=0 run_opencode_scenario "$F_EV")
check_scenario "JSON malformado" "$F_EV" 1 "failed" "protocol_invalid" "$RC"

F_EV="$TMP/f-notext.jsonl"
RC=$(MEFISTO_OPENCODE_STUB_FIXTURE="$FIXTURES_DIR/no-visible-text-1.18.29.jsonl" MEFISTO_OPENCODE_STUB_EXIT=0 run_opencode_scenario "$F_EV")
check_scenario "exit 0 sin texto visible" "$F_EV" 1 "failed" "no_result" "$RC"

F_EV="$TMP/f-model-heredado.jsonl"
F_ARGS="$TMP/f-model-heredado.args"
RC=$(MEFISTO_OPENCODE_STUB_FIXTURE="$FIXTURES_DIR/success-1.18.29.jsonl" MEFISTO_OPENCODE_STUB_EXIT=0 MEFISTO_OPENCODE_STUB_ARGS_FILE="$F_ARGS" run_opencode_scenario "$F_EV")
check_scenario "modelo heredado (sin -m)" "$F_EV" 0 "success" "" "$RC"
read_nul_args "$F_ARGS"
if ! nul_args_contains "-m"; then
    pass "modelo heredado: -m NO aparece en la linea de comando capturada"
else
    fail "modelo heredado: -m aparecio en la linea de comando capturada"
fi

F_EV="$TMP/f-model-opaco.jsonl"
F_ARGS="$TMP/f-model-opaco.args"
RC=$(MEFISTO_OPENCODE_STUB_FIXTURE="$FIXTURES_DIR/success-1.18.29.jsonl" MEFISTO_OPENCODE_STUB_EXIT=0 MEFISTO_OPENCODE_STUB_ARGS_FILE="$F_ARGS" run_opencode_scenario "$F_EV" --model "openai/gpt-4.1 mini")
check_scenario "modelo opaco con / y espacios" "$F_EV" 0 "success" "" "$RC"
read_nul_args "$F_ARGS"
if [ "$(nul_args_pair_value "-m")" = "openai/gpt-4.1 mini" ]; then
    pass "modelo opaco: 'openai/gpt-4.1 mini' reenviado literal en la linea de comando capturada"
else
    fail "modelo opaco: no se encontro el modelo opaco intacto: '$(nul_args_pair_value "-m")'"
fi

F_EV="$TMP/f-system-prefix.jsonl"
F_ARGS="$TMP/f-system-prefix.args"
SYSTEM_FILE_F="$TMP/system-f.txt"; printf 'You are running in non-interactive print mode.' > "$SYSTEM_FILE_F"
RC=$(MEFISTO_OPENCODE_STUB_FIXTURE="$FIXTURES_DIR/success-1.18.29.jsonl" MEFISTO_OPENCODE_STUB_EXIT=0 MEFISTO_OPENCODE_STUB_ARGS_FILE="$F_ARGS" run_opencode_scenario "$F_EV" --system-file "$SYSTEM_FILE_F")
check_scenario "prefijo de --system-file al inicio del mensaje" "$F_EV" 0 "success" "" "$RC"
read_nul_args "$F_ARGS"
MSG_IDX=$(( ${#NUL_ARGS[@]} - 1 ))
MSG="${NUL_ARGS[$MSG_IDX]}"
case "$MSG" in
    "You are running in non-interactive print mode."$'\n\n'*)
        pass "system-file: el mensaje capturado (ultimo elemento del argv) empieza con el contenido de --system-file" ;;
    *)
        fail "system-file: el mensaje capturado no empieza con el system-file: '$MSG'" ;;
esac

export PATH="$ORIG_PATH"

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
