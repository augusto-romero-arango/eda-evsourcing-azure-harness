#!/usr/bin/env bash
# test-stream-watch.sh -- Tests del visor en vivo del stream-json (issue #434).
#
# Contexto: mefisto-stream-watch.sh sigue incrementalmente
# `<log_base>.stream.jsonl` (la traza cruda que #431 ya deja creciendo en
# vivo en .claude/pipeline/logs/) y renderiza una linea legible por accion
# del agente -- hora, delta desde la accion anterior, herramienta y objetivo
# -- para que un humano viendo el pane de tmux pueda notar que el agente esta
# dando vueltas en vez de mirar 20 minutos de silencio.
#
# Estilo test-abort-log-tail.sh: el script bajo prueba corre codigo top-level
# (source de _mefisto-common.sh, assert_in_mefisto, el chequeo de jq) antes
# de llegar a definir sus funciones -- sourcing el archivo completo lo
# disparia. En vez de eso se extrae SOLO el cuerpo de cada funcion (awk sobre
# "nombre() {" .. "}" en columna 0) y se evalua en este proceso, igual que
# test-abort-log-tail.sh y test-stream-json-trace.sh. `main` (el bucle
# infinito real) nunca se extrae ni se llama: no terminaria.
#
# Casos cubiertos:
#   [pre] Todas las funciones bajo prueba se pueden extraer y cargar.
#   [A] Bash con comando multilinea -> el objetivo llega aplanado a una sola
#       linea, sin newlines embebidos (CA-2/CA-3).
#   [B] Repeticion sobre el mismo archivo (Read, Edit, Read) -> sin sufijo la
#       primera vez, "(x2)" la segunda, "(x3)" la tercera; un Bash repetido
#       NO se cuenta (CA-4, exclusion explicita de comandos identicos).
#   [C] Turno sin tool call -> se señala distinto de una tool call, tanto el
#       de solo texto como el de solo thinking (CA-2).
#   [D] Evento `result` REAL (sin `.timestamp`, como lo emite el CLI) ->
#       cierre de stage con turnos/costo/duracion (API vs no-API) sin
#       desplazamiento de campos, con el reloj de la ultima accion; no aborta
#       ni termina el proceso que lo invoca (CA-5).
#   [E] Linea final truncada (pillada a mitad de escritura) -> no avanza el
#       contador de lineas mas alla de ella ni la descarta; al completarse en
#       el streaming real, el siguiente ciclo la procesa junto con lo que
#       vino despues (CA-6).
#   [F] discover_stream elige el *.stream.jsonl mas reciente por mtime, entre
#       varios candidatos, y no falla si el directorio no existe (CA-1).
#   [G] parse_stream_header deriva issue/stage/agente del nombre de archivo
#       (sin leer contenido) y degrada a mostrar el nombre tal cual si no
#       matchea el patron conocido (CA-1).
#   [H] fmt_delta_s -> "-" sin accion anterior, numerico con ella (CA-2).
#   [I] Una linea JSON valida pero no-objeto no rompe el resto del lote
#       (paridad con select(type=="object") de derive_stage_log_from_stream).
#   [J] Truncado al ancho del pane: un comando corta por el final y una ruta
#       conserva la cola, para que el nombre del archivo no se pierda (CA-3).
#   [K] is_missing y el placeholder "-" del filtro jq: el contrato que evita
#       que un campo vacio desplace la fila en el `IFS=$'\t' read`.
#
# Uso: .claude/scripts/tests/test-stream-watch.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TARGET="$REPO_ROOT/.claude/scripts/mefisto-stream-watch.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: este test requiere jq (no encontrado en PATH)." >&2
    exit 1
fi

# extract_fn <function_name> <file> -- mismo patron que test-abort-log-tail.sh.
extract_fn() {
    local name="$1" file="$2"
    awk -v fn="$name" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p{print} p && /^}/{p=0}' "$file"
}

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Colores a vacio: las funciones extraidas los referencian, y este test corre
# con `set -u` (mismo motivo que test-abort-log-tail.sh).
RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; NC=""

FNS="write_jq_filter stream_matches_issues stream_is_newer_than discover_stream parse_stream_header pane_width is_missing truncate_target truncate_path fmt_time_hhmmss fmt_delta_s ms_to_s touch_count render_result_summary render_row process_new_lines"

