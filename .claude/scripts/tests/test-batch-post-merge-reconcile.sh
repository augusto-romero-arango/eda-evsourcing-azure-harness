#!/usr/bin/env bash
# test-batch-post-merge-reconcile.sh -- Reconciliacion best-effort del batch (#1161).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BATCH="$REPO_ROOT/src/internal/scripts/mefisto-batch-pipeline.sh"
COMMON="$REPO_ROOT/src/internal/scripts/lib/_mefisto-common.sh"
STATE_LIB="$REPO_ROOT/src/internal/scripts/lib/mefisto-state.sh"
RUNTIME="$REPO_ROOT/src/runtime"
TMP=$(mktemp -d)
PASS=0 FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

setup_repo() {
    local name="$1"
    local root="$TMP/$name/launcher" bare="$TMP/$name/origin.git"
    mkdir -p "$TMP/$name"
    git init -q --bare "$bare"
    git clone -q "$bare" "$root"
    git -C "$root" config user.email test@mefisto.local
    git -C "$root" config user.name 'Mefisto Test'
    git -C "$root" checkout -q -b main
    mkdir -p "$root/.claude-plugin" "$root/src/internal/scripts/lib"
    printf '{"name":"mefisto","version":"0.0.0"}\n' > "$root/.claude-plugin/plugin.json"
    cp "$BATCH" "$root/src/internal/scripts/mefisto-batch-pipeline.sh"
    cp "$COMMON" "$STATE_LIB" "$root/src/internal/scripts/lib/"
    cp -R "$RUNTIME" "$root/src/"
    cat > "$root/src/internal/scripts/mefisto-tooling-pipeline.sh" <<'EOF'
#!/usr/bin/env bash
printf 'tooling %s\n' "$1" >> "$TRACE_LOG"
echo "v PR creado: https://github.com/acme/mefisto/pull/$1"
EOF
    cat > "$root/src/internal/scripts/mefisto-validate-batch-deps.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RECONCILE_LOG"
printf 'reconcile %s\n' "$2" >> "$TRACE_LOG"
if [ "${RECONCILE_FAIL_PR:-}" = "${2:-}" ]; then
    echo "fallo simulado del reconciliador para PR #$2" >&2
    exit 1
fi
echo "Quitado 'bloqueado' de #$((2 + $2)): todas sus dependencias forward están CLOSED/MERGED."
echo "reconciliado PR #$2"
EOF
    chmod +x "$root/src/internal/scripts/mefisto-"{batch-pipeline,tooling-pipeline,validate-batch-deps}.sh
    git -C "$root" add . && git -C "$root" commit -q -m base && git -C "$root" push -q origin main
    git clone -q "$bare" "$TMP/$name/publisher"
    git -C "$TMP/$name/publisher" config user.email test@mefisto.local
    git -C "$TMP/$name/publisher" config user.name 'Mefisto Test'
    git -C "$TMP/$name/publisher" checkout -q main
    printf '%s\n' "$root"
}

run_batch() {
    local root="$1"; shift
    local name="${root%/launcher}"
    local bin="$name/bin"
    mkdir -p "$bin"
    cat > "$bin/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1" = pr ] && [ "$2" = merge ]; then
    printf 'merge %s\n' "$3" >> "$TRACE_LOG"
    if [ "${MERGE_FAIL_PR:-}" = "$3" ]; then exit 1; fi
    git -C "$PUBLISHER" pull -q --ff-only origin main
    git -C "$PUBLISHER" commit -q --allow-empty -m "merge-$3"
    git -C "$PUBLISHER" push -q origin main
    git -C "$PUBLISHER" rev-parse HEAD > "$MERGE_SHA_FILE"
    exit 0
fi
if [ "$1" = pr ] && [ "$2" = view ]; then
    printf 'sync %s\n' "$3" >> "$TRACE_LOG"
    cat "$MERGE_SHA_FILE"
    exit 0
fi
exit 1
EOF
    chmod +x "$bin/claude" "$bin/gh"
    (
        cd "$root" || exit 99
        env -u MEFISTO_STATE_DIR -u MEFISTO_LEGACY_STATE_DIR -u MEFISTO_REPO_ROOT \
            -u MEFISTO_PROJECT_NAME -u MEFISTO_REPO_SLUG -u MEFISTO_RUNTIME_LIB_DIR \
            GH_LOG="$name/gh.log" RECONCILE_LOG="$name/reconcile.log" PUBLISHER="$name/publisher" \
            TRACE_LOG="$name/trace.log" MERGE_SHA_FILE="$name/merge-sha" \
            MEFISTO_RUNTIME=claude PATH="$bin:/usr/bin:/bin:/usr/sbin:/sbin" \
            MERGE_FAIL_PR="${MERGE_FAIL_PR:-}" RECONCILE_FAIL_PR="${RECONCILE_FAIL_PR:-}" \
            ./src/internal/scripts/mefisto-batch-pipeline.sh "$@"
    ) >"$name/out" 2>&1
    LAST_RC=$?
    LAST_DIR="$name"
}

