#!/usr/bin/env bash
# test-batch-status.sh -- Forma de pipeline-status-batch.json que escribe
# batch-pipeline.sh (issue #2202), con stubs de los pipelines y de gh (patron de
# test-batch-stop-signal.sh). Casos: [A] lote exitoso, [B] issue fallido,
# [C] issue saltado por tipo, [D] parada solicitada.
#
# Uso: scripts/tests/test-batch-status.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BATCH_SCRIPT="$REPO_ROOT/scripts/batch-pipeline.sh"
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
    cp "$BATCH_SCRIPT" "$dir/scripts/batch-pipeline.sh"
    cp -R "$REPO_ROOT/src/runtime" "$dir/src/runtime"
    cat > "$dir/scripts/tooling-pipeline.sh" <<EOS
#!/usr/bin/env bash
if [ "\$1" = "$fail_issue" ]; then echo "boom"; exit 3; fi
if [ "\$1" = "$signal_after" ]; then mkdir -p "$dir/pipeline-state"; touch "$dir/pipeline-state/batch-stop"; fi
echo "PR creado: https://github.com/acme/x/pull/\$((\$1 + 1000))"
exit 0
EOS
    cp "$dir/scripts/tooling-pipeline.sh" "$dir/scripts/tdd-pipeline.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/scripts/pr-sync.sh"
    chmod +x "$dir/scripts/"*.sh
}

run_batch() {
    local dir="$1"; shift
    (cd "$dir" && env -u MEFISTO_LEGACY_STATE_DIR -u MEFISTO_REPO_ROOT -u MEFISTO_LAUNCH_ROOT MEFISTO_STATE_DIR="$dir/.mefisto/pipeline" PATH="$FAKE_BIN:$SAFE_SYSTEM_PATH" MEFISTO_RUNTIME=claude ./scripts/batch-pipeline.sh "$@") \
        </dev/null >"$TMP/stdout" 2>"$TMP/stderr"
    LAST_RC=$?
    STATUS_FILE=$(find "$dir" -name 'pipeline-status-batch.json' -not -path '*/.git/*' 2>/dev/null | head -1)
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
run_batch "$W" 11 12
[ "$LAST_RC" -eq 0 ] && pass "A: exit 0" || fail "A: exit $LAST_RC"
check "A: cabecera (pipeline, state completed, current null, stop false, hold 0)" \
    '.pipeline=="batch" and .state=="completed" and .current==null and .stop_requested==false and .hold_seconds==0 and (.started|type=="string") and (.log|test("batch-.*\\.log$"))'
check "A: issues mergeados con PR" \
    '(.issues|map(.status)==["mergeado","mergeado"]) and (.issues|map(.pr)==[1011,1012]) and (.issues|map(.issue)==[11,12])'

echo "[B] issue fallido"
W="$TMP/b"; setup "$W" "21" ""
run_batch "$W" 21 22
[ "$LAST_RC" -eq 1 ] && pass "B: exit 1 intacto" || fail "B: exit $LAST_RC"
check "B: state completed aunque haya fallido" '.state=="completed"'
check "B: 21 fallido con detail, 22 mergeado" \
    '(.issues[0].status=="fallido") and (.issues[0].pr==null) and (.issues[0].detail|test("exit 3")) and (.issues[1].status=="mergeado")'

echo "[C] issue saltado por tipo"
W="$TMP/c"; setup "$W" "" ""
GH_TYPES="31=infra 32=none" run_batch "$W" 31 32 33
[ "$LAST_RC" -eq 0 ] && pass "C: exit 0 (los saltos ya contaban como FAILED sin HAVE_ERRORS)" || fail "C: exit $LAST_RC"
check "C: 31 y 32 saltados con motivo, 33 mergeado" \
    '(.issues[0].status=="saltado") and (.issues[0].detail|length>0) and (.issues[1].status=="saltado") and (.issues[1].detail|length>0) and (.issues[2].status=="mergeado") and .state=="completed"'

echo "[D] parada solicitada"
W="$TMP/d"; setup "$W" "" "41"
run_batch "$W" 41 42 43
[ "$LAST_RC" -eq 0 ] && pass "D: exit 0" || fail "D: exit $LAST_RC"
check "D: state stopped, 41 mergeado, 42/43 aplazado con detail" \
    '.state=="stopped" and .current==null and (.issues|map(.status)==["mergeado","aplazado","aplazado"]) and (.issues[1].detail|test("parada"))'

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
