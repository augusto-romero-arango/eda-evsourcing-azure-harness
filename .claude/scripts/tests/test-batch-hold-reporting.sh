#!/usr/bin/env bash
# test-batch-hold-reporting.sh -- Tests del reporte del eslabon en espera
# (hold, issue #967) como estado propio del batch interno (issue #969).
#
# Cubre:
#   [pre] El script existe, es ejecutable y tiene sintaxis valida.
#   [A]   hold_seconds_in_range()/fmt_hold_duration()/hold_note_suffix() en
#         aislamiento: suman los ciclos "[hold]" del rango pedido, ignoran
#         "[hold][resume]" (issue #968), respetan el offset de linea (no
#         cuentan el hold de un issue anterior en el mismo events.log
#         compartido) y degradan a 0 sin archivo.
#   [B]   Guard de regresion: ninguna de esas tres funciones referencia
#         HAVE_ERRORS ni FAILED -- el reporte de hold es puramente
#         informativo (CA-1).
#   [C]   Corrida real end-to-end: un eslabon que espera (su stub escribe
#         lineas "[hold]" en events.log antes de terminar con exito) queda
#         "completado" con la nota de cuanto espero, FAILED se mantiene en 0,
#         exit 0, y el resumen final anota el tiempo total en espera del
#         batch (CA-1, CA-3, CA-5).
#   [D]   Corrida real end-to-end: un eslabon que espera y LUEGO falla de
#         verdad (techo de espera agotado, simulado con exit != 0) SI cuenta
#         como fallo real -- FAILED se incrementa y el exit code del batch es
#         1, con la nota de cuanto espero como contexto informativo en el
#         mensaje de error (CA-5: el hold en si nunca decide el desenlace,
#         pero tampoco lo enmascara cuando el desenlace real es un fallo).
#   [E]   Dos eslabones con esperas de duracion distinta: cada uno reporta SU
#         propio tiempo (sin arrastrar el del anterior, pese a compartir el
#         mismo events.log) y el total del resumen es la suma exacta de
#         ambos.
#
# Uso: .claude/scripts/tests/test-batch-hold-reporting.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CANON_BATCH="$REPO_ROOT/src/internal/scripts/mefisto-batch-pipeline.sh"
CANON_LIB="$REPO_ROOT/src/internal/scripts/lib/_mefisto-common.sh"
CANON_STATE_LIB="$REPO_ROOT/src/internal/scripts/lib/mefisto-state.sh"
CANON_RUNTIME_LIB="$REPO_ROOT/src/internal/scripts/lib/mefisto-runtime.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# -------- Bloque pre: el script existe, es ejecutable y tiene sintaxis valida --------

echo "[pre] mefisto-batch-pipeline.sh existe, es ejecutable y tiene sintaxis valida"

if [ -x "$CANON_BATCH" ]; then
    pass "el script existe y es ejecutable"
else
    fail "el script no existe o no es ejecutable: $CANON_BATCH"
fi

if bash -n "$CANON_BATCH" 2>/dev/null; then
    pass "sintaxis valida (bash -n)"
else
    fail "bash -n reporto un error de sintaxis en $CANON_BATCH"
fi

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# -------- Extraer las funciones REALES bajo prueba (no reimplementarlas) --------

extract_fn() {
    local name="$1" file="$2"
    awk -v fn="$name" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p{print} p && /^}/{p=0}' "$file"
}

HOLD_SECONDS_SRC=$(extract_fn "hold_seconds_in_range" "$CANON_BATCH")
FMT_HOLD_SRC=$(extract_fn "fmt_hold_duration" "$CANON_BATCH")
HOLD_NOTE_SRC=$(extract_fn "hold_note_suffix" "$CANON_BATCH")

for pair in "hold_seconds_in_range:$HOLD_SECONDS_SRC" "fmt_hold_duration:$FMT_HOLD_SRC" "hold_note_suffix:$HOLD_NOTE_SRC"; do
    name="${pair%%:*}"; src="${pair#*:}"
    if [ -z "$src" ]; then
        fail "no se pudo extraer $name() de $CANON_BATCH -- el resto de los bloques se omite"
        echo ""
        echo "----------------------------------------"
        echo "  Resumen: $PASS pass, $FAIL fail"
        echo "----------------------------------------"
        exit 1
    fi
done
pass "las tres funciones se extrajeron del script real"

load_fns() {
    eval "$HOLD_SECONDS_SRC"
    eval "$FMT_HOLD_SRC"
    eval "$HOLD_NOTE_SRC"
}
load_fns

