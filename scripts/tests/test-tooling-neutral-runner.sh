#!/usr/bin/env bash
# Regresion focalizada de #1062: el pipeline publicado delega la ejecucion al
# runner y conserva ids/perfiles neutrales, sin fijar un CLI de proveedor.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PIPELINE="$ROOT/scripts/tooling-pipeline.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { grep -Fq -- "$1" "$PIPELINE" && pass "$2" || fail "$2"; }
absent() { grep -Fq -- "$1" "$PIPELINE" && fail "$2" || pass "$2"; }

echo '[frontera] runner neutral'
contains 'mefisto-run-agent.sh' 'localiza el runner desde la clausura publicada'
contains 'tooling-writer balanced' 'writer usa id y perfil neutral'
contains 'tooling-reviewer deep' 'reviewer usa id y perfil neutral'
contains '--resume-session' 'reanudacion via session_id neutral'
contains 'agent_events_denials' 'retry por permisos consume denials neutral'
contains 'runtime_supports_resume' 'consulta capability de reanudacion'
absent 'claude -p' 'no invoca Claude directamente'
absent 'CLAUDE_CONFIG_DIR' 'no inspecciona stores privados'
absent 'bypassPermissions' 'no fija permisos de un runtime'
absent 'output-format' 'no fija formatos de stream de un runtime'
absent 'kill -9' 'no conserva watchdog propio'
contains 'if "$RUN_AGENT_BIN" "${args[@]}"' 'invoca el runner con un array, sin eval'
contains 'agent_events_completed_successfully' 'exige terminal neutral de exito'
contains 'mefisto_state_path "summaries/stage-${stage}-${agent}.md" "$WORKTREE_PATH"' 'escribe summaries en el estado canonico del worktree'
contains '--redact-observability' 'pide persistencia redactada al runner'
absent '--raw-log' 'no persiste raw del runtime'
absent '--stderr-log' 'no persiste stderr del runtime'
contains "PIPELINE_OWN_WRITES=(':!.mefisto/pipeline')" 'excluye solo el estado canonico del commit del agente'
contains 'attempt-${attempt}.events.jsonl' 'cada intento conserva su propio JSONL neutral'
contains 'enrich_tooling_stage_metrics' 'status, metricas e history reciben correlacion neutral completa'
contains 'PIPELINE_TMP_DIR="$(mktemp -d -t mefisto-tooling)"' 'inputs y salida del runner viven en un directorio temporal'
absent "trap 'rm -f \"\${prompt_file:-}\"" 'no depende de RETURN para limpiar inputs en abortos'
absent '.claude/settings.json 2>/dev/null' 'no parchea ni restaura settings de Claude'
contains 'get_harness_identity_json "$MEFISTO_RUNTIME_RESUELTO"' 'valida metadata distribuida contra el runtime activo'
contains 'HISTORY_FILE="$(mefisto_state_path' 'history obtiene su destino con el helper canonico'
absent 'pipeline-history.jsonl" 2>/dev/null' 'history no concatena a mano su ruta de escritura'

echo '[contrato] helpers JSONL'
# shellcheck source=/dev/null
source "$ROOT/scripts/_pipeline-common.sh"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
printf '%s\n' '{"type":"run.failed","status":"failed","session_id":"s 1","denials":2,"resets_at":"2030-01-01T00:00:00Z","error":{"kind":"rate_limit"}}' > "$TMP"
[ "$(agent_events_session_id "$TMP")" = 's 1' ] && pass 'lee session_id' || fail 'no lee session_id'
[ "$(agent_events_denials "$TMP")" = 2 ] && pass 'lee denials' || fail 'no lee denials'
[ "$(agent_events_resets_at "$TMP")" = '2030-01-01T00:00:00Z' ] && pass 'lee resets_at raiz' || fail 'no lee resets_at raiz'
[ "$(classify_neutral_agent_failure 1 "$TMP")" = RATE_LIMIT ] && pass 'clasifica error.kind' || fail 'no clasifica error.kind'
if agent_events_completed_successfully "$TMP"; then fail 'un terminal fallido no es exito'; else pass 'rechaza terminal fallido'; fi
printf '%s\n' '{"type":"run.completed","status":"success","session_id":null,"denials":0,"error":null}' > "$TMP"
if agent_events_completed_successfully "$TMP"; then pass 'acepta run.completed success'; else fail 'no acepta run.completed success'; fi

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
