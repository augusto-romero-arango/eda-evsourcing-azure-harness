#!/usr/bin/env bash
# test-metrics-report.sh -- Tests del reporte agregado de metricas de los
# pipelines del consumidor en el lado publicado (issue #647, porte de
# .claude/scripts/mefisto-metrics-report.sh del interno #427).
#
# Contexto: con las metricas por stage ya persistidas por #646
# (agents.<stage>.metrics en pipeline-history.jsonl del consumidor), faltaba
# la pieza publicada que las agrega en un reporte -- el mismo instrumento que
# el interno, pero generalizado a los tres pipelines del consumidor (tdd/
# tooling/infra) y a las claves de stage heterogeneas de cada uno.
#
# Metodologia de testing (dos capas, igual que .claude/scripts/tests/test-metrics-report.sh
# y scripts/tests/test-stage-metrics.sh):
#   - compute_metrics_report_json se extrae con extract_fn + eval (NO se
#     sourcea el archivo completo: tiene `set -euo pipefail` + el guard
#     defensivo top-level, igual que appinsights-query.sh) y se verifica con
#     assert_field contra numeros derivados A MANO del fixture.
#   - El resto (CLI, aborts, texto renderizado, el guard) se corre end-to-end
#     como subproceso real, dentro de un repo de mentira (git init, SIN
#     .claude-plugin/plugin.json -- justo lo opuesto del fixture del test
#     interno, que SI lo necesita) para no tocar nunca .claude/pipeline/
#     pipeline-history.jsonl del repo real.
#
# Casos cubiertos:
#   [pre] El script existe, es ejecutable, y compute_metrics_report_json se
#         puede cargar.
#   [A] Historial vacio/inexistente -> no falla, exit 0, "0" corridas (CA-3).
#   [B] Guard: corriendo dentro de un repo con .claude-plugin/plugin.json
#       (repo de Mefisto) aborta con mensaje claro en vez de leer su historial
#       interno.
#   [C] Historial mixto multi-pipeline (2 tdd instrumentados con test-writer
#       en sonnet + implementer/reviewer en opus + coverage-gate, 1 tdd
#       fallido con reviewer sin metrics, 1 tooling legado, 1 infra legado)
#       contra compute_metrics_report_json: segmentacion por pipeline (CA-1),
#       ranking de herramientas y reparto API/no-API de tdd, deriva por
#       (stage, modelo) sin mezclar sonnet/opus (CA-2), coverage-gate excluido
#       del agregado sin caso especial, y tooling/infra listados enteros bajo
#       "sin instrumentar" (CA-3/CA-5).
#   [D] El mismo historial, end-to-end: las tres secciones de pipeline
#       aparecen, tooling/infra caen a SIN INSTRUMENTAR, y la tabla "Por
#       stage" declara sonnet y opus en filas separadas.
#   [E] --desde/--hasta acotan la ventana (CA-4).
#   [F] --desde/--hasta con formato invalido, o desde > hasta -> abortan con
#       mensaje claro.
#   [G] Argumento desconocido -> aborta con mensaje claro.
#   [H] jq ausente en PATH -> aborta con mensaje claro (CA-5).
#   [I] Comparacion ventana-vs-ventana operativa con solo datos semanales
#       dentro del primer mes instrumentado, sin exigir 2 meses calendario
#       (CA-4) -- y "no hay suficientes periodos" cuando solo hay uno.
#   [J] Celdas nulas no corren las columnas (regresion de corrimiento @tsv,
#       misma clase de bug que el interno).
#
# Uso: scripts/tests/test-metrics-report.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPORT_SCRIPT="$REPO_ROOT/scripts/metrics-report.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

assert_field() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc (esperado '$expected', obtenido '$actual')"
    fi
}

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq no disponible en este entorno, no se puede correr la suite"; exit 0; }

echo "[pre] metrics-report.sh existe y es ejecutable"
if [ -x "$REPORT_SCRIPT" ]; then
    pass "el script existe y es ejecutable"
else
    fail "no existe o no es ejecutable: $REPORT_SCRIPT"