# write_hold_cycle <events_log> <sleep_seconds> [<familia>]
#
# Escribe UNA linea "[hold]" real (formato del issue #967) cuyo delta
# start->proxima-sonda es EXACTAMENTE <sleep_seconds>: ambas horas se derivan
# del MISMO epoch base para no depender de que dos llamadas a `date`
# consecutivas caigan en el mismo segundo.
write_hold_cycle() {
    local events_log="$1" sleep_s="$2" familia="${3:-RATE_LIMIT}"
    local now_epoch probe_epoch start_hms probe_hms
    now_epoch=$(date +%s)
    probe_epoch=$((now_epoch + sleep_s))
    start_hms=$(date -r "$now_epoch" +%H:%M:%S 2>/dev/null || date -d "@$now_epoch" +%H:%M:%S)
    probe_hms=$(date -r "$probe_epoch" +%H:%M:%S 2>/dev/null || date -d "@$probe_epoch" +%H:%M:%S)
    echo "[$start_hms][hold] $familia: esperando, proxima sonda $probe_hms (techo 23:59)" >> "$events_log"
}

# -------- Bloque A: las tres funciones en aislamiento --------

echo ""
echo "[A] hold_seconds_in_range()/fmt_hold_duration()/hold_note_suffix() en aislamiento (CA-3)"

EVENTS_A="$TMP/events-a.log"
: > "$EVENTS_A"
echo "=== SESSION MEFISTO-TOOLING 20260101-090000 issue:900 from-stage:1 ===" >> "$EVENTS_A"
write_hold_cycle "$EVENTS_A" 300
write_hold_cycle "$EVENTS_A" 250
echo "[$(date +%H:%M:%S)][hold][resume] writer: reanudando sesion abc123" >> "$EVENTS_A"

TOTAL_A=$(hold_seconds_in_range "$EVENTS_A" 0)
if [ "$TOTAL_A" -eq 550 ]; then
    pass "A: suma los dos ciclos [hold] (300+250=550), ignora la linea [hold][resume]"
else
    fail "A: se esperaban 550s, se obtuvo '$TOTAL_A'"
fi

# Offset de linea: arrancando DESPUES del primer ciclo, solo cuenta el segundo.
LINE_AFTER_FIRST=$(( $(grep -n '^\[' "$EVENTS_A" | head -1 | cut -d: -f1) ))
TOTAL_A_OFFSET=$(hold_seconds_in_range "$EVENTS_A" "$LINE_AFTER_FIRST")
if [ "$TOTAL_A_OFFSET" -eq 250 ]; then
    pass "A: el offset de linea excluye el ciclo anterior al rango (no arrastra el hold de otro issue)"
else
    fail "A: con offset se esperaban 250s, se obtuvo '$TOTAL_A_OFFSET'"
fi

TOTAL_MISSING=$(hold_seconds_in_range "$TMP/no-existe.log" 0)
if [ "$TOTAL_MISSING" -eq 0 ]; then
    pass "A: un events.log inexistente degrada a 0, nunca aborta"
else
    fail "A: se esperaba 0 con archivo inexistente, se obtuvo '$TOTAL_MISSING'"
fi

if [ "$(fmt_hold_duration 605)" = "10m 5s" ]; then
    pass "A: fmt_hold_duration formatea 'Xm Ys'"
else
    fail "A: fmt_hold_duration(605) deberia ser '10m 5s', fue '$(fmt_hold_duration 605)'"
fi

if [ -z "$(hold_note_suffix 0)" ]; then
    pass "A: hold_note_suffix(0) es cadena vacia (sin nota cuando no hubo espera)"
else
    fail "A: hold_note_suffix(0) deberia ser vacio, fue '$(hold_note_suffix 0)'"
fi

NOTE=$(hold_note_suffix 605)
if echo "$NOTE" | grep -qF "10m 5s"; then
    pass "A: hold_note_suffix(605) nombra la duracion formateada"
else
    fail "A: hold_note_suffix(605) deberia nombrar '10m 5s', fue '$NOTE'"
fi

# -------- Bloque B: guard de regresion -- nunca deciden FAILED/HAVE_ERRORS --------

echo ""
echo "[B] Las tres funciones nunca referencian HAVE_ERRORS ni FAILED (CA-1: el hold es informativo)"

ANY_LEAK=false
for pair in "hold_seconds_in_range:$HOLD_SECONDS_SRC" "fmt_hold_duration:$FMT_HOLD_SRC" "hold_note_suffix:$HOLD_NOTE_SRC"; do
    name="${pair%%:*}"; src="${pair#*:}"
    if echo "$src" | grep -qE 'HAVE_ERRORS|FAILED'; then
        fail "B: $name() referencia HAVE_ERRORS o FAILED"
        ANY_LEAK=true
    fi
