#!/usr/bin/env bash
# test-no-toplevel-local.sh -- Guard SC2168 + test de comportamiento (issue #308).
#
# Bash solo permite `local` dentro de funciones; con `set -e` activo, una
# declaracion `local` en el cuerpo top-level de un script (fuera de cualquier
# funcion) aborta el pipeline con "local: can only be used in a function" antes
# de llegar a su terminacion limpia (abort() con update_status "failed").
#
# Valida:
#   [A] Guard estatico: cero ocurrencias de `local` fuera de funcion en los
#       scripts publicados (scripts/*.sh), via shellcheck regla SC2168. Si
#       shellcheck no esta instalado, el guard FALLA explicitamente (no
#       silenciosamente) -- awk de BSD no soporta \b y un grep '\blocal\b'
#       da falsos positivos con la palabra "local" en prosa/prompts.
#   [B] Comportamiento: cuando el writer del Stage 1 de tooling-pipeline.sh no
#       genera cambios (HAS_COMMITS=false, HAS_UNSTAGED=false), el bloque real
#       del script (extraido literal, sin reescribir) corre bajo `set -e` sin
#       crashear por "local: can only be used in a function" y llega al abort
#       limpio ("El writer no genero ningun cambio...").
#
# Uso: scripts/tests/test-no-toplevel-local.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# -------- Bloque A: guard estatico -- cero 'local' fuera de funcion --------

echo "[A] Guard estatico: cero 'local' fuera de funcion en scripts/*.sh (shellcheck SC2168)"

if ! command -v shellcheck >/dev/null 2>&1; then
    fail "shellcheck no esta instalado -- el guard no puede verificar SC2168 (instalalo: https://github.com/koalaman/shellcheck#installing)"
else
    PUBLISHED_SCRIPTS=("$REPO_ROOT"/scripts/*.sh)
    SC2168_HITS=$(shellcheck -f gcc "${PUBLISHED_SCRIPTS[@]}" 2>/dev/null | grep 'SC2168' || true)
    if [ -z "$SC2168_HITS" ]; then
        pass "cero ocurrencias de SC2168 en scripts/*.sh"
    else
        fail "SC2168 detectado en scripts publicados:"
        echo "$SC2168_HITS" | sed 's/^/    /'
    fi
fi

# -------- Bloque B: comportamiento -- writer del Stage 1 sin cambios --------

echo ""
echo "[B] tooling-pipeline.sh Stage 1: writer sin cambios llega al abort limpio"

TOOLING_SCRIPT="$REPO_ROOT/scripts/tooling-pipeline.sh"

# Extrae el bloque real "writer sin cambios" (desde el if que compara
# HAS_COMMITS/HAS_UNSTAGED hasta el 'fi' que lo cierra, indentado a 4 espacios)
# para ejercerlo tal cual vive en el script -- no una reescritura de la logica.
BLOCK=$(awk '
    /^    if \[ "\$HAS_COMMITS" = false \] && \[ "\$HAS_UNSTAGED" = false \]; then$/ && !started { started=1 }
    started { print; if (/^    fi$/) exit }
' "$TOOLING_SCRIPT")

if [ -z "$BLOCK" ]; then
    fail "no se pudo extraer el bloque 'writer sin cambios' de $TOOLING_SCRIPT (¿cambio de forma del script?)"
else
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    run_block() {
        local writer_log_content="$1"
        local worktree="$TMP_DIR/wt"

        rm -rf "$worktree"
        mkdir -p "$worktree/pipeline-state"
        git -C "$worktree" init -q -b main 2>/dev/null
        git -C "$worktree" config user.email "test@local" 2>/dev/null
        git -C "$worktree" config user.name "Test" 2>/dev/null
        echo "init" > "$worktree/README.md"
        git -C "$worktree" add README.md 2>/dev/null
        git -C "$worktree" commit -q -m "init" 2>/dev/null
        local snapshot
        snapshot=$(git -C "$worktree" rev-parse HEAD)

        local writer_log="$TMP_DIR/writer.log"
        if [ -n "$writer_log_content" ]; then
            echo "$writer_log_content" > "$writer_log"
        fi

        local test_script="$TMP_DIR/block.sh"
        cat > "$test_script" <<EOF
#!/usr/bin/env bash
set -e
LOG_DIR_ABS="$TMP_DIR"
TIMESTAMP="test"
ISSUE_NUM="999"
EVENTS_LOG_ABS="$TMP_DIR/events.log"
STAGE1_PROMPT="prompt original"
WORKTREE_PATH="$worktree"
SNAPSHOT_COMMIT="$snapshot"
warn() { echo "WARN: \$1"; }
run_agent() { :; }
abort() { echo "ABORT: \$1"; exit 42; }
HAS_COMMITS=false
HAS_UNSTAGED=false
$BLOCK
echo "NO_ABORT_REACHED"
EOF
        mv "$writer_log" "$TMP_DIR/tooling-stage-1-writer-test-issue-999.log" 2>/dev/null || true
        bash "$test_script" 2>&1
    }

    # Escenario B1: log sin frases de "pidio permisos" -> va directo al abort limpio
    OUTPUT_B1=$(run_block "El writer reporto: no se encontraron cambios pendientes.")
    RC_B1=$?

    if echo "$OUTPUT_B1" | grep -q "local: can only be used in a function"; then
        fail "B1: el bloque crashea con 'local: can only be used in a function'"
    else
        pass "B1: el bloque no crashea con el error de 'local' top-level"
    fi

    if [ "$RC_B1" -eq 42 ] && echo "$OUTPUT_B1" | grep -q "El writer no genero ningun cambio"; then
        pass "B1: llega al abort limpio ('El writer no genero ningun cambio...')"
    else
        fail "B1: no llego al abort limpio esperado (rc=$RC_B1): $OUTPUT_B1"
    fi

    # Escenario B2: log SI contiene frase de "pidio permisos" -> dispara retry
    # (run_agent stubeado como no-op); tras el retry sigue sin cambios reales y
    # debe llegar igualmente al abort limpio, sin crashear por 'local'.
    OUTPUT_B2=$(run_block "El agente respondio: necesito permiso para continuar.")
    RC_B2=$?

    if echo "$OUTPUT_B2" | grep -q "local: can only be used in a function"; then
        fail "B2 (con retry): el bloque crashea con 'local: can only be used in a function'"
    else
        pass "B2 (con retry): el bloque no crashea con el error de 'local' top-level"
    fi

    if [ "$RC_B2" -eq 42 ] && echo "$OUTPUT_B2" | grep -q "El writer no genero ningun cambio"; then
        pass "B2 (con retry): llega al abort limpio tras el retry sin cambios"
    else
        fail "B2 (con retry): no llego al abort limpio esperado (rc=$RC_B2): $OUTPUT_B2"
    fi
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
