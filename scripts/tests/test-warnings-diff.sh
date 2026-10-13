#!/usr/bin/env bash
# test-warnings-diff.sh -- Tests de scripts/warnings-diff.sh (issue #2405).
#
# Corre el script real como subproceso dentro de repos fixture (git init en
# mktemp -d, SIN .claude-plugin/plugin.json).
#   [pre]  existe, ejecutable, sintaxis valida
#   [CA-1] warning nuevo, linea movida, .sh sin commitear, duplicado
#   [CA-2] supresiones (.sh y .shellcheckrc)
#   [CA-3] cache sin worktree y limpieza del worktree temporal
#   [CA-4] toolchain no soportada / ausente / guard en Mefisto
#   [fix]  WARNINGS_DIFF_FIXTURE_DIR

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAL_SCRIPT="$REPO_ROOT/scripts/warnings-diff.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMPS=()
trap 'for d in "${TMPS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done' EXIT

new_repo() {
    local d
    d=$(mktemp -d)
    TMPS+=("$d")
    git -C "$d" init -q -b main
    git -C "$d" config user.email t@t
    git -C "$d" config user.name t
    printf '#!/usr/bin/env bash\nfoo=1\ncd /tmp\necho ok\n' > "$d/a.sh"
    git -C "$d" add -A
    git -C "$d" commit -q -m base
    echo "$d"
}

run_wd() { # dir args...
    local d="$1"; shift
    (cd "$d" && "$REAL_SCRIPT" "$@" 2>&1)
}

echo "[pre] warnings-diff.sh existe, es ejecutable y tiene sintaxis valida"
if [ -x "$REAL_SCRIPT" ] && bash -n "$REAL_SCRIPT"; then pass "existe, ejecutable, sintaxis ok"; else fail "script ausente o invalido"; fi

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "  SKIP: shellcheck no instalado; casos CA-1..CA-3 omitidos"
else
echo "[CA-1] warning nuevo"
R=$(new_repo); BASE=$(git -C "$R" rev-parse HEAD)
printf 'bar=2\n' >> "$R/a.sh"
OUT=$(run_wd "$R" --toolchain shell --base "$BASE"); RC=$?
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q '^NEW shell a.sh SC2034 ' && echo "$OUT" | grep -q '^warnings nuevos: 1$'; then
    pass "warning nuevo -> NEW + exit 2"; else fail "warning nuevo (rc=$RC): $OUT"; fi

echo "[CA-1] linea movida"
R=$(new_repo); BASE=$(git -C "$R" rev-parse HEAD)
printf '#!/usr/bin/env bash\ncd /tmp\necho ok\n\nfoo=1\n' > "$R/a.sh"
OUT=$(run_wd "$R" --toolchain shell --base "$BASE"); RC=$?
if [ "$RC" -eq 0 ]; then pass "warning movido de linea -> exit 0"; else fail "movido (rc=$RC): $OUT"; fi

echo "[CA-1] .sh nuevo sin commitear"
R=$(new_repo); BASE=$(git -C "$R" rev-parse HEAD)
printf '#!/usr/bin/env bash\nzed=1\n' > "$R/b.sh"
OUT=$(run_wd "$R" --toolchain shell --base "$BASE"); RC=$?
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q '^NEW shell b.sh SC2034 '; then pass ".sh sin commitear reportado"; else fail "sin commitear (rc=$RC): $OUT"; fi

echo "[CA-1] duplicado de una clave existente"
R=$(new_repo); BASE=$(git -C "$R" rev-parse HEAD)
printf 'cd /tmp\n' >> "$R/a.sh"
OUT=$(run_wd "$R" --toolchain shell --base "$BASE"); RC=$?
if [ "$RC" -eq 2 ] && [ "$(echo "$OUT" | grep -c '^NEW ')" -eq 1 ]; then pass "duplicado -> exactamente 1 nuevo"; else fail "duplicado (rc=$RC): $OUT"; fi