echo "[pre] Las funciones bajo prueba se pueden extraer y cargar desde mefisto-stream-watch.sh"
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

# Filtros de descubrimiento en su default (sin filtro): discover_stream los
# referencia bajo `set -u`, y los bloques que los prueban ([L]/[M]) los
# setean y los devuelven a vacio.
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
# al volver -- exactamente lo que necesitamos observar en estos tests. La
# redireccion simple `>` no crea subshell para un comando simple, asi que el
# estado global si sobrevive a la llamada.
run_process_new_lines() {
    local stream="$1" outfile="$2"
    process_new_lines "$stream" > "$outfile"
}

# -------- Bloque A: Bash multilinea se aplana a una sola linea (CA-2/CA-3) --------

echo ""
echo "[A] Bash con comando multilinea -> objetivo aplanado a una sola linea (CA-3)"

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

# -------- Bloque B: repeticion sobre el mismo archivo (CA-4) --------

echo ""
echo "[B] Repeticion sobre el mismo archivo -> sin sufijo, luego (x2), luego (x3) (CA-4)"

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
    pass "B-4: el Bash repetido (dotnet build x2) NO se marca -- CA-4 excluye comandos identicos"
else
    fail "B-4: un Bash repetido no deberia llevar sufijo de repeticion: '$LINE4' / '$LINE5'"
fi

# -------- Bloque C: turno de solo texto (CA-2) --------

echo ""
echo "[C] Turno de solo texto (sin tool call) se señala distinto de una tool call (CA-2)"

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

# Un turno de SOLO thinking es el otro sabor de turno sin tool call, y en una
# traza real es el mas frecuente de los dos (11 bloques thinking contra 4 de
# texto en el stream del reviewer de #437): si no se señalara, su tiempo de
# razonamiento se le cargaria al delta de la accion siguiente, que es
# justamente la lectura que CA-2 quiere habilitar. El texto del bloque viaja
# vacio en el stream (solo queda la firma), asi que se señala el turno.
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

# -------- Bloque D: evento result -> cierre de stage (CA-5) --------

echo ""
echo "[D] Evento result -> cierre de stage con turnos/costo/duracion API vs no-API (CA-5)"

# El fixture reproduce el evento `result` REAL del CLI, que NO trae
# `.timestamp` (verificado contra las trazas de .claude/pipeline/logs/). Es la
# forma exacta que hacia fallar el render: con el campo de hora vacio, la fila
# TSV se leia desplazada (`IFS=$'\t' read` colapsa dos tabs seguidos porque el
# tab es espacio en blanco para IFS) y el cierre reportaba duration_ms como
# turnos y is_error como costo. Va precedido de una accion con hora, porque el
# reloj del cierre es el de la ultima accion vista.
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
    pass "D-1: procesar el evento result no aborta el proceso que invoca (CA-5, sigue esperando)"
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

# El reloj del cierre debe ser el de la ultima accion, no la epoca ni la hora
# en que se corre el visor (asi sirve igual sobre un stream pasado). Se compara
# contra la hora que el propio render puso en la linea de la accion, para no
# atarse a la zona horaria de la maquina que corre el test.
HORA_ACCION_D=$(printf '%s\n' "$OUT_D" | sed -n 's/^\[\([0-9:]*\)\].*Bash.*/\1/p' | head -1)
HORA_CIERRE_D=$(printf '%s\n' "$OUT_D" | sed -n 's/^--- cierre de stage \[\([0-9:-]*\)\].*/\1/p' | head -1)
if [ -n "$HORA_ACCION_D" ] && [ "$HORA_CIERRE_D" = "$HORA_ACCION_D" ]; then
    pass "D-6: el cierre usa el reloj de la ultima accion ($HORA_CIERRE_D), no la epoca ni 'ahora'"
else
    fail "D-6: hora del cierre '$HORA_CIERRE_D' != hora de la ultima accion '$HORA_ACCION_D': $OUT_D"
fi

# -------- Bloque E: linea final truncada -> se reintenta, no se descarta (CA-6) --------

echo ""
echo "[E] Linea final truncada -> no avanza el contador ni la descarta; se completa en el siguiente ciclo (CA-6)"

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

# -------- Bloque F: discover_stream elige el mas reciente por mtime (CA-1) --------

echo ""
echo "[F] discover_stream elige el *.stream.jsonl mas reciente por mtime (CA-1)"

