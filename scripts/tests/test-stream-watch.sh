#!/usr/bin/env bash
# test-stream-watch.sh -- Tests del visor en vivo publicado (issue #690,
# porte del test interno de mefisto-stream-watch.sh, issue #434).
#
# Contexto: scripts/stream-watch.sh sigue incrementalmente
# `<log_base>.stream.jsonl` (la traza cruda que #645/#689 dejan creciendo en
# vivo en .claude/pipeline/logs/ del consumidor) y renderiza una linea
# legible por accion del agente. Suma sobre el visor interno los filtros
# --issues (corridas concurrentes en panes distintos no se cruzan) y
# --newer-than (no mostrar la traza de la corrida anterior mientras nace la
# nueva) y el parseo de los nombres de stream publicados
# ([tooling-|iac-]stage-...-issue-N[-retry|-perm-retry]).
#
# Estilo test-stream-json-trace.sh: el script bajo prueba corre codigo
# top-level (guard de repo, chequeo de jq) antes de definir sus funciones --
# sourcing el archivo completo lo dispararia. En vez de eso se extrae SOLO el
# cuerpo de cada funcion (awk sobre "nombre() {" .. "}" en columna 0) y se
# evalua en este proceso. `main` (el bucle infinito real) nunca se extrae ni
# se llama: no terminaria.
#
# Casos cubiertos:
#   [pre] Todas las funciones bajo prueba se pueden extraer y cargar.
#   [A] Bash con comando multilinea -> objetivo aplanado a una sola linea.
#   [B] Repeticion sobre el mismo archivo -> (x2)/(x3); Bash repetido NO.
#   [C] Turno sin tool call -> se señala distinto (texto y thinking).
#   [D] Evento `result` real (sin .timestamp) -> cierre sin desplazamiento.
#   [E] Linea final truncada -> se reintenta, no se descarta.
#   [F] discover_stream elige el mas reciente por mtime; dir inexistente ok.
#   [G] parse_stream_header con los nombres publicados (tdd/tooling/iac,
#       agentes con guiones, sufijo -retry) y fallback al nombre tal cual.
#   [H] fmt_delta_s -> "-" sin accion previa, numerico con ella.
#   [I] Linea JSON valida pero no-objeto no rompe el resto del lote.
#   [J] Truncado al ancho del pane: comando por el final, ruta por la cola.
#   [K] is_missing y el placeholder "-" del filtro jq.
#   [L] stream_matches_issues: match exacto por issue (4 no matchea 42),
#       sufijos de reintento, lista con varios issues, lista vacia = todo.
#   [M] stream_is_newer_than + discover_stream con filtros activos.
#
# Uso: scripts/tests/test-stream-watch.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/stream-watch.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: este test requiere jq (no encontrado en PATH)." >&2
    exit 1
fi

# extract_fn <function_name> <file> -- mismo patron que test-stream-json-trace.sh.
extract_fn() {
    local name="$1" file="$2"
    awk -v fn="$name" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p{print} p && /^}/{p=0}' "$file"
}

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Colores a vacio: las funciones extraidas los referencian, y este test corre
# con `set -u`.
RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; NC=""

FNS="write_jq_filter stream_matches_issues stream_is_newer_than discover_stream parse_stream_header pane_width is_missing truncate_target truncate_path fmt_time_hhmmss fmt_delta_s ms_to_s touch_count render_result_summary render_row process_new_lines"

echo "[pre] Las funciones bajo prueba se pueden extraer y cargar desde stream-watch.sh"
ALL_LOADED=1
for fn in $FNS; do
    body=$(extract_fn "$fn" "$TARGET")
    if [ -n "$body" ]; then
        eval "$body"
        if declare -F "$fn" >/dev/null; then
            pass "$fn definida y cargable"
        else
            fail "$fn: eval no la dejo definida"
            ALL_LOADED=0
        fi
    else
        fail "$fn: no se pudo extraer el cuerpo"
        ALL_LOADED=0
    fi
done

if [ "$ALL_LOADED" -ne 1 ]; then
    echo "Abortando: no se pudieron cargar todas las funciones bajo prueba."
    exit 1
fi

# Filtro jq materializado una sola vez para todos los bloques.
JQ_FILTER_PATH="$TMP/filter.jq"
write_jq_filter "$JQ_FILTER_PATH"

# Filtros de descubrimiento en su default (sin filtro): los bloques que los
# prueban ([M]) los setean y los devuelven a vacio.
ISSUES_CSV=""
NEWER_THAN=""