echo "[CA-2] supresiones"
R=$(new_repo); BASE=$(git -C "$R" rev-parse HEAD)
printf '# shellcheck disable=SC2086\n' >> "$R/a.sh"
printf 'disable=SC2034\n' > "$R/.shellcheckrc"
git -C "$R" add .shellcheckrc
OUT=$(run_wd "$R" --toolchain shell --base "$BASE"); RC=$?
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q '^NEW shell a.sh SUPPRESSION ' && echo "$OUT" | grep -q '^NEW shell .shellcheckrc SUPPRESSION '; then
    pass "supresiones en .sh y .shellcheckrc"; else fail "supresiones (rc=$RC): $OUT"; fi

echo "[CA-3] cache y worktree temporal"
R=$(new_repo); BASE=$(git -C "$R" rev-parse HEAD)
run_wd "$R" --toolchain shell --base "$BASE" >/dev/null
CACHE="$R/.mefisto/pipeline/warnings-baseline/shell-$BASE-all.txt"
[ -f "$CACHE" ] && pass "cache creado" || fail "cache ausente: $CACHE"
# Una segunda corrida sin posibilidad de crear worktrees prueba que usa el cache.
OUT=$(cd "$R" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.worktree GIT_CONFIG_VALUE_0='!false' "$REAL_SCRIPT" --toolchain shell --base "$BASE" 2>&1); RC=$?
[ "$RC" -eq 0 ] && pass "segunda invocacion reutiliza el cache" || fail "cache no reutilizado (rc=$RC): $OUT"
[ "$(git -C "$R" worktree list | wc -l | tr -d ' ')" -eq 1 ] && pass "sin worktrees temporales tras salir" || fail "worktree residual"
rm -f "$CACHE"
run_wd "$R" --toolchain shell --base deadbeef >/dev/null; RC=$?
[ "$RC" -eq 1 ] && [ "$(git -C "$R" worktree list | wc -l | tr -d ' ')" -eq 1 ] && pass "error -> exit 1 sin worktree residual" || fail "error (rc=$RC)"
fi

echo "[CA-4] toolchain y guard"
R=$(new_repo)
OUT=$(run_wd "$R" --toolchain dotnet --base HEAD); RC=$?
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -q 'toolchain no soportada: dotnet'; then pass "dotnet -> exit 1"; else fail "dotnet (rc=$RC): $OUT"; fi
OUT=$(run_wd "$R"); RC=$?
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -q 'Uso:'; then pass "sin --toolchain -> exit 1 con uso"; else fail "sin toolchain (rc=$RC): $OUT"; fi
OUT=$("$REAL_SCRIPT" --toolchain shell 2>&1); RC=$?
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "plugin publicado y solo aplica al consumidor"; then pass "guard en repo de Mefisto"; else fail "guard (rc=$RC): $OUT"; fi

echo "[fix] WARNINGS_DIFF_FIXTURE_DIR"
R=$(new_repo); BASE=$(git -C "$R" rev-parse HEAD)
FX=$(mktemp -d); TMPS+=("$FX")
echo 'a.sh:2:1: warning: foo appears unused. Verify use (or export if used externally). [SC2034]' > "$FX/base.out"
printf '%s\n' 'a.sh:2:1: warning: foo appears unused. Verify use (or export if used externally). [SC2034]' \
    'a.sh:3:1: warning: bar appears unused. Verify use (or export if used externally). [SC2034]' > "$FX/current.out"
OUT=$(cd "$R" && WARNINGS_DIFF_FIXTURE_DIR="$FX" "$REAL_SCRIPT" --toolchain shell --base "$BASE" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q '^NEW shell a.sh SC2034 bar appears unused' && echo "$OUT" | grep -q '^warnings nuevos: 1$'; then
    pass "fixture dir: parser + diff"; else fail "fixture (rc=$RC): $OUT"; fi

echo "----------------------------------------"
echo "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
