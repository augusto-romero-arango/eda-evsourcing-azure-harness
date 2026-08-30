#!/usr/bin/env bash
# test-release-chaining.sh -- Tests del encadenamiento merge + sync + publish
# de la fase prepare de /mefisto-release (issue #759).
#
#   [A] Parseo de argumentos: patch|minor|major en cualquier posicion,
#       --prepare-only opcional y en cualquier orden, magnitud duplicada y
#       argumento desconocido abortan, y --prepare-only SOLO (sin magnitud) no
#       aborta pero deja BUMP_PART vacio -- la condicion que dispara el mensaje
#       de uso del script (CA-2: el flag solo es valido junto a la magnitud).
#   [B] Guardas estaticas del bloque de encadenamiento: la salida temprana de
#       --prepare-only ocurre ANTES del merge, cada eslabon usa la mecanica
#       acordada (gh pr merge --squash --delete-branch, confirmacion por
#       state+mergeCommit, merge-base --is-ancestor contra origin/main,
#       ff-only) y TODOS son fail-loud (|| abort) -- CA-1 y CA-3.
#   [C] La re-invocacion de la fase publish usa la ruta absoluta resuelta
#       antes del `cd` al root del repo, no "$0" (que es relativo al cwd del
#       invocador y no resolveria tras el cd).
#   [D] Coherencia del skill: .claude/commands/mefisto-release.md documenta
#       --prepare-only y el encadenamiento por defecto (CA-4).
#
# mefisto-release.sh NO es sourceable (ejecuta el pipeline completo en su nivel
# superior). El bloque [A] extrae el parseo con sed y lo evalua aislado, misma
# tecnica que test-release-pr-body.sh usa con summarize_version_section.
#
# Uso: .claude/scripts/tests/test-release-chaining.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RELEASE_SCRIPT="$REPO_ROOT/.claude/scripts/mefisto-release.sh"
RELEASE_SKILL="$REPO_ROOT/.claude/commands/mefisto-release.md"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

[ -f "$RELEASE_SCRIPT" ] || { echo "No existe $RELEASE_SCRIPT"; exit 1; }

# -------- Bloque A: parseo de argumentos --------

echo "[A] Parseo de argumentos de la fase prepare"

PARSE_FILE=$(mktemp)
trap 'rm -f "$PARSE_FILE"' EXIT
{
    echo 'parse_release_args() {'
    sed -n '/^    BUMP_PART=""$/,/^    done$/p' "$RELEASE_SCRIPT"
    echo '}'
} > "$PARSE_FILE"

if grep -q 'for arg in "\$@"' "$PARSE_FILE"; then
    pass "A-0: se localizo el bloque de parseo en mefisto-release.sh"
else
    fail "A-0: no se localizo el bloque de parseo (¿cambio la forma de 'BUMP_PART=\"\"' / 'done'?)"
fi

# Evalua el parseo en un subshell con abort stubeado a exit 1 (como en el
# script real) e imprime el estado resultante.
run_parse() {
    (
        abort() { echo "ABORT: $1" >&2; exit 1; }
        # shellcheck source=/dev/null
        . "$PARSE_FILE"
        parse_release_args "$@" || exit $?
        echo "BUMP=${BUMP_PART}|PREPARE_ONLY=${PREPARE_ONLY}"
    ) 2>/dev/null
}

assert_parse() {
    local descripcion="$1" esperado="$2"; shift 2
    local salida
    salida=$(run_parse "$@")
    if [ "$salida" = "$esperado" ]; then
        pass "A: $descripcion"
    else
        fail "A: $descripcion -- esperado '$esperado', obtenido '$salida'"
    fi
}

assert_parse "'patch' encadena por defecto"            "BUMP=patch|PREPARE_ONLY=false" patch
assert_parse "'minor' encadena por defecto"            "BUMP=minor|PREPARE_ONLY=false" minor
assert_parse "'major' encadena por defecto"            "BUMP=major|PREPARE_ONLY=false" major
assert_parse "'minor --prepare-only' desactiva el encadenamiento" \
    "BUMP=minor|PREPARE_ONLY=true" minor --prepare-only
assert_parse "'--prepare-only major' (orden inverso) tambien" \
    "BUMP=major|PREPARE_ONLY=true" --prepare-only major
assert_parse "'--prepare-only' solo deja BUMP_PART vacio (dispara el uso)" \
    "BUMP=|PREPARE_ONLY=true" --prepare-only
assert_parse "sin argumentos deja BUMP_PART vacio (dispara el uso)" \
    "BUMP=|PREPARE_ONLY=false"
assert_parse "argumento desconocido aborta"            "" foo
assert_parse "dos magnitudes abortan"                  "" patch minor

# -------- Bloque B: guardas estaticas del encadenamiento --------

echo ""
echo "[B] Mecanica y fail-loud del bloque de encadenamiento"

if bash -n "$RELEASE_SCRIPT" 2>/dev/null; then
    pass "B-0: mefisto-release.sh pasa 'bash -n'"
else
    fail "B-0: mefisto-release.sh no pasa 'bash -n'"
fi

