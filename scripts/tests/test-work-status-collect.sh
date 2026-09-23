#!/usr/bin/env bash
# test-work-status-collect.sh -- Tests de scripts/work-status-collect.sh
# (issue #1597): consolidacion deterministica del estado de los pipelines del
# consumidor, con fallback legacy de solo lectura (MEF-ADR-0053 seccion 4).
#
# Cada caso arma su propio par de roots (canonico/legacy) en un temporal,
# sobreescribiendo MEFISTO_STATE_DIR/MEFISTO_LEGACY_STATE_DIR (el mismo
# mecanismo de override que _pipeline-common.sh ya documenta para fixtures) y
# corre el script como subproceso real, nunca sourceado.
#
# Casos cubiertos (CA-5):
#   [1]  CA-1: --json obligatorio; cualquier otro argumento sale con 2.
#   [2]  CA-1: sin ningun estado -- JSON valido, exit 0, empty.status/history
#        en true, rows/history vacios.
#   [3]  CA-2: misma clave en los dos roots -- gana el canonico.
#   [4]  CA-2: status disjuntos -- se conservan ambos, con su origen.
#   [5]  CA-2: formato antiguo sin pipeline/variant/runtime -- se infiere
#        pipeline "tdd", variant/runtime quedan null.
#   [6]  CA-3: hold estructurado -- activity toma cause/next_probe/ceiling
#        del propio status, con prioridad sobre stale.
#   [7]  CA-3: hold textual con UNA fila legacy running elegible -- se
#        traduce la causa y se extraen sonda/techo del events.log legacy.
#   [8]  CA-3: hold textual con DOS filas legacy running -- no se atribuye a
#        ninguna (ambiguedad).
#   [9]  CA-3: stale -- "updated" con mas de 35 minutos.
#   [10] CA-2/CA-1: historial sin "started" -- sigue visible, despues de las
#        entradas fechadas.
#   [11] CA-4: reconstruccion de log legacy cuando el status no declara uno.
#   [12] CA-2: es de solo lectura -- ningun archivo de los roots cambia
#        (checksum antes/despues).
#
# Uso: scripts/tests/test-work-status-collect.sh
# Exit code: 0 si todos los checks pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/work-status-collect.sh"
FIXTURES="$SCRIPT_DIR/fixtures/work-status"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# run_collect <canonical_dir> <legacy_dir>
# Corre el script como subproceso con los roots dados, imprime stdout.
run_collect() {
    local canonical="$1" legacy="$2"
    MEFISTO_STATE_DIR="$canonical" MEFISTO_LEGACY_STATE_DIR="$legacy" "$TARGET" --json
}

# hms_at <delta_segundos> -- HH:MM:SS de "ahora + delta" (mismo patron que
# test-hold-visibility.sh).
hms_at() {
    local delta="$1"
    local epoch=$(( $(date +%s) + delta ))
    date -r "$epoch" +%H:%M:%S 2>/dev/null || date -d "@$epoch" +%H:%M:%S 2>/dev/null
}

# iso_at <delta_segundos> -- "YYYY-MM-DDTHH:MM:SS" de "ahora + delta".
iso_at() {
    local delta="$1"
    local epoch=$(( $(date +%s) + delta ))
    date -r "$epoch" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d "@$epoch" +%Y-%m-%dT%H:%M:%S 2>/dev/null
}

# dir_checksum <dir> -- huella de todos los archivos regulares bajo <dir>.
dir_checksum() {
    local dir="$1"
    if [ -d "$dir" ]; then
        find "$dir" -type f -print0 2>/dev/null | sort -z | xargs -0 shasum 2>/dev/null | shasum | awk '{print $1}'
    else
        echo "no-dir"
    fi
}

echo "[1] CA-1: --json obligatorio; cualquier otro argumento sale con 2"
EMPTY_CANON="$TMP/empty-canon"; EMPTY_LEGACY="$TMP/empty-legacy"
if MEFISTO_STATE_DIR="$EMPTY_CANON" MEFISTO_LEGACY_STATE_DIR="$EMPTY_LEGACY" "$TARGET" >/dev/null 2>&1; then
    fail "sin argumentos deberia salir con codigo != 0"
else
    rc=$?
    [ "$rc" -eq 2 ] && pass "sin argumentos sale con 2" || fail "sin argumentos salio con $rc (esperaba 2)"
fi
if MEFISTO_STATE_DIR="$EMPTY_CANON" MEFISTO_LEGACY_STATE_DIR="$EMPTY_LEGACY" "$TARGET" --otro >/dev/null 2>&1; then
    fail "--otro deberia salir con codigo != 0"
