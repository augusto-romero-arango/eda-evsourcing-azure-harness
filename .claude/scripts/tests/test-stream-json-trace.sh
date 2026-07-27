#!/usr/bin/env bash
# test-stream-json-trace.sh -- Tests de la captura/derivacion de la traza
# stream-json de un stage (issue #425).
#
# Contexto: `run_agent` invocaba `claude -p` con `--output-format text`, asi
# que el log de stage solo guardaba el texto final del agente -- cero tool
# calls, turnos, tokens o tiempos, y el 98.9% del wall-clock de un issue
# quedaba sin instrumentar. El arreglo (`.claude/scripts/_mefisto-common.sh`):
#
#   - run_agent_with_watchdog ahora redirige stdout y stderr a DOS archivos
#     separados (nunca `2>&1`): el stream JSON crudo viaja intacto y los
#     mensajes de error del CLI (texto plano) no lo corrompen (CA-2).
#   - derive_stage_log_from_stream reconstruye el log legible de siempre
#     (mismo nombre de archivo -- CA-3) a partir de ese stream: texto del
#     asistente + una linea "[tool] <nombre>" por tool call, con el stderr
#     anexado al final. Tolera un stream truncado a mitad de linea y una
#     traza vacia sin abortar el pipeline (CA-4). La clasificacion de fallos
#     de run_agent (API Error 4xx/5xx, corte de stream) sigue leyendo ese
#     mismo log derivado, sin cambios (CA-5).
#
# Ninguno de estos casos invoca el CLI real -- todo corre sobre fixtures de
# stream JSON escritas a mano (estilo test-watchdog-trabajo-util.sh, que
# tampoco invoca `claude`).
#
# Casos cubiertos:
#   [pre] derive_stage_log_from_stream y run_agent_with_watchdog estan
#         definidas en _mefisto-common.sh.
#   [A] Stream completo con tool calls -> el log derivado trae el texto del
#       asistente y una linea "[tool] <nombre>" por cada tool_use, en orden,
#       sin JSON crudo visible (CA-3).
#   [B] Stream truncado a mitad de linea -> la linea incompleta se ignora sin
#       abortar el pipeline (set -euo pipefail activo) y el texto de las
#       lineas completas anteriores no se pierde (CA-4).
#   [C] Traza vacia (stream vacio, sin stderr) -> no falla, log derivado vacio
#       (CA-4).
#   [D] .stderr.log con "API Error: 500" -> el texto llega al log derivado, en
#       el mismo lugar que hoy consultan los grep de clasificacion de
#       run_agent (CA-5); idem con "API Error: 400" y con un corte de stream
#       a mitad de respuesta (agent_log_has_stream_cut sigue detectandolo
#       sobre el log derivado, sin cambios).
#   [E] jq ausente -> degrada con gracia: no aborta, deja una nota legible y
#       de todos modos anexa el stderr (CA-4, notas tecnicas del issue).
#   [F] run_agent_with_watchdog separa stdout/stderr en dos archivos propios
#       (nunca los mezcla) -- verificado con un comando stand-in, no el CLI
#       real (CA-2).
#   [G] Evento `result` con is_error y stderr VACIO -> el error igual llega al
#       log derivado y la clasificacion de run_agent lo sigue viendo (CA-5).
#       Es el caso que de verdad ocurre: verificado contra el CLI v2.1.220
#       que una corrida fallida deja stderr sin una sola linea de error y
#       reporta todo dentro del evento `result` de stdout. Incluye el caso
#       negativo (un `result` sano no debe ensuciar el log) y una linea de
#       JSON valido pero no-objeto, que no debe tumbar la derivacion.
#
# Uso: .claude/scripts/tests/test-stream-json-trace.sh
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

# -------- Bloque pre: funciones existen --------

echo "[pre] Las funciones nuevas estan definidas en _mefisto-common.sh"
for fn in derive_stage_log_from_stream run_agent_with_watchdog; do
    if declare -F "$fn" >/dev/null; then
        pass "$fn definida"
    else
        fail "$fn NO definida"
    fi
done

# -------- Bloque A: stream completo con tool calls --------

echo ""
echo "[A] Stream completo con tool calls -> texto del asistente + una linea por tool call (CA-3)"

