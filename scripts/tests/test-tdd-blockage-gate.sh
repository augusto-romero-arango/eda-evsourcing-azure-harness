#!/usr/bin/env bash
# test-tdd-blockage-gate.sh -- Tests de la rama del Gate 2 (fase verde) de
# scripts/tdd-pipeline.sh que distingue los dos motivos de blockage-report.md
# (issue #1561).
#
# Contexto: el implementer escribe blockage-report.md por dos motivos con
# doctrina opuesta -- "issue incompleto" (implementer.md paso 1b, antes de
# escribir codigo: el planner debe completar el issue) y "tests bloqueados"
# (implementer.md "Cuando reportar bloqueo": el reviewer 2b tiene autoridad
# para resolverlo). Antes de este issue el Gate 2 trataba cualquier reporte
# como "tests bloqueados" y siempre continuaba al reviewer, contradiciendo la
# doctrina del primer motivo (certificacion TDD v0.38.2, PR #1559/#1565).
#
# Se distinguen por un encabezado canonico exacto -- "## Issue incompleto",
# linea completa -- en vez de texto libre.
#
# Casos cubiertos (reproduccion local de la rama del Gate 2, sin invocar
# agentes reales ni el pipeline completo -- mismo patron que
# test-no-red-gate.sh):
#   [A] CA-2: tests rojos + reporte con el encabezado canonico -> detiene el
#       pipeline (STOP_BLOCKED), no continua al reviewer.
#   [B] CA-4: tests rojos + reporte sin el encabezado canonico (tests
#       bloqueados) -> comportamiento actual sin cambios (CONTINUE_TO_REVIEWER).
#   [C] CA-5: tests rojos + sin reporte -> el gate aborta como hoy
#       (ABORT_FAILED).
#   [D] Sanity: tests en verde (g2_rc=0) -> PASSED, la rama de blockage no
#       aplica.
#   [E] Nota tecnica del issue: si el reporte trae los dos motivos a la vez,
#       gana "issue incompleto".
#   [F] Coherencia con los artefactos reales: scripts/tdd-pipeline.sh (Gate 2
#       y abort()) y src/published/agents/implementer.md (paso 1b) --
#       deteccion de drift.
#
# Uso: scripts/tests/test-tdd-blockage-gate.sh
# Exit code: 0 si todos los escenarios pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TDD_SCRIPT="$REPO_ROOT/scripts/tdd-pipeline.sh"
IMPLEMENTER_DOC="$REPO_ROOT/src/published/agents/implementer.md"

PASS=0
FAIL=0

CANONICAL_HEADER='## Issue incompleto'

# Reproduccion de la rama del Gate 2 tras verificar tests (scripts/tdd-pipeline.sh,
# bloque "Gate: verificando fase verde..."). Cualquier cambio aqui debe
# acompanarse de un cambio en el script real (Escenario F).
gate_2() {
    local g2_rc="$1" blockage_report="$2"
    if [ "$g2_rc" -eq 0 ]; then
        echo "PASSED"
        return
    fi
    if [ -f "$blockage_report" ] && grep -qx "$CANONICAL_HEADER" "$blockage_report"; then
        echo "STOP_BLOCKED"
    elif [ -f "$blockage_report" ]; then
        echo "CONTINUE_TO_REVIEWER"
    else
        echo "ABORT_FAILED"
    fi
}

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    esperado: $expected"
        echo "    obtenido: $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_contains() {
    local name="$1" needle="$2" file="$3"
    if grep -qF -- "$needle" "$file"; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    cadena ausente en $file: $needle"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_not_contains() {
    local name="$1" needle="$2" file="$3"
    if grep -qF -- "$needle" "$file"; then
        echo "  FAIL: $name"
        echo "    cadena presente (no deberia) en $file: $needle"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    fi
}

assert_script_contains() { assert_file_contains "$1" "$2" "$TDD_SCRIPT"; }

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ─── Escenario A (CA-2): tests rojos + issue incompleto ────────────────────
echo "Escenario A (CA-2): tests rojos + reporte con encabezado canonico"
REPORT_A="$TMPDIR_BASE/blockage-incompleto.md"
cat > "$REPORT_A" <<'EOF'
## Issue incompleto

Falta la seccion `## ADRs aplicables` en el issue (o esta vacia). El planner debe completarla antes de reanudar con `--from-stage 2`.
EOF
assert_eq "A1: tests rojos + issue incompleto detiene el pipeline (no reviewer, no PR)" \
    "STOP_BLOCKED" "$(gate_2 1 "$REPORT_A")"

