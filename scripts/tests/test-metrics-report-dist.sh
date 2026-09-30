#!/usr/bin/env bash
# test-metrics-report-dist.sh -- metrics-report.sh viaja en la clausura
# publicada (issue #1683, MEF-ADR-0053): dist/opencode lo trae identico y
# ejecutable, y corre sobre un historial con filas claude y opencode
# (tokens nulos) produciendo un reporte segmentado por runtime.
#
# Uso: scripts/tests/test-metrics-report-dist.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq no disponible"; exit 0; }

for dist in claude opencode; do
    D="$REPO_ROOT/dist/$dist/scripts/metrics-report.sh"
    echo "[$dist] distribucion"
    if [ -x "$D" ]; then pass "dist/$dist/scripts/metrics-report.sh existe y es ejecutable"; else fail "falta o no ejecutable: $D"; fi
    if cmp -s "$D" "$REPO_ROOT/scripts/metrics-report.sh"; then pass "identico al fuente"; else fail "difiere del fuente"; fi
    if jq -e '.assets[] | select(.destination == "scripts/metrics-report.sh")' "$REPO_ROOT/dist/$dist/.mefisto-generated-assets.json" >/dev/null 2>&1; then
        pass "registrado en .mefisto-generated-assets.json"
    else
        fail "ausente del inventario de $dist"
    fi
done

echo "[run] dist/opencode corre sobre un repo temporal"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/consumer"
mkdir -p "$FAKE/.claude/pipeline"
git -C "$FAKE" init -q
cp "$REPO_ROOT/dist/opencode/scripts/metrics-report.sh" "$REPO_ROOT/dist/opencode/scripts/_pipeline-common.sh" "$FAKE/"
chmod +x "$FAKE/metrics-report.sh"
cat > "$FAKE/.claude/pipeline/pipeline-history.jsonl" <<'JSONL'
{"issue":"1","pipeline":"tdd","started":"20260901-090000","state":"completed","runtime":"claude","agents":{"implementer":{"duration":60,"metrics":{"turns":5,"duration_ms":60000,"duration_api_ms":50000,"non_api_ms":10000,"cost_usd":0.5,"tokens":{"input":100,"output":50},"model":"opus","tool_calls":[{"name":"Read","count":2}]}}}}
{"issue":"2","pipeline":"tdd","started":"20260902-090000","state":"completed","runtime":"opencode","agents":{"implementer":{"duration":70,"metrics":{"turns":6,"duration_ms":70000,"duration_api_ms":60000,"non_api_ms":10000,"cost_usd":null,"tokens":null,"model":"modelo-abierto","tool_calls":[{"name":"read","count":3}]}}}}
JSONL
OUT=$(cd "$FAKE" && ./metrics-report.sh 2>&1)
RC=$?
[ "$RC" -eq 0 ] && pass "exit 0" || fail "exit $RC: $OUT"
echo "$OUT" | grep -q "Corridas totales en la ventana: 2" && pass "cuenta las 2 corridas" || fail "no cuenta 2 corridas"
echo "$OUT" | grep -q "tdd .*2 corridas (instrumentadas: 2" && pass "ambas filas (claude y opencode con tokens null) cuentan como instrumentadas" || fail "sin seccion tdd con 2 instrumentadas"
# El reporte no tiene eje literal "runtime": la fila de cada runtime se
# distingue por su modelo declarado en la tabla "Por stage".
echo "$OUT" | grep -Eq "^implementer +- +opus " && pass "fila del stage para la corrida claude" || fail "falta la fila opus (claude) en Por stage"
echo "$OUT" | grep -Eq "^implementer +- +modelo-abierto " && pass "fila del stage para la corrida opencode (tokens null)" || fail "falta la fila modelo-abierto (opencode) en Por stage"

echo ""
echo "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