# reset_stage_state -- vuelve al estado "recien cambiado de stream" (lo que
# hace el bucle principal en cada switch): contador de lineas en cero, sin
# accion previa, sin toques registrados.
STATE_SEQ=0
reset_stage_state() {
    LAST_LINE=0
    PREV_EMS=""
    STATE_SEQ=$((STATE_SEQ+1))
    TOUCHED_FILE="$TMP/touched-${STATE_SEQ}.txt"
    : > "$TOUCHED_FILE"
}

# run_process_new_lines <stream_file> <out_file>
#
# Llama a process_new_lines SIN command substitution: `$(...)` correria en
# una subshell y las mutaciones a LAST_LINE/PREV_EMS (variables globales que
# el bucle principal real depende que persistan entre ciclos) se perderian
# al volver. La redireccion simple `>` no crea subshell para un comando
# simple, asi que el estado global si sobrevive a la llamada.
run_process_new_lines() {
    local stream="$1" outfile="$2"
    process_new_lines "$stream" > "$outfile"
}

# -------- Bloque A: Bash multilinea se aplana a una sola linea --------

echo ""
echo "[A] Bash con comando multilinea -> objetivo aplanado a una sola linea"

reset_stage_state
STREAM_A="$TMP/a-stream.jsonl"
printf '%s\n' '{"type":"assistant","timestamp":"2026-07-29T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la\ncat foo.sh\necho listo"}}]}}' > "$STREAM_A"

run_process_new_lines "$STREAM_A" "$TMP/a-out.txt"
OUT_A=$(cat "$TMP/a-out.txt")

if [ "$(wc -l < "$TMP/a-out.txt" | tr -d ' ')" = "1" ]; then
    pass "A-1: el comando multilinea produce una sola linea de salida"
else
    fail "A-1: se esperaba una sola linea de salida, se obtuvo: $OUT_A"
fi

if printf '%s' "$OUT_A" | grep -q "ls -la cat foo.sh echo listo"; then
    pass "A-2: el comando aplanado conserva las tres partes en orden, separadas por espacio"
else
    fail "A-2: no se encontro el comando aplanado esperado: $OUT_A"
fi

if printf '%s' "$OUT_A" | grep -q "Bash"; then
    pass "A-3: el nombre de la herramienta (Bash) aparece en la linea"
else
    fail "A-3: no se encontro el nombre de la herramienta: $OUT_A"
fi

if [ "$LAST_LINE" -eq 1 ]; then
    pass "A-4: LAST_LINE avanzo a 1 (unica linea del stream, bien formada)"
else
    fail "A-4: se esperaba LAST_LINE=1, se obtuvo $LAST_LINE"
fi

# -------- Bloque B: repeticion sobre el mismo archivo --------

echo ""
echo "[B] Repeticion sobre el mismo archivo -> sin sufijo, luego (x2), luego (x3)"

reset_stage_state
STREAM_B="$TMP/b-stream.jsonl"
printf '%s\n' \
  '{"type":"assistant","timestamp":"2026-07-29T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"src/Foo.cs"}}]}}' \
  '{"type":"assistant","timestamp":"2026-07-29T10:00:05.000Z","message":{"content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"src/Foo.cs","old_string":"a","new_string":"b"}}]}}' \
  '{"type":"assistant","timestamp":"2026-07-29T10:00:10.000Z","message":{"content":[{"type":"tool_use","id":"t3","name":"Read","input":{"file_path":"src/Foo.cs"}}]}}' \
  '{"type":"assistant","timestamp":"2026-07-29T10:00:15.000Z","message":{"content":[{"type":"tool_use","id":"t4","name":"Bash","input":{"command":"dotnet build"}}]}}' \
  '{"type":"assistant","timestamp":"2026-07-29T10:00:20.000Z","message":{"content":[{"type":"tool_use","id":"t5","name":"Bash","input":{"command":"dotnet build"}}]}}' \
  > "$STREAM_B"

run_process_new_lines "$STREAM_B" "$TMP/b-out.txt"
OUT_B=$(cat "$TMP/b-out.txt")
LINE1=$(printf '%s\n' "$OUT_B" | sed -n '1p')
LINE2=$(printf '%s\n' "$OUT_B" | sed -n '2p')
LINE3=$(printf '%s\n' "$OUT_B" | sed -n '3p')
LINE4=$(printf '%s\n' "$OUT_B" | sed -n '4p')
LINE5=$(printf '%s\n' "$OUT_B" | sed -n '5p')

