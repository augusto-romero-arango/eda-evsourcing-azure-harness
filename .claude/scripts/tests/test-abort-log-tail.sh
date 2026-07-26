#!/usr/bin/env bash
# test-abort-log-tail.sh -- Tests del emisor de tail del log en abort() (issue #379).
#
# Contexto (incidente del batch mefisto-batch-125628, 2026-07-26): cuando `gh pr
# create` fallaba, el log del batch solo mostraba "ERROR: No se pudo crear el
# PR" -- la causa real ("a pull request ... already exists") quedaba en OTRO
# archivo (el log del pipeline). abort() redirige stderr de los comandos
# externos al log del pipeline pero nunca lo mostraba.
#
# Arreglo: _tail_log_for_abort() imprime a stderr las ultimas N lineas del log
# (sin ANSI) bajo un encabezado explicito, antes de que abort() llame a
# update_status. Esta funcion vive duplicada en los tres pipelines "ricos"
# (mismo patron que _strip_ansi/log/success/warn/header, que ya estan
# duplicadas per-pipeline y no centralizadas en _mefisto-common.sh /
# _pipeline-common.sh).
#
# Casos cubiertos (CA-1/CA-3/CA-6):
#   - log con contenido    -> devuelve las ultimas N lineas sin ANSI, con encabezado
#   - log inexistente      -> no imprime nada, no falla (exit 0)
#   - log vacio             -> no imprime nada, no falla (exit 0)
#   - log con menos de N   -> devuelve todas las lineas disponibles, no falla
#   - ANSI                  -> los codigos de color no aparecen en la salida
#   - paridad de copias    -> el cuerpo de la funcion es identico en los tres pipelines
#
# Uso: .claude/scripts/tests/test-abort-log-tail.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

INTERNAL_PIPELINE="$REPO_ROOT/.claude/scripts/mefisto-tooling-pipeline.sh"
PUBLISHED_TOOLING="$REPO_ROOT/scripts/tooling-pipeline.sh"
PUBLISHED_TDD="$REPO_ROOT/scripts/tdd-pipeline.sh"

# extract_fn <function_name> <file>
#
# Extrae el cuerpo de una funcion bash desde "<nombre>() {" hasta el "}" que
# cierra en columna 0 (mismo patron que extract_helper_body en
# test-pr-reuse-gate.sh).
extract_fn() {
    local name="$1" file="$2"
    awk -v fn="$name" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p{print} p && /^}/{p=0}' "$file"
}

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- Preparar entorno de la funcion bajo prueba (sin ejecutar el pipeline completo) ---
# abort() y sus dependencias corren top-level (arg parsing, assert_in_mefisto...)
# antes de llegar a definir las funciones; sourcing el archivo completo dispararia
# ese codigo. En vez de eso extraemos SOLO _strip_ansi y _tail_log_for_abort y las
# evaluamos en este proceso, igual que test-pr-reuse-gate.sh extrae find_open_pr_for_branch
# para el chequeo de paridad (aqui ademas se ejecuta, no solo se compara texto).
YELLOW=""
NC=""

load_tail_fn() {
    local file="$1"
    local strip_body tail_body
    strip_body=$(extract_fn "_strip_ansi" "$file")
    tail_body=$(extract_fn "_tail_log_for_abort" "$file")
    [ -n "$strip_body" ] && [ -n "$tail_body" ] || return 1
    eval "$strip_body"
    eval "$tail_body"
}

echo "[pre] _tail_log_for_abort se puede cargar y ejecutar desde cada pipeline"
for f in "$INTERNAL_PIPELINE" "$PUBLISHED_TOOLING" "$PUBLISHED_TDD"; do
    if load_tail_fn "$f" && declare -F _tail_log_for_abort >/dev/null; then
        pass "$(basename "$f"): _tail_log_for_abort definida y cargable"
    else
        fail "$(basename "$f"): no se pudo extraer/cargar _tail_log_for_abort"
    fi
done

# A partir de aqui trabajamos con la copia cargada del pipeline interno (las tres
# son funcionalmente identicas -- lo verifica el bloque de paridad mas abajo).
load_tail_fn "$INTERNAL_PIPELINE"

echo ""
echo "[A] Log con contenido -> ultimas N lineas sin ANSI, con encabezado (CA-1)"

for i in $(seq 1 30); do
    printf '\033[0;31mlinea %02d\033[0m\n' "$i"
done > "$TMP/con-contenido.log"

OUT=$(_tail_log_for_abort "$TMP/con-contenido.log" 20 2>&1)
RC=$?