done
[ "$ANY_LEAK" = false ] && pass "B: ninguna de las tres funciones toca HAVE_ERRORS ni FAILED"

# -------- Fixtures compartidas de los bloques C/D/E: repo Mefisto + origin real --------

new_bare_with_publisher() {
    local bare="$1" publisher="$2"
    git init -q --bare "$bare"
    git -C "$bare" symbolic-ref HEAD refs/heads/main
    git clone -q "$bare" "$publisher"
    git -C "$publisher" config user.email "test@mefisto.local"
    git -C "$publisher" config user.name "Mefisto Test"
    git -C "$publisher" checkout -q -b main 2>/dev/null || git -C "$publisher" checkout -q main
    git -C "$publisher" commit -q --allow-empty -m "base"
    git -C "$publisher" push -q origin main
}

setup_work_repo() {
    local dir="$1"
    mkdir -p "$dir/.claude-plugin" "$dir/src/internal/scripts/lib"
    cat > "$dir/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "mefisto",
  "version": "0.0.0"
}
EOF
    cp "$CANON_LIB" "$dir/src/internal/scripts/lib/_mefisto-common.sh"
    cp "$CANON_STATE_LIB" "$dir/src/internal/scripts/lib/mefisto-state.sh"
    cp "$CANON_RUNTIME_LIB" "$dir/src/internal/scripts/lib/mefisto-runtime.sh"
    touch "$dir/src/internal/scripts/lib/runtime-claude.sh"
    cp "$CANON_BATCH" "$dir/src/internal/scripts/mefisto-batch-pipeline.sh"
    chmod +x "$dir/src/internal/scripts/mefisto-batch-pipeline.sh"
}

# fake_tooling_pipeline_hold <dir> <call_log> <hold_spec...>
#
# Stub del pipeline de tooling: registra cada issue invocado en <call_log>.
# <hold_spec> es "issue:segundos:familia:desenlace" (desenlace = "ok" o
# "fail"), uno o mas separados por espacio -- solo actua cuando "$1" matchea
# el <issue> de algun spec. Escribe la(s) linea(s) "[hold]" reales en el
# events.log COMPARTIDO del checkout (mismo archivo que
# mefisto-tooling-pipeline.sh usaria) antes de terminar, para ejercer
# hold_seconds_in_range() con datos identicos a los de una corrida real.
fake_tooling_pipeline_hold() {
    local dir="$1" call_log="$2"; shift 2
    local specs=("$@")

    {
        echo '#!/usr/bin/env bash'
        echo "echo \"\$1\" >> \"$call_log\""
        echo 'EVENTS_LOG="$PWD/.mefisto/pipeline/events.log"'
        echo 'mkdir -p "$(dirname "$EVENTS_LOG")"'
        for spec in "${specs[@]}"; do
            IFS=':' read -r sp_issue sp_secs sp_familia sp_outcome <<< "$spec"
            cat <<EOF
if [ "\$1" = "$sp_issue" ]; then
    NOW_EPOCH=\$(date +%s)
    PROBE_EPOCH=\$((NOW_EPOCH + $sp_secs))
    START_HMS=\$(date -r "\$NOW_EPOCH" +%H:%M:%S 2>/dev/null || date -d "@\$NOW_EPOCH" +%H:%M:%S)
    PROBE_HMS=\$(date -r "\$PROBE_EPOCH" +%H:%M:%S 2>/dev/null || date -d "@\$PROBE_EPOCH" +%H:%M:%S)
    echo "[\$START_HMS][hold] $sp_familia: esperando, proxima sonda \$PROBE_HMS (techo 23:59)" >> "\$EVENTS_LOG"
EOF
            if [ "$sp_outcome" = "fail" ]; then
                echo "    exit 1"
            fi
            echo "fi"
        done
        echo 'echo "v PR creado: https://github.com/acme/mefisto-fake/pull/$(($1 + 1000))"'
        echo 'exit 0'
    } > "$dir/src/internal/scripts/mefisto-tooling-pipeline.sh"
    chmod +x "$dir/src/internal/scripts/mefisto-tooling-pipeline.sh"
}

