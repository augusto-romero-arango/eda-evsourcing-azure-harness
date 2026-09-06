#!/usr/bin/env bash
# test-stream-json-trace.sh -- Tests de la derivacion del log legible de un
# stage a partir del JSONL neutral (issue #425, reescrita sobre
# run-events.schema.json en el issue #906).
#
# Contexto: derive_stage_log_from_stream ya no interpreta la traza cruda de
# ningun runtime concreto (MEF-ADR-0049 decision 1) -- lee el
# `<log_base>.events.jsonl` que run_agent escribe traduciendo cada intento con
# runtime_claude_translate (#859), y solo conoce el vocabulario neutral de
# `src/internal/contract/run-events.schema.json`: `message{kind}`,
# `tool.started{tool}` y el evento terminal (`run.completed`/`run.failed`)
# con su `error{kind, detail}`. La traza cruda de Claude sigue guardandose
# (`.stream.jsonl`) solo para diagnostico -- ningun test de este archivo la
# usa como entrada.
#
# Casos cubiertos:
#   [pre] derive_stage_log_from_stream y run_agent_with_watchdog estan
#         definidas en _mefisto-common.sh.
#   [A] Eventos neutrales con tool calls -> el log derivado trae el texto de
#       cada `message` y una linea "[tool] <nombre>" por cada `tool.started`,
#       en orden, sin JSON crudo visible (CA-1).
#   [B] JSONL truncado a mitad de linea -> la linea incompleta se ignora sin
#       abortar el pipeline (set -euo pipefail activo) y el texto de las
#       lineas completas anteriores no se pierde (CA-1).
#   [C] Traza vacia (events vacio, sin stderr) -> no falla, log derivado vacio
#       (CA-1).
#   [D] .stderr.log con texto de error -> el texto llega al log derivado,
#       anexado tal cual (CA-1).
#   [E] jq ausente -> degrada con gracia: no aborta, deja una nota legible y
#       de todos modos anexa el stderr (CA-1).
#   [F] run_agent_with_watchdog separa stdout/stderr en dos archivos propios
#       (nunca los mezcla) -- verificado con un comando stand-in, no el CLI
#       real (sin cambios respecto a #425).
#   [G] Terminal con `error` no nulo -> el log derivado trae la linea
#       "<error.kind>: <error.detail>", con el detalle ya prefijado
#       "API Error: <status>" cuando el traductor lo conoce (CA-1); y
#       agent_events_error_kind (issue #906) expone ese mismo `error.kind`
#       para que classify_agent_failure/agent_failure_is_unrecoverable
#       clasifiquen sin volver a grepear el log (CA-2). Incluye el caso
#       negativo (un terminal sin error no debe ensuciar el log), el caso
#       degenerado de un events_file ausente y una linea de JSON valido pero
#       no-objeto, que no debe tumbar la derivacion.
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
for fn in derive_stage_log_from_stream run_agent_with_watchdog agent_events_error_kind agent_events_error_detail; do
    if declare -F "$fn" >/dev/null; then
        pass "$fn definida"
    else
        fail "$fn NO definida"
    fi
done

# -------- Bloque A: eventos neutrales con tool calls --------

echo ""
echo "[A] Eventos neutrales con tool calls -> texto del asistente + una linea por tool call (CA-1)"

cat > "$TMP/a-events.jsonl" <<'EOF'
{"v":1,"type":"message","ts":"2026-09-06T10:00:00Z","role":"assistant","text":"Voy a leer el archivo relevante."}
{"v":1,"type":"tool.started","ts":"2026-09-06T10:00:01Z","tool":"Read","input_summary":"x"}
{"v":1,"type":"tool.completed","ts":"2026-09-06T10:00:02Z","tool":"Read","ok":true,"duration_ms":100}
{"v":1,"type":"tool.started","ts":"2026-09-06T10:00:03Z","tool":"Write","input_summary":"y"}
{"v":1,"type":"tool.completed","ts":"2026-09-06T10:00:04Z","tool":"Write","ok":true,"duration_ms":100}
{"v":1,"type":"message","ts":"2026-09-06T10:00:05Z","role":"assistant","text":"Listo, hice el cambio."}
{"v":1,"type":"run.completed","ts":"2026-09-06T10:00:06Z","status":"success","runtime":"claude","model":"claude-sonnet-5","session_id":null,"duration_ms":4200,"tokens":{"input":null,"output":null},"cost_usd":null,"turns":null,"denials":null,"ttft_ms":null,"api_duration_ms":null,"error":null}
EOF
: > "$TMP/a-stderr.log"

