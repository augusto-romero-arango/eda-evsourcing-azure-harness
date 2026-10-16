#!/usr/bin/env bash
# test-parallel-stagger.sh -- Escalonado de lanzamientos de parallel-pipeline.sh
# (issue #2448). Pipelines stub y un `sleep` interceptado que registra su argumento.
#   [A] por defecto espera 30 s entre lanzamientos (N-1 esperas de 30)
#   [B] --stagger 0 lanza sin espera
#   [C] --stagger 7 usa el valor dado
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAKE_BIN="$TMP/bin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then printf 'OPEN|tipo:tooling\n'; fi
exit 0
STUB
cat > "$FAKE_BIN/sleep" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$SLEEP_LOG"
exit 0
STUB
for b in claude dotnet; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/$b"; done
chmod +x "$FAKE_BIN"/*
SAFE="/usr/bin:/bin:/usr/sbin:/sbin"

setup() {
    local dir="$1" bare="$1.git"
    git init -q --bare "$bare"; git -C "$bare" symbolic-ref HEAD refs/heads/main
    git clone -q "$bare" "$dir" 2>/dev/null
    git -C "$dir" config user.email t@m.local; git -C "$dir" config user.name T
    git -C "$dir" commit -q --allow-empty -m base; git -C "$dir" push -q origin main
    mkdir -p "$dir/scripts" "$dir/src"
    cp "$REPO_ROOT/scripts/_pipeline-common.sh" "$REPO_ROOT/scripts/parallel-pipeline.sh" "$dir/scripts/"
    cp -R "$REPO_ROOT/src/runtime" "$dir/src/runtime"
    printf '#!/usr/bin/env bash\necho "PR creado: https://github.com/a/x/pull/$((${1:-0}+1000))"\nexit 0\n' > "$dir/scripts/tooling-pipeline.sh"
    cp "$dir/scripts/tooling-pipeline.sh" "$dir/scripts/tdd-pipeline.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/scripts/pr-sync.sh"
    chmod +x "$dir/scripts/"*.sh
}

# run_case <nombre> <args...> -> cuenta de esperas de escalonado en $WAITS
run_case() {
    local name="$1"; shift
    local dir="$TMP/$name"; setup "$dir"
    export SLEEP_LOG="$TMP/$name.sleep"; : > "$SLEEP_LOG"
    (cd "$dir" && env -u MEFISTO_LEGACY_STATE_DIR -u MEFISTO_REPO_ROOT -u MEFISTO_LAUNCH_ROOT \
        MEFISTO_STATE_DIR="$dir/.mefisto/pipeline" PATH="$FAKE_BIN:$SAFE" MEFISTO_RUNTIME=claude \
        ./scripts/parallel-pipeline.sh "$@") </dev/null >"$TMP/$name.out" 2>&1
    LAST_RC=$?
}
count() { grep -cx "$2" "$1" 2>/dev/null || true; }

echo "[A] por defecto: 30 s entre lanzamientos"
run_case a 11 12 13
[ "$LAST_RC" -eq 0 ] && pass "A: exit 0" || fail "A: exit $LAST_RC"
[ "$(count "$TMP/a.sleep" 30)" = "2" ] && pass "A: dos esperas de 30 s para 3 issues" || fail "A: esperas: $(tr '\n' ' ' < "$TMP/a.sleep")"

echo "[B] --stagger 0: sin espera"
run_case b --stagger 0 11 12 13
[ "$LAST_RC" -eq 0 ] && pass "B: exit 0" || fail "B: exit $LAST_RC"
[ "$(count "$TMP/b.sleep" 30)" = "0" ] && [ "$(count "$TMP/b.sleep" 0)" = "0" ] && pass "B: ninguna espera de escalonado" || fail "B: esperas: $(tr '\n' ' ' < "$TMP/b.sleep")"

echo "[C] --stagger 7"
run_case c --stagger 7 11 12
[ "$(count "$TMP/c.sleep" 7)" = "1" ] && pass "C: una espera de 7 s" || fail "C: esperas: $(tr '\n' ' ' < "$TMP/c.sleep")"

echo "[D] --stagger invalido"
run_case d --stagger x 11
[ "$LAST_RC" -ne 0 ] && pass "D: rechaza valor no numerico" || fail "D: no rechazo"

echo ""
echo "Resumen: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
