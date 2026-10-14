#!/usr/bin/env bash
# test-tdd-gate2-preexisting-routing.sh -- Gate 2 determinista para rojos
# preexistentes, Gate 3 verde sin label y seccion de tests ajustados (issues #2062, #2438).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../_pipeline-common.sh
source "$REPO_ROOT/scripts/_pipeline-common.sh"
TDD="$REPO_ROOT/scripts/tdd-pipeline.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
W="$TMP/wt"; mkdir -p "$W/tests/X.Tests"
git -C "$W" init -q -b main
git -C "$W" config user.email t@t; git -C "$W" config user.name t
cat > "$W/tests/X.Tests/GuardTests.cs" <<'CS'
public class GuardTests
{
    [Fact]
    public void Guarda_Inventario()
    {
        Assert.Equal(28, Catalogo.Count);
    }
}
CS
git -C "$W" add -A; git -C "$W" commit -qm base
SNAP=$(git -C "$W" rev-parse HEAD)

echo "Gate 2: rojos"
OUT_PRE=$'  failed X.Tests.GuardTests.Guarda_Inventario (5ms)\nTest run summary: Failed!\n'
LIST=$(preexisting_red_only "$W" "$SNAP" "$OUT_PRE"); rc=$?
[ "$rc" -eq 0 ] && echo "$LIST" | grep -q '^Guarda_Inventario' && ok "solo preexistentes: continua (rc 0)" || bad "solo preexistentes rc=$rc"
OUT_NEW="$OUT_PRE"$'  failed X.Tests.NuevosTests.Nuevo_Rojo (1ms)\n'
preexisting_red_only "$W" "$SNAP" "$OUT_NEW" >/dev/null; rc=$?
[ "$rc" -eq 1 ] && ok "un rojo nuevo: aborta (rc 1)" || bad "rojo nuevo rc=$rc"
preexisting_red_only "$W" "$SNAP" "basura" >/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "analisis falla: aborta (rc 2)" || bad "basura rc=$rc"

echo "Reviewer toca tests"
BASE=$(git -C "$W" rev-parse HEAD)
list_reviewer_touched_tests "$W" "$BASE" | grep -q . && bad "sin cambios no deberia listar" || ok "sin tests tocados: lista vacia"
sed -i.bak 's/28/29/' "$W/tests/X.Tests/GuardTests.cs"; rm -f "$W/tests/X.Tests/GuardTests.cs.bak"
git -C "$W" commit -qam "reviewer ajusta guarda"
FILES=$(list_reviewer_touched_tests "$W" "$BASE")
[ "$FILES" = "tests/X.Tests/GuardTests.cs" ] && ok "tests modificados detectados por diff" || bad "files='$FILES'"

echo "Seccion del PR de tests ajustados"
[ -z "$(render_reviewer_touched_tests_section "" false)" ] && ok "sin archivos: salida vacia" || bad "sin archivos imprime"
TWO=$'tests/A.Tests/ATests.cs\ntests/B.Tests/BTests.cs'
SEC=$(render_reviewer_touched_tests_section "$TWO" false)
echo "$SEC" | grep -qF '## Tests ajustados por el reviewer' && ok "encabezado presente" || bad "encabezado"
[ "$(echo "$SEC" | grep -c '^- `')" -eq 2 ] && echo "$SEC" | grep -qF -- '- `tests/A.Tests/ATests.cs`' && ok "una linea por archivo" || bad "lineas por archivo"
echo "$SEC" | grep -qF 'destrabar' && bad "sin destrabe no debe incluir la linea extra" || ok "sin linea de destrabe"
SEC2=$(render_reviewer_touched_tests_section "$TWO" true)
echo "$SEC2" | grep -qF 'destrabar tests en rojo despues de la fase verde' && ok "blockage_resolved=true agrega la linea extra" || bad "linea de destrabe"
! grep -q 'create_reviewer_tests_review''_issue' "$TDD" && ok "el pipeline ya no crea el issue de revision" || bad "invocacion residual"
grep -qF '${WARNING_REMNANTS_SECTION}${REVIEWER_TESTS_SECTION}## Commits' "$TDD" && ok "seccion interpolada en el body del PR" || bad "interpolacion en el PR"

echo "Cableado en tdd-pipeline.sh"
chk() { grep -qF -- "$2" "$TDD" && ok "$1" || bad "$1"; }
chk "Gate 2 usa preexisting_red_only" 'preexisting_red_only "$WORKTREE_PATH" "$SNAPSHOT_COMMIT" "$TEST_OUTPUT_G2"'
chk "Gate 3 verde limpia HAS_BLOCKAGE" 'BLOCKAGE_RESOLVED=true'
chk "se calcula el diff de tests del reviewer" 'list_reviewer_touched_tests'
chk "seccion construida con los tests del reviewer" 'render_reviewer_touched_tests_section "${REVIEWER_TOUCHED_TESTS:-}" "${BLOCKAGE_RESOLVED:-false}"'
chk "abort original sin reporte intacto" 'abort "Stage 2 fallido: no todos los tests pasan'
echo "Resultado: $PASS pass, $FAIL fail"; [ "$FAIL" -eq 0 ]
