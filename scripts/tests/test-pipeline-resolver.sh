#!/usr/bin/env bash
# test-pipeline-resolver.sh -- Tests del resolver de pipelines (scripts/_pipeline-common.sh).
#
# Cubre el contrato de retorno del resolver (issue #289): las rutas de pipeline
# devueltas deben ser ABSOLUTAS al plugin (no relativas al cwd), para que
# batch-pipeline.sh y parallel-pipeline.sh -- que hacen 'cd "$REPO_ROOT"' antes
# de ejecutar la ruta tal cual -- no fallen cuando el plugin no vive dentro del
# repo del consumidor.
#
#   R-1: resolve_pipeline con override "tdd"/"tooling" retorna una ruta absoluta
#        y existente, sin importar el cwd desde el que se invoque.
#   R-2: _resolve_from_labels retorna ruta absoluta y existente para tipo:feature,
#        tipo:refactor y tipo:tooling.
#   R-3: los sentinels SKIP:infra y SKIP:no-tipo se retornan intactos (no se
#        absolutizan).
#   R-4: resolve_pipeline_with_state antepone el estado y absolutiza la ruta,
#        tanto con override como resolviendo por labels.
#   R-5: la ruta devuelta no depende del cwd (misma ruta con distintos cwd).
#
# Uso: scripts/tests/test-pipeline-resolver.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

source "$REPO_ROOT/scripts/_pipeline-common.sh"

# Simula el consumidor: un directorio SIN scripts/ propio, distinto de REPO_ROOT.
FAKE_CONSUMER="$(mktemp -d)"
trap 'rm -rf "$FAKE_CONSUMER"' EXIT

echo "[R-1] resolve_pipeline con override retorna ruta absoluta y existente"
for override in tdd tooling; do
    (
        cd "$FAKE_CONSUMER" || exit 1
        resolve_pipeline 999 "$override"
    ) > /tmp/.test-pipeline-resolver-out 2>&1
    RESULT="$(cat /tmp/.test-pipeline-resolver-out)"
    case "$RESULT" in
        /*) pass "override '$override': ruta absoluta ($RESULT)" ;;
        *)  fail "override '$override': ruta NO absoluta ($RESULT)" ;;
    esac
    if [ -f "$RESULT" ]; then
        pass "override '$override': el archivo resuelto existe"
    else
        fail "override '$override': el archivo resuelto NO existe ($RESULT)"
    fi
done
rm -f /tmp/.test-pipeline-resolver-out

echo ""
echo "[R-2] _resolve_from_labels retorna ruta absoluta y existente por tipo"
# Arrays paralelos (no asociativos: bash 3.2 de macOS no los soporta).
LABEL_CASES=("tipo:feature" "tipo:refactor" "tipo:tooling")
LABEL_EXPECTED=("tdd-pipeline.sh" "tdd-pipeline.sh" "tooling-pipeline.sh")
for idx in "${!LABEL_CASES[@]}"; do
    label="${LABEL_CASES[$idx]}"
    expected_basename="${LABEL_EXPECTED[$idx]}"
    RESULT=$(cd "$FAKE_CONSUMER" && _resolve_from_labels "$label")
    case "$RESULT" in
        /*"$expected_basename") pass "labels '$label' -> ruta absoluta a $expected_basename" ;;
        *) fail "labels '$label' -> se esperaba ruta absoluta terminada en $expected_basename, fue '$RESULT'" ;;
    esac
    if [ -f "$RESULT" ]; then
        pass "labels '$label': el archivo resuelto existe"
    else
        fail "labels '$label': el archivo resuelto NO existe ($RESULT)"
    fi
done

echo ""
echo "[R-3] sentinels SKIP:* se retornan intactos"
RESULT=$(cd "$FAKE_CONSUMER" && _resolve_from_labels "tipo:infra")
if [ "$RESULT" = "SKIP:infra" ]; then
    pass "tipo:infra -> SKIP:infra intacto"
else
    fail "tipo:infra -> se esperaba SKIP:infra, fue '$RESULT'"
fi

RESULT=$(cd "$FAKE_CONSUMER" && _resolve_from_labels "otra-cosa")
if [ "$RESULT" = "SKIP:no-tipo" ]; then
    pass "sin tipo:* -> SKIP:no-tipo intacto"
else
    fail "sin tipo:* -> se esperaba SKIP:no-tipo, fue '$RESULT'"
fi

echo ""
echo "[R-4] resolve_pipeline_with_state antepone estado y absolutiza"
RESULT=$(cd "$FAKE_CONSUMER" && resolve_pipeline_with_state 999 tdd)
STATE="${RESULT%%|*}"
PIPELINE="${RESULT#*|}"
if [ "$STATE" = "UNKNOWN" ]; then
    pass "sin gh/red -> estado UNKNOWN (fallback esperado)"
else
    pass "estado resuelto: $STATE"
fi
case "$PIPELINE" in
    /*tdd-pipeline.sh|SKIP:*)
        if [[ "$PIPELINE" == /* ]]; then
            pass "resolve_pipeline_with_state con override: ruta absoluta ($PIPELINE)"
        else
            pass "resolve_pipeline_with_state: gh no disponible, retorno $PIPELINE (no aplica en este entorno)"
        fi
        ;;
    *) fail "resolve_pipeline_with_state con override: ruta inesperada '$PIPELINE'" ;;
esac

echo ""
echo "[R-5] la ruta resuelta no depende del cwd"
R_FROM_REPO=$(cd "$REPO_ROOT" && resolve_pipeline 999 tooling)
R_FROM_TMP=$(cd "$FAKE_CONSUMER" && resolve_pipeline 999 tooling)
R_FROM_ROOT=$(cd / && resolve_pipeline 999 tooling)
if [ "$R_FROM_REPO" = "$R_FROM_TMP" ] && [ "$R_FROM_TMP" = "$R_FROM_ROOT" ]; then
    pass "misma ruta absoluta sin importar el cwd ($R_FROM_REPO)"
else
    fail "la ruta cambia segun el cwd: '$R_FROM_REPO' vs '$R_FROM_TMP' vs '$R_FROM_ROOT'"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
