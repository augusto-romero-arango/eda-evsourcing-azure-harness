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
contains 'log_agent_model_invocation "$agent" "$model"' 'anuncia el modelo resuelto antes de invocar writer, reviewer o merge'
contains '[ -n "$model" ] && args+=(--model "$model")' 'conserva intacto el argv condicional del runner'
contains 'case "$agent" in reviewer) agent_id="tooling-reviewer"; profile="deep"; model="$MODEL_REVIEWER" ;; *) agent_id="tooling-writer"; profile="balanced"; model="$MODEL_WRITER" ;; esac' 'el anuncio usa el modelo ya resuelto por rol'
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

eval "$(awk '/^log_agent_model_invocation\(\) \{/{p=1} p{print} p && /^}/{p=0}' "$PIPELINE")"
MODEL_LOG="$(mktemp)"
log() { printf '%s\n' "$*" >> "$MODEL_LOG"; }
: > "$MODEL_LOG"
log_agent_model_invocation writer 'vendor/model-v2'
log_agent_model_invocation reviewer ''
if grep -qxF 'Invocando writer (modelo: vendor/model-v2)...' "$MODEL_LOG" \
    && grep -qxF 'Invocando reviewer (modelo: <heredado>)...' "$MODEL_LOG"; then
    pass 'formatea modelo concreto y fallback heredado sin tocar el runner'
else
    fail 'no formatea correctamente modelo concreto/heredado'
fi
rm -f "$MODEL_LOG"

echo '[regresion] invocacion ejecutable de run_agent'
REGRESSION_TMP="$(mktemp -d -t mefisto-tooling-run-agent)"
REGRESSION_ARGS="$REGRESSION_TMP/runner.args"
export REGRESSION_ARGS
cat > "$REGRESSION_TMP/run-agent-double" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REGRESSION_ARGS"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --event-log) printf '%s\n' '{"type":"run.completed","status":"success","session_id":null,"denials":0,"error":null}' > "$2"; shift 2 ;;
        *) shift ;;
    esac
done
EOF
chmod +x "$REGRESSION_TMP/run-agent-double"
(
    # Extrae y ejecuta la funcion publicada real bajo nounset. Los dobles solo
    # reemplazan sus dependencias externas; el argv y las rutas los deriva
    # run_agent por si misma.
    set -u
    eval "$(awk '/^run_agent\(\) \{/{p=1} p{print} p && /^}/{p=0}' "$PIPELINE")"
    LOG_DIR_ABS="$REGRESSION_TMP/logs"
    TIMESTAMP='20260912-120000'
    ISSUE_LOG_TAG='1283'
    PIPELINE_TMP_DIR="$REGRESSION_TMP/pipeline"
    WORKTREE_PATH="$ROOT"
    RUN_AGENT_BIN="$REGRESSION_TMP/run-agent-double"
    MEFISTO_RUNTIME_RESUELTO='fake'
    MEFISTO_AGENT_TIMEOUT_SECONDS=60
    EVENTS_LOG_ABS="$REGRESSION_TMP/events.log"
    ISSUE_NUM=1283
    VARIANT_LABEL_JSON='null'
    HARNESS_IDENTITY_JSON='{}'
    MODEL_WRITER=''
    MODEL_REVIEWER=''
    PIPELINE_OWN_WRITES=(':!.mefisto/pipeline')
    mkdir -p "$LOG_DIR_ABS" "$PIPELINE_TMP_DIR"
    log() { :; }
    warn() { :; }
    abort() { return 1; }
    update_status() { :; }
    mefisto_state_path() { mkdir -p "$REGRESSION_TMP/state/$(dirname "$1")"; printf '%s\n' "$REGRESSION_TMP/state/$1"; }
    derive_stage_log_from_stream() { :; }
    compute_stage_metrics() { printf '{}'; }
    enrich_tooling_stage_metrics() { printf '%s' "$2"; }
    agent_events_denials() { printf '0'; }
    agent_events_completed_successfully() { return 0; }
    classify_neutral_agent_failure() { printf 'UNKNOWN'; }
    agent_failure_is_holdable() { return 1; }
    run_agent '1' 'writer' 'prompt de regresion'
)
EXPECTED_EVENT_LOG="$REGRESSION_TMP/logs/tooling-stage-1-writer-20260912-120000-issue-1283-attempt-1.events.jsonl"
EXPECTED_PROMPT="$REGRESSION_TMP/pipeline/1-writer.prompt.md"
EXPECTED_SYSTEM="$REGRESSION_TMP/pipeline/1-writer.system.md"
if [ "$(wc -l < "$REGRESSION_ARGS" | tr -d ' ')" -eq 17 ] \
    && grep -Fx -- '--agent' "$REGRESSION_ARGS" >/dev/null \
    && grep -Fx -- 'tooling-writer' "$REGRESSION_ARGS" >/dev/null \
    && grep -Fx -- '--cwd' "$REGRESSION_ARGS" >/dev/null \
    && grep -Fx -- "$ROOT" "$REGRESSION_ARGS" >/dev/null \
    && grep -Fx -- "$EXPECTED_PROMPT" "$REGRESSION_ARGS" >/dev/null \
    && grep -Fx -- "$EXPECTED_SYSTEM" "$REGRESSION_ARGS" >/dev/null \
    && grep -Fx -- "$EXPECTED_EVENT_LOG" "$REGRESSION_ARGS" >/dev/null \
    && [ -f "$EXPECTED_PROMPT" ] && [ -f "$EXPECTED_SYSTEM" ] && [ -f "$EXPECTED_EVENT_LOG" ]; then
    pass 'run_agent deriva rutas e invoca una vez al runner neutral bajo nounset'
else
    fail 'run_agent no invoca el runner neutral esperado bajo nounset'
fi
rm -rf "$REGRESSION_TMP"

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
