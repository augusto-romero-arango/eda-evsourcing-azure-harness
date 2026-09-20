#!/usr/bin/env bash
# test-legacy-directive-mentions.sh -- Anti-regresion de prosa (#1536): ningun
# agente/skill publicado debe presentar `CLAUDE.md` como el archivo efectivo
# de directivas del consumidor (MEF-ADR-0049 decision 3: `AGENTS.md` es la
# fuente neutral; `CLAUDE.md` es a lo sumo un puente/fallback legacy), ni
# `scripts/setup-github-labels.sh` debe presentar `.claude/harness.config.json`
# como el contrato canonico (MEF-ADR-0053 decision 4: `.mefisto/harness.config.json`
# es el contrato; el legacy solo es fallback de lectura).
#
# Grep puro, sin ejecutar ningun bloque bash de los agentes. Lista de archivos
# cerrada a proposito (los seis de la tabla del issue): un barrido global sobre
# todo agents/*.md marcaria en falso los bloques `MEFISTO_INSTRUCTIONS_PATH`
# de agentes ya migrados, que contienen `if [ -f "CLAUDE.md" ]` legitimos.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BUG_INVESTIGATOR="$REPO_ROOT/agents/bug-investigator.md"
TOOLING_INVESTIGATOR="$REPO_ROOT/agents/tooling-investigator.md"
PLANNER="$REPO_ROOT/agents/planner.md"
HISTORIADOR="$REPO_ROOT/agents/historiador.md"
FIX_REVIEW="$REPO_ROOT/commands/fix-review.md"
SETUP_LABELS="$REPO_ROOT/scripts/setup-github-labels.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "[1] Ninguna linea de CLAUDE.md sin calificar en los cinco artefactos"
for f in "$BUG_INVESTIGATOR" "$TOOLING_INVESTIGATOR" "$PLANNER" "$HISTORIADOR" "$FIX_REVIEW"; do
    name="$(basename "$f")"
    OFFENDING=$(grep -n 'CLAUDE\.md' "$f" | grep -v -i 'legacy\|fallback\|@AGENTS')
    if [ -z "$OFFENDING" ]; then
        pass "$name no presenta CLAUDE.md como el archivo efectivo de directivas"
    else
        fail "$name tiene linea(s) sin calificar:"
        echo "$OFFENDING" | sed 's/^/    /'
    fi
done

echo "[2] setup-github-labels.sh no presenta .claude/harness.config.json como el contrato canonico"
OFFENDING=$(grep -n '\.claude/harness\.config\.json' "$SETUP_LABELS" | grep -v -i 'legacy\|fallback')
if [ -z "$OFFENDING" ]; then
    pass "setup-github-labels.sh no tiene linea(s) sin calificar"
else
    fail "setup-github-labels.sh tiene linea(s) sin calificar:"
    echo "$OFFENDING" | sed 's/^/    /'
fi

echo "[3] planner.md nombra el indice tematico del plugin (INDICE-TEMATICO.md) al menos dos veces"
COUNT=$(grep -c 'INDICE-TEMATICO\.md' "$PLANNER")
if [ "$COUNT" -ge 2 ]; then
    pass "planner.md nombra INDICE-TEMATICO.md $COUNT veces"
else
    fail "planner.md nombra INDICE-TEMATICO.md solo $COUNT vez/veces (se esperaban >= 2)"
fi

echo "[4] fix-review.md remite a mef-adr-0019 en la(s) linea(s) del routing cross-repo"
ROUTING_LINES=$(grep -i 'Routing cross-repo' "$FIX_REVIEW")
if [ -n "$ROUTING_LINES" ] && echo "$ROUTING_LINES" | grep -qi 'mef-adr-0019'; then
    pass "fix-review.md nombra mef-adr-0019 en la linea del routing"
else
    fail "fix-review.md no nombra mef-adr-0019 en ninguna linea de routing cross-repo"
fi

echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
