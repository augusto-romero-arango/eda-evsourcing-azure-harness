#!/usr/bin/env bash
# test-wait-pr-checks.sh -- mefisto_wait_pr_checks y ausencia de --admin (#1744).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
COMMON="$REPO_ROOT/src/internal/scripts/lib/_mefisto-common.sh"
TMP=$(mktemp -d)
PASS=0 FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOS'
#!/usr/bin/env bash
# STUB_MODE: empty | success | failure | cancelled | late
if [ "$1 $2" = "pr checks" ]; then
    if printf '%s ' "$@" | grep -q -- '--json'; then
        case "$STUB_MODE" in
            empty) echo '[]' ;;
            success) echo '[{"name":"tests","state":"SUCCESS"}]' ;;
            failure) echo '[{"name":"tests","state":"FAILURE"}]' ;;
            cancelled) echo '[{"name":"tests","state":"CANCELLED"}]' ;;
            late)
                n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0); echo $((n + 1)) > "$STUB_COUNT"
                if [ "$n" -ge 1 ]; then echo '[{"name":"tests","state":"SUCCESS"}]'; else echo '[]'; fi ;;
        esac
    else
        echo "watching"
    fi
    exit 0
fi
exit 0
EOS
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" STUB_COUNT="$TMP/count"
export MEFISTO_CI_POLL_SECONDS=1 MEFISTO_CI_APPEAR_TIMEOUT=2 MEFISTO_CI_TOTAL_TIMEOUT=10

run() { STUB_MODE="$1" bash -c "source '$COMMON'; mefisto_wait_pr_checks 7; echo \"rc=\$? reason=\$MEFISTO_PR_CHECKS_REASON\"" 2>&1; }

out=$(run success); echo "$out" | grep -q "rc=0" && pass "SUCCESS retorna 0" || fail "SUCCESS: $out"
out=$(run failure); echo "$out" | grep -q "rc=1 reason=rojo" && echo "$out" | grep -q "CI rojo" && pass "FAILURE retorna 1" || fail "FAILURE: $out"
out=$(run cancelled); echo "$out" | grep -q "rc=1" && pass "CANCELLED retorna 1" || fail "CANCELLED: $out"
out=$(run empty); echo "$out" | grep -q "rc=2 reason=ausente" && echo "$out" | grep -q "sin check" && pass "PR sin checks no es verde (CA-2)" || fail "empty: $out"
rm -f "$TMP/count"
out=$(run late); echo "$out" | grep -q "rc=0" && pass "check que aparece tarde se espera" || fail "late: $out"

if grep -rn --include="*.sh" --include="*.md" -e "gh pr merge.*--admin" "$REPO_ROOT/src/internal/" "$REPO_ROOT/.claude/scripts/" \
    | grep -v "test-wait-pr-checks.sh" | grep -q .; then
    fail "CA-6: hay gh pr merge --admin"
else
    pass "CA-6: sin gh pr merge --admin"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