else
    rc=$?
    [ "$rc" -eq 2 ] && pass "--otro sale con 2" || fail "--otro salio con $rc (esperaba 2)"
fi

echo ""
echo "[2] CA-1: sin ningun estado -- JSON valido, exit 0, empty en true/true"
OUT=$(run_collect "$EMPTY_CANON" "$EMPTY_LEGACY")
rc=$?
[ "$rc" -eq 0 ] && pass "exit 0 sin estado" || fail "exit $rc sin estado (esperaba 0)"
if jq -e '.schemaVersion == 1' <<< "$OUT" >/dev/null 2>&1; then
    pass "schemaVersion == 1"
else
    fail "schemaVersion incorrecto: $OUT"
fi
if [ "$(jq -r '.empty.status' <<< "$OUT")" = "true" ] && [ "$(jq -r '.empty.history' <<< "$OUT")" = "true" ]; then
    pass "empty.status y empty.history en true"
else
    fail "empty inesperado: $(jq -c '.empty' <<< "$OUT")"
fi
if [ "$(jq '.rows | length' <<< "$OUT")" -eq 0 ] && [ "$(jq '.history | length' <<< "$OUT")" -eq 0 ]; then
    pass "rows y history vacios"
else
    fail "rows/history no vacios sin estado"
fi
if jq -e '.now | test("^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$")' <<< "$OUT" >/dev/null 2>&1; then
    pass "now con formato YYYY-MM-DD HH:MM:SS"
else
    fail "now con formato inesperado: $(jq -r '.now' <<< "$OUT")"
fi

echo ""
echo "[3] CA-2: misma clave en los dos roots -- gana el canonico"
OUT=$(run_collect "$FIXTURES/dedup-canonical-wins/canonical" "$FIXTURES/dedup-canonical-wins/legacy")
ROW=$(jq -c '.rows[] | select(.issue == "100")' <<< "$OUT")
if [ -n "$ROW" ]; then
    if [ "$(jq -r '.title' <<< "$ROW")" = "canonical wins" ] && [ "$(jq -r '.origin' <<< "$ROW")" = "canonical" ]; then
        pass "gana el status canonico ante la misma clave"
    else
        fail "no gano el canonico: $ROW"
    fi
    if [ "$(jq '.rows | map(select(.issue == "100")) | length' <<< "$OUT")" -eq 1 ]; then
        pass "solo una fila para la clave duplicada (deduplicado)"
    else
        fail "quedaron ambas filas duplicadas"
    fi
else
    fail "no se encontro la fila issue 100"
fi

echo ""
echo "[4] CA-2: status disjuntos -- se conservan ambos con su origen"
OUT=$(run_collect "$FIXTURES/dedup-disjoint/canonical" "$FIXTURES/dedup-disjoint/legacy")
R101=$(jq -c '.rows[] | select(.issue == "101")' <<< "$OUT")
R103=$(jq -c '.rows[] | select(.issue == "103")' <<< "$OUT")
if [ "$(jq -r '.origin' <<< "$R101")" = "canonical" ] && [ "$(jq -r '.origin' <<< "$R103")" = "legacy" ]; then
    pass "ambos status disjuntos se conservan con su origen"
else
    fail "no se conservaron los disjuntos: 101=$R101 / 103=$R103"
fi

echo ""
echo "[5] CA-2: formato antiguo sin pipeline/variant/runtime"
OUT=$(run_collect "$TMP/no-existe-old" "$FIXTURES/old-format/legacy")
ROW=$(jq -c '.rows[] | select(.issue == "55")' <<< "$OUT")
if [ -n "$ROW" ]; then
    if [ "$(jq -r '.pipeline' <<< "$ROW")" = "tdd" ] \
        && [ "$(jq -r '.variant' <<< "$ROW")" = "null" ] \
        && [ "$(jq -r '.runtime' <<< "$ROW")" = "null" ]; then
        pass "pipeline inferido tdd, variant/runtime null"
    else
        fail "campos inferidos incorrectos: $ROW"
    fi
else
    fail "no se encontro la fila del formato antiguo (issue 55)"
fi

echo ""
echo "[6] CA-3: hold estructurado -- prioridad sobre stale"
OUT=$(run_collect "$FIXTURES/hold-structured/canonical" "$TMP/no-existe-hs-legacy")
ROW=$(jq -c '.rows[] | select(.issue == "200")' <<< "$OUT")
ACTIVITY=$(jq -c '.activity' <<< "$ROW")
if [ "$(jq -r '.kind' <<< "$ACTIVITY")" = "hold" ] \
    && [ "$(jq -r '.cause' <<< "$ACTIVITY")" = "RATE_LIMIT" ] \
    && [ "$(jq -r '.next_probe' <<< "$ACTIVITY")" = "2026-01-01T00:10:00" ] \
    && [ "$(jq -r '.ceiling' <<< "$ACTIVITY")" = "21600" ]; then
    pass "activity refleja el hold estructurado del propio status"
