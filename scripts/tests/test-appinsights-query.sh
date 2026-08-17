#!/usr/bin/env bash
# test-appinsights-query.sh -- Tests de run_query en scripts/appinsights-query.sh
# (issue #649: distinguir consulta vacia de consulta fallida).
#
# Cubre:
#   CA-1: run_query ya no usa --output table (grep sobre el script real).
#   CA-2: 0 filas -> mensaje de "resultado vacio" distinguible, exit 0.
#   CA-3: JSON con forma inesperada (.tables[0].rows ausente/no-array) -> avería,
#         exit distinto de 0.
#   CA-4: con filas presentes, la salida es tabular y legible (sin JSON crudo).
#
# El script real arranca con un guard que aborta si detecta
# .claude-plugin/plugin.json en la raiz del repo (este es justamente ese repo).
# Por eso se corre como subproceso real dentro de un repo de mentira (git init,
# SIN ese archivo) -- mismo patron que test-metrics-report.sh -- con un stub de
# `az` en el PATH que responde segun AZ_STUB_SCENARIO, sin depender de una
# sesion real de Azure CLI ni de un App Insights real.
#
# Uso: scripts/tests/test-appinsights-query.sh
# Exit code: 0 si todos los checks pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAL_SCRIPT="$REPO_ROOT/scripts/appinsights-query.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "[CA-1] run_query no usa --output table"

if grep -n 'output table' "$REAL_SCRIPT" >/dev/null; then
    fail "todavia queda una ocurrencia de 'output table' en appinsights-query.sh"
else
    pass "ninguna ocurrencia de 'output table' en appinsights-query.sh"
fi

echo ""
echo "[Arnes] repo de mentira sin plugin.json + stub de az"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAKE_REPO="$TMP/fake-consumer"
mkdir -p "$FAKE_REPO/scripts"
git -C "$FAKE_REPO" init -q
cp "$REAL_SCRIPT" "$FAKE_REPO/scripts/appinsights-query.sh"
chmod +x "$FAKE_REPO/scripts/appinsights-query.sh"
cat > "$FAKE_REPO/scripts/.env" <<'EOF'
APPINSIGHTS_APP=fake-app
APPINSIGHTS_RG=fake-rg
EOF

STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"

# Stub de az: responde "account show" siempre OK, y "monitor app-insights
# query" segun el escenario en AZ_STUB_SCENARIO -- filas con datos, cero filas
# (vacio legitimo), una respuesta que no parsea como JSON, o JSON valido con
# .tables[0].rows presente pero de tipo incorrecto (ambas son averia, no vacio).
cat > "$STUB_BIN/az" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "account" ] && [ "$2" = "show" ]; then
    echo '{}'
    exit 0
fi
if [ "$1" = "monitor" ] && [ "$2" = "app-insights" ] && [ "$3" = "query" ]; then
    case "${AZ_STUB_SCENARIO:-rows}" in
        rows)
            echo '{"tables":[{"columns":[{"name":"type"},{"name":"count_"}],"name":"PrimaryResult","rows":[["System.TimeoutException",13],["System.NullReferenceException",2]]}]}'
            exit 0
            ;;
        empty)
            echo '{"tables":[{"columns":[{"name":"type"},{"name":"count_"}],"name":"PrimaryResult","rows":[]}]}'
            exit 0
            ;;
        corrupt)
            echo 'esto no es JSON valido'
            exit 0
            ;;
        bad-shape)
            echo '{"tables":[{"columns":[{"name":"type"}],"rows":"no-es-un-array"}]}'
            exit 0
            ;;
    esac
fi
exit 0
STUB
chmod +x "$STUB_BIN/az"

run_fake() {
    ( cd "$FAKE_REPO" && PATH="$STUB_BIN:$PATH" "$@" )
}

echo ""
echo "[CA-2] 0 filas -> mensaje de resultado vacio distinguible, exit 0"

OUT_EMPTY=$(AZ_STUB_SCENARIO=empty run_fake ./scripts/appinsights-query.sh custom "exceptions | where timestamp > ago(1h) | where type == 'NoExisteEsteTipo'" 2>&1)
RC_EMPTY=$?

