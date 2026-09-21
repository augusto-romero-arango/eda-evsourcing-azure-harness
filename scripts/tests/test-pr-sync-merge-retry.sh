#!/usr/bin/env bash
# test-pr-sync-merge-retry.sh -- Regresiones de merge_pr_with_retry() (#1551).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PR_SYNC="$REPO_ROOT/scripts/pr-sync.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export TMP_DIR

FUNC_SRC=$(awk '
    /^merge_pr_with_retry\(\) \{/ { flag=1 }
    flag && /^# ─── Función: desbloquear/ { exit }
    flag { print }
' "$PR_SYNC")

if [ -z "$FUNC_SRC" ]; then
    fail "no se pudo extraer merge_pr_with_retry() de pr-sync.sh"
    exit 1
fi
pass "se extrajo merge_pr_with_retry() de pr-sync.sh"

make_stubs() {
    local bin_dir="$1"
    mkdir "$bin_dir"
    cat > "$bin_dir/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
    "api repos/{owner}/{repo}") printf 'merge ' ;;
    "pr view")
        case "$GH_SCENARIO:$*" in
            post-merge:*,mergeStateStatus*) printf '%s' '{"state":"OPEN","mergeStateStatus":"CLEAN"}' ;;
            post-merge:*) printf '%s' 'MERGED' ;;
            rejected:*,mergeStateStatus*) printf '%s' '{"state":"OPEN","mergeStateStatus":"CLEAN"}' ;;
            rejected:*) printf '%s' 'OPEN' ;;
            blocked:*) printf '%s' '{"state":"OPEN","mergeStateStatus":"BLOCKED"}' ;;
        esac
        ;;
    "pr merge")
        printf '%s\n' "$3" >> "$TMP_DIR/merge-calls.txt"
        case "$GH_SCENARIO" in
            post-merge) printf '%s\n' 'failed to delete remote branch'; exit 1 ;;
            rejected) printf '%s\n' 'not mergeable'; exit 1 ;;
        esac
        ;;
esac
GH
    cat > "$bin_dir/sleep" <<'SLEEP'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$TMP_DIR/sleep-calls.txt"
SLEEP
    chmod +x "$bin_dir/gh" "$bin_dir/sleep"
}

run_case() {
    local scenario="$1"
    local case_file="$TMP_DIR/$scenario.sh"
    local bin_dir="$TMP_DIR/$scenario-bin"
    make_stubs "$bin_dir"
    : > "$TMP_DIR/log.txt"
    : > "$TMP_DIR/warn.txt"
    : > "$TMP_DIR/sleep-calls.txt"
    : > "$TMP_DIR/merge-calls.txt"
    {
        printf '%s\n' 'set -euo pipefail'
        printf '%s\n' "$FUNC_SRC"
        cat <<'HARNESS'
LOG_FILE_ABS="$TMP_DIR/log.txt"
log() { printf '%s\n' "$1" >> "$TMP_DIR/log.txt"; }
warn() { printf '%s\n' "$1" >> "$TMP_DIR/warn.txt"; }
set +e
merge_pr_with_retry 123
rc=$?
set -e
printf 'RESULT=%s\n' "$rc"
HARNESS
    } > "$case_file"
    OUTPUT=$(PATH="$bin_dir:$PATH" GH_SCENARIO="$scenario" /bin/bash "$case_file" 2>&1)
    RC=$?
}

echo "[M-1] gh pr merge falla después de que el PR quedó mergeado"
run_case post-merge
if [ "$RC" -eq 0 ] && echo "$OUTPUT" | grep -q 'RESULT=0'; then
    pass "M-1: retorna 0 cuando state es MERGED tras el fallo de gh pr merge"
else
    fail "M-1: se esperaba RESULT=0. Salida: $OUTPUT"
fi
if [ ! -s "$TMP_DIR/sleep-calls.txt" ]; then
    pass "M-1: no invoca sleep después de confirmar el merge"
else
    fail "M-1: no debía reintentar. Sleeps: $(cat "$TMP_DIR/sleep-calls.txt")"
fi
if grep -q 'failed to delete remote branch' "$TMP_DIR/warn.txt"; then
    pass "M-1: el warn conserva la salida de gh pr merge"
else
    fail "M-1: falta la salida de gh en el warn: $(cat "$TMP_DIR/warn.txt")"
fi

echo "[M-2] rechazo no reintentable de gh pr merge"
run_case rejected
if [ "$RC" -eq 0 ] && echo "$OUTPUT" | grep -q 'RESULT=1'; then
    pass "M-2: retorna 1 para not mergeable"
else
    fail "M-2: se esperaba RESULT=1. Salida: $OUTPUT"
fi
if [ ! -s "$TMP_DIR/sleep-calls.txt" ]; then
    pass "M-2: no reintenta un rechazo no reintentable"
else
    fail "M-2: no debía invocar sleep"
fi

echo "[M-3] PR bloqueado durante todos los intentos"
run_case blocked
if [ "$RC" -eq 0 ] && echo "$OUTPUT" | grep -q 'RESULT=1'; then
    pass "M-3: retorna 1 tras agotar los cinco intentos"
else
    fail "M-3: se esperaba RESULT=1. Salida: $OUTPUT"
fi
SLEEP_COUNT=$(wc -l < "$TMP_DIR/sleep-calls.txt" | tr -d ' ')
if [ "$SLEEP_COUNT" -eq 4 ] && [ ! -s "$TMP_DIR/merge-calls.txt" ]; then
    pass "M-3: conserva cuatro esperas y no intenta mergear un PR BLOCKED"
else
    fail "M-3: se esperaban 4 sleeps y cero merges; sleeps=$SLEEP_COUNT merges=$(cat "$TMP_DIR/merge-calls.txt")"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