DIR_F="$TMP/logs-f"
mkdir -p "$DIR_F"
echo '{}' > "$DIR_F/mefisto-tooling-stage-1-writer-20260729-090000-issue-100.stream.jsonl"
touch -t 202607290900 "$DIR_F/mefisto-tooling-stage-1-writer-20260729-090000-issue-100.stream.jsonl"
echo '{}' > "$DIR_F/mefisto-tooling-stage-2-reviewer-20260729-093000-issue-100.stream.jsonl"
touch -t 202607290930 "$DIR_F/mefisto-tooling-stage-2-reviewer-20260729-093000-issue-100.stream.jsonl"

FOUND_F=$(discover_stream "$DIR_F")
if [ "$(basename "$FOUND_F")" = "mefisto-tooling-stage-2-reviewer-20260729-093000-issue-100.stream.jsonl" ]; then
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

# -------- Bloque G: parse_stream_header deriva issue/stage/agente del nombre (CA-1) --------

echo ""
echo "[G] parse_stream_header deriva issue/stage/agente del nombre del archivo (CA-1)"

HEADER_G1=$(parse_stream_header "/tmp/x/mefisto-tooling-stage-1-writer-20260729-100000-issue-434.stream.jsonl")
if printf '%s' "$HEADER_G1" | grep -q "issue #434" \
    && printf '%s' "$HEADER_G1" | grep -q "stage 1" \
    && printf '%s' "$HEADER_G1" | grep -q "writer"; then
    pass "G-1: extrae issue=434, stage=1, agente=writer del nombre convencional"
else
    fail "G-1: no se extrajeron los campos esperados: $HEADER_G1"
fi

HEADER_G2=$(parse_stream_header "/tmp/x/mefisto-tooling-stage-merge-writer-20260729-100000-issue-441.stream.jsonl")
if printf '%s' "$HEADER_G2" | grep -q "stage merge"; then
    pass "G-2: el stage 'merge' (no numerico) tambien se extrae -- run_agent lo usa para la resolucion de conflictos"
else
    fail "G-2: no se extrajo el stage 'merge': $HEADER_G2"
fi

HEADER_G3=$(parse_stream_header "/tmp/x/un-nombre-cualquiera.jsonl")
if printf '%s' "$HEADER_G3" | grep -q "un-nombre-cualquiera.jsonl"; then
    pass "G-3: un nombre que no matchea el patron degrada a mostrarlo tal cual (no falla)"
else
    fail "G-3: no degrado mostrando el nombre tal cual: $HEADER_G3"
fi

# -------- Bloque H: delta -- "-" sin accion previa, numerico con ella (CA-2) --------

echo ""
echo "[H] fmt_delta_s -- sin accion previa devuelve '-', con ella devuelve el delta en segundos (CA-2)"

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

# -------- Bloque J: truncado -- comando por el final, ruta por la cola (CA-3) --------

echo ""
echo "[J] Truncado al ancho del pane: el comando corta por el final, la ruta conserva la cola (CA-3)"

CMD_J=$(truncate_target "dotnet test tests/Proyecto.Dominio.Tests/Proyecto.Dominio.Tests.csproj --no-build" 30)
if [ "${#CMD_J}" -le 30 ] && printf '%s' "$CMD_J" | grep -q "^dotnet test" && printf '%s' "$CMD_J" | grep -q '\.\.\.$'; then
    pass "J-1: un comando se trunca por el final -- lo que identifica la accion esta al principio"
else
    fail "J-1: truncado de comando inesperado: '$CMD_J'"
fi

# El agente reporta rutas absolutas y el prefijo comun del worktree se come el
# ancho de un pane estrecho: truncar por el final dejaria solo
# "/Users/augusto-romero-arango/Codigo/Sinco..." en cada Read/Edit/Write, sin
# el nombre del archivo -- la unica parte informativa y la que sostiene la
# señal de repeticion de CA-4.
PATH_J="/Users/augusto-romero-arango/Codigo/Sincosoft/Cosmos/worktree-mefisto-issue-434-anadir/agents/infra-reviewer.md"
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
printf '%s\n' '{"type":"assistant","timestamp":"2026-07-29T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/Users/augusto-romero-arango/Codigo/Sincosoft/Cosmos/worktree-mefisto-issue-434-anadir/agents/infra-reviewer.md"}}]}}' > "$STREAM_J"

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
echo "[L] stream_matches_issues: match exacto por issue, copias .attempt-, lista y sin filtro"

