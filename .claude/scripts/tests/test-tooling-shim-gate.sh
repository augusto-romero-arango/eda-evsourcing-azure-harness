#!/usr/bin/env bash
# test-tooling-shim-gate.sh -- Gate de cobertura de shims en el cierre de stage
# de mefisto-tooling-pipeline.sh (issue #1965).
# Uso: .claude/scripts/tests/test-tooling-shim-gate.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LIB="$REPO_ROOT/src/internal/scripts/lib/mefisto-test-inventory.sh"
PIPE="$REPO_ROOT/src/internal/scripts/mefisto-tooling-pipeline.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/src/published/scripts/tests" "$FIX/scripts/tests"
printf '#!/usr/bin/env bash\n' > "$FIX/src/published/scripts/tests/test-nueva-1965.sh"

echo "[A] Fuente canonica sin shim -> el gate falla con el nombre"
out="$(bash -c 'source "$1"; mefisto_test_inventory_check_canonical_coverage "$2"' _ "$LIB" "$FIX" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && pass "retorna distinto de 0" || fail "debio fallar sin shim"
case "$out" in *test-nueva-1965.sh*) pass "lista la fuente huerfana" ;; *) fail "no nombra la fuente: $out" ;; esac

echo "[B] Con shim homonimo -> pasa"
printf '#!/usr/bin/env bash\nexec true\n' > "$FIX/scripts/tests/test-nueva-1965.sh"
bash -c 'source "$1"; mefisto_test_inventory_check_canonical_coverage "$2"' _ "$LIB" "$FIX" >/dev/null 2>&1 \
    && pass "cobertura completa" || fail "debio pasar con shim"

echo "[C] El pipeline cablea el gate tras la neutralidad y el prompt exige el shim"
grep -q '^    run_test_shim_gate 1 writer' "$PIPE" && pass "gate en stage 1" || fail "falta gate en stage 1"
grep -q '^    run_test_shim_gate 2 reviewer' "$PIPE" && pass "gate en stage 2" || fail "falta gate en stage 2"
grep -q 'mefisto_test_inventory_check_canonical_coverage "\$WORKTREE_PATH"' "$PIPE" && pass "invoca la lib sobre el worktree" || fail "no invoca la lib"
grep -q 'su shim homonimo' "$PIPE" && pass "prompt del writer menciona el shim" || fail "prompt sin instruccion de shim"
a="$(grep -n '^    run_neutrality_gate 1 writer' "$PIPE" | cut -d: -f1)"
b="$(grep -n '^    run_test_shim_gate 1 writer' "$PIPE" | cut -d: -f1)"
[ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ] && pass "orden: neutralidad antes que shims" || fail "orden incorrecto"

echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
