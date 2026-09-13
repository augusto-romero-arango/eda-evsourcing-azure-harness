#!/usr/bin/env bash
# test-tdd-run-metrics.sh -- Composicion publicada de metricas del pipeline TDD (#1313).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PIPE="$REPO_ROOT/scripts/tdd-pipeline.sh"
PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/_pipeline-common.sh"

for expected in \
    'add_run_metrics_stage "Scaffolder"' \
    'add_run_metrics_stage "$STAGE1_LABEL"' \
    'add_run_metrics_stage "$STAGE2_LABEL"' \
    'add_run_metrics_stage "Smoke Test Writer"' \
    'add_run_metrics_stage "Reviewer"' \
    'add_run_metrics_stage "Remediacion: $STAGE1_LABEL"' \
    'add_run_metrics_stage "Remediacion: $STAGE2_LABEL"' \
    'add_run_metrics_stage "coverage-gate"'; do
    if grep -qF "$expected" "$PIPE"; then pass "$expected"; else fail "falta $expected"; fi
done
if grep -qF '[ -n "$duration" ] || return 0' "$PIPE"; then
    pass "las etapas omitidas no producen filas"
else
    fail "la lista no filtra etapas sin duracion"
fi

FULL='{"model":"modelo-a","tokens":{"input":10,"output":20,"cache_read":30,"cache_write":40,"reasoning":50},"estimated_cost_usd":0.25}'
OUT=$(render_run_metrics_table "Test Writer" 60 "$FULL" "Remediacion: Implementer" 30 "$FULL")
if printf '%s' "$OUT" | grep -qF '| Test Writer | modelo-a | 150 | 10 / 20 / 70 / 50 | 1m 0s | $0.25 |' \
    && printf '%s' "$OUT" | grep -qF '| Remediacion: Implementer | modelo-a | 150 | 10 / 20 / 70 / 50 | 0m 30s | $0.25 |' \
    && printf '%s' "$OUT" | grep -qF '| **Total** | - | **300** | - | **1m 30s** | **$0.50** |'; then
    pass "corrida completa suma remediaciones y sus tokens ampliados"
else
    fail "tabla completa inesperada: $OUT"
fi

OUT=$(render_run_metrics_table Reviewer 45 "$FULL")
if ! printf '%s' "$OUT" | grep -q 'Test Writer\|Smoke Test'; then pass "refactor puro solo lista reviewer"; else fail "refactor invento etapas: $OUT"; fi
OUT=$(render_run_metrics_table 'coverage-gate' 12 null)
if printf '%s' "$OUT" | grep -qF '| coverage-gate | - | - | - | 0m 12s | - |' \
    && printf '%s' "$OUT" | grep -qF '| **Total (parcial)** | - | - | - | **0m 12s** | - |'; then
    pass "coverage-gate deja total parcial"
else
    fail "coverage-gate deberia tener solo duracion: $OUT"
fi

if grep -qF 'RUN_METRICS_TABLE=$(render_run_metrics_table "${RUN_METRICS_STAGE_ARGS[@]}")' "$PIPE" \
    && grep -qF '## Metricas de la corrida' "$PIPE" \
    && grep -qF 'HISTORY_AGENT_ARGS' "$PIPE"; then
    pass "PR e historial derivan de la lista unica"
else
    fail "PR e historial no comparten la lista de etapas"
fi
if grep -qF 'gh pr comment "$PR_URL"' "$PIPE" \
    && grep -qF -- '--repo "$REPO_SLUG_PR"' "$PIPE" \
    && grep -qF '|| warn "No se pudo publicar las metricas en el PR reutilizado' "$PIPE"; then
    pass "PR reutilizado recibe comentario no fatal con repo explicito"
else
    fail "comentario del PR reutilizado incompleto"
fi

echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