fi

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# extract_fn <function_name> <file> -- mismo patron que el test interno: no
# sourceamos metrics-report.sh completo (tiene `set -euo pipefail` + el guard
# defensivo top-level, que abortaria este mismo shell de test).
extract_fn() {
    local name="$1" file="$2"
    awk -v fn="$name" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p{print} p && /^}/{p=0}' "$file"
}

CMR_BODY=$(extract_fn "compute_metrics_report_json" "$REPORT_SCRIPT")
if [ -n "$CMR_BODY" ]; then
    eval "$CMR_BODY"
fi

if declare -F compute_metrics_report_json >/dev/null 2>&1 || [ -n "$CMR_BODY" ]; then
    pass "compute_metrics_report_json se pudo extraer y cargar"
else
    fail "no se pudo extraer/cargar compute_metrics_report_json"
fi

# --- Repo consumidor de mentira (SIN .claude-plugin/plugin.json) para las pruebas end-to-end ---
FAKE_REPO="$TMP/fake-consumer"
mkdir -p "$FAKE_REPO/.claude/pipeline"
git -C "$FAKE_REPO" init -q
cp "$REPORT_SCRIPT" "$FAKE_REPO/metrics-report.sh"
chmod +x "$FAKE_REPO/metrics-report.sh"

run_report() {
    (cd "$FAKE_REPO" && ./metrics-report.sh "$@")
}

echo ""
echo "[A] Historial vacio/inexistente -> no falla, exit 0, 0 corridas (CA-3)"

: > "$FAKE_REPO/.claude/pipeline/pipeline-history.jsonl"
OUT=$(run_report)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "Corridas totales en la ventana: 0"; then
    pass "historial vacio: exit 0 y reporta 0 corridas"
else
    fail "historial vacio: se esperaba exit 0 y '0 corridas', se obtuvo rc=$RC: $OUT"
fi

rm -f "$FAKE_REPO/.claude/pipeline/pipeline-history.jsonl"
OUT=$(run_report)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "Corridas totales en la ventana: 0"; then
    pass "historial inexistente: exit 0 y reporta 0 corridas"
else
    fail "historial inexistente: se esperaba exit 0 y '0 corridas', se obtuvo rc=$RC: $OUT"
fi

echo ""
echo "[B] Guard: repo con .claude-plugin/plugin.json (Mefisto) aborta"

