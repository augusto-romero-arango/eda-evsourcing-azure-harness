#!/usr/bin/env bash
# test-appinsights-query.sh -- Tests de run_query en scripts/appinsights-query.sh
# (issue #649: distinguir consulta vacia de consulta fallida).
#
# Cubre:
#   CA-1: run_query ya no usa --output table (grep sobre el script real).
#   CA-2: 0 filas -> mensaje de "resultado vacio" distinguible, exit 0.
#   CA-3: JSON con forma inesperada (.tables[0].rows/.columns ausente o de tipo
#         incorrecto) -> averia, exit distinto de 0.
#   CA-4: con filas presentes, la salida es tabular y legible (sin JSON crudo),
#         incluyendo los dos casos que rompen un @tsv ingenuo: columnas
#         'dynamic' de App Insights (objetos/arrays) y celdas vacias, que el
#         column de BSD colapsa desalineando la tabla.
#   Extra: si falta jq, el error nombra la dependencia local en vez de culpar a
#         la respuesta de az (el falso diagnostico que este issue combate).
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
skip() { echo "  SKIP: $1"; }

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
# (vacio legitimo), una respuesta que no parsea como JSON, JSON valido con
# .tables[0].rows de tipo incorrecto o sin .columns (todas averia, no vacio), y
# los dos casos de formato: una columna 'dynamic' con un objeto/array anidado y
# una fila con celdas vacias.
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
        no-columns)
            echo '{"tables":[{"name":"PrimaryResult","rows":[["System.TimeoutException",13]]}]}'
            exit 0
            ;;
        dynamic)
            echo '{"tables":[{"columns":[{"name":"type"},{"name":"details"}],"name":"PrimaryResult","rows":[["System.TimeoutException",[{"message":"Npgsql timeout","parsedStack":"at Marten"}]]]}]}'
            exit 0
            ;;
        empty-cell)
            echo '{"tables":[{"columns":[{"name":"aaa"},{"name":"bbb"},{"name":"ccc"}],"name":"PrimaryResult","rows":[["x1",null,"z1"],["x2","y2","z2"]]}]}'
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

# El formateador lee .tables[0].columns[].name: si esa clave falta, jq aborta a
# mitad del pipe. El guard debe atajarlo antes, con mensaje propio.
OUT_NOCOLS=$(AZ_STUB_SCENARIO=no-columns run_fake ./scripts/appinsights-query.sh exceptions 2>&1)
RC_NOCOLS=$?

if [ "$RC_NOCOLS" -ne 0 ]; then
    pass "respuesta sin .tables[0].columns termina con exit distinto de 0 (fue $RC_NOCOLS)"
else
    fail "respuesta sin .tables[0].columns termino con exit 0 (deberia fallar)"
fi

if echo "$OUT_NOCOLS" | grep -q "no tiene la forma esperada"; then
    pass "respuesta sin .tables[0].columns reporta el mensaje de forma inesperada del script"
else
    fail "respuesta sin .tables[0].columns no reporto el mensaje del script. Salida: $OUT_NOCOLS"
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

# Las columnas 'dynamic' de App Insights (details, customDimensions) traen
# objetos y arrays. @tsv los rechaza y aborta la fila entera -- justo la que
# lleva el stack trace que motivo este issue.
OUT_DYN=$(AZ_STUB_SCENARIO=dynamic run_fake ./scripts/appinsights-query.sh exceptions 2>&1)
RC_DYN=$?

if [ "$RC_DYN" -eq 0 ]; then
    pass "una columna dynamic (objeto/array anidado) no rompe la consulta"
else
    fail "una columna dynamic termino con exit $RC_DYN (esperado 0). Salida: $OUT_DYN"
fi

if echo "$OUT_DYN" | grep -q "Npgsql timeout"; then
    pass "el contenido de la columna dynamic se conserva en la salida"
else
    fail "se perdio el contenido de la columna dynamic. Salida: $OUT_DYN"
fi

if echo "$OUT_DYN" | grep -qi "not valid in a csv row"; then
    fail "jq aborto por la columna dynamic en vez de serializarla"
else
    pass "jq no aborta por la columna dynamic"
fi

# Una celda vacia produce dos tabs seguidos; el column de BSD (macOS) los
# colapsa y corre las columnas siguientes una posicion a la izquierda.
OUT_CELL=$(AZ_STUB_SCENARIO=empty-cell run_fake ./scripts/appinsights-query.sh exceptions 2>&1)
RC_CELL=$?

if [ "$RC_CELL" -eq 0 ]; then
    pass "una fila con celda vacia termina con exit 0"
else
    fail "una fila con celda vacia termino con exit $RC_CELL (esperado 0). Salida: $OUT_CELL"
fi

if echo "$OUT_CELL" | grep -qE '^x1 +[^ ]+ +z1$'; then
    pass "la celda vacia mantiene alineada la columna siguiente (z1 bajo 'ccc')"
else
    fail "la celda vacia desalineo la fila. Salida: $OUT_CELL"
fi

echo ""
echo "[Extra] jq ausente -> error que nombra la dependencia, no la respuesta de az"

# PATH minimo SIN jq. Se usa un stub de git para no depender del shim de Xcode,
# que no sobrevive a un PATH recortado.
NOJQ_BIN="$TMP/nojq-bin"
mkdir -p "$NOJQ_BIN"
cp "$STUB_BIN/az" "$NOJQ_BIN/az"
cat > "$NOJQ_BIN/git" <<'GITSTUB'
#!/usr/bin/env bash
if [ "$1" = "rev-parse" ]; then
    echo "$FAKE_REPO_PATH"
    exit 0
fi
exit 0
GITSTUB
chmod +x "$NOJQ_BIN/git"

MISSING_TOOLS=""
for b in bash env date dirname column; do
    p=$(command -v "$b" 2>/dev/null) || p=""
    if [ -n "$p" ]; then
        ln -sf "$p" "$NOJQ_BIN/$b"
    else
        MISSING_TOOLS="$MISSING_TOOLS $b"
    fi
done

if [ -n "$MISSING_TOOLS" ]; then
    skip "no se pudo armar el PATH minimo (falta:$MISSING_TOOLS)"
else
    OUT_NOJQ=$( cd "$FAKE_REPO" && AZ_STUB_SCENARIO=rows FAKE_REPO_PATH="$FAKE_REPO" PATH="$NOJQ_BIN" ./scripts/appinsights-query.sh exceptions 2>&1 )
    RC_NOJQ=$?

    if [ "$RC_NOJQ" -ne 0 ]; then
        pass "sin jq en el PATH el script termina con exit distinto de 0 (fue $RC_NOJQ)"
    else
        fail "sin jq en el PATH el script termino con exit 0. Salida: $OUT_NOJQ"
    fi

    if echo "$OUT_NOJQ" | grep -q "jq"; then
        pass "el error nombra la dependencia jq"
    else
        fail "el error no nombra jq. Salida: $OUT_NOJQ"
    fi

    if echo "$OUT_NOJQ" | grep -q "no tiene la forma esperada"; then
        fail "sin jq el script culpa a la respuesta de az en vez de a la dependencia local"
    else
        pass "sin jq el script NO culpa a la respuesta de az"
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