derive_stage_log_from_stream "$TMP/a-events.jsonl" "$TMP/a-stderr.log" "$TMP/a-out.log"
RC=$?

if [ "$RC" -eq 0 ]; then
    pass "A-1: exit 0"
else
    fail "A-1: se esperaba exit 0, se obtuvo $RC"
fi

if grep -qF "Voy a leer el archivo relevante." "$TMP/a-out.log" && grep -qF "Listo, hice el cambio." "$TMP/a-out.log"; then
    pass "A-2: el texto de ambos mensajes llego al log derivado"
else
    fail "A-2: falta texto de mensaje en el log derivado: $(cat "$TMP/a-out.log")"
fi

if grep -qF "[tool] Read" "$TMP/a-out.log" && grep -qF "[tool] Write" "$TMP/a-out.log"; then
    pass "A-3: una linea '[tool] <nombre>' por cada tool.started (Read y Write)"
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
    pass "A-5: el orden del log derivado respeta el orden del JSONL neutral"
else
    fail "A-5: el orden del log derivado no respeta el orden del JSONL neutral"
fi

# -------- Bloque B: JSONL truncado a mitad de linea --------

echo ""
echo "[B] JSONL truncado a mitad de linea -> se ignora sin abortar, no se pierde texto previo (CA-1)"

printf '{"v":1,"type":"message","ts":"2026-09-06T10:00:00Z","role":"assistant","text":"primera linea completa"}\n{"v":1,"type":"tool.started","ts":"2026-09-06T10:00:01Z","tool":"Bash","input_summary":"ls' > "$TMP/b-events.jsonl"
: > "$TMP/b-stderr.log"

(
    set -euo pipefail
    derive_stage_log_from_stream "$TMP/b-events.jsonl" "$TMP/b-stderr.log" "$TMP/b-out.log"
)
RC=$?

if [ "$RC" -eq 0 ]; then
    pass "B-1: un JSONL truncado no aborta el pipeline (set -euo pipefail activo)"
else
    fail "B-1: se esperaba exit 0 bajo set -euo pipefail, se obtuvo $RC"
fi

if grep -qF "primera linea completa" "$TMP/b-out.log"; then
    pass "B-2: el texto de la linea completa anterior a la truncada no se pierde"
else
    fail "B-2: se perdio el texto de la linea completa: $(cat "$TMP/b-out.log" 2>/dev/null)"
fi

if grep -qF "Bash" "$TMP/b-out.log"; then
    fail "B-3: la linea truncada (JSON invalido) no deberia haberse colado en el log"
else
    pass "B-3: la linea truncada se ignoro (no aparece en el log derivado)"
fi

# -------- Bloque C: traza vacia --------

echo ""
echo "[C] Traza vacia (events vacio, sin stderr) -> no falla, log derivado vacio (CA-1)"

: > "$TMP/c-events.jsonl"
: > "$TMP/c-stderr.log"

