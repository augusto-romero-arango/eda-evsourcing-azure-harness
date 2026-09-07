#!/usr/bin/env bash
# test-hold-visibility.sh -- Tests de la visibilidad de la espera (hold) en
# los orquestadores publicados con cola (issue #973, contraparte publicada de
# #969, consumidora de la politica de espera del issue #971).
#
# Contexto: agent_hold_wait (issue #971, _pipeline-common.sh) ya deja
# constancia de una espera activa en events.log, pero solo el pipeline que la
# sufre (tdd/tooling/iac-pipeline.sh) la ve -- esta bloqueado en su propio
# sleep. batch-pipeline.sh (secuencial) hereda esa opacidad gratis porque
# nunca corre nada mientras espera; parallel-pipeline.sh SI necesita saber,
# sin bloquearse, si hay una espera activa: para no lanzar mas issues de la
# cola (CA-3) y para reflejarlo en su dashboard (CA-2).
#
# Casos cubiertos:
#   [1] hold_recently_active: sin events.log -> falso.
#   [2] hold_recently_active: events.log vacio -> falso.
#   [3] hold_recently_active: linea de hold con "proxima sonda" en el FUTURO
#       -> verdadero (espera activa).
#   [4] hold_recently_active: linea de hold con "proxima sonda" en el PASADO
#       -> falso (se resolvio, o se agoto el techo).
#   [5] hold_recently_active: solo hay lineas "[hold][resume]" (sub-eventos de
#       una sonda puntual) -- no cuentan como el anuncio de la espera.
#   [6] hold_recently_active: con varias lineas de hold, usa la ULTIMA.
#   [7] format_hold_status: con espera activa, imprime la linea sin timestamp
#       ni corchetes de "[hold]" (causa + proxima sonda + techo).
#   [8] format_hold_status: sin espera activa, no imprime nada y retorna 1.
#   [9] CA-3: parallel-pipeline.sh consulta hold_recently_active ANTES de
#       lanzar el siguiente pendiente de la cola (grep de wiring -- el
#       comportamiento en si ya lo cubren los casos 1-6 sobre la funcion
#       real que consume).
#   [10] CA-2: parallel-pipeline.sh dibuja el hold en su dashboard via
#        format_hold_status.
#   [11] CA-1/CA-5: batch-pipeline.sh anota la espera en el tracker sin tocar
#        FAILED/HAVE_ERRORS/STOP_ON_ERROR ni el exit code -- la anotacion es
#        puramente informativa (CA-2), nunca una nueva categoria de fallo.
#
# Uso: scripts/tests/test-hold-visibility.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BATCH_SCRIPT="$REPO_ROOT/scripts/batch-pipeline.sh"
PARALLEL_SCRIPT="$REPO_ROOT/scripts/parallel-pipeline.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/_pipeline-common.sh"

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# hms_at <delta_segundos> -- HH:MM:SS de "ahora + delta" (mismo patron que
# agent_hold_wait para formatear un epoch: date -r (BSD/macOS) con fallback a
# date -d (GNU)). Usado para construir lineas [hold] con "proxima sonda" en
# el futuro o el pasado sin acoplar el test a un valor de reloj fijo.
hms_at() {
    local delta="$1"
    local epoch=$(( $(date +%s) + delta ))
    date -r "$epoch" +%H:%M:%S 2>/dev/null || date -d "@$epoch" +%H:%M:%S 2>/dev/null
}

echo "[1] hold_recently_active: sin events.log -> falso"
NO_FILE="$TMP/no-existe.log"
if hold_recently_active "$NO_FILE"; then
    fail "deberia ser falso sin events.log"
else
    pass "sin events.log -> falso"
fi

echo ""
echo "[2] hold_recently_active: events.log vacio -> falso"
EMPTY_LOG="$TMP/empty-events.log"
: > "$EMPTY_LOG"
if hold_recently_active "$EMPTY_LOG"; then
    fail "deberia ser falso con events.log vacio"
else
    pass "events.log vacio -> falso"
fi

echo ""
echo "[3] hold_recently_active: proxima sonda en el FUTURO -> espera activa"
FUTURE_LOG="$TMP/future.log"
FUTURE_HMS=$(hms_at 120)
cat > "$FUTURE_LOG" <<EOF
=== SESSION TOOLING 20260101-000000 issue:42 from-stage:1 ===
[$(hms_at -300)][hold] RATE_LIMIT: esperando, proxima sonda $FUTURE_HMS (techo 23:59)
EOF
if hold_recently_active "$FUTURE_LOG"; then
    pass "proxima sonda en el futuro -> espera activa"
else
    fail "deberia detectar espera activa con proxima sonda en el futuro"
fi

echo ""
echo "[4] hold_recently_active: proxima sonda en el PASADO -> ya no esta activa"
PAST_LOG="$TMP/past.log"
PAST_HMS=$(hms_at -120)
cat > "$PAST_LOG" <<EOF
[$(hms_at -420)][hold] PROVIDER_UNAVAILABLE: esperando, proxima sonda $PAST_HMS (techo 23:59)
EOF
if hold_recently_active "$PAST_LOG"; then
    fail "no deberia estar activa con proxima sonda ya pasada"
else
    pass "proxima sonda en el pasado -> no activa (resuelta o techo agotado)"
fi

echo ""
echo "[5] hold_recently_active: solo lineas [hold][resume] -> no cuentan como anuncio"
RESUME_ONLY_LOG="$TMP/resume-only.log"
cat > "$RESUME_ONLY_LOG" <<EOF
[$(hms_at -60)][hold][resume] writer: el intento fallido no dejo transcript en el worktree -- reintento desde cero (sin -c)
EOF
if hold_recently_active "$RESUME_ONLY_LOG"; then
    fail "una linea [hold][resume] sola no deberia contar como espera activa"
