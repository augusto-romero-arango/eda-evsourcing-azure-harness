#!/usr/bin/env bash
# test-mefisto-tooling-manual-close.sh -- Chequeos estaticos del label
# cierre:manual en mefisto-tooling-pipeline.sh (issue #1489).
#
# Cubre:
#   [1] La consulta del issue incluye labels y detecta cierre:manual.
#   [2] La rama por defecto conserva Closes y la rama manual usa Refs.
#   [3] El comentario final y la sugerencia manual reutilizan la referencia.
#   [4] El test aparece en el inventario interno que ejecuta la suite.
#
# Uso: .claude/scripts/tests/test-mefisto-tooling-manual-close.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PIPE="$REPO_ROOT/src/internal/scripts/mefisto-tooling-pipeline.sh"
INVENTORY_LIB="$REPO_ROOT/src/internal/scripts/lib/mefisto-test-inventory.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "[1] Consulta y deteccion del label (CA-2)"
if grep -qF 'gh issue view "$ISSUE_NUM" --json number,title,body,state,labels' "$PIPE"; then
    pass "gh issue view solicita labels"
else
    fail "gh issue view no solicita labels"
fi
if grep -qF "label['name'] == 'cierre:manual'" "$PIPE"; then
    pass "el pipeline detecta cierre:manual en ISSUE_JSON"
else
    fail "el pipeline no detecta cierre:manual"
fi

echo ""
echo "[2] Referencia del PR por rama (CA-2, CA-3)"
if grep -qF 'ISSUE_PR_REFERENCE="Closes"' "$PIPE"; then
    pass "la rama por defecto conserva Closes"
else
    fail "falta la referencia Closes por defecto"
fi
if grep -qF 'ISSUE_PR_REFERENCE="Refs"' "$PIPE"; then
    pass "la rama cierre:manual usa Refs"
else
    fail "falta la referencia Refs para cierre:manual"
fi
DEFAULT_LINE=$(grep -nF 'ISSUE_PR_REFERENCE="Closes"' "$PIPE" | cut -d: -f1)
MANUAL_IF_LINE=$(grep -nF "label['name'] == 'cierre:manual'" "$PIPE" | cut -d: -f1)
MANUAL_BRANCH=$(awk -v start="$MANUAL_IF_LINE" 'NR >= start { print; if (NR > start && $0 == "fi") exit }' "$PIPE")
if [ "$(grep -cF 'ISSUE_PR_REFERENCE="Closes"' "$PIPE")" -eq 1 ] \
    && [ "$(grep -cF 'ISSUE_PR_REFERENCE="Refs"' "$PIPE")" -eq 1 ] \
    && [ -n "$DEFAULT_LINE" ] \
    && [ -n "$MANUAL_IF_LINE" ] \
    && [ "$DEFAULT_LINE" -lt "$MANUAL_IF_LINE" ] \
    && printf '%s\n' "$MANUAL_BRANCH" | grep -qF 'ISSUE_PR_REFERENCE="Refs"' \
    && ! printf '%s\n' "$MANUAL_BRANCH" | grep -qF 'ISSUE_PR_REFERENCE="Closes"'; then
    pass "Closes queda como default sin label y Refs solo en la rama cierre:manual"
else
    fail "Closes o Refs no estan limitados a la rama que corresponde"
fi
if [ "$(grep -cF '$ISSUE_PR_REFERENCE #$ISSUE_NUM' "$PIPE")" -eq 2 ]; then
    pass "el cuerpo del PR y la sugerencia manual usan la referencia decidida"
else
    fail "el cuerpo del PR y la sugerencia manual deben reutilizar la referencia exactamente dos veces"
fi

echo ""
echo "[3] Evidencia visible para cierre manual (CA-4)"
WARN_LINE=$(grep -nF 'warn "El issue #$ISSUE_NUM tiene el label cierre:manual' "$PIPE" | cut -d: -f1)
CREATE_LINE=$(grep -nF 'log "Creando PR..."' "$PIPE" | cut -d: -f1)
if [ -n "$WARN_LINE" ] && [ -n "$CREATE_LINE" ] && [ "$WARN_LINE" -lt "$CREATE_LINE" ]; then
    pass "el pipeline advierte inmediatamente antes de crear el PR"
else
    fail "falta la advertencia de cierre:manual"
fi
if grep -qF 'Este PR no cierra el issue (label cierre:manual).' "$PIPE"; then
    pass "el comentario final explica que el PR no cierra el issue"
else
    fail "falta la explicacion en el comentario final"
fi
if grep -qF 'gh pr create --base main --head $BRANCH_NAME' "$PIPE" \
    && grep -qF -- '--body \"$ISSUE_PR_REFERENCE #$ISSUE_NUM\"' "$PIPE"; then
    pass "la sugerencia manual reutiliza la referencia decidida"
else
    fail "la sugerencia manual no reutiliza la referencia decidida"
fi

echo ""
echo "[4] Inventario de tests (CA-5)"
# shellcheck source=/dev/null
source "$INVENTORY_LIB"
INVENTORY_OUTPUT="$(mefisto_test_inventory_lane_interno "$REPO_ROOT")"
if printf '%s\n' "$INVENTORY_OUTPUT" | grep -qF $'interno\t.claude/scripts/tests/test-mefisto-tooling-manual-close.sh'; then
    pass "el test esta registrado en el inventario interno"
else
    fail "el test no aparece en el inventario interno: $INVENTORY_OUTPUT"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -eq 0 ]