setup_fake_gh() {
    local bin_dir="$1"
    cat > "$bin_dir/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
    num="$3"
    git -C "$FAKE_GH_PUBLISHER" commit -q --allow-empty -m "merge PR #$num" >/dev/null 2>&1
    git -C "$FAKE_GH_PUBLISHER" push -q origin main >/dev/null 2>&1
    mkdir -p "$FAKE_GH_SHA_DIR"
    git -C "$FAKE_GH_PUBLISHER" rev-parse main > "$FAKE_GH_SHA_DIR/$num"
    exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    num="$3"
    [ -f "$FAKE_GH_SHA_DIR/$num" ] && cat "$FAKE_GH_SHA_DIR/$num"
    exit 0
fi
exit 0
STUB
    chmod +x "$bin_dir/gh"
}

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
setup_fake_gh "$FAKE_BIN"
cat > "$FAKE_BIN/claude" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FAKE_BIN/claude"

SAFE_SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

run_batch() {
    local dir="$1" publisher="$2" sha_dir="$3"; shift 3
    local out="$TMP/stdout" err="$TMP/stderr"
    (
        cd "$dir" || exit 99
        env -u MEFISTO_STATE_DIR -u MEFISTO_LEGACY_STATE_DIR -u MEFISTO_REPO_ROOT \
            -u MEFISTO_PROJECT_NAME -u MEFISTO_REPO_SLUG -u MEFISTO_RUNTIME_LIB_DIR \
            MEFISTO_RUNTIME=claude PATH="$FAKE_BIN:$SAFE_SYSTEM_PATH" \
            FAKE_GH_PUBLISHER="$publisher" FAKE_GH_SHA_DIR="$sha_dir" \
            ./src/internal/scripts/mefisto-batch-pipeline.sh "$@"
    ) </dev/null >"$out" 2>"$err"
    LAST_RC=$?
    LAST_STDOUT=$(cat "$out")
    LAST_STDERR=$(cat "$err")
}

# -------- Bloque C: eslabon que espera y luego SI tiene exito --------

echo ""
echo "[C] Eslabon que espera y se recupera: 'completado' con la nota de hold, FAILED=0, exit 0, total en el resumen (CA-1, CA-3, CA-5)"

BARE_C="$TMP/origin-c.git"; PUB_C="$TMP/pub-c"
new_bare_with_publisher "$BARE_C" "$PUB_C"
WORK_C="$TMP/work-c"
git clone -q "$BARE_C" "$WORK_C"
setup_work_repo "$WORK_C"
CALL_LOG_C="$TMP/call-log-c"; : > "$CALL_LOG_C"
# Dos ciclos de 300s (=10m totales) para el issue 601; el 602 no espera nada.
fake_tooling_pipeline_hold "$WORK_C" "$CALL_LOG_C" "601:300:RATE_LIMIT:ok" "601:300:RATE_LIMIT:ok"

run_batch "$WORK_C" "$PUB_C" "$TMP/sha-c" 601 602

if [ "$LAST_RC" -eq 0 ]; then
    pass "C: exit 0 (CA-5: el hold no cambia el exit code de una corrida sin fallos reales)"
else
    fail "C: se esperaba exit 0, se obtuvo $LAST_RC. stdout: $LAST_STDOUT / stderr: $LAST_STDERR"
fi

if ! echo "$LAST_STDOUT" | grep -q "Fallidos: [^0]"; then
    pass "C: FAILED se mantuvo en 0 pese a la espera (CA-1)"
else
    fail "C: FAILED no deberia incrementarse por una espera. stdout: $LAST_STDOUT"
fi

if echo "$LAST_STDOUT" | grep -E '#601\s' | grep -q "completado" \
    && ! echo "$LAST_STDOUT" | grep -E '#601\s' | grep -q "ERROR"; then
    pass "C: el issue 601 quedo 'completado' (nunca 'ERROR:', CA-1)"
else
    fail "C: el issue 601 deberia quedar 'completado' sin 'ERROR:'. stdout: $LAST_STDOUT"
fi

if echo "$LAST_STDOUT" | grep -E '#601\s' | grep -qF "espero 10m 0s en hold"; then
    pass "C: la fila del issue 601 nombra 'espero 10m 0s en hold' (CA-2)"
else
    fail "C: se esperaba la nota de hold en la fila del issue 601. stdout: $LAST_STDOUT"
fi

if echo "$LAST_STDOUT" | grep -E '#602\s' | grep -q "completado" \
    && ! echo "$LAST_STDOUT" | grep -E '#602\s' | grep -qF "en hold"; then
    pass "C: el issue 602 (sin espera) no lleva nota de hold"
else
    fail "C: el issue 602 no deberia mencionar hold. stdout: $LAST_STDOUT"
fi