# La salida temprana de --prepare-only debe estar ANTES del primer gh pr merge.
LINEA_PREPARE_ONLY=$(grep -n 'if \[ "\$PREPARE_ONLY" = true \]; then' "$RELEASE_SCRIPT" | head -n1 | cut -d: -f1)
LINEA_MERGE=$(grep -n 'gh pr merge "\$PR_NUM" --squash --delete-branch' "$RELEASE_SCRIPT" | head -n1 | cut -d: -f1)
if [ -n "$LINEA_PREPARE_ONLY" ] && [ -n "$LINEA_MERGE" ] && [ "$LINEA_PREPARE_ONLY" -lt "$LINEA_MERGE" ]; then
    pass "B-1: --prepare-only sale antes del merge (no mergea ni publica)"
else
    fail "B-1: --prepare-only deberia salir antes del 'gh pr merge' (prepare-only: ${LINEA_PREPARE_ONLY:-ausente}, merge: ${LINEA_MERGE:-ausente})"
fi

check_presencia() {
    local descripcion="$1" patron="$2"
    if grep -qF "$patron" "$RELEASE_SCRIPT"; then
        pass "B: $descripcion"
    else
        fail "B: $descripcion -- falta '$patron'"
    fi
}

check_presencia "el merge es squash + delete-branch" 'gh pr merge "$PR_NUM" --squash --delete-branch'
check_presencia "la confirmacion consulta state y mergeCommit" 'gh pr view "$PR_NUM" --json state,mergeCommit'
check_presencia "se exige state == MERGED" '"$PR_STATE" != "MERGED"'
check_presencia "el sync confirma el commit de merge en origin/main" 'git merge-base --is-ancestor "$MERGE_SHA" origin/main'
check_presencia "main local se fast-forwardea sin merge commit" 'git merge --ff-only origin/main'

# Fail-loud: cada eslabon del encadenamiento aborta si falla. La region medida
# va del merge al cierre de la fase prepare, para no contar los aborts de la
# fase publish (que ya cubren sus propias precondiciones).
LINEA_FIN=$(grep -n '^# FASE PUBLISH$' "$RELEASE_SCRIPT" | head -n1 | cut -d: -f1)
[ -n "$LINEA_FIN" ] || LINEA_FIN=$(wc -l < "$RELEASE_SCRIPT")
CHAIN=$(sed -n "${LINEA_MERGE},${LINEA_FIN}p" "$RELEASE_SCRIPT")
ABORTS=$(echo "$CHAIN" | grep -c 'abort "')
if [ "$ABORTS" -ge 7 ]; then
    pass "B-2: el encadenamiento aborta en cada eslabon (${ABORTS} aborts)"
else
    fail "B-2: el encadenamiento deberia abortar en cada eslabon (merge, confirmacion, fetch, ancestro, switch, ff-only, publish); encontrados ${ABORTS}"
fi

if echo "$CHAIN" | grep -q 'Paso manual:'; then
    pass "B-3: los aborts nombran el paso manual restante (CA-3)"
else
    fail "B-3: los aborts deberian nombrar el paso manual restante (CA-3)"
fi

# -------- Bloque C: re-invocacion de la fase publish --------

echo ""
echo "[C] Re-invocacion de la fase publish"

if grep -q '^SCRIPT_PATH=.*BASH_SOURCE' "$RELEASE_SCRIPT"; then
    pass "C-1: SCRIPT_PATH se resuelve desde BASH_SOURCE"
else
    fail "C-1: falta la resolucion de SCRIPT_PATH desde BASH_SOURCE"
fi

LINEA_SCRIPT_PATH=$(grep -n '^SCRIPT_PATH=' "$RELEASE_SCRIPT" | head -n1 | cut -d: -f1)
LINEA_CD=$(grep -n '^cd "\$MEFISTO_REPO_ROOT"' "$RELEASE_SCRIPT" | head -n1 | cut -d: -f1)
if [ -n "$LINEA_SCRIPT_PATH" ] && [ -n "$LINEA_CD" ] && [ "$LINEA_SCRIPT_PATH" -lt "$LINEA_CD" ]; then
    pass "C-2: SCRIPT_PATH se resuelve antes del cd al root del repo"
else
    fail "C-2: SCRIPT_PATH deberia resolverse antes del 'cd \$MEFISTO_REPO_ROOT' (script: ${LINEA_SCRIPT_PATH:-ausente}, cd: ${LINEA_CD:-ausente})"
fi

if echo "$CHAIN" | grep -qE '^\s*"\$SCRIPT_PATH" \\'; then
    pass "C-3: la fase publish se encadena via \"\$SCRIPT_PATH\" (no \"\$0\", relativo al cwd)"
else
    fail "C-3: la fase publish deberia re-invocarse via \"\$SCRIPT_PATH\""
fi

# -------- Bloque D: coherencia del skill --------

echo ""
echo "[D] El skill documenta el encadenamiento y el flag de escape"

for token in '--prepare-only' 'encadena'; do
    if grep -qF -- "$token" "$RELEASE_SKILL"; then
        pass "D: mefisto-release.md menciona '${token}'"
    else
        fail "D: mefisto-release.md deberia mencionar '${token}'"
    fi
done

# -------- Resumen --------

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ] || exit 1
