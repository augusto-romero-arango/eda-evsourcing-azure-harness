#!/usr/bin/env bash
# test-mefisto-nightly-report.sh -- Tests de src/internal/scripts/mefisto-nightly-report.sh
# (issue #1773, CA-4/CA-5). Fixtures de results.tsv generados en un directorio
# temporal; el test no invoca gh.
#
#   [A] Todos PASS: conteos y sin rutas FAIL.
#   [B] FAIL en dos carriles: conteos totales/por carril y lista de rutas.
#   [D] Entradas CANCELLED: se reportan aparte, sin contar como PASS/FAIL.
#   [C] Directorio sin results.tsv: mensaje explicito de "sin resultados".
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

echo "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