if echo "$LAST_STDOUT" | grep -qF "Tiempo total en espera (hold): 10m 0s"; then
    pass "C: el resumen final anota el tiempo total en espera del batch (CA-3)"
else
    fail "C: se esperaba la linea de tiempo total en espera. stdout: $LAST_STDOUT"
fi

# -------- Bloque D: eslabon que espera y LUEGO falla de verdad --------

echo ""
echo "[D] Eslabon que espera y falla de verdad (techo agotado): FAILED se incrementa, exit 1, con la nota de hold como contexto (CA-5)"

BARE_D="$TMP/origin-d.git"; PUB_D="$TMP/pub-d"
new_bare_with_publisher "$BARE_D" "$PUB_D"
WORK_D="$TMP/work-d"
git clone -q "$BARE_D" "$WORK_D"
setup_work_repo "$WORK_D"
CALL_LOG_D="$TMP/call-log-d"; : > "$CALL_LOG_D"
fake_tooling_pipeline_hold "$WORK_D" "$CALL_LOG_D" "701:120:PROVIDER_UNAVAILABLE:fail"

run_batch "$WORK_D" "$PUB_D" "$TMP/sha-d" 701

if [ "$LAST_RC" -eq 1 ]; then
    pass "D: exit 1 -- un fallo real tras esperar sigue siendo un fallo (CA-5)"
else
    fail "D: se esperaba exit 1, se obtuvo $LAST_RC. stdout: $LAST_STDOUT / stderr: $LAST_STDERR"
fi

if echo "$LAST_STDOUT" | grep -q "Fallidos: 1"; then
    pass "D: FAILED se incremento a 1 (el hold no enmascara un fallo real)"
else
    fail "D: se esperaba 'Fallidos: 1'. stdout: $LAST_STDOUT"
fi

if echo "$LAST_STDOUT" | grep -E '#701\s' | grep -q "ERROR"; then
    pass "D: el issue 701 quedo 'ERROR:' (fallo real, no una espera en curso)"
else
    fail "D: el issue 701 deberia quedar 'ERROR:'. stdout: $LAST_STDOUT"
fi

if echo "$LAST_STDOUT" | grep -E '#701\s' | grep -qF "espero 2m 0s en hold"; then
    pass "D: el mensaje de error nombra igual cuanto se espero antes del fallo"
else
    fail "D: se esperaba la nota de hold en el mensaje de error del issue 701. stdout: $LAST_STDOUT"
fi

# -------- Bloque E: dos eslabones con esperas de duracion distinta --------

echo ""
echo "[E] Dos eslabones con esperas distintas: cada uno reporta la SUYA, el total es la suma exacta"

BARE_E="$TMP/origin-e.git"; PUB_E="$TMP/pub-e"
new_bare_with_publisher "$BARE_E" "$PUB_E"
WORK_E="$TMP/work-e"
git clone -q "$BARE_E" "$WORK_E"
setup_work_repo "$WORK_E"
CALL_LOG_E="$TMP/call-log-e"; : > "$CALL_LOG_E"
fake_tooling_pipeline_hold "$WORK_E" "$CALL_LOG_E" "801:300:RATE_LIMIT:ok" "802:450:RATE_LIMIT:ok"

run_batch "$WORK_E" "$PUB_E" "$TMP/sha-e" 801 802

if [ "$LAST_RC" -eq 0 ]; then
    pass "E: exit 0"
else
    fail "E: se esperaba exit 0, se obtuvo $LAST_RC. stdout: $LAST_STDOUT / stderr: $LAST_STDERR"
fi

if echo "$LAST_STDOUT" | grep -E '#801\s' | grep -qF "espero 5m 0s en hold"; then
    pass "E: el issue 801 reporta su propia espera (5m 0s), sin arrastrar la del 802"
else
    fail "E: se esperaba 'espero 5m 0s en hold' en la fila del issue 801. stdout: $LAST_STDOUT"
fi

if echo "$LAST_STDOUT" | grep -E '#802\s' | grep -qF "espero 7m 30s en hold"; then
    pass "E: el issue 802 reporta su propia espera (7m 30s), sin arrastrar la del 801"
else
    fail "E: se esperaba 'espero 7m 30s en hold' en la fila del issue 802. stdout: $LAST_STDOUT"
fi

if echo "$LAST_STDOUT" | grep -qF "Tiempo total en espera (hold): 12m 30s"; then
    pass "E: el total del resumen es la suma exacta de ambas esperas (5m+7m30s=12m30s)"
else
    fail "E: se esperaba 'Tiempo total en espera (hold): 12m 30s'. stdout: $LAST_STDOUT"
fi

# -------- Resumen --------

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
