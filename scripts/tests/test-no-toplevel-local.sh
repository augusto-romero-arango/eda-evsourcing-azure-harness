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
#       scripts publicados (scripts/*.sh), via shellcheck regla SC2168. Si el
#       binario no esta instalado, el guard FALLA explicitamente (no
#       silenciosamente) -- awk de BSD no soporta \b y un grep '\blocal\b'
#       da falsos positivos con la palabra "local" en prosa/prompts.
#   [B] Comportamiento: cuando el writer del Stage 1 de tooling-pipeline.sh no
#       genera cambios (HAS_COMMITS=false, HAS_UNSTAGED=false), el bloque real
#       del script (extraido literal, sin reescribir) muestra exclusivamente el
#       contenido no vacio de `## Pendiente/bloqueos` del summary canonico y
#       conserva el abort limpio ("El writer no genero ningun cambio...").
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
echo "[B] tooling-pipeline.sh Stage 1: writer sin cambios conserva bloqueos del summary"

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
        local summary_content="$1"
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

        if [ -n "$summary_content" ]; then
            mkdir -p "$worktree/.mefisto/pipeline/summaries"
            printf '%s\n' "$summary_content" > "$worktree/.mefisto/pipeline/summaries/stage-1-writer.md"
        fi

        local test_script="$TMP_DIR/block.sh"
        cat > "$test_script" <<EOF
#!/usr/bin/env bash
set -e
LOG_DIR_ABS="$TMP_DIR"
TIMESTAMP="test"
ISSUE_NUM="999"
ISSUE_LOG_TAG="999"
EVENTS_LOG_ABS="$TMP_DIR/events.log"
STAGE1_PROMPT="prompt original"
WORKTREE_PATH="$worktree"
 SNAPSHOT_COMMIT="$snapshot"
mefisto_state_path() { printf '%s\n' "$worktree/.mefisto/pipeline/\$1"; }
abort() { echo "ABORT: \$1"; exit 42; }
HAS_COMMITS=false
HAS_UNSTAGED=false
$BLOCK
echo "NO_ABORT_REACHED"
EOF
        bash "$test_script" 2>&1
    }

    # Escenario B1: el centinela de la seccion estructurada es visible antes del abort.
    OUTPUT_B1=$(run_block "## Implementado

Nada.

## Pendiente/bloqueos

BLOQUEO-CENTINELA-1315

Detalle del bloqueo.

## Verificacion

No aplica.")
    RC_B1=$?

    if echo "$OUTPUT_B1" | grep -q "BLOQUEO-CENTINELA-1315"; then
        pass "B1: muestra el bloqueo centinela del summary canonico"
    else
        fail "B1: no mostro el bloqueo centinela: $OUTPUT_B1"
    fi

    if [ "$RC_B1" -eq 42 ] && echo "$OUTPUT_B1" | grep -q "El writer no genero ningun cambio"; then
        pass "B1: conserva el abort limpio ('El writer no genero ningun cambio...')"
    else
        fail "B1: no llego al abort limpio esperado (rc=$RC_B1): $OUTPUT_B1"
    fi

    # Escenario B2: summary ausente degrada al abort generico, sin fallo secundario.
    OUTPUT_B2=$(run_block "")
    RC_B2=$?

    if [ "$RC_B2" -eq 42 ] && echo "$OUTPUT_B2" | grep -q "El writer no genero ningun cambio" \
        && ! echo "$OUTPUT_B2" | grep -q "Pendiente/bloqueos informado"; then
        pass "B2: summary ausente conserva el abort generico sin error secundario"
    else
        fail "B2: summary ausente no degrado correctamente (rc=$RC_B2): $OUTPUT_B2"
    fi

    # Escenario B3: una seccion ausente tampoco agrega diagnosticos secundarios.
    OUTPUT_B3=$(run_block "## Implementado

Sin cambios.")
    RC_B3=$?
    if [ "$RC_B3" -eq 42 ] && echo "$OUTPUT_B3" | grep -q "El writer no genero ningun cambio" \
        && ! echo "$OUTPUT_B3" | grep -q "Pendiente/bloqueos informado"; then
        pass "B3: seccion ausente conserva el abort generico"
    else
        fail "B3: seccion ausente no degrado correctamente (rc=$RC_B3): $OUTPUT_B3"
    fi

    # Escenario B4: una seccion vacia no se presenta como un bloqueo.
    OUTPUT_B4=$(run_block "## Pendiente/bloqueos

## Verificacion

No aplica.")
    RC_B4=$?
    if [ "$RC_B4" -eq 42 ] && echo "$OUTPUT_B4" | grep -q "El writer no genero ningun cambio" \
        && ! echo "$OUTPUT_B4" | grep -q "Pendiente/bloqueos informado"; then
        pass "B4: seccion vacia conserva el abort generico"
    else
        fail "B4: seccion vacia no degrado correctamente (rc=$RC_B4): $OUTPUT_B4"
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