if stream_matches_issues "mefisto-tooling-stage-1-writer-20260826-100000-issue-42.stream.jsonl" "42"; then
    pass "L-1: el stream del issue 42 matchea el filtro '42'"
else
    fail "L-1: el stream del issue 42 no matcheo el filtro '42'"
fi

if ! stream_matches_issues "mefisto-tooling-stage-1-writer-20260826-100000-issue-42.stream.jsonl" "4"; then
    pass "L-2: el filtro '4' NO matchea el issue 42 (el match es exacto, no substring)"
else
    fail "L-2: el filtro '4' matcheo el issue 42 -- cruzaria visores de corridas concurrentes"
fi

if stream_matches_issues "mefisto-tooling-stage-2-reviewer-20260826-100000-issue-42.attempt-2.stream.jsonl" "42"; then
    pass "L-3: la copia de reintento (.attempt-2) sigue matcheando su issue"
else
    fail "L-3: la copia .attempt-2 no matcheo su issue"
fi

if stream_matches_issues "mefisto-tooling-stage-1-writer-20260826-100000-issue-43.stream.jsonl" "42,43,44" \
    && ! stream_matches_issues "mefisto-tooling-stage-1-writer-20260826-100000-issue-99.stream.jsonl" "42,43,44"; then
    pass "L-4: una lista de issues (batch) matchea sus miembros y rechaza los ajenos"
else
    fail "L-4: la lista '42,43,44' no filtro como se esperaba"
fi

if stream_matches_issues "cualquier-cosa.stream.jsonl" ""; then
    pass "L-5: sin filtro (lista vacia) todo stream matchea -- el comportamiento original"
else
    fail "L-5: la lista vacia deberia matchear todo"
fi

# -------- Bloque M: stream_is_newer_than + discover_stream con filtros --------

echo ""
echo "[M] stream_is_newer_than y discover_stream con filtros activos"

DIR_M="$TMP/logs-m"
mkdir -p "$DIR_M"
echo '{}' > "$DIR_M/mefisto-tooling-stage-1-writer-20260826-090000-issue-10.stream.jsonl"
touch -t 202608260900 "$DIR_M/mefisto-tooling-stage-1-writer-20260826-090000-issue-10.stream.jsonl"
echo '{}' > "$DIR_M/mefisto-tooling-stage-1-writer-20260826-100000-issue-20.stream.jsonl"
touch -t 202608261000 "$DIR_M/mefisto-tooling-stage-1-writer-20260826-100000-issue-20.stream.jsonl"

if ! stream_is_newer_than "$DIR_M/mefisto-tooling-stage-1-writer-20260826-090000-issue-10.stream.jsonl" "9999999999" \
    && stream_is_newer_than "$DIR_M/mefisto-tooling-stage-1-writer-20260826-100000-issue-20.stream.jsonl" "1" \
    && stream_is_newer_than "$DIR_M/mefisto-tooling-stage-1-writer-20260826-090000-issue-10.stream.jsonl" ""; then
    pass "M-1: el corte por mtime rechaza lo anterior, deja pasar lo posterior y sin corte pasa todo"
else
    fail "M-1: stream_is_newer_than no filtro como se esperaba"
fi

ISSUES_CSV="10"
NEWER_THAN=""
FOUND_M1=$(discover_stream "$DIR_M")
if [ "$(basename "$FOUND_M1")" = "mefisto-tooling-stage-1-writer-20260826-090000-issue-10.stream.jsonl" ]; then
    pass "M-2: con ISSUES_CSV=10, discover_stream ignora el stream mas reciente de OTRO issue"
else
    fail "M-2: se esperaba el stream del issue 10, se obtuvo: $FOUND_M1"
fi

ISSUES_CSV="10"
NEWER_THAN="9999999999"
FOUND_M2=$(discover_stream "$DIR_M")
if [ -z "$FOUND_M2" ]; then
    pass "M-3: con un corte posterior al mtime, discover_stream espera (devuelve vacio)"
else
    fail "M-3: se esperaba vacio con corte futuro, se obtuvo: $FOUND_M2"
fi

ISSUES_CSV=""
NEWER_THAN=""

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