(
    set -euo pipefail
    derive_stage_log_from_stream "$TMP/c-events.jsonl" "$TMP/c-stderr.log" "$TMP/c-out.log"
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

# -------- Bloque D: .stderr.log llega al log derivado --------

echo ""
echo "[D] .stderr.log se anexa tal cual al log derivado (CA-1)"

: > "$TMP/d-events.jsonl"

echo "API Error: 500 Internal Server Error" > "$TMP/d-stderr.log"
derive_stage_log_from_stream "$TMP/d-events.jsonl" "$TMP/d-stderr.log" "$TMP/d-out.log"
if grep -qF "API Error: 500 Internal Server Error" "$TMP/d-out.log"; then
    pass "D-1: el .stderr.log llega intacto al log derivado"
else
    fail "D-1: no se encontro el texto de stderr en el log derivado: $(cat "$TMP/d-out.log")"
fi

# -------- Bloque E: jq ausente -> degrada con gracia --------

echo ""
echo "[E] jq ausente -> degrada con gracia, no aborta, igual anexa el stderr (CA-1)"

E_PATH_SIN_JQ="$TMP/bin-sin-jq"
mkdir -p "$E_PATH_SIN_JQ"
# PATH minimo que NO incluye ningun directorio con jq -- un directorio senuelo
# sin binarios basta para que `command -v jq` falle dentro de la funcion.
echo "API Error: 500 sin jq" > "$TMP/e-stderr.log"
cat > "$TMP/e-events.jsonl" <<'EOF'
{"v":1,"type":"message","ts":"2026-09-06T10:00:00Z","role":"assistant","text":"esto no se deberia parsear sin jq"}
EOF

(
    set -euo pipefail
    # /bin (no /usr/bin, donde vive jq en esta maquina) para que `cat` siga
    # resolviendo -- solo `jq` debe faltar.
    PATH="$E_PATH_SIN_JQ:/bin"
    derive_stage_log_from_stream "$TMP/e-events.jsonl" "$TMP/e-stderr.log" "$TMP/e-out.log"
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

# -------- Bloque F: run_agent_with_watchdog separa stdout/stderr --------

echo ""
echo "[F] run_agent_with_watchdog nunca mezcla stdout y stderr en un solo archivo"

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

# -------- Bloque G: terminal con error -> log derivado + agent_events_error_kind --------

echo ""
echo "[G] Terminal con 'error' no nulo -> el log derivado y agent_events_error_kind lo exponen (CA-1/CA-2)"

cat > "$TMP/g-events-5xx.jsonl" <<'EOF'
{"v":1,"type":"message","ts":"2026-09-06T10:00:00Z","role":"assistant","text":"Empiezo a trabajar."}
{"v":1,"type":"run.failed","ts":"2026-09-06T10:01:30Z","status":"failed","runtime":"claude","model":null,"session_id":null,"duration_ms":90000,"tokens":{"input":null,"output":null},"cost_usd":null,"turns":3,"denials":null,"ttft_ms":null,"api_duration_ms":null,"error":{"kind":"api_error","detail":"API Error: 500 Overloaded"}}
EOF
: > "$TMP/g-stderr-vacio.log"

derive_stage_log_from_stream "$TMP/g-events-5xx.jsonl" "$TMP/g-stderr-vacio.log" "$TMP/g-out-5xx.log"

if grep -q "API Error: 5" "$TMP/g-out-5xx.log"; then
    pass "G-1: un 5xx del terminal se ve en el log derivado como 'api_error: API Error: 500 ...'"
else
    fail "G-1: el 5xx del terminal no llego al log derivado: $(cat "$TMP/g-out-5xx.log")"
fi

if [ "$(agent_events_error_kind "$TMP/g-events-5xx.jsonl")" = "api_error" ]; then
    pass "G-2: agent_events_error_kind expone 'api_error' desde el terminal (issue #906, sin grep sobre el log)"
else
    fail "G-2: agent_events_error_kind no devolvio 'api_error': '$(agent_events_error_kind "$TMP/g-events-5xx.jsonl")'"
fi

# El detalle es lo que classify_agent_failure grepea para partir 5xx de 4xx:
# el contrato neutral no tiene un campo de status HTTP, viaja aqui con el
# prefijo canonico que normaliza el adaptador.
if [ "$(agent_events_error_detail "$TMP/g-events-5xx.jsonl")" = "API Error: 500 Overloaded" ]; then
    pass "G-2b: agent_events_error_detail expone el detalle con el prefijo 'API Error: <status>'"
else
    fail "G-2b: agent_events_error_detail no devolvio el detalle esperado: '$(agent_events_error_detail "$TMP/g-events-5xx.jsonl")'"
fi

if grep -qF "Empiezo a trabajar." "$TMP/g-out-5xx.log"; then
    pass "G-3: el texto previo al fallo se conserva"
else
    fail "G-3: se perdio el texto previo al fallo"
fi

cat > "$TMP/g-events-4xx.jsonl" <<'EOF'
{"v":1,"type":"run.failed","ts":"2026-09-06T10:00:05Z","status":"failed","runtime":"claude","model":null,"session_id":null,"duration_ms":5000,"tokens":{"input":null,"output":null},"cost_usd":null,"turns":null,"denials":null,"ttft_ms":null,"api_duration_ms":null,"error":{"kind":"api_error","detail":"API Error: 404 There's an issue with the selected model."}}
EOF
derive_stage_log_from_stream "$TMP/g-events-4xx.jsonl" "$TMP/g-stderr-vacio.log" "$TMP/g-out-4xx.log"
if grep -q "API Error: 4" "$TMP/g-out-4xx.log"; then
    pass "G-4: un 4xx del terminal se ve en el log derivado"
else
    fail "G-4: el 4xx del terminal no llego al log derivado: $(cat "$TMP/g-out-4xx.log")"
fi

cat > "$TMP/g-events-cut.jsonl" <<'EOF'
{"v":1,"type":"run.failed","ts":"2026-09-06T10:00:05Z","status":"failed","runtime":"claude","model":null,"session_id":null,"duration_ms":5000,"tokens":{"input":null,"output":null},"cost_usd":null,"turns":null,"denials":null,"ttft_ms":null,"api_duration_ms":null,"error":{"kind":"stream_cut","detail":"el stream de Claude se corto a mitad de escritura"}}
EOF
derive_stage_log_from_stream "$TMP/g-events-cut.jsonl" "$TMP/g-stderr-vacio.log" "$TMP/g-out-cut.log"
if grep -qF "stream_cut:" "$TMP/g-out-cut.log"; then
    pass "G-5: un corte de stream (error.kind=stream_cut) se ve en el log derivado"
else
    fail "G-5: el corte de stream no llego al log derivado: $(cat "$TMP/g-out-cut.log")"
fi
if [ "$(agent_events_error_kind "$TMP/g-events-cut.jsonl")" = "stream_cut" ]; then
    pass "G-6: agent_events_error_kind distingue 'stream_cut' de 'api_error' (incidente #416)"
else
    fail "G-6: agent_events_error_kind no devolvio 'stream_cut'"
fi

# Caso negativo: un terminal sano (sin error) no debe dejar rastro en el log.
cat > "$TMP/g-events-ok.jsonl" <<'EOF'
{"v":1,"type":"message","ts":"2026-09-06T10:00:00Z","role":"assistant","text":"Listo."}
{"v":1,"type":"run.completed","ts":"2026-09-06T10:00:05Z","status":"success","runtime":"claude","model":"claude-sonnet-5","session_id":null,"duration_ms":3490,"tokens":{"input":null,"output":null},"cost_usd":null,"turns":2,"denials":null,"ttft_ms":null,"api_duration_ms":null,"error":null}
EOF
derive_stage_log_from_stream "$TMP/g-events-ok.jsonl" "$TMP/g-stderr-vacio.log" "$TMP/g-out-ok.log"
if [ "$(cat "$TMP/g-out-ok.log")" = "Listo." ]; then
    pass "G-7: un terminal sin error no agrega nada al log derivado (no introduce falsos positivos)"
else
    fail "G-7: el terminal sano ensucio el log: $(cat "$TMP/g-out-ok.log")"
fi
if [ -z "$(agent_events_error_kind "$TMP/g-events-ok.jsonl")" ] \
   && [ -z "$(agent_events_error_detail "$TMP/g-events-ok.jsonl")" ]; then
    pass "G-8: agent_events_error_kind/_detail devuelven vacio cuando el terminal no trae error"
else
    fail "G-8: deberian devolver vacio: kind='$(agent_events_error_kind "$TMP/g-events-ok.jsonl")' detail='$(agent_events_error_detail "$TMP/g-events-ok.jsonl")'"
fi

# Archivo vacio/inexistente: los lectores degradan a vacio sin abortar bajo
# set -euo pipefail (es la ruta que toma un stage cuya traza nunca se
# escribio -- jq ausente, o el CLI murio antes del primer evento).
(
    set -euo pipefail
    [ -z "$(agent_events_error_kind "$TMP/no-existe.jsonl")" ]
    [ -z "$(agent_events_error_detail "")" ]
)
if [ $? -eq 0 ]; then
    pass "G-8b: sin events_file (inexistente o vacio) los lectores devuelven vacio sin abortar"
else
    fail "G-8b: los lectores abortaron o devolvieron algo con un events_file ausente"
fi

# Linea de JSON valido pero no-objeto: `.type` sobre un string es un error duro
# de jq que `fromjson?` NO atrapa -- el select(type=="object") es lo que evita
# que una sola linea rara contamine la derivacion de todo el stage.
printf '"una linea suelta"\n{"v":1,"type":"message","ts":"2026-09-06T10:00:00Z","role":"assistant","text":"texto posterior"}\n' > "$TMP/g-events-raro.jsonl"
(
    set -euo pipefail
    derive_stage_log_from_stream "$TMP/g-events-raro.jsonl" "$TMP/g-stderr-vacio.log" "$TMP/g-out-raro.log"
) 2>"$TMP/g-raro.stderr"
RC=$?

if [ "$RC" -eq 0 ] && grep -qF "texto posterior" "$TMP/g-out-raro.log"; then
    pass "G-9: una linea de JSON valido pero no-objeto no aborta ni corta la derivacion del resto"
else
    fail "G-9: la linea no-objeto rompio la derivacion (rc=$RC): $(cat "$TMP/g-out-raro.log" 2>/dev/null)"
fi

if [ ! -s "$TMP/g-raro.stderr" ]; then
    pass "G-10: la derivacion no escupe ruido de jq por stderr"
else
    fail "G-10: jq dejo ruido por stderr: $(cat "$TMP/g-raro.stderr")"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
