#!/usr/bin/env bash
# test-refactor-gate.sh — Tests del gate post-Stage-1 del pipeline TDD.
#
# Valida tres escenarios documentados en issue #150 / ADR-0017:
#   A) Refactor puro detectado correctamente (existe pipeline-state/refactor-signal.md)
#   B) Refactor puro probable pero senal ausente (log evidencia razonamiento de refactor)
#   C) Agente fallo — ni senal, ni cambios, ni evidencia en log
#
# Uso: scripts/tests/test-refactor-gate.sh
# Exit code: 0 si todos los escenarios pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0

# Reproduccion de la logica del gate (extraida de scripts/tdd-pipeline.sh
# Stage 1, post test-writer, antes del build). Cualquier cambio aqui debe
# acompanarse de un cambio en el script real.
gate_logic() {
    local worktree="$1"
    local stage1_log="$2"
    local snapshot_commit="$3"

    local refactor_signal_path="$worktree/pipeline-state/refactor-signal.md"
    local legacy_signal_path="$worktree/.claude/pipeline/refactor-signal.md"
    if [ ! -f "$refactor_signal_path" ] && [ -f "$legacy_signal_path" ]; then
        refactor_signal_path="$legacy_signal_path"
    fi

    local is_refactor=false
    if [ -f "$refactor_signal_path" ]; then
        is_refactor=true
    fi

    local has_changes=false
    if [ -n "$(git -C "$worktree" status --porcelain -- tests/ src/ 2>/dev/null)" ]; then
        has_changes=true
    fi
    if ! git -C "$worktree" diff --quiet "$snapshot_commit" HEAD 2>/dev/null; then
        has_changes=true
    fi

    if [ "$is_refactor" = true ]; then
        echo "REFACTOR_DETECTED"
        return 0
    fi

    if [ "$has_changes" = false ]; then
        if [ -f "$stage1_log" ] && grep -qiE "refactor.*pur|REFACTOR_ONLY|refactor-signal|refactoring puro" "$stage1_log"; then
            echo "ABORT_REFACTOR_SIGNAL_MISSING"
            return 0
        fi
        echo "ABORT_AGENT_PRODUCED_NOTHING"
        return 0
    fi

    echo "TESTS_GENERATED"
    return 0
}

# Reproduccion de extract_test_count() de scripts/tdd-pipeline.sh (issue #80).
# Suma los N de TODAS las lineas de resumen del output combinado (una por
# proyecto), con sentinela "?" cuando no hay ninguna linea parseable. Cualquier
# cambio aqui debe acompanarse de un cambio en el script real; la coherencia con
# el script se verifica en el Escenario E.
extract_test_count() {
    local count
    count=$(echo "$1" | grep -oiE '(correcto|correctas|passed|superado):[[:space:]]+[0-9]+' \
        | grep -oE '[0-9]+' \
        | awk '{ s += $1 } END { if (NR == 0) print "?"; else print s }') || true
    echo "${count:-?}"
}