if ! printf '%s' "$LINE1" | grep -q "(x"; then
    pass "B-1: el primer toque de src/Foo.cs no lleva sufijo de repeticion"
else
    fail "B-1: el primer toque no deberia llevar sufijo: $LINE1"
fi

if printf '%s' "$LINE2" | grep -q "(x2)"; then
    pass "B-2: el segundo toque (Edit) lleva sufijo (x2)"
else
    fail "B-2: se esperaba (x2) en el segundo toque: $LINE2"
fi

if printf '%s' "$LINE3" | grep -q "(x3)"; then
    pass "B-3: el tercer toque (Read de nuevo) lleva sufijo (x3)"
else
    fail "B-3: se esperaba (x3) en el tercer toque: $LINE3"
fi

if ! printf '%s' "$LINE4" | grep -q "(x" && ! printf '%s' "$LINE5" | grep -q "(x"; then
    pass "B-4: el Bash repetido (dotnet build x2) NO se marca -- exclusion explicita de comandos identicos"
else
    fail "B-4: un Bash repetido no deberia llevar sufijo de repeticion: '$LINE4' / '$LINE5'"
fi

# -------- Bloque C: turno de solo texto --------

echo ""
echo "[C] Turno de solo texto (sin tool call) se señala distinto de una tool call"

reset_stage_state
STREAM_C="$TMP/c-stream.jsonl"
printf '%s\n' '{"type":"assistant","timestamp":"2026-07-29T10:00:00.000Z","message":{"content":[{"type":"text","text":"Estoy pensando en el enfoque."}]}}' > "$STREAM_C"

run_process_new_lines "$STREAM_C" "$TMP/c-out.txt"
OUT_C=$(cat "$TMP/c-out.txt")

if [ -n "$OUT_C" ]; then
    pass "C-1: un turno de solo texto SI produce una linea (no se descarta silenciosamente)"
else
    fail "C-1: un turno de solo texto no genero ninguna linea"
fi

if ! printf '%s' "$OUT_C" | grep -qE "Read|Edit|Write|Bash|Grep|Glob"; then
    pass "C-2: la linea de un turno de solo texto no aparenta ser una tool call"
else
    fail "C-2: la linea de texto se confundio con una tool call: $OUT_C"
fi

# Un turno de SOLO thinking es el otro sabor de turno sin tool call. Su texto
# viaja vacio en el stream (solo queda la firma), asi que se señala el turno:
# sin eso, su tiempo de razonamiento se le cargaria al delta de la accion
# siguiente.
reset_stage_state
STREAM_C2="$TMP/c2-stream.jsonl"
printf '%s\n' \
  '{"type":"assistant","timestamp":"2026-07-29T10:00:00.000Z","message":{"content":[{"type":"thinking","thinking":"","signature":"CAIS"}]}}' \
  '{"type":"assistant","timestamp":"2026-07-29T10:00:30.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"z.txt"}}]}}' \
  > "$STREAM_C2"

run_process_new_lines "$STREAM_C2" "$TMP/c2-out.txt"
OUT_C2=$(cat "$TMP/c2-out.txt")

if [ "$(wc -l < "$TMP/c2-out.txt" | tr -d ' ')" = "2" ]; then
    pass "C-3: un turno de solo thinking tambien produce su linea (2 lineas: razonamiento + Read)"
else
    fail "C-3: se esperaban 2 lineas (thinking + Read), se obtuvo: $OUT_C2"
fi

if printf '%s\n' "$OUT_C2" | sed -n '1p' | grep -q "razonamiento"; then
    pass "C-4: el turno de solo thinking se señala como razonamiento"
else
    fail "C-4: el turno de thinking no se señalo: $OUT_C2"
fi

if printf '%s\n' "$OUT_C2" | sed -n '2p' | grep -q "30.0s"; then
    pass "C-5: el delta de 30s queda entre el razonamiento y la accion, no oculto antes de ella"
else
    fail "C-5: no se encontro el delta de 30s en la accion posterior: $OUT_C2"
fi

# -------- Bloque D: evento result -> cierre de stage --------

echo ""
echo "[D] Evento result -> cierre de stage con turnos/costo/duracion API vs no-API"