if [ "$RC_EMPTY" -eq 0 ]; then
    pass "custom con 0 filas termina con exit 0"
else
    fail "custom con 0 filas termino con exit $RC_EMPTY (esperado 0)"
fi

if echo "$OUT_EMPTY" | grep -q "Resultado vacio"; then
    pass "custom con 0 filas imprime el mensaje de resultado vacio"
else
    fail "custom con 0 filas no imprimio el mensaje de resultado vacio. Salida: $OUT_EMPTY"
fi

if echo "$OUT_EMPTY" | grep -q "Consulta completada"; then
    fail "custom con 0 filas imprimio el mensaje de exito generico (indistinguible de un resultado con datos)"
else
    pass "custom con 0 filas NO imprime el mensaje de exito generico"
fi

echo ""
echo "[CA-3] JSON con forma inesperada -> averia, exit distinto de 0"

OUT_CORRUPT=$(AZ_STUB_SCENARIO=corrupt run_fake ./scripts/appinsights-query.sh exceptions 2>&1)
RC_CORRUPT=$?

if [ "$RC_CORRUPT" -ne 0 ]; then
    pass "respuesta que no parsea como JSON esperado termina con exit distinto de 0 (fue $RC_CORRUPT)"
else
    fail "respuesta que no parsea como JSON esperado termino con exit 0 (deberia fallar)"
fi

if echo "$OUT_CORRUPT" | grep -qi "ERROR"; then
    pass "respuesta corrupta reporta un mensaje de ERROR"
else
    fail "respuesta corrupta no reporto ningun mensaje de ERROR. Salida: $OUT_CORRUPT"
fi

# Ademas de la ausencia total de "tables" (escenario "corrupt" de mas arriba),
# un JSON valido con .tables[0].rows presente pero de tipo incorrecto (no
# array) tambien debe tratarse como averia, no como resultado vacio.
OUT_BADSHAPE=$(AZ_STUB_SCENARIO=bad-shape run_fake ./scripts/appinsights-query.sh exceptions 2>&1)
RC_BADSHAPE=$?

if [ "$RC_BADSHAPE" -ne 0 ]; then
    pass ".tables[0].rows de tipo incorrecto termina con exit distinto de 0 (fue $RC_BADSHAPE)"
else
    fail ".tables[0].rows de tipo incorrecto termino con exit 0 (deberia fallar, no reportarse como vacio)"
fi

if echo "$OUT_BADSHAPE" | grep -q "Resultado vacio"; then
    fail ".tables[0].rows de tipo incorrecto se reporto como resultado vacio legitimo"
else
    pass ".tables[0].rows de tipo incorrecto NO se confunde con un resultado vacio legitimo"
fi

echo ""
echo "[CA-4] con filas presentes, la salida es tabular y legible"

OUT_ROWS=$(AZ_STUB_SCENARIO=rows run_fake ./scripts/appinsights-query.sh exceptions 2>&1)
RC_ROWS=$?

if [ "$RC_ROWS" -eq 0 ]; then
    pass "exceptions con filas termina con exit 0"
else
    fail "exceptions con filas termino con exit $RC_ROWS (esperado 0)"
fi

if echo "$OUT_ROWS" | grep -qE '^type +count_$'; then
    pass "la salida tiene un encabezado 'type   count_' alineado con espacios (column -t)"
else
    fail "no se encontro el encabezado tabular esperado. Salida: $OUT_ROWS"
fi

if echo "$OUT_ROWS" | grep -qE '^System\.TimeoutException +13$'; then
    pass "una fila con datos aparece alineada con column -t"
else
    fail "no se encontro la fila de datos esperada alineada. Salida: $OUT_ROWS"
fi

if echo "$OUT_ROWS" | grep -q '{"tables"'; then
    fail "la salida con filas presentes filtro JSON crudo en vez de la tabla formateada"
else
    pass "la salida con filas presentes no filtra JSON crudo"
fi

if echo "$OUT_ROWS" | grep -q "Consulta completada (2 filas)"; then
    pass "el mensaje de exito reporta el conteo real de filas"
else
    fail "no se encontro el mensaje de exito con conteo de filas. Salida: $OUT_ROWS"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