cat > "$TMP/a-stream.jsonl" <<'EOF'
{"type":"system","subtype":"init","session_id":"abc"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Voy a leer el archivo relevante."}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"x"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"contenido"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_2","name":"Write","input":{"file_path":"y"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"ok"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Listo, hice el cambio."}]}}
{"type":"result","num_turns":4,"duration_ms":4200,"duration_api_ms":3000,"total_cost_usd":0.02,"is_error":false}
EOF
: > "$TMP/a-stderr.log"

derive_stage_log_from_stream "$TMP/a-stream.jsonl" "$TMP/a-stderr.log" "$TMP/a-out.log"
RC=$?

if [ "$RC" -eq 0 ]; then
    pass "A-1: exit 0"
else
    fail "A-1: se esperaba exit 0, se obtuvo $RC"
fi

if grep -qF "Voy a leer el archivo relevante." "$TMP/a-out.log" && grep -qF "Listo, hice el cambio." "$TMP/a-out.log"; then
    pass "A-2: el texto del asistente (ambos turnos) llego al log derivado"
else
    fail "A-2: falta texto del asistente en el log derivado: $(cat "$TMP/a-out.log")"
fi

if grep -qF "[tool] Read" "$TMP/a-out.log" && grep -qF "[tool] Write" "$TMP/a-out.log"; then
    pass "A-3: una linea '[tool] <nombre>' por cada tool_use (Read y Write)"
else
    fail "A-3: no se encontraron las lineas de tool call esperadas: $(cat "$TMP/a-out.log")"
fi

if grep -q '"type"' "$TMP/a-out.log"; then
    fail "A-4: quedo JSON crudo visible en el log derivado"
else
    pass "A-4: el log derivado es texto legible, sin JSON crudo"
fi

ORDER_OK=$(awk '/Voy a leer/{a=NR} /\[tool\] Read/{b=NR} /\[tool\] Write/{c=NR} /Listo, hice el cambio/{d=NR} END{print (a<b && b<c && c<d) ? "si" : "no"}' "$TMP/a-out.log")
if [ "$ORDER_OK" = "si" ]; then
    pass "A-5: el orden del log derivado respeta el orden del stream"
else
    fail "A-5: el orden del log derivado no respeta el orden del stream"
fi

# -------- Bloque B: stream truncado a mitad de linea --------

echo ""
echo "[B] Stream truncado a mitad de linea -> se ignora sin abortar, no se pierde texto previo (CA-4)"

printf '{"type":"assistant","message":{"content":[{"type":"text","text":"primera linea completa"}]}}\n{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_9","name":"Bash","input":{"command":"ls' > "$TMP/b-stream.jsonl"
: > "$TMP/b-stderr.log"

(
    set -euo pipefail
    derive_stage_log_from_stream "$TMP/b-stream.jsonl" "$TMP/b-stderr.log" "$TMP/b-out.log"
)
RC=$?

if [ "$RC" -eq 0 ]; then
    pass "B-1: un stream truncado no aborta el pipeline (set -euo pipefail activo)"
else
    fail "B-1: se esperaba exit 0 bajo set -euo pipefail, se obtuvo $RC"
fi

if grep -qF "primera linea completa" "$TMP/b-out.log"; then
    pass "B-2: el texto de la linea completa anterior a la truncada no se pierde"
else
    fail "B-2: se perdio el texto de la linea completa: $(cat "$TMP/b-out.log" 2>/dev/null)"
fi

if grep -qF "toolu_9" "$TMP/b-out.log"; then
    fail "B-3: la linea truncada (JSON invalido) no deberia haberse colado en el log"
else
    pass "B-3: la linea truncada se ignoro (no aparece en el log derivado)"
fi

# -------- Bloque C: traza vacia --------

echo ""
echo "[C] Traza vacia (stream vacio, sin stderr) -> no falla, log derivado vacio (CA-4)"

: > "$TMP/c-stream.jsonl"
: > "$TMP/c-stderr.log"

(
    set -euo pipefail
    derive_stage_log_from_stream "$TMP/c-stream.jsonl" "$TMP/c-stderr.log" "$TMP/c-out.log"
)
RC=$?

if [ "$RC" -eq 0 ]; then
    pass "C-1: traza vacia no aborta el pipeline"
else
    fail "C-1: se esperaba exit 0 con traza vacia, se obtuvo $RC"
fi

if [ -f "$TMP/c-out.log" ] && [ ! -s "$TMP/c-out.log" ]; then
    pass "C-2: el log derivado existe y queda vacio (nada que perder)"
else
    fail "C-2: el log derivado deberia existir y estar vacio: $(cat "$TMP/c-out.log" 2>/dev/null)"
fi

# -------- Bloque D: .stderr.log con errores del CLI llega al log derivado --------

echo ""
echo "[D] .stderr.log con errores del CLI -> el texto llega al log derivado, donde run_agent clasifica (CA-5)"

: > "$TMP/d-stream.jsonl"

echo "API Error: 500 Internal Server Error" > "$TMP/d-stderr-5xx.log"
derive_stage_log_from_stream "$TMP/d-stream.jsonl" "$TMP/d-stderr-5xx.log" "$TMP/d-out-5xx.log"
if grep -q "API Error: 5" "$TMP/d-out-5xx.log"; then
    pass "D-1: 'API Error: 500' del .stderr.log llega al log derivado (mismo grep que usa run_agent para API_ERROR_SERVER)"
else
    fail "D-1: no se encontro 'API Error: 5' en el log derivado: $(cat "$TMP/d-out-5xx.log")"
fi

echo "API Error: 400 Bad Request" > "$TMP/d-stderr-4xx.log"
derive_stage_log_from_stream "$TMP/d-stream.jsonl" "$TMP/d-stderr-4xx.log" "$TMP/d-out-4xx.log"
if grep -q "API Error: 4" "$TMP/d-out-4xx.log"; then
    pass "D-2: 'API Error: 400' del .stderr.log llega al log derivado (mismo grep que usa run_agent para API_ERROR_CLIENT)"
else
    fail "D-2: no se encontro 'API Error: 4' en el log derivado: $(cat "$TMP/d-out-4xx.log")"
fi

echo "API Error: Connection closed mid-response" > "$TMP/d-stderr-corte.log"
derive_stage_log_from_stream "$TMP/d-stream.jsonl" "$TMP/d-stderr-corte.log" "$TMP/d-out-corte.log"
if agent_log_has_stream_cut "$TMP/d-out-corte.log"; then
    pass "D-3: agent_log_has_stream_cut sigue detectando el corte de stream sobre el log derivado (sin cambios en su criterio)"
else
    fail "D-3: agent_log_has_stream_cut no detecto el corte de stream en el log derivado"
fi

# -------- Bloque E: jq ausente -> degrada con gracia --------

echo ""
echo "[E] jq ausente -> degrada con gracia, no aborta, igual anexa el stderr (CA-4)"

E_PATH_SIN_JQ="$TMP/bin-sin-jq"
mkdir -p "$E_PATH_SIN_JQ"
# PATH minimo que NO incluye ningun directorio con jq -- un directorio senuelo
# sin binarios basta para que `command -v jq` falle dentro de la funcion.
echo "API Error: 500 sin jq" > "$TMP/e-stderr.log"
cat > "$TMP/e-stream.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"esto no se deberia parsear sin jq"}]}}
EOF

(
    set -euo pipefail
    # /bin (no /usr/bin, donde vive jq en esta maquina) para que `cat` siga
    # resolviendo -- solo `jq` debe faltar.
    PATH="$E_PATH_SIN_JQ:/bin"
    derive_stage_log_from_stream "$TMP/e-stream.jsonl" "$TMP/e-stderr.log" "$TMP/e-out.log"
)
RC=$?

if [ "$RC" -eq 0 ]; then
    pass "E-1: sin jq en PATH, la funcion no aborta el pipeline"
else
    fail "E-1: se esperaba exit 0 sin jq, se obtuvo $RC"
fi

if [ -s "$TMP/e-out.log" ] && ! grep -q '"type"' "$TMP/e-out.log"; then
    pass "E-2: sin jq, el log derivado queda con una nota legible (no JSON crudo)"
else
    fail "E-2: el log derivado sin jq no es el esperado: $(cat "$TMP/e-out.log" 2>/dev/null)"
fi

if grep -qF "API Error: 500 sin jq" "$TMP/e-out.log"; then
    pass "E-3: sin jq, el .stderr.log de todos modos se anexa al log derivado"
else
    fail "E-3: sin jq, no se anexo el stderr al log derivado"
fi

# -------- Bloque F: run_agent_with_watchdog separa stdout/stderr (CA-2) --------

echo ""
echo "[F] run_agent_with_watchdog nunca mezcla stdout y stderr en un solo archivo (CA-2)"

WT_F="$TMP/wt-f"; mkdir -p "$WT_F"
EXIT_F=$(run_agent_with_watchdog "$WT_F" 5 "$TMP/f-stdout.log" "$TMP/f-stderr.log" "$TMP/f-events.log" "writer" "$TMP/f-signal" \
    bash -c 'echo "{\"type\":\"result\"}"; echo "API Error: 500 de prueba" >&2')

if [ "$EXIT_F" = "0" ]; then
    pass "F-1: el comando stand-in termino con exit 0"
else
    fail "F-1: se esperaba exit 0, se obtuvo '$EXIT_F'"
fi

if grep -q '"type":"result"' "$TMP/f-stdout.log" 2>/dev/null && ! grep -q "API Error" "$TMP/f-stdout.log" 2>/dev/null; then
    pass "F-2: el stdout (stream JSON) no quedo contaminado con el texto de stderr"
else
    fail "F-2: el archivo de stdout no es el esperado: $(cat "$TMP/f-stdout.log" 2>/dev/null)"
fi

if grep -q "API Error: 500 de prueba" "$TMP/f-stderr.log" 2>/dev/null && ! grep -q '"type"' "$TMP/f-stderr.log" 2>/dev/null; then
    pass "F-3: el stderr quedo en su propio archivo, sin JSON del stdout"
else
    fail "F-3: el archivo de stderr no es el esperado: $(cat "$TMP/f-stderr.log" 2>/dev/null)"
fi

# -------- Bloque G: el evento result con is_error llega al log derivado (CA-5) --------

echo ""
echo "[G] Evento 'result' con is_error y stderr vacio -> el error igual se clasifica (CA-5)"

# Forma real capturada del CLI v2.1.220 en una corrida fallida: subtype
# "success" pero is_error true, el status en api_error_status y el texto en
# .result -- y stderr sin una sola linea de error.
cat > "$TMP/g-stream-5xx.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"Empiezo a trabajar."}]}}
{"type":"result","is_error":true,"terminal_reason":"api_error","api_error_status":500,"subtype":"success","result":"Overloaded","num_turns":3,"duration_ms":90000}
EOF
: > "$TMP/g-stderr-vacio.log"

derive_stage_log_from_stream "$TMP/g-stream-5xx.jsonl" "$TMP/g-stderr-vacio.log" "$TMP/g-out-5xx.log"

if grep -q "API Error: 5" "$TMP/g-out-5xx.log"; then
    pass "G-1: un 5xx reportado SOLO en el evento result se clasifica API_ERROR_SERVER (sin esto volvia el bug de #416)"
else
    fail "G-1: el 5xx del evento result no llego al log derivado: $(cat "$TMP/g-out-5xx.log")"
fi

if agent_log_has_stream_cut "$TMP/g-out-5xx.log"; then
    pass "G-2: agent_failure_is_unrecoverable seguira marcando el stage como irrecuperable (no se abre PR con trabajo truncado)"
else
    fail "G-2: el fallo de API quedaria como recuperable"
fi

if grep -qF "Empiezo a trabajar." "$TMP/g-out-5xx.log"; then
    pass "G-3: el texto del asistente previo al fallo se conserva"
else
    fail "G-3: se perdio el texto del asistente"
fi

cat > "$TMP/g-stream-4xx.jsonl" <<'EOF'
{"type":"result","is_error":true,"terminal_reason":"api_error","api_error_status":404,"subtype":"success","result":"There's an issue with the selected model."}
EOF
derive_stage_log_from_stream "$TMP/g-stream-4xx.jsonl" "$TMP/g-stderr-vacio.log" "$TMP/g-out-4xx.log"
if grep -q "API Error: 4" "$TMP/g-out-4xx.log"; then
    pass "G-4: un 4xx del evento result se clasifica API_ERROR_CLIENT"
else
    fail "G-4: el 4xx del evento result no llego al log derivado: $(cat "$TMP/g-out-4xx.log")"
fi

# Caso negativo: una corrida sana no debe dejar rastro del result en el log --
# si lo dejara, un `result` cualquiera podria disparar los grep de fallo.
cat > "$TMP/g-stream-ok.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"Listo."}]}}
{"type":"result","is_error":false,"subtype":"success","result":"ok","num_turns":2,"duration_ms":3490,"duration_api_ms":1727}
EOF
derive_stage_log_from_stream "$TMP/g-stream-ok.jsonl" "$TMP/g-stderr-vacio.log" "$TMP/g-out-ok.log"
if [ "$(cat "$TMP/g-out-ok.log")" = "Listo." ]; then
    pass "G-5: un result sin error no agrega nada al log derivado (no introduce falsos positivos)"
else
    fail "G-5: el result de una corrida sana ensucio el log: $(cat "$TMP/g-out-ok.log")"
fi

# Linea de JSON valido pero no-objeto: `.type` sobre un string es un error duro
# de jq que `fromjson?` NO atrapa -- el select(type=="object") es lo que evita
# que una sola linea rara contamine la derivacion de todo el stage.
printf '"una linea suelta"\n{"type":"assistant","message":{"content":[{"type":"text","text":"texto posterior"}]}}\n' > "$TMP/g-stream-raro.jsonl"
(
    set -euo pipefail
    derive_stage_log_from_stream "$TMP/g-stream-raro.jsonl" "$TMP/g-stderr-vacio.log" "$TMP/g-out-raro.log"
) 2>"$TMP/g-raro.stderr"
RC=$?

if [ "$RC" -eq 0 ] && grep -qF "texto posterior" "$TMP/g-out-raro.log"; then
    pass "G-6: una linea de JSON valido pero no-objeto no aborta ni corta la derivacion del resto"
else
    fail "G-6: la linea no-objeto rompio la derivacion (rc=$RC): $(cat "$TMP/g-out-raro.log" 2>/dev/null)"
fi

if [ ! -s "$TMP/g-raro.stderr" ]; then
    pass "G-7: la derivacion no escupe ruido de jq por stderr"
else
    fail "G-7: jq dejo ruido por stderr: $(cat "$TMP/g-raro.stderr")"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