# El fixture reproduce el evento `result` REAL del CLI, que NO trae
# `.timestamp`. Es la forma exacta que hacia fallar el render original: con
# el campo de hora vacio, la fila TSV se leia desplazada (`IFS=$'\t' read`
# colapsa dos tabs seguidos) y el cierre reportaba duration_ms como turnos e
# is_error como costo. Va precedido de una accion con hora, porque el reloj
# del cierre es el de la ultima accion vista.
reset_stage_state
STREAM_D="$TMP/d-stream.jsonl"
printf '%s\n' \
  '{"type":"assistant","timestamp":"2026-07-29T10:04:55.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git status"}}]}}' \
  '{"type":"result","subtype":"success","is_error":false,"duration_ms":45000,"duration_api_ms":40000,"num_turns":7,"total_cost_usd":0.55,"session_id":"abc"}' \
  > "$STREAM_D"

process_new_lines "$STREAM_D" > "$TMP/d-out.txt"
RC_D=$?
OUT_D=$(cat "$TMP/d-out.txt")

if [ "$RC_D" -eq 0 ]; then
    pass "D-1: procesar el evento result no aborta el proceso que invoca (sigue esperando)"
else
    fail "D-1: se esperaba exit 0, se obtuvo $RC_D"
fi

if printf '%s' "$OUT_D" | grep -q "turnos=7"; then
    pass "D-2: el cierre reporta los turnos del evento result (num_turns=7, no duration_ms)"
else
    fail "D-2: no se encontraron los turnos esperados: $OUT_D"
fi

if printf '%s' "$OUT_D" | grep -q "costo_usd=0.55"; then
    pass "D-3: el cierre reporta el costo del evento result (no is_error)"
else
    fail "D-3: no se encontro el costo esperado: $OUT_D"
fi

if printf '%s' "$OUT_D" | grep -q "api=40.0s" && printf '%s' "$OUT_D" | grep -q "no-api=5.0s"; then
    pass "D-4: el cierre desglosa duracion API (40.0s) vs no-API (45-40=5.0s)"
else
    fail "D-4: el desglose API/no-API no es el esperado: $OUT_D"
fi

if printf '%s' "$OUT_D" | grep -q "duracion=45.0s"; then
    pass "D-5: sin timestamp en el result, los campos NO se desplazan (duracion=45.0s)"
else
    fail "D-5: los campos del result se desplazaron -- duracion incorrecta: $OUT_D"
fi

HORA_ACCION_D=$(printf '%s\n' "$OUT_D" | sed -n 's/^\[\([0-9:]*\)\].*Bash.*/\1/p' | head -1)
HORA_CIERRE_D=$(printf '%s\n' "$OUT_D" | sed -n 's/^--- cierre de stage \[\([0-9:-]*\)\].*/\1/p' | head -1)
if [ -n "$HORA_ACCION_D" ] && [ "$HORA_CIERRE_D" = "$HORA_ACCION_D" ]; then
    pass "D-6: el cierre usa el reloj de la ultima accion ($HORA_CIERRE_D), no la epoca ni 'ahora'"
else
    fail "D-6: hora del cierre '$HORA_CIERRE_D' != hora de la ultima accion '$HORA_ACCION_D': $OUT_D"
fi

# -------- Bloque E: linea final truncada -> se reintenta, no se descarta --------

echo ""
echo "[E] Linea final truncada -> no avanza el contador ni la descarta; se completa en el siguiente ciclo"

reset_stage_state
STREAM_E="$TMP/e-stream.jsonl"
printf '%s\n' '{"type":"assistant","timestamp":"2026-07-29T10:00:00.000Z","message":{"content":[{"type":"text","text":"primera accion completa"}]}}' > "$STREAM_E"
# Linea truncada a mitad de escritura -- SIN newline final, como quedaria si
# el proceso productor fuera pillado a mitad del write() de esta linea.
printf '%s' '{"type":"assistant","timestamp":"2026-07-29T10:00:05.000Z","message":{"content":[{"type":"tool_use","id":"t9","name":"Bash","input":{"command":"ls' >> "$STREAM_E"

process_new_lines "$STREAM_E" > "$TMP/e-out1.txt"
RC_E1=$?
OUT_E1=$(cat "$TMP/e-out1.txt")
LAST_LINE_AFTER_1=$LAST_LINE

if [ "$RC_E1" -eq 0 ]; then
    pass "E-1: una linea truncada no aborta el proceso (set -uo pipefail activo)"
else
    fail "E-1: se esperaba exit 0 con una linea truncada, se obtuvo $RC_E1"
fi