FAKE_PLUGIN="$TMP/fake-plugin"
mkdir -p "$FAKE_PLUGIN/.claude-plugin"
git -C "$FAKE_PLUGIN" init -q
echo '{"name":"mefisto"}' > "$FAKE_PLUGIN/.claude-plugin/plugin.json"
cp "$REPORT_SCRIPT" "$FAKE_PLUGIN/metrics-report.sh"
chmod +x "$FAKE_PLUGIN/metrics-report.sh"
OUT=$(cd "$FAKE_PLUGIN" && ./metrics-report.sh 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "solo aplica al consumidor"; then
    pass "guard: aborta con mensaje claro dentro de un repo con plugin.json"
else
    fail "guard: se esperaba abort mencionando 'solo aplica al consumidor', se obtuvo rc=$RC: $OUT"
fi

# --- Fixture mixto multi-pipeline: 2 tdd instrumentados (sonnet en test-writer,
#     opus en implementer/reviewer, coverage-gate con su propia forma sin metrics)
#     + 1 tdd fallido (reviewer sin metrics) + 1 tooling legado + 1 infra legado.
#     Los numeros esperados en el bloque [C] se derivaron A MANO sumando estos
#     mismos campos.
cat > "$FAKE_REPO/.claude/pipeline/pipeline-history.jsonl" <<'EOF'
{"issue":"100","title":"Tooling legado","pipeline":"tooling","started":"20260505-090000","finished":"2026-05-05T09:07:00","state":"completed","agents":{"writer":{"duration":250},"reviewer":{"duration":170}},"pr":"https://github.com/x/x/pull/100"}
{"issue":"300","title":"Infra legado","pipeline":"infra","started":"20260701-100000","finished":"2026-07-01T10:05:00","state":"completed","agents":{"infra-writer":{"duration":60},"infra-reviewer":{"duration":40}},"pr":"https://github.com/x/x/pull/300"}
{"issue":"200","title":"TDD instrumentado semana1","pipeline":"tdd","started":"20260806-090000","finished":"2026-08-06T09:20:00","state":"completed","agents":{"test-writer":{"duration":320,"metrics":{"turns":8,"duration_ms":320000,"duration_api_ms":250000,"non_api_ms":70000,"cost_usd":0.45,"tokens":{"input":12000,"output":1800,"cache_read":40000,"cache_creation":6000},"model":"claude-sonnet-5","tool_calls":[{"name":"Read","count":10,"duration_ms_sum":8000,"duration_ms_median":700},{"name":"Bash","count":5,"duration_ms_sum":15000,"duration_ms_median":2500}]}},"implementer":{"duration":400,"metrics":{"turns":12,"duration_ms":400000,"duration_api_ms":300000,"non_api_ms":100000,"cost_usd":0.6,"tokens":{"input":15000,"output":2000,"cache_read":30000,"cache_creation":8000},"model":"claude-opus-5","tool_calls":[{"name":"Edit","count":6,"duration_ms_sum":6000,"duration_ms_median":900}]}},"reviewer":{"duration":220,"metrics":{"turns":5,"duration_ms":220000,"duration_api_ms":180000,"non_api_ms":40000,"cost_usd":0.30,"tokens":{"input":9000,"output":1200,"cache_read":30000,"cache_creation":4000},"model":"claude-opus-5","tool_calls":[{"name":"Read","count":6,"duration_ms_sum":4000,"duration_ms_median":650}]}},"coverage-gate":{"duration":30,"result":"clean","gaps":0,"patch_applied":false}},"pr":"https://github.com/x/x/pull/200"}
{"issue":"210","title":"TDD instrumentado semana2","pipeline":"tdd","started":"20260813-090000","finished":"2026-08-13T09:20:00","state":"completed","agents":{"test-writer":{"duration":620,"metrics":{"turns":18,"duration_ms":620000,"duration_api_ms":450000,"non_api_ms":170000,"cost_usd":0.85,"tokens":{"input":22000,"output":2800,"cache_read":50000,"cache_creation":9000},"model":"claude-sonnet-5","tool_calls":[{"name":"Read","count":14,"duration_ms_sum":11000,"duration_ms_median":700}]}},"implementer":{"duration":700,"metrics":{"turns":20,"duration_ms":700000,"duration_api_ms":500000,"non_api_ms":200000,"cost_usd":1.1,"tokens":{"input":25000,"output":3200,"cache_read":40000,"cache_creation":12000},"model":"claude-opus-5","tool_calls":[{"name":"Edit","count":10,"duration_ms_sum":9000,"duration_ms_median":800}]}},"reviewer":{"duration":260,"metrics":{"turns":7,"duration_ms":260000,"duration_api_ms":210000,"non_api_ms":50000,"cost_usd":0.35,"tokens":{"input":9500,"output":1300,"cache_read":31000,"cache_creation":4200},"model":"claude-opus-5","tool_calls":[{"name":"Read","count":7,"duration_ms_sum":4500,"duration_ms_median":600}]}},"coverage-gate":{"duration":20,"result":"clean","gaps":0,"patch_applied":false}},"pr":"https://github.com/x/x/pull/210"}
{"issue":"220","title":"TDD fallido en reviewer","pipeline":"tdd","started":"20260814-110000","finished":"2026-08-14T11:20:00","state":"failed","stage":"reviewer","agents":{"test-writer":{"duration":300,"metrics":{"turns":9,"duration_ms":300000,"duration_api_ms":230000,"non_api_ms":70000,"cost_usd":0.4,"tokens":{"input":11000,"output":1600,"cache_read":38000,"cache_creation":5000},"model":"claude-sonnet-5","tool_calls":[{"name":"Bash","count":4,"duration_ms_sum":11000,"duration_ms_median":2200}]}},"implementer":{"duration":null,"metrics":null},"reviewer":{"duration":null,"metrics":null},"coverage-gate":{"duration":null,"result":"n/a","gaps":0,"patch_applied":false}},"error":"timeout"}
EOF

echo ""
echo "[C] Historial mixto multi-pipeline contra compute_metrics_report_json (numeros a mano)"

AGG=$(compute_metrics_report_json "$FAKE_REPO/.claude/pipeline/pipeline-history.jsonl" "" "")

echo "  -- segmentacion por pipeline (CA-1) --"
assert_field "C-1: tdd.meta.total (3 corridas)" "3" "$(echo "$AGG" | jq -r '.pipelines.tdd.meta.total')"
assert_field "C-2: tdd.meta.instrumented (las 3 traen al menos un stage con metrics)" "3" "$(echo "$AGG" | jq -r '.pipelines.tdd.meta.instrumented')"
assert_field "C-3: tooling.meta.total" "1" "$(echo "$AGG" | jq -r '.pipelines.tooling.meta.total')"
assert_field "C-4: tooling.meta.instrumented (legado, sin metrics)" "0" "$(echo "$AGG" | jq -r '.pipelines.tooling.meta.instrumented')"
assert_field "C-5: infra.meta.total" "1" "$(echo "$AGG" | jq -r '.pipelines.infra.meta.total')"
assert_field "C-6: infra.meta.instrumented (legado, sin metrics)" "0" "$(echo "$AGG" | jq -r '.pipelines.infra.meta.instrumented')"

echo "  -- ranking de herramientas de tdd (CA-1) --"
# Read: 200:tw10+rv6 + 210:tw14+rv7 + 220:0 = 37
assert_field "C-7: tdd Read calls" "37" "$(echo "$AGG" | jq -r '.pipelines.tdd.tool_ranking[] | select(.name=="Read") | .calls')"
# Bash: 200:tw5 + 220:tw4 = 9
assert_field "C-8: tdd Bash calls" "9" "$(echo "$AGG" | jq -r '.pipelines.tdd.tool_ranking[] | select(.name=="Bash") | .calls')"

echo "  -- reparto API/no-API de tdd, sumando TODAS las claves presentes por corrida (no solo writer/reviewer) --"
# api_ms 200: 250000(tw)+300000(im)+180000(rv) = 730000 ; 210: 450000+500000+210000=1160000 ; 220: 230000(tw solo)=230000
# total = 730000+1160000+230000 = 2120000
assert_field "C-9: tdd wallclock.aggregate.api_ms suma test-writer+implementer+reviewer" "2120000" "$(echo "$AGG" | jq -r '.pipelines.tdd.wallclock.aggregate.api_ms')"

echo "  -- coverage-gate excluido del agregado sin nombrarlo (su forma no tiene 'metrics') --"
if echo "$AGG" | jq -e '.pipelines.tdd.wallclock.by_stage | map(.stage) | index("coverage-gate") == null' >/dev/null 2>&1; then
    pass "C-10: coverage-gate no aparece en la tabla por-stage"
else
    fail "C-10: coverage-gate aparecio en by_stage, deberia quedar fuera por no tener 'metrics'"
fi

echo "  -- deriva por (stage, modelo): sonnet y opus nunca se mezclan en una fila (CA-2) --"
assert_field "C-11: test-writer corre en sonnet (fila propia)" "claude-sonnet-5" "$(echo "$AGG" | jq -r '.pipelines.tdd.wallclock.by_stage[] | select(.stage=="test-writer") | .model')"
assert_field "C-12: test-writer.n (3 corridas, todas con test-writer instrumentado)" "3" "$(echo "$AGG" | jq -r '.pipelines.tdd.wallclock.by_stage[] | select(.stage=="test-writer") | .n')"
# turnos test-writer: 8+18+9=35/3=11.666... -> jq imprime 11.666666666666666, comparamos con awk
TW_TURNS=$(echo "$AGG" | jq -r '.pipelines.tdd.wallclock.by_stage[] | select(.stage=="test-writer") | .turns_mean')
if awk -v v="$TW_TURNS" 'BEGIN{exit !(v > 11.6 && v < 11.7)}'; then
    pass "C-13: test-writer.turns_mean ~= 11.67 (35/3)"
else
    fail "C-13: se esperaba ~11.67, se obtuvo $TW_TURNS"
fi
assert_field "C-14: reviewer corre en opus" "claude-opus-5" "$(echo "$AGG" | jq -r '.pipelines.tdd.wallclock.by_stage[] | select(.stage=="reviewer") | .model')"
assert_field "C-15: reviewer.n (2 -- 220 murio antes del reviewer)" "2" "$(echo "$AGG" | jq -r '.pipelines.tdd.wallclock.by_stage[] | select(.stage=="reviewer") | .n')"
# Solo debe existir UNA fila para test-writer (un solo modelo observado) y UNA para reviewer.
assert_field "C-16: una sola fila de test-writer (un unico modelo, sin split espurio)" "1" "$(echo "$AGG" | jq -r '[.pipelines.tdd.wallclock.by_stage[] | select(.stage=="test-writer")] | length')"

echo "  -- sin instrumentar (CA-3/CA-5): tooling/infra legados completos --"
assert_field "C-17: tooling.legacy.count" "1" "$(echo "$AGG" | jq -r '.pipelines.tooling.legacy.count')"
assert_field "C-18: tooling.legacy incluye issue 100" "100" "$(echo "$AGG" | jq -r '.pipelines.tooling.legacy.issues[0].issue')"
assert_field "C-19: infra.legacy incluye issue 300" "300" "$(echo "$AGG" | jq -r '.pipelines.infra.legacy.issues[0].issue')"
assert_field "C-20: tdd.legacy.count (las 3 traen algun stage con metrics)" "0" "$(echo "$AGG" | jq -r '.pipelines.tdd.legacy.count')"

echo ""
echo "[D] El mismo historial mixto, end-to-end (texto renderizado real)"

OUT=$(run_report)
RC=$?

if [ "$RC" -eq 0 ]; then
    pass "D-1: exit 0 con historial mixto multi-pipeline"
else
    fail "D-1: se esperaba exit 0, se obtuvo rc=$RC"
fi

if echo "$OUT" | grep -q "PIPELINE: tdd " && echo "$OUT" | grep -q "PIPELINE: tooling " && echo "$OUT" | grep -q "PIPELINE: infra "; then
    pass "D-2: las tres secciones de pipeline aparecen (tdd/tooling/infra)"
else
    fail "D-2: falta alguna seccion de pipeline: $(echo "$OUT" | grep '^PIPELINE:')"
fi

if echo "$OUT" | awk '/PIPELINE: tooling/,/PIPELINE: infra/' | grep -q "SIN INSTRUMENTAR (n=1"; then
    pass "D-3: la seccion tooling cae a SIN INSTRUMENTAR con n=1"
else
    fail "D-3: no se encontro SIN INSTRUMENTAR (n=1) dentro de la seccion tooling"
fi

if echo "$OUT" | awk '/PIPELINE: tdd/,/PIPELINE: tooling/' | grep -qE 'test-writer +claude-sonnet-5' \
   && echo "$OUT" | awk '/PIPELINE: tdd/,/PIPELINE: tooling/' | grep -qE 'reviewer +claude-opus-5'; then
    pass "D-4: la tabla 'Por stage' de tdd declara sonnet y opus en filas separadas"
else
    fail "D-4: no se encontraron las filas esperadas de test-writer/reviewer con su modelo"
fi

echo ""
echo "[E] --desde/--hasta acotan la ventana (CA-4)"

OUT=$(run_report --desde 2026-08-01 --hasta 2026-08-10)
if echo "$OUT" | grep -q "Corridas totales en la ventana: 1"; then
    pass "E-1: --desde 2026-08-01 --hasta 2026-08-10 deja solo la corrida #200"
else
    fail "E-1: se esperaba 1 corrida en la ventana, se obtuvo: $(echo "$OUT" | grep 'Corridas totales')"
fi

echo ""
echo "[F] Fechas invalidas o invertidas -> abortan con mensaje claro"

OUT=$(run_report --desde 2026/08/01 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "YYYY-MM-DD"; then
    pass "F-1: --desde con formato invalido aborta mencionando el formato esperado"
else
    fail "F-1: se esperaba abort, se obtuvo rc=$RC: $OUT"
fi

OUT=$(run_report --hasta 2026-08 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "YYYY-MM-DD"; then
    pass "F-2: --hasta con formato invalido aborta mencionando el formato esperado"
else
    fail "F-2: se esperaba abort, se obtuvo rc=$RC: $OUT"
fi

OUT=$(run_report --desde 2026-08-01 --hasta 2026-01-01 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "posterior"; then
    pass "F-3: --desde posterior a --hasta aborta con mensaje claro"
else
    fail "F-3: se esperaba abort, se obtuvo rc=$RC: $OUT"
fi

echo ""
echo "[G] Argumento desconocido -> aborta con mensaje claro"

OUT=$(run_report --no-existe 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "argumento desconocido"; then
    pass "G-1: argumento desconocido aborta con mensaje claro"
else
    fail "G-1: se esperaba abort, se obtuvo rc=$RC: $OUT"
fi

echo ""
echo "[H] jq ausente en PATH -> aborta con mensaje claro (CA-5)"

FAKE_BIN="$TMP/fake-bin"
mkdir -p "$FAKE_BIN"
for dir in /usr/bin /bin /usr/local/bin /opt/homebrew/bin; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        [ "$name" = "jq" ] && continue
        [ -e "$FAKE_BIN/$name" ] && continue
        ln -s "$f" "$FAKE_BIN/$name" 2>/dev/null || true
    done
done

OUT=$(cd "$FAKE_REPO" && PATH="$FAKE_BIN" ./metrics-report.sh 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "requiere jq"; then
    pass "H-1: jq ausente aborta con mensaje claro (rc=$RC)"
else
    fail "H-1: se esperaba abort mencionando jq, se obtuvo rc=$RC: $OUT"
fi

echo ""
echo "[I] Comparacion operativa con solo datos semanales del primer mes instrumentado (CA-4)"

# Todo dentro de 2026-08 (un solo mes calendario, lo que el interno NO podia
# comparar): #200 semana W32, #210 y #220 semana W33 -- ya hay 2 semanas.
AGG_I=$(compute_metrics_report_json "$FAKE_REPO/.claude/pipeline/pipeline-history.jsonl" "2026-08-01" "2026-08-31")
assert_field "I-1: granularidad semanal (sin exigir 2 meses calendario)" "semanal" "$(echo "$AGG_I" | jq -r '.pipelines.tdd.comparison.granularity')"
assert_field "I-2: primer periodo comparado es la semana W32" "2026-W32" "$(echo "$AGG_I" | jq -r '.pipelines.tdd.comparison.first.period')"
assert_field "I-3: ultimo periodo comparado es la semana W33" "2026-W33" "$(echo "$AGG_I" | jq -r '.pipelines.tdd.comparison.last.period')"

AGG_I2=$(compute_metrics_report_json "$FAKE_REPO/.claude/pipeline/pipeline-history.jsonl" "2026-08-06" "2026-08-06")
assert_field "I-4: con un solo periodo en la ventana, no hay comparacion posible" "null" "$(echo "$AGG_I2" | jq -r '.pipelines.tdd.comparison')"

echo ""
echo "[J] Celdas nulas no corren las columnas (regresion de corrimiento por @tsv)"

cat > "$FAKE_REPO/.claude/pipeline/pipeline-history.jsonl" <<'EOF'
{"issue":"400","title":"Read sin mediana derivable","pipeline":"tdd","started":"20260806-090000","state":"completed","agents":{"test-writer":{"duration":100,"metrics":{"turns":3,"duration_ms":100000,"duration_api_ms":80000,"non_api_ms":20000,"cost_usd":0.1,"tokens":{"input":1000,"output":100,"cache_read":900,"cache_creation":100},"model":"claude-sonnet-5","tool_calls":[{"name":"Read","count":10,"duration_ms_sum":8000,"duration_ms_median":null},{"name":"Bash","count":5,"duration_ms_sum":15000,"duration_ms_median":2500}]}},"reviewer":{"duration":null,"metrics":null}}}
EOF
OUT=$(run_report)
# Bash 15000/(15000+8000)=65.2% ; Read 8000/23000=34.8%
if echo "$OUT" | grep -qE '^Read +10 +8\.0s +- +34\.8%'; then
    pass "J-1: mediana nula -> '-' en su columna y el % en la suya (sin corrimiento)"
else
    fail "J-1: fila de Read corrida o mal formada: $(echo "$OUT" | grep '^Read' || echo '(no hay fila Read)')"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
