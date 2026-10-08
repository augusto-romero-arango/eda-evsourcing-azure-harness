#!/usr/bin/env bash
# test-tdd-gate2-preexisting-routing.sh -- Gate 2 determinista para rojos
# preexistentes, Gate 3 verde sin label y issue de revision (issue #2062).
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

echo "Issue de revision"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GH_CAPTURE"
[ "${GH_FAIL:-0}" = 1 ] && exit 1
echo "https://github.com/o/r/issues/99"
SH
chmod +x "$TMP/bin/gh"
export GH_CAPTURE="$TMP/gh.args"
URL=$(PATH="$TMP/bin:$PATH" create_reviewer_tests_review_issue o/r 12 https://github.com/o/r/pull/13 "$W" "$BASE" "$FILES" "$OUT_PRE" /nonexistent); rc=$?
[ "$rc" -eq 0 ] && [ "$URL" = "https://github.com/o/r/issues/99" ] && ok "crea el issue" || bad "crear rc=$rc url=$URL"
grep -qF 'Revisar los tests ajustados por el reviewer en #12' "$GH_CAPTURE" && grep -q 'pull/13' "$GH_CAPTURE" \
  && grep -q 'Guarda_Inventario' "$GH_CAPTURE" && grep -q '^+.*29' "$GH_CAPTURE" && ok "titulo, PR, salida roja y diff presentes" || bad "contenido del issue"
grep -q -- '--label' "$GH_CAPTURE" && bad "no debe usar labels" || ok "sin labels"
GH_FAIL=1 PATH="$TMP/bin:$PATH" create_reviewer_tests_review_issue o/r 12 u "$W" "$BASE" "$FILES" "" /x >/dev/null; rc=$?
[ "$rc" -ne 0 ] && ok "fallo de gh propaga rc != 0 (el pipeline degrada a warn)" || bad "fallo no propagado"

echo "Cableado en tdd-pipeline.sh"
chk() { grep -qF -- "$2" "$TDD" && ok "$1" || bad "$1"; }
chk "Gate 2 usa preexisting_red_only" 'preexisting_red_only "$WORKTREE_PATH" "$SNAPSHOT_COMMIT" "$TEST_OUTPUT_G2"'
chk "Gate 3 verde limpia HAS_BLOCKAGE" 'BLOCKAGE_RESOLVED=true'
chk "se calcula el diff de tests del reviewer" 'list_reviewer_touched_tests'
chk "issue de revision al abrir el PR" 'create_reviewer_tests_review_issue'
chk "fallo al crear degrada a warn" 'No se pudo crear el issue de revision'
chk "abort original sin reporte intacto" 'abort "Stage 2 fallido: no todos los tests pasan'
echo "Resultado: $PASS pass, $FAIL fail"; [ "$FAIL" -eq 0 ]