if printf '%s' "$OUT_E1" | grep -q "sin tool call"; then
    pass "E-2: el turno completo anterior a la linea truncada SI se renderizo"
else
    fail "E-2: no se renderizo el turno completo previo: $OUT_E1"
fi

if [ "$LAST_LINE_AFTER_1" -eq 1 ]; then
    pass "E-3: LAST_LINE se detuvo en 1 -- la linea truncada NO se cuenta como consumida"
else
    fail "E-3: se esperaba LAST_LINE=1 tras la linea truncada, se obtuvo $LAST_LINE_AFTER_1"
fi

if ! printf '%s' "$OUT_E1" | grep -q "Bash"; then
    pass "E-4: la tool call de la linea truncada NO aparecio (ni a medias)"
else
    fail "E-4: la linea truncada no deberia haber producido salida: $OUT_E1"
fi

# El productor real termina de escribir esa misma linea (cierra el JSON) y
# agrega una linea nueva completa a continuacion.
printf '%s\n' '"}}]}}' >> "$STREAM_E"
printf '%s\n' '{"type":"assistant","timestamp":"2026-07-29T10:00:12.000Z","message":{"content":[{"type":"tool_use","id":"t10","name":"Read","input":{"file_path":"x.txt"}}]}}' >> "$STREAM_E"

run_process_new_lines "$STREAM_E" "$TMP/e-out2.txt"
OUT_E2=$(cat "$TMP/e-out2.txt")

if [ "$LAST_LINE" -eq 3 ]; then
    pass "E-5: al completarse, el siguiente ciclo avanza sobre la linea reparada Y la que vino despues"
else
    fail "E-5: se esperaba LAST_LINE=3 tras completar la linea, se obtuvo $LAST_LINE"
fi

if printf '%s' "$OUT_E2" | grep -q "Bash" && printf '%s' "$OUT_E2" | grep -q "Read"; then
    pass "E-6: el segundo ciclo renderiza tanto la linea reparada (Bash) como la nueva (Read)"
else
    fail "E-6: no se encontraron ambas tool calls en el segundo ciclo: $OUT_E2"
fi

# -------- Bloque F: discover_stream elige el mas reciente por mtime --------

echo ""
echo "[F] discover_stream elige el *.stream.jsonl mas reciente por mtime"

DIR_F="$TMP/logs-f"
mkdir -p "$DIR_F"
echo '{}' > "$DIR_F/tooling-stage-1-writer-20260729-090000-issue-100.stream.jsonl"
touch -t 202607290900 "$DIR_F/tooling-stage-1-writer-20260729-090000-issue-100.stream.jsonl"
echo '{}' > "$DIR_F/tooling-stage-2-reviewer-20260729-093000-issue-100.stream.jsonl"
touch -t 202607290930 "$DIR_F/tooling-stage-2-reviewer-20260729-093000-issue-100.stream.jsonl"

FOUND_F=$(discover_stream "$DIR_F")
if [ "$(basename "$FOUND_F")" = "tooling-stage-2-reviewer-20260729-093000-issue-100.stream.jsonl" ]; then
    pass "F-1: elige el archivo con mtime mas reciente (stage 2), no el mas viejo (stage 1)"
else
    fail "F-1: se esperaba el stream de stage 2, se obtuvo: $FOUND_F"
fi

FOUND_F_EMPTY=$(discover_stream "$TMP/no-existe-jamas")
RC_F_EMPTY=$?
if [ "$RC_F_EMPTY" -eq 0 ] && [ -z "$FOUND_F_EMPTY" ]; then
    pass "F-2: un directorio inexistente no aborta -- devuelve vacio"
else
    fail "F-2: se esperaba exit 0 y vacio con directorio inexistente, se obtuvo rc=$RC_F_EMPTY out='$FOUND_F_EMPTY'"
fi

# -------- Bloque G: parse_stream_header con los nombres publicados --------

echo ""
echo "[G] parse_stream_header deriva familia/issue/stage/agente de los nombres publicados"

HEADER_G1=$(parse_stream_header "/tmp/x/tooling-stage-1-writer-20260729-100000-issue-434.stream.jsonl")
if printf '%s' "$HEADER_G1" | grep -q "issue #434" \
    && printf '%s' "$HEADER_G1" | grep -q "tooling stage 1" \
    && printf '%s' "$HEADER_G1" | grep -q "writer"; then
    pass "G-1: extrae issue=434, familia=tooling, stage=1, agente=writer"