else
    fail "activity incorrecta para hold estructurado: $ACTIVITY"
fi

echo ""
echo "[7] CA-3: hold textual con UNA fila legacy running elegible"
CANON7="$TMP/hold-text-one/canonical"; LEGACY7="$TMP/hold-text-one/legacy"
mkdir -p "$CANON7" "$LEGACY7"
PROBE_HMS=$(hms_at 120)
cat > "$LEGACY7/pipeline-status-tooling-300.json" <<EOF
{
  "issue": "300",
  "title": "hold textual",
  "pipeline": "tooling",
  "variant": null,
  "runtime": null,
  "stage": "1-writer",
  "state": "running",
  "started": "$(date +%Y%m%d-%H%M%S)",
  "updated": "$(date +%Y-%m-%dT%H:%M:%S)",
  "log": "/no/existe/300.log",
  "pr": null,
  "last_error": null,
  "agents": {"writer": {"duration": null, "result": "running"}, "reviewer": {"duration": null, "result": "pending"}}
}
EOF
cat > "$LEGACY7/events.log" <<EOF
=== SESSION TOOLING $(date +%Y%m%d-%H%M%S) issue:300 from-stage:1 ===
[$(hms_at -60)][hold] RATE_LIMIT: esperando, proxima sonda $PROBE_HMS (techo 23:59)
EOF
OUT=$(run_collect "$CANON7" "$LEGACY7")
ROW=$(jq -c '.rows[] | select(.issue == "300")' <<< "$OUT")
ACTIVITY=$(jq -c '.activity' <<< "$ROW")
if [ "$(jq -r '.kind' <<< "$ACTIVITY")" = "hold" ] && [ "$(jq -r '.cause' <<< "$ACTIVITY")" = "limite de uso" ]; then
    pass "hold textual traducido a 'limite de uso' con una unica fila legacy running"
else
    fail "hold textual no aplicado: $ACTIVITY"
fi
if [ "$(jq -r '.next_probe' <<< "$ACTIVITY")" = "$PROBE_HMS" ]; then
    pass "next_probe extraido del events.log legacy"
else
    fail "next_probe incorrecto: $(jq -r '.next_probe' <<< "$ACTIVITY") (esperaba $PROBE_HMS)"
fi

echo ""
echo "[8] CA-3: hold textual con DOS filas legacy running -- ambiguo, no se atribuye"
CANON8="$TMP/hold-text-two/canonical"; LEGACY8="$TMP/hold-text-two/legacy"
mkdir -p "$CANON8" "$LEGACY8"
for issue in 301 302; do
cat > "$LEGACY8/pipeline-status-tooling-${issue}.json" <<EOF
{
  "issue": "$issue",
  "title": "hold textual ambiguo",
  "pipeline": "tooling",
  "variant": null,
  "runtime": null,
  "stage": "1-writer",
  "state": "running",
  "started": "$(date +%Y%m%d-%H%M%S)",
  "updated": "$(date +%Y-%m-%dT%H:%M:%S)",
  "log": "/no/existe/${issue}.log",
  "pr": null,
  "last_error": null,
  "agents": {"writer": {"duration": null, "result": "running"}, "reviewer": {"duration": null, "result": "pending"}}
}
EOF
done
cat > "$LEGACY8/events.log" <<EOF
[$(hms_at -60)][hold] RATE_LIMIT: esperando, proxima sonda $(hms_at 120) (techo 23:59)
EOF
OUT=$(run_collect "$CANON8" "$LEGACY8")
R301=$(jq -c '.rows[] | select(.issue == "301") | .activity' <<< "$OUT")
R302=$(jq -c '.rows[] | select(.issue == "302") | .activity' <<< "$OUT")
if [ "$(jq -r '.kind' <<< "$R301")" != "hold" ] && [ "$(jq -r '.kind' <<< "$R302")" != "hold" ]; then
    pass "con dos filas legacy running ninguna recibe el hold textual"
else
    fail "el hold textual se atribuyo con ambiguedad: 301=$R301 / 302=$R302"
fi

