#!/usr/bin/env bash
# test-coverage-gate-collect.sh — Contrato de recoleccion del coverage gate (#1550).
#
# Extrae y ejercita las funciones reales del pipeline con stubs: valida que
# dotnet-coverage ejecute solo *.Tests/, conserve el exit code de tests fallidos
# y distinga esa causa de un fallo de instrumentacion.

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

extract_stage4_function() {
    local name="$1"
    awk -v fn="$name" '
        $0 ~ "^    " fn "\\(\\) \\{" { printing=1 }
        printing {
            is_end = ($0 == "    }")
            sub(/^    /, "")
            print
            if (is_end) exit
        }
    ' "$PIPELINE"
}

MEASURE_BODY=$(extract_stage4_function measure_coverage)
SKIP_REASON_BODY=$(extract_stage4_function coverage_measurement_skip_reason)
eval "$MEASURE_BODY"
eval "$SKIP_REASON_BODY"

cat > "$STUB_BIN/dotnet" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "build" ]; then
    exit 0
fi
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
if [ "$1" = "instrument" ]; then
    exit 0
fi
[ "$1" = "collect" ] && shift
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

log() { :; }
warn() { :; }
HARNESS_NAMESPACE_PREFIX="Cosmos.ControlPlane"
LOG_FILE="$TMPDIR_BASE/coverage.log"
LOG_FILE_ABS="$LOG_FILE"

prepare_worktree() {
    local worktree="$1"
    shift
    local project
    for project in "$@"; do
        mkdir -p "$worktree/tests/$project/bin/Debug/net10.0"
        : > "$worktree/tests/$project/bin/Debug/net10.0/Cosmos.ControlPlane.Domain.dll"
    done
}

echo "[A] El pipeline conserva el contrato de recoleccion"
if grep -q 'dotnet test --solution' "$PIPELINE"; then
    fail "el coverage gate aun usa dotnet test --solution"
else
    pass "el coverage gate no usa dotnet test --solution"
fi
if declare -F measure_coverage >/dev/null \
    && declare -F coverage_measurement_skip_reason >/dev/null; then
    pass "las funciones reales del Stage 4 se pudieron cargar"
else
    fail "no se pudieron cargar las funciones reales del Stage 4"
fi

echo "[B] Recoleccion con stubs"
WT="$TMPDIR_BASE/worktree"
prepare_worktree "$WT" \
    "Cosmos.ControlPlane.Unit.Tests" \
    "Cosmos.ControlPlane.Failing.Tests" \
    "Cosmos.ControlPlane.Api.SmokeTests"
export DOTNET_STUB_LOG="$TMPDIR_BASE/dotnet.log"
: > "$DOTNET_STUB_LOG"
WORKTREE_PATH="$WT"
rc=0
measure_coverage >/dev/null 2>&1 || rc=$?
collect_rc=$(<"$WT/coverage-collect.rc")
if [ "$rc" -eq 3 ] && [ "$collect_rc" -eq 2 ] \
    && [ -f "$WT/coverage.cobertura.xml" ]; then
    pass "measure_coverage conserva el exit 2 del test, retorna 3 y deja XML"
else
    fail "se esperaba measure=3, collect=2 y XML; se obtuvo measure=$rc collect=$collect_rc"
fi
if grep -q 'SmokeTests' "$DOTNET_STUB_LOG"; then
    fail "la recoleccion invoco un proyecto SmokeTests"
else
    pass "ningun --project recibido termina en SmokeTests"
fi

echo "[C] Causa del SKIP"
reason=$(coverage_measurement_skip_reason \
    "$rc" "$WT/coverage.cobertura.xml" "$collect_rc")
if [ "$reason" = "SKIP coverage-gate: tests fallaron bajo cobertura (exit code 2)" ]; then
    pass "XML con tests fallidos reporta el exit code real"
else
    fail "causa inesperada para tests fallidos: $reason"
fi

rm -f "$WT/coverage.cobertura.xml"
reason=$(coverage_measurement_skip_reason 1 "$WT/coverage.cobertura.xml" "")
if [ "$reason" = "SKIP coverage-gate: instrumentacion fallo" ]; then
    pass "sin XML se reporta fallo de instrumentacion"
else
    fail "causa inesperada sin XML: $reason"
fi

echo ""
echo "Resumen: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
