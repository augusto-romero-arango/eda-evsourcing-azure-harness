#!/usr/bin/env bash
# test-no-red-gate.sh — Tests de la señal de fase roja no aplicable en el gate 1b
# del Stage 1 del pipeline TDD (issue #585, MEF-ADR-0017).
#
# Valida:
#   A) Ruta read-side (STAGE1_AGENT=projection-test-writer) con la señal presente:
#      exit 0 NO aborta (CA-2), exit 8 sigue abortando (CA-3), exit != 0/8 sigue
#      siendo fase roja confirmada
#   B) Ruta write-side (STAGE1_AGENT=test-writer): la señal se ignora aunque el
#      archivo exista -- exit 0 aborta igual (CA-3)
#   C) Sin señal, la ruta read-side aborta por exit 0 (CA-4: comportamiento previo
#      conservado) y el texto del abort presenta las dos hipotesis
#   D) Parseo de JUSTIFICATION (mismo patron grep+cut que refactor-signal.md)
#   E) Deteccion pre-existente al reanudar con --from-stage (CA-6)
#   F) Coherencia entre este test y los artefactos reales (deteccion de drift):
#      scripts/tdd-pipeline.sh y agents/projection-test-writer.md
#
# Uso: scripts/tests/test-no-red-gate.sh
# Exit code: 0 si todos los escenarios pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TDD_SCRIPT="$REPO_ROOT/scripts/tdd-pipeline.sh"
AGENT_DOC="$REPO_ROOT/agents/projection-test-writer.md"

PASS=0
FAIL=0

