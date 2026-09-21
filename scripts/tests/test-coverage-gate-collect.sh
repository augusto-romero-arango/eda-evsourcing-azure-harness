#!/usr/bin/env bash
# test-coverage-gate-collect.sh — Contrato de recoleccion del coverage gate (#1550).
#
# Valida con stubs que el comando que usa dotnet-coverage ejecuta solamente
# proyectos *.Tests/, conserva el exit code de tests fallidos y genera el XML.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PIPELINE="$REPO_ROOT/scripts/tdd-pipeline.sh"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT
STUB_BIN="$TMPDIR_BASE/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/dotnet" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "test" ]; then
    shift
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --project) project="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    printf '%s\n' "$project" >> "${DOTNET_STUB_LOG:?}"
    case "$project" in
        *Failing.Tests/) exit 2 ;;
        *) exit 0 ;;
    esac
fi
exit 0
STUB

cat > "$STUB_BIN/dotnet-coverage" <<'STUB'
#!/usr/bin/env bash
output=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) output="$2"; shift 2 ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
"$@"
rc=$?
printf '<coverage/>\n' > "$output"
exit "$rc"
STUB
chmod +x "$STUB_BIN/dotnet" "$STUB_BIN/dotnet-coverage"
export PATH="$STUB_BIN:$PATH"

run_collect() {
    local worktree="$1"
    dotnet-coverage collect --output "$worktree/coverage.cobertura.xml" -f cobertura -- \
        bash -c '
            for proj in "$1"/tests/Cosmos.ControlPlane.*.Tests/; do
                [ -d "$proj" ] || continue
                dotnet test --project "$proj" --no-build
                test_rc=$?
                if [ "$test_rc" -ne 0 ] && [ "$test_rc" -ne 8 ]; then
                    exit "$test_rc"
                fi
            done
        ' _ "$worktree"
}

echo "[A] El pipeline conserva el contrato de recoleccion"
if grep -q 'dotnet test --solution' "$PIPELINE"; then
    fail "el coverage gate aun usa dotnet test --solution"
else
    pass "el coverage gate no usa dotnet test --solution"
fi
if grep -q 'coverage-collect.rc' "$PIPELINE" \
    && grep -q 'tests fallaron bajo cobertura (exit code' "$PIPELINE" \
    && grep -q 'SKIP coverage-gate: instrumentacion fallo' "$PIPELINE"; then
    pass "el pipeline distingue tests fallidos de instrumentacion fallida"
else
    fail "faltan el RC persistido o los mensajes de SKIP esperados"
fi

echo "[B] Recoleccion con stubs"
WT="$TMPDIR_BASE/worktree"
mkdir -p "$WT/tests/Cosmos.ControlPlane.Unit.Tests" \
    "$WT/tests/Cosmos.ControlPlane.Failing.Tests" \
    "$WT/tests/Cosmos.ControlPlane.Api.SmokeTests"
export DOTNET_STUB_LOG="$TMPDIR_BASE/dotnet.log"
: > "$DOTNET_STUB_LOG"
rc=0
run_collect "$WT" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ] && [ -f "$WT/coverage.cobertura.xml" ]; then
    pass "un test fallido conserva su exit code y deja XML"
else
    fail "se esperaba exit 2 con XML, se obtuvo rc=$rc"
fi
if grep -q 'SmokeTests' "$DOTNET_STUB_LOG"; then
    fail "la recoleccion invoco un proyecto SmokeTests"
else
    pass "ningun --project recibido termina en SmokeTests"
fi

echo ""
echo "Resumen: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
