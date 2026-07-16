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
#        tanto con override como resolviendo por labels. El override se honra
#        incluso si gh falla (issue #291): el estado queda UNKNOWN (honesto,
#        sin fingir OPEN) pero el pipeline forzado se retorna igual; sin
#        override y con gh fallando se preserva el fallback UNKNOWN|SKIP:no-tipo;
#        y un override desconocido sigue siendo error aunque gh falle.
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
    RESULT=$(cd "$FAKE_CONSUMER" && resolve_pipeline 999 "$override")
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
echo "[R-4] resolve_pipeline_with_state antepone estado y absolutiza (gh mockeado)"
# batch-pipeline.sh y parallel-pipeline.sh usan ESTA funcion (no resolve_pipeline
# directo), asi que es el call-site exacto del bug #289. gh se mockea para
# exografiar la ruta de forma determinista, sin red ni un issue real: el mock
# emite el mismo formato "STATE|label\nlabel..." que gh produce tras aplicar -q.

# Via override: antepone el estado y absolutiza el pipeline forzado.
RESULT=$(cd "$FAKE_CONSUMER" && { gh() { echo "OPEN|tipo:feature"; }; resolve_pipeline_with_state 999 tooling; })
STATE="${RESULT%%|*}"
PIPELINE="${RESULT#*|}"
if [ "$STATE" = "OPEN" ]; then
    pass "override: estado antepuesto ($STATE)"
else
    fail "override: se esperaba estado OPEN, fue '$STATE'"
fi
case "$PIPELINE" in
    /*tooling-pipeline.sh) pass "override: ruta absoluta a tooling-pipeline.sh ($PIPELINE)" ;;
    *) fail "override: se esperaba ruta absoluta a tooling-pipeline.sh, fue '$PIPELINE'" ;;
esac
if [ -f "$PIPELINE" ]; then
    pass "override: el archivo resuelto existe"
else
    fail "override: el archivo resuelto NO existe ($PIPELINE)"
fi

# Via labels (sin override): resuelve por label y absolutiza igual.
RESULT=$(cd "$FAKE_CONSUMER" && { gh() { echo "OPEN|tipo:feature"; }; resolve_pipeline_with_state 999; })
STATE="${RESULT%%|*}"
PIPELINE="${RESULT#*|}"
case "$PIPELINE" in
    /*tdd-pipeline.sh) pass "labels: estado $STATE + ruta absoluta a tdd-pipeline.sh ($PIPELINE)" ;;
    *) fail "labels: se esperaba ruta absoluta a tdd-pipeline.sh, fue '$PIPELINE'" ;;
esac

# Override con gh fallando: el override se sigue honrando (issue #291) -- el
# estado queda UNKNOWN (honesto) pero el pipeline forzado no se pierde.
for override_gh_fail in tdd tooling; do
    expected_basename="tdd-pipeline.sh"
    [ "$override_gh_fail" = "tooling" ] && expected_basename="tooling-pipeline.sh"
    RESULT=$(cd "$FAKE_CONSUMER" && { gh() { return 1; }; resolve_pipeline_with_state 999 "$override_gh_fail"; })
    STATE="${RESULT%%|*}"
    PIPELINE="${RESULT#*|}"
    if [ "$STATE" = "UNKNOWN" ]; then
        pass "override '$override_gh_fail' + gh falla: estado UNKNOWN (honesto, sin fingir OPEN)"
    else
        fail "override '$override_gh_fail' + gh falla: se esperaba estado UNKNOWN, fue '$STATE'"
    fi
    case "$PIPELINE" in
        /*"$expected_basename") pass "override '$override_gh_fail' + gh falla: override honrado, ruta absoluta a $expected_basename ($PIPELINE)" ;;
        *) fail "override '$override_gh_fail' + gh falla: se esperaba ruta absoluta a $expected_basename, fue '$PIPELINE'" ;;
    esac
done

# Sin override y gh fallando: se preserva el fallback UNKNOWN|SKIP:no-tipo byte a byte.
RESULT=$(cd "$FAKE_CONSUMER" && { gh() { return 1; }; resolve_pipeline_with_state 999; })
if [ "$RESULT" = "UNKNOWN|SKIP:no-tipo" ]; then
    pass "sin override + gh falla -> UNKNOWN|SKIP:no-tipo (fallback intacto)"
else
    fail "sin override + gh falla -> se esperaba UNKNOWN|SKIP:no-tipo, fue '$RESULT'"
fi

# Override desconocido: error aunque gh falle (el contrato de override invalido
# no debe quedar enmascarado por el fallback de gh).
RESULT=$(cd "$FAKE_CONSUMER" && { gh() { return 1; }; resolve_pipeline_with_state 999 foo; } 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$RESULT" | grep -q "ERROR: override desconocido 'foo'"; then
    pass "override desconocido 'foo' + gh falla -> ERROR y return != 0"
else
    fail "override desconocido 'foo' + gh falla -> se esperaba ERROR y return != 0, fue rc=$RC '$RESULT'"
fi

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