echo "[pre] sintaxis valida"
if bash -n "$BATCH"; then pass "batch con sintaxis valida"; else fail "batch con sintaxis invalida"; fi

echo "[A] dos merges exitosos reconcilian exactamente una vez y conservan sync"
ROOT=$(setup_repo success)
unset MERGE_FAIL_PR RECONCILE_FAIL_PR
run_batch "$ROOT" 101 102
if [ "$LAST_RC" -eq 0 ]; then pass "dos eslabones exitosos terminan en exito"; else fail "batch exitoso retorno $LAST_RC: $(cat "$LAST_DIR/out")"; fi
if [ "$(grep -c '^--reconcile-pr ' "$LAST_DIR/reconcile.log")" -eq 2 ] \
    && grep -qx -- '--reconcile-pr 101' "$LAST_DIR/reconcile.log" \
    && grep -qx -- '--reconcile-pr 102' "$LAST_DIR/reconcile.log"; then
    pass "cada merge exitoso invoca una sola reconciliacion, incluido el ultimo"
else
    fail "invocaciones de reconciliacion inesperadas: $(cat "$LAST_DIR/reconcile.log" 2>/dev/null)"
fi
if [ "$(grep -c '^pr view ' "$LAST_DIR/gh.log")" -eq 2 ] \
    && [ "$(git -C "$ROOT" rev-parse main)" = "$(git -C "$LAST_DIR/publisher" rev-parse main)" ]; then
    pass "el sync verificado se conserva despues de cada reconciliacion"
else
    fail "el sync no se ejecuto o main no quedo actualizado: $(cat "$LAST_DIR/gh.log")"
fi
EXPECTED_TRACE='tooling 101
merge 101
reconcile 101
sync 101
tooling 102
merge 102
reconcile 102
sync 102'
if [ "$(cat "$LAST_DIR/trace.log")" = "$EXPECTED_TRACE" ]; then
    pass "cada reconciliacion ocurre tras su merge y antes del sync y del siguiente eslabon"
else
    fail "orden post-merge inesperado: $(cat "$LAST_DIR/trace.log")"
fi

echo "[B] fallo de reconciliacion es warning best-effort y no detiene el siguiente eslabon"
ROOT=$(setup_repo degraded)
MERGE_FAIL_PR="" RECONCILE_FAIL_PR=201
run_batch "$ROOT" 201 202
ISSUE_201_LOG=$(printf '%s\n' "$ROOT/.mefisto/pipeline/logs/"mefisto-batch-issue-201-*.log)
if [ "$LAST_RC" -eq 0 ] \
    && grep -qF 'reconciliacion post-merge de bloqueados fallo' "$LAST_DIR/out" \
    && grep -qF 'fallo simulado del reconciliador para PR #201' "$ISSUE_201_LOG"; then
    pass "el fallo del reconciliador se registra como warning sin fallar el batch"
else
    fail "el fallo best-effort no se degrado correctamente: rc=$LAST_RC salida=$(cat "$LAST_DIR/out")"
fi
if [ "$(grep -c '^--reconcile-pr 201$' "$LAST_DIR/reconcile.log")" -eq 1 ] \
    && [ "$(grep -c '^--reconcile-pr 202$' "$LAST_DIR/reconcile.log")" -eq 1 ] \
    && [ "$(grep -c '^pr merge ' "$LAST_DIR/gh.log")" -eq 2 ] \
    && [ "$(grep -c '^pr view ' "$LAST_DIR/gh.log")" -eq 2 ] \
    && grep -qF "Quitado 'bloqueado' de #204" "$ROOT/.mefisto/pipeline/logs/"mefisto-batch-issue-202-*.log; then
    pass "no hay reintento; el siguiente eslabon, su trazabilidad y ambos sync continuan"
else
    fail "el batch no continuo tras el warning: reconcile=$(cat "$LAST_DIR/reconcile.log") gh=$(cat "$LAST_DIR/gh.log")"
fi

echo "[C] merge fallido no invoca reconciliacion ni sync"
ROOT=$(setup_repo merge-failed)
MERGE_FAIL_PR=301 RECONCILE_FAIL_PR=""
run_batch "$ROOT" 301
if [ "$LAST_RC" -ne 0 ]; then pass "merge fallido conserva el fallo del batch"; else fail "merge fallido no marco error"; fi
if [ ! -s "$LAST_DIR/reconcile.log" ] && ! grep -q '^pr view ' "$LAST_DIR/gh.log"; then
    pass "merge fallido no reconcilia ni intenta sync"
else
    fail "merge fallido ejecuto post-merge: reconcile=$(cat "$LAST_DIR/reconcile.log" 2>/dev/null) gh=$(cat "$LAST_DIR/gh.log")"
fi

echo "Resumen: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