else
    pass "solo [hold][resume] -> no activa (no es el anuncio de agent_hold_wait)"
fi

echo ""
echo "[6] hold_recently_active: con varias lineas, usa la ULTIMA"
MULTI_LOG="$TMP/multi.log"
cat > "$MULTI_LOG" <<EOF
[$(hms_at -900)][hold] RATE_LIMIT: esperando, proxima sonda $(hms_at -600) (techo 23:59)
[$(hms_at -300)][hold] RATE_LIMIT: esperando, proxima sonda $FUTURE_HMS (techo 23:59)
EOF
if hold_recently_active "$MULTI_LOG"; then
    pass "usa la ultima linea (proxima sonda en el futuro), no la primera (ya pasada)"
else
    fail "deberia usar la ultima linea de hold, que sigue activa"
fi

echo ""
echo "[7] format_hold_status: con espera activa, imprime causa + proxima sonda + techo sin timestamp/corchetes de [hold]"
OUT=$(format_hold_status "$FUTURE_LOG")
case "$OUT" in
    "RATE_LIMIT: esperando, proxima sonda $FUTURE_HMS (techo 23:59)")
        pass "format_hold_status: linea formateada como se esperaba"
        ;;
    *)
        fail "format_hold_status devolvio '$OUT'"
        ;;
esac
case "$OUT" in
    "["*) fail "format_hold_status no deberia dejar el timestamp/corchete inicial" ;;
    *) pass "sin timestamp ni corchete inicial" ;;
esac

echo ""
echo "[8] format_hold_status: sin espera activa, no imprime nada y retorna 1"
OUT=""
if OUT=$(format_hold_status "$PAST_LOG"); then
    fail "deberia retornar 1 sin espera activa"
else
    pass "retorna 1 sin espera activa"
fi
if [ -z "$OUT" ]; then
    pass "sin salida cuando no hay espera activa"
else
    fail "no deberia imprimir nada, imprimio '$OUT'"
fi

# -------- Bloques de wiring (structural): confirman que los orquestadores --
# -------- CONSUMEN las funciones de arriba, no que las reimplementan -------

echo ""
echo "[9] CA-3: parallel-pipeline.sh consulta hold_recently_active antes de lanzar el siguiente pendiente"
if grep -q 'hold_recently_active "\$EVENTS_LOG_ABS"' "$PARALLEL_SCRIPT"; then
    pass "parallel-pipeline.sh invoca hold_recently_active sobre EVENTS_LOG_ABS"
else
    fail "parallel-pipeline.sh no invoca hold_recently_active"
fi
# El chequeo debe vivir DENTRO del while del scheduler, antes del bucle que
# recorre PENDING_IDXS y lanza -- si no, gatearia el lanzamiento de nada.
SCHED_BLOCK=$(awk '/^while \[ \$\{#PENDING_IDXS\[@\]\} -gt 0 \]; do/{p=1} p{print} p && /^done$/{exit}' "$PARALLEL_SCRIPT")
if echo "$SCHED_BLOCK" | grep -q "hold_recently_active" && echo "$SCHED_BLOCK" | grep -q "for idx in \"\${PENDING_IDXS\[@\]}\""; then
    pass "el chequeo de hold vive dentro del while del scheduler, junto al lanzamiento de pendientes"
else
    fail "no se pudo confirmar que el chequeo de hold este dentro del while del scheduler"
fi

echo ""
echo "[10] CA-2: parallel-pipeline.sh dibuja la espera en su dashboard via format_hold_status"
if grep -q 'format_hold_status "\$EVENTS_LOG_ABS"' "$PARALLEL_SCRIPT"; then
    pass "parallel-pipeline.sh invoca format_hold_status sobre EVENTS_LOG_ABS"
else
    fail "parallel-pipeline.sh no invoca format_hold_status"
fi
if grep -q 'status_label="en espera"' "$PARALLEL_SCRIPT"; then
    pass "print_dashboard tiene la etiqueta 'en espera'"
else
    fail "print_dashboard no tiene la etiqueta 'en espera'"
fi

echo ""
echo "[11] CA-1/CA-5: batch-pipeline.sh anota la espera sin tocar FAILED/HAVE_ERRORS/STOP_ON_ERROR ni el exit code"
HELD_BLOCK=$(awk '/EVENTS_LOG_LINES_BEFORE=\$\(wc -l/{p=1} p{print} p && /ISSUE_HELD_NOTE=" \(esperó/{exit}' "$BATCH_SCRIPT")
if [ -n "$HELD_BLOCK" ]; then
    pass "se extrajo el bloque de deteccion de hold de batch-pipeline.sh"
else
    fail "no se pudo extraer el bloque de deteccion de hold de batch-pipeline.sh -- el resto de este caso se omite"
fi
HELD_BLOCK_CODE=$(echo "$HELD_BLOCK" | grep -vE '^[[:space:]]*#')
if echo "$HELD_BLOCK_CODE" | grep -qE 'FAILED|HAVE_ERRORS|STOP_ON_ERROR|\bexit\b'; then
    fail "el bloque de deteccion de hold no deberia referenciar FAILED/HAVE_ERRORS/STOP_ON_ERROR/exit"
else
    pass "el bloque de deteccion de hold es puramente informativo (CA-1)"
fi
if grep -q 'set_status "\$ISSUE_NUM" "completado (PR #\$PR_NUM mergeado)\$ISSUE_HELD_NOTE"' "$BATCH_SCRIPT"; then
    pass "la anotacion de espera se agrega al estado 'completado', no reemplaza el tracker (CA-2)"
else
    fail "no se encontro la anotacion de espera en el estado 'completado'"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
