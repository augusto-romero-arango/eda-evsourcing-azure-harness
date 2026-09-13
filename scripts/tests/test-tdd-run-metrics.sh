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

extract_fn() {
    local name="$1" file="$2"
    awk -v fn="$name" '$0 ~ "^"fn"\\(\\) \\{" {p=1; depth=0} p {print; depth += gsub(/\{/, "{") - gsub(/\}/, "}")} p && depth == 0 {p=0}' "$file"
}

eval "$(extract_fn _tdd_add_run_metrics_stage "$PIPE")"
eval "$(extract_fn _tdd_collect_run_metrics_stages "$PIPE")"
if declare -F _tdd_add_run_metrics_stage >/dev/null && declare -F _tdd_collect_run_metrics_stages >/dev/null; then
    pass "la composicion real del pipeline se pudo cargar"
else
    fail "no se pudieron cargar las funciones de composicion"
fi

FULL='{"model":"modelo-a","tokens":{"input":10,"output":20,"cache_read":30,"cache_write":40,"reasoning":50},"estimated_cost_usd":0.25}'

reset_stages() {
    STAGE1_AGENT="projection-test-writer" STAGE2_AGENT="projection-implementer"
    STAGE1_LABEL="Projection Test Writer" STAGE2_LABEL="Projection Implementer"
    AGENT_SCAFFOLD_DUR="" AGENT_SCAFFOLD_METRICS_JSON=""
    AGENT_TW_DUR="" AGENT_TW_METRICS_JSON=""
    AGENT_IM_DUR="" AGENT_IM_METRICS_JSON=""
    AGENT_ST_DUR="" AGENT_ST_METRICS_JSON=""
    AGENT_RV_DUR="" AGENT_RV_METRICS_JSON=""
    AGENT_PATCH_TW_DUR="" AGENT_PATCH_TW_METRICS_JSON=""
    AGENT_PATCH_IM_DUR="" AGENT_PATCH_IM_METRICS_JSON=""
    AGENT_CG_DUR=""
}

reset_stages
AGENT_SCAFFOLD_DUR=10 AGENT_SCAFFOLD_METRICS_JSON="$FULL"
AGENT_TW_DUR=20 AGENT_TW_METRICS_JSON="$FULL"
AGENT_IM_DUR=30 AGENT_IM_METRICS_JSON="$FULL"
AGENT_ST_DUR=40 AGENT_ST_METRICS_JSON="$FULL"
AGENT_RV_DUR=50 AGENT_RV_METRICS_JSON="$FULL"
AGENT_CG_DUR=60
_tdd_collect_run_metrics_stages
OUT=$(render_run_metrics_table "${RUN_METRICS_STAGE_ARGS[@]}")
if [ "${#RUN_METRICS_STAGE_ARGS[@]}" -eq 18 ] \
    && printf '%s' "$OUT" | grep -qF '| Projection Test Writer | modelo-a |' \
    && printf '%s' "$OUT" | grep -qF '| Projection Implementer | modelo-a |' \
    && printf '%s' "$OUT" | grep -qF '| Smoke Test Writer | modelo-a |' \
    && printf '%s' "$OUT" | grep -qF '| coverage-gate | - | - | - | 1m 0s | - |' \
    && printf '%s' "$OUT" | grep -qF '| **Total (parcial)** | - | - | - | **3m 30s** | **$1.25** |' \
    && [ "${#HISTORY_AGENT_ARGS[@]}" -eq 20 ] \
    && [ "$HISTORY_COVERAGE_GATE_INCLUDED" = true ]; then
    pass "corrida completa respeta labels y compone solo sus seis etapas"
else
    fail "tabla completa inesperada: $OUT"
fi

reset_stages
AGENT_RV_DUR=45 AGENT_RV_METRICS_JSON="$FULL"
_tdd_collect_run_metrics_stages
OUT=$(render_run_metrics_table "${RUN_METRICS_STAGE_ARGS[@]}")
if [ "${#RUN_METRICS_STAGE_ARGS[@]}" -eq 3 ] \
    && printf '%s' "$OUT" | grep -qF '| Reviewer | modelo-a |' \
    && ! printf '%s' "$OUT" | grep -q 'Writer\|coverage-gate' \
    && [ "$HISTORY_COVERAGE_GATE_INCLUDED" = false ]; then
    pass "refactor puro solo lista reviewer en PR e historial"
else
    fail "refactor invento etapas: $OUT"
fi

reset_stages
AGENT_RV_DUR=15 AGENT_RV_METRICS_JSON=null
AGENT_PATCH_TW_DUR=30 AGENT_PATCH_TW_METRICS_JSON="$FULL"
AGENT_PATCH_IM_DUR=45 AGENT_PATCH_IM_METRICS_JSON="$FULL"
AGENT_CG_DUR=12
_tdd_collect_run_metrics_stages
OUT=$(render_run_metrics_table "${RUN_METRICS_STAGE_ARGS[@]}")
if printf '%s' "$OUT" | grep -qF '| Reviewer | - | - | - | 0m 15s | - |' \
    && printf '%s' "$OUT" | grep -qF '| Remediacion: Projection Test Writer | modelo-a | 150 | 10 / 20 / 70 / 50 | 0m 30s | $0.25 |' \
    && printf '%s' "$OUT" | grep -qF '| Remediacion: Projection Implementer | modelo-a | 150 | 10 / 20 / 70 / 50 | 0m 45s | $0.25 |' \
    && printf '%s' "$OUT" | grep -qF '| coverage-gate | - | - | - | 0m 12s | - |' \
    && printf '%s' "$OUT" | grep -qF '| **Total (parcial)** | - | - | - | **1m 42s** | **$0.50** |' \
    && [ "${#HISTORY_AGENT_ARGS[@]}" -eq 12 ]; then
    pass "remediaciones, metricas null y coverage-gate conservan total parcial"
else
    fail "composicion de remediacion inesperada: $OUT"
fi

if grep -qF 'RUN_METRICS_TABLE=$(render_run_metrics_table "${RUN_METRICS_STAGE_ARGS[@]}")' "$PIPE" \
    && grep -qF '## Metricas de la corrida' "$PIPE" \
    && grep -qF 'if [ "$HISTORY_COVERAGE_GATE_INCLUDED" = true ]' "$PIPE"; then
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
