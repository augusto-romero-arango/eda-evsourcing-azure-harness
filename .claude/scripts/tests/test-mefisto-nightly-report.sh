#!/usr/bin/env bash
# test-mefisto-nightly-report.sh -- Tests de src/internal/scripts/mefisto-nightly-report.sh
# (issue #1773, CA-4/CA-5). Fixtures de results.tsv generados en un directorio
# temporal; el test no invoca gh.
#
#   [A] Todos PASS: conteos y sin rutas FAIL.
#   [B] FAIL en dos carriles: conteos totales/por carril y lista de rutas.
#   [D] Entradas CANCELLED: se reportan aparte, sin contar como PASS/FAIL.
#   [C] Directorio sin results.tsv: mensaje explicito de "sin resultados".
#   [E] 4.o argumento <failed-log> (#1969): evidencia, limpieza ANSI/timestamps,
#       truncado y compatibilidad sin el argumento.
#
# Uso: .claude/scripts/tests/test-mefisto-nightly-report.sh
# Exit code: 0 si todos los checks pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPORT="$REPO_ROOT/src/internal/scripts/mefisto-nightly-report.sh"
PASS=0
FAIL=0

check() {
    if [ "$2" = "0" ]; then
        PASS=$((PASS + 1)); echo "PASS: $1"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: $1"
    fi
}