else
    fail "G-1: no se extrajeron los campos esperados: $HEADER_G1"
fi

# tdd-pipeline.sh nombra sin prefijo de familia y con agentes CON guiones
# (projection-test-writer): el patron debe tragarse el guion del agente sin
# comerse el timestamp.
HEADER_G2=$(parse_stream_header "/tmp/x/stage-1-projection-test-writer-20260729-100000-issue-371.stream.jsonl")
if printf '%s' "$HEADER_G2" | grep -q "issue #371" \
    && printf '%s' "$HEADER_G2" | grep -q "tdd stage 1" \
    && printf '%s' "$HEADER_G2" | grep -q "projection-test-writer"; then
    pass "G-2: un agente con guiones (projection-test-writer) se extrae completo, familia tdd"
else
    fail "G-2: no se extrajo el agente con guiones: $HEADER_G2"
fi

HEADER_G3=$(parse_stream_header "/tmp/x/iac-stage-2-infra-reviewer-20260729-100000-issue-199.stream.jsonl")
if printf '%s' "$HEADER_G3" | grep -q "issue #199" \
    && printf '%s' "$HEADER_G3" | grep -q "iac stage 2" \
    && printf '%s' "$HEADER_G3" | grep -q "infra-reviewer"; then
    pass "G-3: la familia iac y el agente infra-reviewer se extraen"
else
    fail "G-3: no se extrajo el stream de iac: $HEADER_G3"
fi

HEADER_G4=$(parse_stream_header "/tmp/x/tooling-stage-1-writer-20260729-100000-issue-434-retry.stream.jsonl")
if printf '%s' "$HEADER_G4" | grep -q "issue #434" && printf '%s' "$HEADER_G4" | grep -q "reintento"; then
    pass "G-4: el sufijo -retry se reconoce y se señala como reintento"
else
    fail "G-4: no se reconocio el sufijo -retry: $HEADER_G4"
fi

HEADER_G5=$(parse_stream_header "/tmp/x/un-nombre-cualquiera.jsonl")
if printf '%s' "$HEADER_G5" | grep -q "un-nombre-cualquiera.jsonl"; then
    pass "G-5: un nombre que no matchea el patron degrada a mostrarlo tal cual (no falla)"
else
    fail "G-5: no degrado mostrando el nombre tal cual: $HEADER_G5"
fi

# -------- Bloque H: delta -- "-" sin accion previa, numerico con ella --------

echo ""
echo "[H] fmt_delta_s -- sin accion previa devuelve '-', con ella devuelve el delta en segundos"

DELTA_H1=$(fmt_delta_s "" "1785190194169")
if printf '%s' "$DELTA_H1" | grep -q -- "-"; then
    pass "H-1: sin accion previa, el delta se muestra como '-'"
else
    fail "H-1: se esperaba '-' sin accion previa, se obtuvo: $DELTA_H1"
fi

DELTA_H2=$(fmt_delta_s "1785190174000" "1785190194169")
if printf '%s' "$DELTA_H2" | grep -q "20.2"; then
    pass "H-2: con accion previa, el delta es la diferencia en segundos (20.2s)"
else
    fail "H-2: delta incorrecto, se esperaba ~20.2s: $DELTA_H2"
fi

# -------- Bloque I: JSON valido pero no-objeto no rompe el lote --------

echo ""
echo "[I] Una linea JSON valida pero no-objeto no rompe la derivacion del resto"

reset_stage_state
STREAM_I="$TMP/i-stream.jsonl"
printf '%s\n' \
  '"una linea suelta"' \
  '{"type":"assistant","timestamp":"2026-07-29T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"y.txt"}}]}}' \
  > "$STREAM_I"

process_new_lines "$STREAM_I" > "$TMP/i-out.txt"
RC_I=$?
OUT_I=$(cat "$TMP/i-out.txt")

if [ "$RC_I" -eq 0 ] && [ "$LAST_LINE" -eq 2 ]; then
    pass "I-1: la linea no-objeto se salta sin cortar el resto del lote (LAST_LINE llega a 2)"
else
    fail "I-1: se esperaba rc=0 y LAST_LINE=2, se obtuvo rc=$RC_I LAST_LINE=$LAST_LINE"
fi

if printf '%s' "$OUT_I" | grep -q "Read"; then
    pass "I-2: la tool call posterior a la linea rara SI se renderizo"
else
    fail "I-2: no se renderizo la tool call posterior a la linea rara: $OUT_I"
fi

