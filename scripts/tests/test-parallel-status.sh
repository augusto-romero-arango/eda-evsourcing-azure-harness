#!/usr/bin/env bash
# test-parallel-status.sh -- Forma de pipeline-status-parallel.json que escribe
# parallel-pipeline.sh (issue #2447), con stubs de los pipelines y de gh (patron de
# test-batch-stop-signal.sh). Casos: [A] lote exitoso, [B] issue fallido,
# [C] issue saltado por tipo, [D] parada solicitada con un issue en cola.
#
# Uso: scripts/tests/test-parallel-status.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PARALLEL_SCRIPT="$REPO_ROOT/scripts/parallel-pipeline.sh"
COMMON_LIB="$REPO_ROOT/scripts/_pipeline-common.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq no disponible"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
ln -s "$(command -v jq)" "$FAKE_BIN/jq"
# gh: el label tipo sale de GH_TYPES ("<issue>=<tipo>,..."); por defecto tooling.
cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    tipo="tooling"
    for kv in ${GH_TYPES:-}; do [ "${kv%%=*}" = "$3" ] && tipo="${kv#*=}"; done
    if [ "$tipo" = "none" ]; then printf 'OPEN|\n'; else printf 'OPEN|tipo:%s\n' "$tipo"; fi
    exit 0
fi
exit 0
STUB
for b in claude dotnet; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/$b"; done
chmod +x "$FAKE_BIN"/*
SAFE_SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# setup <dir> <fail_issue|""> <signal_after|""> -- repo consumidor con origin real y stubs.
setup() {
    local dir="$1" fail_issue="$2" signal_after="$3" bare="$1.git"
    git init -q --bare "$bare"
    git -C "$bare" symbolic-ref HEAD refs/heads/main
    git clone -q "$bare" "$dir" 2>/dev/null
    git -C "$dir" config user.email "test@mefisto.local"
    git -C "$dir" config user.name "Mefisto Test"
    git -C "$dir" commit -q --allow-empty -m "base"
    git -C "$dir" push -q origin main
    mkdir -p "$dir/scripts" "$dir/src"
    cp "$COMMON_LIB" "$dir/scripts/_pipeline-common.sh"
    cp "$PARALLEL_SCRIPT" "$dir/scripts/parallel-pipeline.sh"
    cp -R "$REPO_ROOT/src/runtime" "$dir/src/runtime"
    cat > "$dir/scripts/tooling-pipeline.sh" <<EOS
#!/usr/bin/env bash
if [ "\$1" = "$fail_issue" ]; then echo "boom"; exit 3; fi
if [ "\$1" = "$signal_after" ]; then mkdir -p "$dir/pipeline-state"; touch "$dir/pipeline-state/batch-stop"; sleep 2; fi
echo "PR creado: https://github.com/acme/x/pull/\$((\$1 + 1000))"
exit 0
EOS
    cp "$dir/scripts/tooling-pipeline.sh" "$dir/scripts/tdd-pipeline.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/scripts/pr-sync.sh"
    chmod +x "$dir/scripts/"*.sh
}

run_parallel() {
    local dir="$1"; shift
    (cd "$dir" && env -u MEFISTO_LEGACY_STATE_DIR -u MEFISTO_REPO_ROOT -u MEFISTO_LAUNCH_ROOT MEFISTO_STATE_DIR="$dir/.mefisto/pipeline" PATH="$FAKE_BIN:$SAFE_SYSTEM_PATH" MEFISTO_RUNTIME=claude ./scripts/parallel-pipeline.sh "$@") \
        </dev/null >"$TMP/stdout" 2>"$TMP/stderr"
    LAST_RC=$?
    STATUS_FILE=$(find "$dir" -name 'pipeline-status-parallel.json' -not -path '*/.git/*' 2>/dev/null | head -1)
}

# check <label> <jq-expr-boolean>
check() {
    if [ -n "$STATUS_FILE" ] && jq -e "$2" "$STATUS_FILE" >/dev/null 2>&1; then
        pass "$1"
    else
        fail "$1 -- $(cat "${STATUS_FILE:-/dev/null}" 2>/dev/null | tr -d '\n')"
    fi
}

echo "[A] lote exitoso"
W="$TMP/a"; setup "$W" "" ""
run_parallel "$W" 11 12
[ "$LAST_RC" -eq 0 ] && pass "A: exit 0" || fail "A: exit $LAST_RC"
check "A: cabecera (pipeline, state completed, stop false, sin current)" \
    '.pipeline=="parallel" and .state=="completed" and .stop_requested==false and (has("current")|not) and (.started|type=="string") and (.log|test("parallel-.*\\.log$"))'
check "A: issues terminados con PR, pipeline y tiempos" \
    '(.issues|map(.status)==["terminado","terminado"]) and (.issues|map(.pr)==[1011,1012]) and (.issues|map(.issue)==[11,12]) and (.issues|map(.pipeline)==["tooling","tooling"]) and (.issues|all(.started!=null and .finished!=null and .finished>=.started))'
[ -f "$W/.mefisto/pipeline/pipeline-status-parallel.json" ] && pass "A: el archivo sobrevive a la limpieza" || fail "A: archivo borrado"

echo "[B] issue fallido"
W="$TMP/b"; setup "$W" "21" ""
run_parallel "$W" 21 22
[ "$LAST_RC" -eq 1 ] && pass "B: exit 1 intacto" || fail "B: exit $LAST_RC"
check "B: 21 fallido con detail, 22 terminado" \
    '.state=="completed" and (.issues[0].status=="fallido") and (.issues[0].pr==null) and (.issues[0].detail|test("exit 3")) and (.issues[1].status=="terminado")'

echo "[C] issue saltado por tipo"
W="$TMP/c"; setup "$W" "" ""
GH_TYPES="31=infra 32=none" run_parallel "$W" 31 32 33
[ "$LAST_RC" -eq 0 ] && pass "C: exit 0" || fail "C: exit $LAST_RC"
check "C: 31 y 32 saltados con motivo, 33 terminado" \
    '(.issues[0].status=="saltado") and (.issues[0].detail|length>0) and (.issues[0].pipeline==null) and (.issues[1].status=="saltado") and (.issues[1].detail|length>0) and (.issues[2].status=="terminado") and .state=="completed"'

echo "[D] parada solicitada con un issue en cola"
W="$TMP/d"; setup "$W" "" "41"
run_parallel "$W" 41 42 --max-parallel 1
[ "$LAST_RC" -eq 0 ] && pass "D: exit 0" || fail "D: exit $LAST_RC"
check "D: state stopped, stop_requested, 41 terminado, 42 aplazado con detail" \
    '.state=="stopped" and .stop_requested==true and (.issues|map(.status)==["terminado","aplazado"]) and (.issues[1].detail|test("parada")) and .issues[1].started==null'

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