contains() { printf '%s' "$1" | grep -qF -- "$2"; echo $?; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/o/r/actions/runs/42"
SHA="abc1234def"
T=$'\t'

mkdir -p "$TMP/a/publicado" "$TMP/a/interno"
printf '1%st1.sh%sPASS%s0%s1%s2%s1%slog\n' "$T" "$T" "$T" "$T" "$T" "$T" "$T" > "$TMP/a/publicado/results.tsv"
printf '1%st2.sh%sPASS%s0%s1%s2%s1%slog\n' "$T" "$T" "$T" "$T" "$T" "$T" "$T" > "$TMP/a/interno/results.tsv"
out="$(bash "$REPORT" "$TMP/a" "$URL" "$SHA")"; rc=$?
check "[A] sale 0" "$rc"
check "[A] enlace al run" "$(contains "$out" "$URL")"
check "[A] sha" "$(contains "$out" "$SHA")"
check "[A] total PASS=2 FAIL=0" "$(contains "$out" "PASS=2 FAIL=0")"
check "[A] sin rutas FAIL" "$(contains "$out" "(ninguna")"

mkdir -p "$TMP/b/publicado" "$TMP/b/interno"
{
    printf '1%sscripts/tests/test-ok.sh%sPASS%s0%s1%s2%s1%slog\n' "$T" "$T" "$T" "$T" "$T" "$T" "$T"
    printf '2%sscripts/tests/test-rojo-a.sh%sFAIL%s1%s1%s2%s1%slog\n' "$T" "$T" "$T" "$T" "$T" "$T" "$T"
} > "$TMP/b/publicado/results.tsv"
{
    printf '1%s.claude/scripts/tests/test-rojo-b.sh%sFAIL%s1%s1%s2%s1%slog\n' "$T" "$T" "$T" "$T" "$T" "$T" "$T"
    printf '2%s.claude/scripts/tests/test-ok2.sh%sPASS%s0%s1%s2%s1%slog\n' "$T" "$T" "$T" "$T" "$T" "$T" "$T"
    printf '3%s.claude/scripts/tests/test-ok3.sh%sPASS%s0%s1%s2%s1%slog\n' "$T" "$T" "$T" "$T" "$T" "$T" "$T"
} > "$TMP/b/interno/results.tsv"
out="$(bash "$REPORT" "$TMP/b" "$URL" "$SHA")"; rc=$?
check "[B] sale 0" "$rc"
check "[B] total PASS=3 FAIL=2" "$(contains "$out" "PASS=3 FAIL=2")"
check "[B] carril publicado 1/1" "$(contains "$out" "| publicado | 1 | 1 |")"
check "[B] carril interno 2/1" "$(contains "$out" "| interno | 2 | 1 |")"
check "[B] lista rojo-a" "$(contains "$out" "scripts/tests/test-rojo-a.sh")"
check "[B] lista rojo-b" "$(contains "$out" "test-rojo-b.sh")"
check "[B] no lista PASS" "$(contains "$out" "test-ok.sh" | grep -q '^0$' && echo 1 || echo 0)"

check "[B] sin CANCELLED no lo menciona" "$(contains "$out" "CANCELLED" | grep -q '^0$' && echo 1 || echo 0)"

mkdir -p "$TMP/d/interno"
{
    printf '1%st-rojo.sh%sFAIL%s1%s1%s2%s1%slog\n' "$T" "$T" "$T" "$T" "$T" "$T" "$T"
    printf '2%st-cortado.sh%sCANCELLED%s-%s-%s-%s-%s-\n' "$T" "$T" "$T" "$T" "$T" "$T" "$T"
} > "$TMP/d/interno/results.tsv"
out="$(bash "$REPORT" "$TMP/d" "$URL" "$SHA")"; rc=$?
check "[D] sale 0" "$rc"
check "[D] total PASS=0 FAIL=1" "$(contains "$out" "PASS=0 FAIL=1")"
check "[D] reporta CANCELLED=1" "$(contains "$out" "CANCELLED=1")"
check "[D] carril interno 0/1" "$(contains "$out" "| interno | 0 | 1 |")"

mkdir -p "$TMP/c"
out="$(bash "$REPORT" "$TMP/c" "$URL" "$SHA")"; rc=$?
check "[C] sale 0" "$rc"
check "[C] mensaje sin resultados" "$(contains "$out" "no produjo resultados")"
check "[C] enlace al run" "$(contains "$out" "$URL")"
out="$(bash "$REPORT" "$TMP/no-existe" "$URL" "$SHA")"; rc=$?
check "[C] dir inexistente sale 0" "$rc"
check "[C] dir inexistente mensaje" "$(contains "$out" "no produjo resultados")"

# [E] 4.o argumento <failed-log> (issue #1969).
ESC=$'\033'
mkdir -p "$TMP/e"
FL="$TMP/e/failed.log"
{
    printf 'tests%sAdaptadores internos sincronizados%s2026-10-04T08:01:02.1234567Z %s[31mERROR:%s [inventario-tests] fuentes canonicas sin shim:\n' "$T" "$T" "$ESC" "$ESC[0m"
    printf 'tests%sAdaptadores internos sincronizados%s2026-10-04T08:01:02.2234567Z   scripts/tests/test-uno.sh\n' "$T" "$T"
    printf 'tests%sAdaptadores internos sincronizados%s2026-10-04T08:01:02.3234567Z   scripts/tests/test-dos.sh\n' "$T" "$T"
} > "$FL"
out="$(bash "$REPORT" "$TMP/c" "$URL" "$SHA" "$FL")"; rc=$?
check "[E] sale 0" "$rc"
check "[E] seccion evidencia" "$(contains "$out" "### Evidencia del paso fallido")"
check "[E] nombre del paso" "$(contains "$out" "Adaptadores internos sincronizados")"
check "[E] linea inventario-tests" "$(contains "$out" "ERROR: [inventario-tests] fuentes canonicas sin shim")"
check "[E] ruta uno" "$(contains "$out" "scripts/tests/test-uno.sh")"
check "[E] ruta dos" "$(contains "$out" "scripts/tests/test-dos.sh")"
check "[E] sin ANSI" "$(printf '%s' "$out" | grep -q "$ESC" && echo 1 || echo 0)"
check "[E] sin timestamps" "$(printf '%s' "$out" | grep -qE '2026-10-04T08' && echo 1 || echo 0)"
check "[E] sin resultados sigue explicito" "$(contains "$out" "no produjo resultados")"

out="$(bash "$REPORT" "$TMP/b" "$URL" "$SHA" "$FL")"
check "[E] con results.tsv: conteo" "$(contains "$out" "PASS=3 FAIL=2")"
check "[E] con results.tsv: evidencia" "$(contains "$out" "[inventario-tests]")"

: > "$TMP/e/vacio.log"
out_sin="$(bash "$REPORT" "$TMP/b" "$URL" "$SHA")"
out_vacio="$(bash "$REPORT" "$TMP/b" "$URL" "$SHA" "$TMP/e/vacio.log")"
out_noex="$(bash "$REPORT" "$TMP/b" "$URL" "$SHA" "$TMP/e/no-existe.log")"
check "[E] log vacio = sin 4.o argumento" "$([ "$out_sin" = "$out_vacio" ] && echo 0 || echo 1)"
check "[E] log inexistente = sin 4.o argumento" "$([ "$out_sin" = "$out_noex" ] && echo 0 || echo 1)"
check "[E] sin 4.o argumento no hay seccion" "$(contains "$out_sin" "Evidencia" | grep -q '^0$' && echo 1 || echo 0)"

awk 'BEGIN{for(i=1;i<=3000;i++) printf "tests\tPaso grande\t2026-10-04T08:00:00.0000000Z ERROR: linea de error numero %d con relleno relleno relleno relleno\n", i}' > "$TMP/e/enorme.log"
out="$(bash "$REPORT" "$TMP/b" "$URL" "$SHA" "$TMP/e/enorme.log")"
size="$(printf '%s' "$out" | wc -c | tr -d ' ')"
check "[E] enorme: cuerpo <= 60000" "$([ "$size" -le 60000 ] && echo 0 || echo 1)"
check "[E] enorme: indica truncado" "$(contains "$out" "evidencia truncada")"

echo "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
