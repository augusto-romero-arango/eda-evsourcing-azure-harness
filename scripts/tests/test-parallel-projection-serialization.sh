#!/usr/bin/env bash
# test-parallel-projection-serialization.sh -- Tests de los helpers de
# serializacion de tipo:projection (scripts/_pipeline-common.sh, issue #372).
#
# parallel-pipeline.sh serializa entre si cualquier par de issues tipo:projection
# de un mismo lote (comparten los archivos del worker de proyecciones del BC,
# MEF-ADR-0034), sin necesitar deteccion de BC (un repo = un BC, MEF-ADR-0023).
# Estos tests cubren los helpers PUROS que implementan esa regla, sin lanzar
# background jobs reales ni depender de gh/red:
#
#   S-1: _is_tipo_projection_from_labels reconoce el label EXACTO tipo:projection
#        y no un prefijo como tipo:projection-experimental.
#   S-2: is_tipo_projection (gh mockeado) refleja los labels del issue; si gh
#        falla, degrada a "no es projection" (no aborta el lote).
#   S-3: can_launch_now cubre la matriz de las 4 combinaciones de
#        (limite de paralelismo alcanzado) x (projection ya corriendo).
#
# Uso: scripts/tests/test-parallel-projection-serialization.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

source "$REPO_ROOT/scripts/_pipeline-common.sh"

echo "[S-1] _is_tipo_projection_from_labels: label exacto vs. prefijo"

if _is_tipo_projection_from_labels "estado:listo
tipo:projection
dom:facturacion"; then
    pass "labels con tipo:projection exacto -> reconocido"
else
    fail "labels con tipo:projection exacto -> se esperaba reconocido"
fi

if _is_tipo_projection_from_labels "tipo:projection-experimental"; then
    fail "prefijo tipo:projection-experimental -> NO deberia reconocerse como projection"
else
    pass "prefijo tipo:projection-experimental -> correctamente descartado"
fi

if _is_tipo_projection_from_labels "tipo:feature
estado:listo"; then
    fail "labels sin tipo:projection -> NO deberia reconocerse como projection"
else
    pass "labels sin tipo:projection -> correctamente descartado"
fi

if _is_tipo_projection_from_labels ""; then
    fail "labels vacios -> NO deberia reconocerse como projection"
else
    pass "labels vacios -> correctamente descartado"
fi

echo ""
echo "[S-2] is_tipo_projection (gh mockeado)"

RESULT_A=$(cd /tmp && { gh() { echo "tipo:projection"; }; is_tipo_projection 999 && echo "true" || echo "false"; })
if [ "$RESULT_A" = "true" ]; then
    pass "gh devuelve tipo:projection -> is_tipo_projection true"
else
    fail "gh devuelve tipo:projection -> se esperaba true, fue '$RESULT_A'"
fi

RESULT_B=$(cd /tmp && { gh() { echo "tipo:feature"; }; is_tipo_projection 998 && echo "true" || echo "false"; })
if [ "$RESULT_B" = "false" ]; then
    pass "gh devuelve tipo:feature -> is_tipo_projection false"
else
    fail "gh devuelve tipo:feature -> se esperaba false, fue '$RESULT_B'"
fi

RESULT_C=$(cd /tmp && { gh() { return 1; }; is_tipo_projection 997 && echo "true" || echo "false"; })
if [ "$RESULT_C" = "false" ]; then
    pass "gh falla -> is_tipo_projection degrada a false (no aborta el lote)"
else
    fail "gh falla -> se esperaba false, fue '$RESULT_C'"
fi

echo ""
echo "[S-3] can_launch_now: matriz de 4 combinaciones"

# can_launch_now <max_parallel> <running_count> <is_projection> <projection_running>

if can_launch_now 0 5 "false" "false"; then
    pass "sin limite, no-projection, sin projection corriendo -> lanza"
else
    fail "sin limite, no-projection, sin projection corriendo -> se esperaba lanzar"
fi

if can_launch_now 0 5 "true" "false"; then
    pass "sin limite, projection, sin projection corriendo -> lanza"
else
    fail "sin limite, projection, sin projection corriendo -> se esperaba lanzar"
fi

if can_launch_now 0 5 "true" "true"; then
    fail "sin limite, projection, YA hay projection corriendo -> NO deberia lanzar"
else
    pass "sin limite, projection, YA hay projection corriendo -> correctamente bloqueado"
fi

if can_launch_now 2 2 "false" "false"; then
    fail "limite alcanzado (2/2), no-projection -> NO deberia lanzar"
else
    pass "limite alcanzado (2/2), no-projection -> correctamente bloqueado"
fi

if can_launch_now 2 1 "false" "false"; then
    pass "bajo el limite (1/2), no-projection -> lanza"
else
    fail "bajo el limite (1/2), no-projection -> se esperaba lanzar"
fi

if can_launch_now 2 1 "true" "true"; then
    fail "bajo el limite (1/2) pero YA hay projection corriendo -> NO deberia lanzar"
else
    pass "bajo el limite (1/2) pero YA hay projection corriendo -> correctamente bloqueado (ambas condiciones aplican)"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