# -------- Bloque J: truncado -- comando por el final, ruta por la cola --------

echo ""
echo "[J] Truncado al ancho del pane: el comando corta por el final, la ruta conserva la cola"

CMD_J=$(truncate_target "dotnet test tests/Proyecto.Dominio.Tests/Proyecto.Dominio.Tests.csproj --no-build" 30)
if [ "${#CMD_J}" -le 30 ] && printf '%s' "$CMD_J" | grep -q "^dotnet test" && printf '%s' "$CMD_J" | grep -q '\.\.\.$'; then
    pass "J-1: un comando se trunca por el final -- lo que identifica la accion esta al principio"
else
    fail "J-1: truncado de comando inesperado: '$CMD_J'"
fi

PATH_J="/Users/augusto-romero-arango/Codigo/Sincosoft/Cosmos/worktree-issue-434-anadir/agents/infra-reviewer.md"
CUT_J=$(truncate_path "$PATH_J" 40)
if [ "${#CUT_J}" -le 40 ] && printf '%s' "$CUT_J" | grep -q "agents/infra-reviewer.md$" && printf '%s' "$CUT_J" | grep -q "^\.\.\."; then
    pass "J-2: una ruta larga conserva la cola (el nombre del archivo) con '...' al principio"
else
    fail "J-2: truncado de ruta inesperado: '$CUT_J'"
fi

CORTO_J=$(truncate_path "agents/x.md" 40)
if [ "$CORTO_J" = "agents/x.md" ]; then
    pass "J-3: una ruta que ya entra en el ancho se devuelve intacta"
else
    fail "J-3: se esperaba la ruta intacta, se obtuvo: '$CORTO_J'"
fi

reset_stage_state
STREAM_J="$TMP/j-stream.jsonl"
printf '%s\n' '{"type":"assistant","timestamp":"2026-07-29T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/Users/augusto-romero-arango/Codigo/Sincosoft/Cosmos/worktree-issue-434-anadir/agents/infra-reviewer.md"}}]}}' > "$STREAM_J"

export COLUMNS=80
run_process_new_lines "$STREAM_J" "$TMP/j-out.txt"
unset COLUMNS
OUT_J=$(cat "$TMP/j-out.txt")
if [ "${#OUT_J}" -le 80 ] && printf '%s' "$OUT_J" | grep -q "infra-reviewer.md"; then
    pass "J-4: en un pane de 80 columnas el Read se trunca y el nombre del archivo sigue visible"
else
    fail "J-4: el nombre del archivo se perdio en el truncado (ancho ${#OUT_J}): $OUT_J"
fi

# -------- Bloque K: is_missing -- contrato del placeholder de la fila jq --------

echo ""
echo "[K] is_missing reconoce los tres sabores de campo ausente de una fila del filtro"

MISSING_OK=1
for v in "" "-" "null"; do
    is_missing "$v" || { fail "K-1: is_missing deberia reconocer '$v' como ausente"; MISSING_OK=0; }
done
[ "$MISSING_OK" -eq 1 ] && pass "K-1: vacio, '-' (placeholder de cell) y 'null' cuentan como ausente"

if ! is_missing "0" && ! is_missing "false" && ! is_missing "src/Foo.cs"; then
    pass "K-2: un valor real no se confunde con ausente (0, false y una ruta son presentes)"
else
    fail "K-2: un valor real se clasifico como ausente"
fi

if [ "$(ms_to_s "-")" = "?" ] && [ "$(fmt_time_hhmmss "-")" = "--:--:--" ]; then
    pass "K-3: los formateadores traducen el placeholder a su marca de dato ausente"
else
    fail "K-3: los formateadores no tradujeron el placeholder: ms_to_s='$(ms_to_s "-")' hora='$(fmt_time_hhmmss "-")'"
fi

# -------- Bloque L: stream_matches_issues -- filtro exacto por issue --------

echo ""
echo "[L] stream_matches_issues: match exacto por issue, sufijos de reintento, lista y sin filtro"

if stream_matches_issues "tooling-stage-1-writer-20260729-100000-issue-42.stream.jsonl" "42"; then
    pass "L-1: el stream del issue 42 matchea el filtro '42'"
else
    fail "L-1: el stream del issue 42 no matcheo el filtro '42'"
fi

if ! stream_matches_issues "tooling-stage-1-writer-20260729-100000-issue-42.stream.jsonl" "4"; then
    pass "L-2: el filtro '4' NO matchea el issue 42 (el match es exacto, no substring)"