# ─── Escenario B (CA-4): tests rojos + tests bloqueados (sin cambios) ──────
echo "Escenario B (CA-4): tests rojos + reporte de tests bloqueados"
REPORT_B="$TMPDIR_BASE/blockage-tests.md"
cat > "$REPORT_B" <<'EOF'
## Reporte de bloqueo - Implementer

### Tests bloqueados
| Test | Error | Intentos enfocados |
|------|-------|--------------------|
| `AlgunTest` | mensaje resumido | 5 |
EOF
assert_eq "B1: tests rojos + tests bloqueados continua al reviewer (comportamiento actual)" \
    "CONTINUE_TO_REVIEWER" "$(gate_2 1 "$REPORT_B")"

# ─── Escenario C (CA-5): tests rojos + sin reporte ─────────────────────────
echo "Escenario C (CA-5): tests rojos + sin blockage-report.md"
REPORT_C="$TMPDIR_BASE/no-existe.md"
assert_eq "C1: sin reporte el gate sigue abortando (Stage 2 fallido)" \
    "ABORT_FAILED" "$(gate_2 1 "$REPORT_C")"

# ─── Escenario D: sanity, tests en verde ───────────────────────────────────
echo "Escenario D: tests en verde -- la rama de blockage no aplica"
assert_eq "D1: g2_rc=0 no consulta el reporte" "PASSED" "$(gate_2 0 "$REPORT_A")"

# ─── Escenario E: ambos motivos a la vez -> gana issue incompleto ──────────
echo "Escenario E: reporte con los dos motivos a la vez"
REPORT_E="$TMPDIR_BASE/blockage-ambos.md"
cat > "$REPORT_E" <<'EOF'
## Issue incompleto

Falta la seccion `## ADRs aplicables`.

## Reporte de bloqueo - Implementer

### Tests bloqueados
| Test | Error | Intentos enfocados |
|------|-------|--------------------|
| `OtroTest` | mensaje resumido | 5 |
EOF
assert_eq "E1: gana 'issue incompleto' sobre 'tests bloqueados'" \
    "STOP_BLOCKED" "$(gate_2 1 "$REPORT_E")"

# ─── Escenario F: coherencia con los artefactos reales ─────────────────────
echo "Escenario F: coherencia entre este test y tdd-pipeline.sh / implementer.md"

assert_script_contains "F1: la deteccion se ancla al encabezado canonico exacto" \
    "grep -qx '## Issue incompleto' \"\$BLOCKAGE_REPORT\""
assert_script_contains "F2 (CA-2): el caso 'issue incompleto' marca AGENT_IM_RES=blocked" \
    'AGENT_IM_RES="blocked"'
assert_script_contains "F3 (CA-2/CA-3): el abort de 'issue incompleto' pasa el estado blocked" \
    '" "blocked"'
assert_script_contains "F4 (CA-3): el mensaje nombra el reporte" \
    'reporto issue incompleto en $BLOCKAGE_REPORT_CANONICAL'
assert_script_contains "F5 (CA-3): el mensaje indica refinar con el planner" \
    'Refina el issue con el planner'
assert_script_contains "F6 (CA-3): el mensaje indica reanudar con --from-stage 2" \
    'reanuda con --from-stage 2'
assert_script_contains "F7 (CA-4): la rama de tests bloqueados sigue intacta" \
    'warn "Stage 2: hay tests rojos pero el $STAGE2_AGENT reporto bloqueo — continuando al reviewer"'
assert_script_contains "F8 (CA-5): sin reporte el gate sigue abortando con el mensaje original" \
    'abort "Stage 2 fallido: no todos los tests pasan después del $STAGE2_AGENT'
assert_script_contains "F9: abort() acepta un estado final distinto de failed por defecto" \
    'local abort_state="${2:-failed}"'
assert_script_contains "F10: abort() registra el estado parametrizado en el status del pipeline" \
    'update_status "$CURRENT_STAGE" "$abort_state"'
assert_file_not_contains "F11: no queda un update_status(...,\"failed\") hardcodeado dentro de abort()" \
    'update_status "$CURRENT_STAGE" "failed"' "$TDD_SCRIPT"
assert_script_contains "F12: el historial de metricas tambien usa el estado parametrizado" \
    'state:$state,stage:$stage'

assert_file_contains "F13 (CA-1): implementer.md fija el encabezado canonico exacto en 1b" \
    '`## Issue incompleto`' "$IMPLEMENTER_DOC"
assert_file_contains "F14 (CA-1): implementer.md exige que sea la primera linea del reporte" \
    "primera linea" "$IMPLEMENTER_DOC"
assert_file_contains "F15: implementer.md no escribe codigo antes de reportar el gap" \
    "No escribas codigo" "$IMPLEMENTER_DOC"

echo
echo "─── Resumen ───"
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