echo ""
echo "[9] CA-3: stale -- 'updated' con mas de 35 minutos"
CANON9="$TMP/stale/canonical"
mkdir -p "$CANON9"
cat > "$CANON9/pipeline-status-tooling-400.json" <<EOF
{
  "issue": "400",
  "title": "stale",
  "pipeline": "tooling",
  "variant": null,
  "runtime": "claude",
  "stage": "1-writer",
  "state": "running",
  "started": "$(date +%Y%m%d-%H%M%S)",
  "updated": "$(iso_at -2400)",
  "log": "/no/existe/400.log",
  "pr": null,
  "last_error": null,
  "agents": {"writer": {"duration": null, "result": "running"}, "reviewer": {"duration": null, "result": "pending"}}
}
EOF
OUT=$(run_collect "$CANON9" "$TMP/no-existe-stale-legacy")
ACTIVITY=$(jq -c '.rows[] | select(.issue == "400") | .activity' <<< "$OUT")
if [ "$(jq -r '.kind' <<< "$ACTIVITY")" = "stale" ]; then
    pass "activity stale cuando 'updated' supera 35 minutos"
else
    fail "activity incorrecta para stale: $ACTIVITY"
fi

echo ""
echo "[10] CA-2/CA-1: historial sin 'started' sigue visible, despues de las fechadas"
OUT=$(run_collect "$FIXTURES/history-mixed/canonical" "$TMP/no-existe-hist-legacy")
if [ "$(jq '.history | length' <<< "$OUT")" -eq 2 ]; then
    pass "las dos entradas de historial aparecen"
else
    fail "no aparecieron las dos entradas de historial: $(jq -c '.history' <<< "$OUT")"
fi
FIRST_ISSUE=$(jq -r '.history[0].issue' <<< "$OUT")
SECOND_ISSUE=$(jq -r '.history[1].issue' <<< "$OUT")
if [ "$FIRST_ISSUE" = "10" ] && [ "$SECOND_ISSUE" = "11" ]; then
    pass "la entrada fechada precede a la que carece de 'started'"
else
    fail "orden incorrecto: primero=$FIRST_ISSUE segundo=$SECOND_ISSUE"
fi
if [ "$(jq -r '.history[1].started' <<< "$OUT")" = "null" ]; then
    pass "la entrada sin 'started' conserva started=null"
else
    fail "started deberia ser null: $(jq -r '.history[1].started' <<< "$OUT")"
fi
if [ "$(jq -r '.history[0].duration' <<< "$OUT")" = "300" ] && [ "$(jq -r '.history[0].detail' <<< "$OUT")" = "PR #999" ]; then
    pass "duration/detail calculados para la entrada fechada (300s, PR #999)"
else
    fail "duration/detail incorrectos: $(jq -c '.history[0]' <<< "$OUT")"
fi

echo ""
echo "[11] CA-4: reconstruccion de log legacy cuando el status no declara uno"
OUT=$(run_collect "$FIXTURES/log-reconstruct/canonical" "$TMP/no-existe-logrec-legacy")
LOG=$(jq -r '.rows[] | select(.issue == "500") | .log' <<< "$OUT")
EXPECTED="$FIXTURES/log-reconstruct/canonical/logs/tooling-stage-2-reviewer-20260101-120000.log"
if [ "$LOG" = "$EXPECTED" ]; then
    pass "log reconstruido con el patron legacy de Tooling"
else
    fail "log reconstruido incorrecto: '$LOG' (esperaba '$EXPECTED')"
fi

echo ""
echo "[12] CA-2: de solo lectura -- ningun archivo de los roots cambia (checksum)"
CANON12="$TMP/readonly/canonical"; LEGACY12="$TMP/readonly/legacy"
mkdir -p "$CANON12" "$LEGACY12"
cp "$FIXTURES/dedup-canonical-wins/canonical/pipeline-status-tooling-100.json" "$CANON12/"
cp "$FIXTURES/dedup-canonical-wins/legacy/pipeline-status-tooling-100.json" "$LEGACY12/"
cp "$FIXTURES/history-mixed/canonical/pipeline-history.jsonl" "$CANON12/"
BEFORE_CANON=$(dir_checksum "$CANON12")
BEFORE_LEGACY=$(dir_checksum "$LEGACY12")
run_collect "$CANON12" "$LEGACY12" >/dev/null
AFTER_CANON=$(dir_checksum "$CANON12")
AFTER_LEGACY=$(dir_checksum "$LEGACY12")
if [ "$BEFORE_CANON" = "$AFTER_CANON" ] && [ "$BEFORE_LEGACY" = "$AFTER_LEGACY" ]; then
    pass "ningun archivo de los roots cambio (checksum identico antes/despues)"
else
    fail "algun archivo cambio: canon $BEFORE_CANON -> $AFTER_CANON / legacy $BEFORE_LEGACY -> $AFTER_LEGACY"
fi
if [ ! -d "$TMP/no-existe-old" ] && [ ! -d "$TMP/no-existe-stale-legacy" ]; then
    pass "no se crearon roots ausentes durante ninguna corrida"
else
    fail "el script creo un root que no existia"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