else
    fail "L-2: el filtro '4' matcheo el issue 42 -- cruzaria visores de corridas concurrentes"
fi

if stream_matches_issues "stage-2-implementer-20260729-100000-issue-42-retry.stream.jsonl" "42" \
    && stream_matches_issues "tooling-stage-1-writer-20260729-100000-issue-42-perm-retry.stream.jsonl" "42"; then
    pass "L-3: los sufijos de reintento (-retry, -perm-retry) siguen matcheando su issue"
else
    fail "L-3: un stream de reintento no matcheo su issue"
fi

if stream_matches_issues "stage-1-test-writer-20260729-100000-issue-43.stream.jsonl" "42,43,44"; then
    pass "L-4: una lista de issues (batch) matchea cualquiera de sus miembros"
else
    fail "L-4: la lista '42,43,44' no matcheo el issue 43"
fi

if ! stream_matches_issues "stage-1-test-writer-20260729-100000-issue-99.stream.jsonl" "42,43,44"; then
    pass "L-5: un issue fuera de la lista no matchea"
else
    fail "L-5: el issue 99 matcheo la lista '42,43,44'"
fi

if stream_matches_issues "cualquier-cosa.stream.jsonl" ""; then
    pass "L-6: sin filtro (lista vacia) todo stream matchea -- el comportamiento del visor interno"
else
    fail "L-6: la lista vacia deberia matchear todo"
fi

# -------- Bloque M: stream_is_newer_than + discover_stream con filtros --------

echo ""
echo "[M] stream_is_newer_than y discover_stream con filtros activos"

DIR_M="$TMP/logs-m"
mkdir -p "$DIR_M"
# Corrida "anterior" (issue 10, mtime viejo) y corrida "actual" (issue 20).
echo '{}' > "$DIR_M/tooling-stage-1-writer-20260729-090000-issue-10.stream.jsonl"
touch -t 202607290900 "$DIR_M/tooling-stage-1-writer-20260729-090000-issue-10.stream.jsonl"
echo '{}' > "$DIR_M/tooling-stage-1-writer-20260729-100000-issue-20.stream.jsonl"
touch -t 202607291000 "$DIR_M/tooling-stage-1-writer-20260729-100000-issue-20.stream.jsonl"

if ! stream_is_newer_than "$DIR_M/tooling-stage-1-writer-20260729-090000-issue-10.stream.jsonl" "9999999999"; then
    pass "M-1: un stream con mtime anterior al corte no pasa stream_is_newer_than"
else
    fail "M-1: el stream viejo paso un corte imposiblemente futuro"
fi

if stream_is_newer_than "$DIR_M/tooling-stage-1-writer-20260729-100000-issue-20.stream.jsonl" "1"; then
    pass "M-2: un stream con mtime posterior al corte pasa stream_is_newer_than"
else
    fail "M-2: el stream nuevo no paso un corte de epoch=1"
fi

if stream_is_newer_than "$DIR_M/tooling-stage-1-writer-20260729-090000-issue-10.stream.jsonl" ""; then
    pass "M-3: sin corte (vacio) todo stream pasa"
else
    fail "M-3: el corte vacio deberia dejar pasar todo"
fi

# discover_stream con filtro de issue: aunque el issue 20 es el mas reciente,
# el filtro '10' debe devolver el stream del issue 10.
ISSUES_CSV="10"
NEWER_THAN=""
FOUND_M1=$(discover_stream "$DIR_M")
if [ "$(basename "$FOUND_M1")" = "tooling-stage-1-writer-20260729-090000-issue-10.stream.jsonl" ]; then
    pass "M-4: con ISSUES_CSV=10, discover_stream ignora el stream mas reciente de OTRO issue"
else
    fail "M-4: se esperaba el stream del issue 10, se obtuvo: $FOUND_M1"
fi

# discover_stream con corte temporal: el filtro de issue 10 + un corte
# posterior a su mtime no devuelve nada (la corrida nueva aun no escribio).
ISSUES_CSV="10"
NEWER_THAN="9999999999"
FOUND_M2=$(discover_stream "$DIR_M")
if [ -z "$FOUND_M2" ]; then
    pass "M-5: con un corte posterior al mtime, discover_stream espera (devuelve vacio)"
else
    fail "M-5: se esperaba vacio con corte futuro, se obtuvo: $FOUND_M2"
fi

ISSUES_CSV=""
NEWER_THAN=""

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