# Reproduccion de la deteccion de la señal (scripts/tdd-pipeline.sh: bloque
# pre-existente para --from-stage y re-chequeo post run_agent del Stage 1).
# La condicion de ruta es lo esencial: en write-side la señal se ignora aunque
# el archivo exista. Cualquier cambio aqui debe acompanarse de un cambio en el
# script real (Escenario F).
detect_no_red_signal() {
    local stage1_agent="$1" worktree="$2"
    local signal_path="$worktree/pipeline-state/no-red-signal.md"
    if [ "$stage1_agent" = "projection-test-writer" ] && [ -f "$signal_path" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# Reproduccion del parseo de JUSTIFICATION (mismo patron que refactor-signal.md).
parse_justification() {
    local signal_path="$1"
    grep "^JUSTIFICATION=" "$signal_path" 2>/dev/null | cut -d= -f2- || echo "no especificada"
}

# Reproduccion del gate 1b (scripts/tdd-pipeline.sh, post-build del Stage 1).
# Exit codes de Microsoft Testing Platform: 0=pasan, 2=fallan, 8=no hay tests.
gate_1b() {
    local g1_rc="$1" is_no_red="$2"
    if [ "$g1_rc" -eq 0 ]; then
        if [ "$is_no_red" = true ]; then
            echo "CONTINUE_NO_RED"
        else
            echo "ABORT_ALL_GREEN"
        fi
    elif [ "$g1_rc" -eq 8 ]; then
        echo "ABORT_NO_TESTS"
    else
        echo "RED_CONFIRMED"
    fi
}

setup_worktree() {
    local dir="$1" with_signal="$2"
    rm -rf "$dir"
    mkdir -p "$dir/pipeline-state"
    if [ "$with_signal" = true ]; then
        cat > "$dir/pipeline-state/no-red-signal.md" <<'EOF'
JUSTIFICATION=Unica capa posible: test de composicion de ListarTurnos; no invoca Run y pasa con el stub
EOF
    fi
    echo "$dir"
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

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ─── Escenario A: read-side con señal ───────────────────────────────────────
echo "Escenario A: read-side + señal presente"
WT_A=$(setup_worktree "$TMPDIR_BASE/wt_a" true)
IS_NO_RED_A=$(detect_no_red_signal "projection-test-writer" "$WT_A")
assert_eq "A1: señal detectada en la ruta read-side" "true" "$IS_NO_RED_A"
assert_eq "A2 (CA-2): exit 0 con señal no aborta y continua al Stage 2" \
    "CONTINUE_NO_RED" "$(gate_1b 0 "$IS_NO_RED_A")"
assert_eq "A3 (CA-3): exit 8 con señal sigue abortando (los tests deben existir)" \
    "ABORT_NO_TESTS" "$(gate_1b 8 "$IS_NO_RED_A")"
assert_eq "A4: exit 2 con señal sigue siendo fase roja confirmada" \
    "RED_CONFIRMED" "$(gate_1b 2 "$IS_NO_RED_A")"
assert_eq "A5: exit 1 (agregado mixto) con señal sigue siendo fase roja confirmada" \
    "RED_CONFIRMED" "$(gate_1b 1 "$IS_NO_RED_A")"

# ─── Escenario B: write-side con el archivo presente -> se ignora (CA-3) ────
echo "Escenario B: write-side + archivo de señal presente -> NO se honra"
WT_B=$(setup_worktree "$TMPDIR_BASE/wt_b" true)
IS_NO_RED_B=$(detect_no_red_signal "test-writer" "$WT_B")
assert_eq "B1: la señal no se detecta en la ruta write-side" "false" "$IS_NO_RED_B"
assert_eq "B2 (CA-3): exit 0 en write-side aborta igual que antes" \
    "ABORT_ALL_GREEN" "$(gate_1b 0 "$IS_NO_RED_B")"

# ─── Escenario C: read-side sin señal -> abort conservado (CA-4) ────────────
echo "Escenario C: read-side sin señal -> abort por exit 0 conservado"
WT_C=$(setup_worktree "$TMPDIR_BASE/wt_c" false)
IS_NO_RED_C=$(detect_no_red_signal "projection-test-writer" "$WT_C")
assert_eq "C1: sin archivo no hay señal" "false" "$IS_NO_RED_C"
assert_eq "C2 (CA-4): exit 0 sin señal aborta" "ABORT_ALL_GREEN" "$(gate_1b 0 "$IS_NO_RED_C")"

# ─── Escenario D: parseo de JUSTIFICATION ──────────────────────────────────
echo "Escenario D: parseo de JUSTIFICATION"
assert_eq "D1: justificacion parseada de la señal" \
    "Unica capa posible: test de composicion de ListarTurnos; no invoca Run y pasa con el stub" \
    "$(parse_justification "$WT_A/pipeline-state/no-red-signal.md")"

# El valor puede contener '=' (cut -d= -f2- conserva todo lo que sigue al primero).
WT_D2="$TMPDIR_BASE/wt_d2"
mkdir -p "$WT_D2/pipeline-state"
cat > "$WT_D2/pipeline-state/no-red-signal.md" <<'EOF'
JUSTIFICATION=Config-test del worker: Inline=0 y MetadataConfig ya alineado
EOF
assert_eq "D2: el valor conserva los '=' internos" \
    "Config-test del worker: Inline=0 y MetadataConfig ya alineado" \
    "$(parse_justification "$WT_D2/pipeline-state/no-red-signal.md")"

# ─── Escenario E: deteccion pre-existente al reanudar (CA-6) ────────────────
# Al reanudar con --from-stage el Stage 1 no corre, asi que la señal ya esta en
# el worktree antes del primer run_agent: la misma condicion debe detectarla.
echo "Escenario E: --from-stage sobre un worktree que ya tiene la señal (CA-6)"
assert_eq "E1: worktree previo con señal -> detectada sin correr el Stage 1" \
    "true" "$(detect_no_red_signal "projection-test-writer" "$WT_A")"
assert_eq "E2: worktree previo write-side con el archivo -> sigue ignorada" \
    "false" "$(detect_no_red_signal "test-writer" "$WT_A")"

# ─── Escenario F: coherencia con los artefactos reales ─────────────────────
echo "Escenario F: coherencia entre este test y tdd-pipeline.sh / projection-test-writer.md"

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

assert_script_contains "F1: path de la señal en pipeline-state/" \
    'NO_RED_SIGNAL_PATH="$WORKTREE_PATH/pipeline-state/no-red-signal.md"'
assert_script_contains "F2: la deteccion exige la ruta read-side" \
    '[ "$STAGE1_AGENT" = "projection-test-writer" ] && [ -f "$NO_RED_SIGNAL_PATH" ]'
assert_script_contains "F3: parseo de JUSTIFICATION con el mismo patron que refactor-signal" \
    'NO_RED_JUSTIFICATION=$(grep "^JUSTIFICATION=" "$NO_RED_SIGNAL_PATH" | cut -d= -f2- || echo "no especificada")'
assert_script_contains "F4 (CA-3): exit 8 conserva su rama de abort propia" \
    'elif [ "$g1_rc" -eq 8 ]; then'
assert_script_contains "F5 (CA-4): el abort sin señal presenta las dos hipotesis" \
    "Dos hipotesis:"
assert_script_contains "F6 (CA-4): el abort instruye como señalizar el caso legitimo" \
    "pipeline-state/no-red-signal.md con JUSTIFICATION="
assert_script_contains "F7 (CA-5): la justificacion viaja al prompt del reviewer" \
    'Justificación: $NO_RED_JUSTIFICATION'
assert_script_contains "F8 (CA-5): la justificacion viaja al cuerpo del PR" \
    '- Fase roja no aplicable: $NO_RED_JUSTIFICATION'

# La señal nace directo en pipeline-state/ (MEF-ADR-0017): a diferencia de
# refactor-signal.md no tiene ubicacion legacy que aceptar.
assert_file_not_contains "F9: sin ubicacion legacy .claude/pipeline/ para esta señal" \
    ".claude/pipeline/no-red-signal.md" "$TDD_SCRIPT"

# CA-2: a diferencia de IS_REFACTOR, la señal no salta ninguna etapa -- hay
# implementacion por escribir. Si alguna guarda de salto de etapa empezara a
# consultarla, este assert lo detecta.
SKIP_GUARD_DRIFT=$(grep -n 'IS_NO_RED_SIGNAL' "$TDD_SCRIPT" | grep -c 'FROM_STAGE')
assert_eq "F10 (CA-2): ninguna guarda de salto de etapa consulta la señal" "0" "$SKIP_GUARD_DRIFT"
assert_script_contains "F11 (CA-2): el Stage 2 sigue gobernado solo por IS_REFACTOR/--from-stage" \
    'if [ "$IS_REFACTOR" != true ] && [ "$FROM_STAGE" -le 2 ]; then'

# CA-1: el agente es quien emite la señal; sin estas instrucciones el gate nunca
# la ve (el pipeline no la crea por su cuenta).
assert_file_contains "F12 (CA-1): el agente instruye crear la señal en pipeline-state/" \
    "pipeline-state/no-red-signal.md" "$AGENT_DOC"
assert_file_contains "F13 (CA-1): el agente instruye el campo JUSTIFICATION=" \
    "JUSTIFICATION=" "$AGENT_DOC"
assert_file_contains "F14 (CA-1): el agente documenta la señal en su resumen de stage" \
    "señal no-red si aplica" "$AGENT_DOC"

echo
echo "─── Resumen ───"
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