setup_fake_worktree() {
    local dir="$1"
    rm -rf "$dir"
    mkdir -p "$dir/tests" "$dir/src" "$dir/.claude/pipeline" "$dir/pipeline-state"
    git -C "$dir" init -q -b main 2>/dev/null
    git -C "$dir" config user.email "test@local" 2>/dev/null
    git -C "$dir" config user.name "Test" 2>/dev/null
    echo "init" > "$dir/README.md"
    git -C "$dir" add README.md 2>/dev/null
    git -C "$dir" commit -q -m "init" 2>/dev/null
    git -C "$dir" rev-parse HEAD
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
trap "rm -rf $TMPDIR_BASE" EXIT

# ─── Escenario A: refactor puro detectado correctamente ─────────────────────
echo "Escenario A: senal en pipeline-state/ → REFACTOR_DETECTED"
WT_A="$TMPDIR_BASE/wt_a"
SNAPSHOT_A=$(setup_fake_worktree "$WT_A")
cat > "$WT_A/pipeline-state/refactor-signal.md" <<'EOF'
REFACTOR_ONLY=true
JUSTIFICATION=Refactor mecanico de tipos
EOF
LOG_A="$TMPDIR_BASE/log_a.txt"
echo "Resultado: refactor puro detectado" > "$LOG_A"
RESULT_A=$(gate_logic "$WT_A" "$LOG_A" "$SNAPSHOT_A")
assert_eq "A1: senal nueva detectada" "REFACTOR_DETECTED" "$RESULT_A"

# ─── Escenario A2: senal en ubicacion legacy detectada ──────────────────────
echo "Escenario A2: senal legacy en .claude/pipeline/ → REFACTOR_DETECTED"
WT_A2="$TMPDIR_BASE/wt_a2"
SNAPSHOT_A2=$(setup_fake_worktree "$WT_A2")
cat > "$WT_A2/.claude/pipeline/refactor-signal.md" <<'EOF'
REFACTOR_ONLY=true
JUSTIFICATION=Compatibilidad con worktrees previos
EOF
LOG_A2="$TMPDIR_BASE/log_a2.txt"
echo "ok" > "$LOG_A2"
RESULT_A2=$(gate_logic "$WT_A2" "$LOG_A2" "$SNAPSHOT_A2")
assert_eq "A2: senal legacy detectada" "REFACTOR_DETECTED" "$RESULT_A2"

# ─── Escenario B: refactor probable pero senal ausente (Bug 1 reproducido) ──
echo "Escenario B: log evidencia refactor + 0 cambios + 0 senal → ABORT_REFACTOR_SIGNAL_MISSING"
WT_B="$TMPDIR_BASE/wt_b"
SNAPSHOT_B=$(setup_fake_worktree "$WT_B")
LOG_B="$TMPDIR_BASE/log_b.txt"
cat > "$LOG_B" <<'EOF'
El directorio .claude/ esta bloqueado para escritura.
Resultado: Refactoring Puro - No se requieren tests nuevos.
El archivo .claude/pipeline/refactor-signal.md no pudo escribirse.
EOF
RESULT_B=$(gate_logic "$WT_B" "$LOG_B" "$SNAPSHOT_B")
assert_eq "B: detecta blocked-write y aborta con mensaje correcto" "ABORT_REFACTOR_SIGNAL_MISSING" "$RESULT_B"

# ─── Escenario C: agente realmente fallo ────────────────────────────────────
echo "Escenario C: 0 cambios + 0 senal + log sin evidencia → ABORT_AGENT_PRODUCED_NOTHING"
WT_C="$TMPDIR_BASE/wt_c"
SNAPSHOT_C=$(setup_fake_worktree "$WT_C")
LOG_C="$TMPDIR_BASE/log_c.txt"
cat > "$LOG_C" <<'EOF'
Error: API timeout.
No se pudo conectar al modelo. Reintenta mas tarde.
EOF
RESULT_C=$(gate_logic "$WT_C" "$LOG_C" "$SNAPSHOT_C")
assert_eq "C: agente sin output ni evidencia → mensaje de definicion de agente" "ABORT_AGENT_PRODUCED_NOTHING" "$RESULT_C"

# ─── Escenario D: flujo TDD normal (cambios en tests/src) ───────────────────
echo "Escenario D: cambios en tests/src → TESTS_GENERATED"
WT_D="$TMPDIR_BASE/wt_d"
SNAPSHOT_D=$(setup_fake_worktree "$WT_D")
mkdir -p "$WT_D/tests/Foo.Tests"
echo "// test" > "$WT_D/tests/Foo.Tests/SomeTest.cs"
LOG_D="$TMPDIR_BASE/log_d.txt"
echo "tests escritos" > "$LOG_D"
RESULT_D=$(gate_logic "$WT_D" "$LOG_D" "$SNAPSHOT_D")
assert_eq "D: cambios uncommitted en tests/" "TESTS_GENERATED" "$RESULT_D"

# ─── Escenario F: extract_test_count suma todos los proyectos (issue #80) ───
# El output combinado de run_tests_projects emite una linea de resumen por cada
# proyecto de test. extract_test_count debe SUMAR todos los N, no quedarse con
# el primero (bug del falso "se perdieron tests" al mover tests entre proyectos).
echo "Escenario F: extract_test_count suma todas las lineas de resumen"

# F1 (CA-1): dos proyectos MTP => suma, no head -1 del primero.
OUT_F1=$'Resumen de pruebas: total: 100, error: 0, correcto: 100\nResumen de pruebas: total: 325, error: 0, correcto: 325'
assert_eq "F1: 100 + 325 => 425 (no 100)" "425" "$(extract_test_count "$OUT_F1")"

# F2 (CA-3): sin ninguna linea parseable => sentinela "?", no 0 ni vacio.
assert_eq "F2: sin resumen parseable => sentinela ?" "?" "$(extract_test_count "no hay nada que parsear aqui")"

# F3 (CA-4): la salida es un unico entero limpio, valido para `-lt` de bash.
F3_VAL=$(extract_test_count "$OUT_F1")
if [ "$F3_VAL" -lt 999 ] 2>/dev/null; then
    echo "  PASS: F3: salida es entero usable en comparacion -lt"
    PASS=$((PASS + 1))
else
    echo "  FAIL: F3: salida no es un entero limpio: '$F3_VAL'"
    FAIL=$((FAIL + 1))
fi

# F4: multi-runner mezclado (Superado + Passed + correctas) en un solo output.
OUT_F4=$'Superado: 10  con errores: 0\nPassed: 20\nPruebas correctas: 5'
assert_eq "F4: Superado 10 + Passed 20 + correctas 5 => 35" "35" "$(extract_test_count "$OUT_F4")"

# ─── Escenario G: reubicar tests entre proyectos NO dispara el abort ────────
# CA-2: un refactor que MUEVE tests de Contracts.Tests a ControlHoras.Tests sin
# cambiar el total -> baseline y post-count suman la suite completa -> iguales ->
# la condicion `[ "$POST_TEST_COUNT" -lt "$BASELINE_TEST_COUNT" ]` del gate en
# tdd-pipeline.sh es falsa y no se dispara el abort.
echo "Escenario G: reubicacion de tests sin cambiar el total => baseline == post"
BASELINE_G=$'correcto: 100\ncorrecto: 325'   # Contracts.Tests=100, ControlHoras.Tests=325
POST_G=$'correcto: 60\ncorrecto: 365'        # 40 tests movidos a ControlHoras.Tests
BASELINE_COUNT_G=$(extract_test_count "$BASELINE_G")
POST_COUNT_G=$(extract_test_count "$POST_G")
assert_eq "G1: baseline suma la suite completa" "425" "$BASELINE_COUNT_G"
assert_eq "G2: post suma la suite completa" "425" "$POST_COUNT_G"
assert_eq "G3: baseline == post tras reubicar (no dispara abort)" "$BASELINE_COUNT_G" "$POST_COUNT_G"

# ─── Escenario E: smoke check de coherencia con el script real ──────────────
# El gate_logic() de este test reproduce la logica del script. Para detectar
# divergencias, verificamos que las cadenas clave (paths y regex de heuristica)
# aparezcan literalmente en scripts/tdd-pipeline.sh. Si alguien las cambia en
# un solo lugar, este test lo detecta.
echo "Escenario E: coherencia entre test y scripts/tdd-pipeline.sh"
TDD_SCRIPT="$REPO_ROOT/scripts/tdd-pipeline.sh"

assert_script_contains() {
    local name="$1" needle="$2"
    if grep -qF -- "$needle" "$TDD_SCRIPT"; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    cadena ausente en $TDD_SCRIPT: $needle"
        FAIL=$((FAIL + 1))
    fi
}

assert_script_contains "E1: path nuevo pipeline-state/refactor-signal.md" "pipeline-state/refactor-signal.md"
assert_script_contains "E2: path legacy .claude/pipeline/refactor-signal.md" ".claude/pipeline/refactor-signal.md"
assert_script_contains "E3: regex heuristica de log" "refactor.*pur|REFACTOR_ONLY|refactor-signal|refactoring puro"
# Coherencia de extract_test_count (issue #80): el script real debe SUMAR con
# awk y conservar el sentinela "?", no usar `head -1`.
assert_script_contains "E4: extract_test_count suma con awk" "awk '{ s += \$1 } END { if (NR == 0) print \"?\"; else print s }'"

assert_script_not_contains() {
    local name="$1" needle="$2"
    if grep -qF -- "$needle" "$TDD_SCRIPT"; then
        echo "  FAIL: $name"
        echo "    cadena presente (no deberia) en $TDD_SCRIPT: $needle"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    fi
}

assert_script_not_contains "E5: extract_test_count ya no usa head -1" "| grep -oE '[0-9]+' | head -1"

echo
echo "─── Resumen ───"
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