if [ "$RC" -eq 0 ]; then
    pass "exit 0 con log no vacio"
else
    fail "se esperaba exit 0, se obtuvo $RC"
fi

if echo "$OUT" | grep -q "Ultimas 20 lineas del log:"; then
    pass "encabezado explicito presente"
else
    fail "no se encontro el encabezado 'Ultimas 20 lineas del log:'"
fi

if echo "$OUT" | grep -q "linea 11" && echo "$OUT" | grep -q "linea 30" && ! echo "$OUT" | grep -q "linea 10"; then
    pass "devuelve exactamente las ultimas 20 lineas (11..30)"
else
    fail "el rango de lineas no es el esperado: $OUT"
fi

if printf '%s' "$OUT" | od -c | grep -q '033'; then
    fail "quedaron codigos ANSI en la salida"
else
    pass "sin codigos ANSI en la salida"
fi

echo ""
echo "[B] Log inexistente -> no imprime nada, no falla (CA-3)"

OUT=$(_tail_log_for_abort "$TMP/no-existe.log" 20 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    pass "log inexistente: exit 0 y sin salida"
else
    fail "log inexistente: se esperaba exit 0 y vacio, se obtuvo rc=$RC out='$OUT'"
fi

echo ""
echo "[C] Log vacio -> no imprime nada, no falla (CA-3)"

: > "$TMP/vacio.log"
OUT=$(_tail_log_for_abort "$TMP/vacio.log" 20 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    pass "log vacio: exit 0 y sin salida"
else
    fail "log vacio: se esperaba exit 0 y vacio, se obtuvo rc=$RC out='$OUT'"
fi

echo ""
echo "[D] Log con menos de N lineas -> devuelve todas, no falla (CA-3)"

printf 'a\nb\nc\n' > "$TMP/corto.log"
OUT=$(_tail_log_for_abort "$TMP/corto.log" 20 2>&1)
RC=$?
LINE_COUNT=$(echo "$OUT" | grep -Ec '^[abc]$')
if [ "$RC" -eq 0 ] && [ "$LINE_COUNT" -eq 3 ]; then
    pass "log mas corto que N: exit 0 y devuelve las 3 lineas disponibles"
else
    fail "log mas corto que N: se esperaba exit 0 y 3 lineas, se obtuvo rc=$RC out='$OUT'"
fi

echo ""
echo "[E] Paridad: el cuerpo de _tail_log_for_abort es identico en los tres pipelines"

BODY_INTERNAL=$(extract_fn "_tail_log_for_abort" "$INTERNAL_PIPELINE")
BODY_TOOLING=$(extract_fn "_tail_log_for_abort" "$PUBLISHED_TOOLING")
BODY_TDD=$(extract_fn "_tail_log_for_abort" "$PUBLISHED_TDD")

if [ -z "$BODY_INTERNAL" ] || [ -z "$BODY_TOOLING" ] || [ -z "$BODY_TDD" ]; then
    fail "paridad: no se pudo extraer el cuerpo de _tail_log_for_abort de alguna copia"
elif [ "$BODY_INTERNAL" = "$BODY_TOOLING" ] && [ "$BODY_INTERNAL" = "$BODY_TDD" ]; then
    pass "paridad: identico en mefisto-tooling-pipeline.sh, tooling-pipeline.sh y tdd-pipeline.sh"
else
    fail "paridad: las copias DERIVARON entre si"
    diff <(echo "$BODY_INTERNAL") <(echo "$BODY_TOOLING") || true
    diff <(echo "$BODY_INTERNAL") <(echo "$BODY_TDD") || true
fi

echo ""
echo "[F] abort() invoca _tail_log_for_abort antes de update_status (CA-4)"

for f in "$INTERNAL_PIPELINE" "$PUBLISHED_TOOLING" "$PUBLISHED_TDD"; do
    ABORT_BODY=$(extract_fn "abort" "$f")
    TAIL_LINE=$(echo "$ABORT_BODY" | grep -n "_tail_log_for_abort " | head -1 | cut -d: -f1)
    STATUS_LINE=$(echo "$ABORT_BODY" | grep -n "update_status " | head -1 | cut -d: -f1)
    if [ -n "$TAIL_LINE" ] && [ -n "$STATUS_LINE" ] && [ "$TAIL_LINE" -lt "$STATUS_LINE" ]; then
        pass "$(basename "$f"): el tail se lee antes de update_status"
    else
        fail "$(basename "$f"): orden incorrecto o llamada faltante (tail=$TAIL_LINE, status=$STATUS_LINE)"
    fi
done

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
