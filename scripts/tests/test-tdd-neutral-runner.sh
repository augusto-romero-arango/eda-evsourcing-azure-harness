#!/usr/bin/env bash
# Regresion focalizada de #1360/#1361: TDD solo consume el contrato JSONL.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PIPELINE="$ROOT/scripts/tdd-pipeline.sh"
PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { grep -Fq -- "$1" "$PIPELINE" && pass "$2" || fail "$2"; }
run_agent_body() { awk '/^run_agent\(\) \{/{p=1} p{print} p && /^}/{p=0}' "$PIPELINE"; }
invoke_agent_once_body() { awk '/^invoke_agent_once\(\) \{/{p=1} p{print} p && /^}/{p=0}' "$PIPELINE"; }
stage_zero_body() { awk '/^    # --- Stage 0:/{p=1; next} p{print} p && /^    fi$/{exit}' "$PIPELINE"; }
remediation_4b_failure_body() { awk '/^        CG_TW_EXIT=0$/{p=1} p && /^        else$/{print "        fi"; exit} p{print}' "$PIPELINE"; }
absent_run_agent() { run_agent_body | grep -Fq -- "$1" && fail "$2" || pass "$2"; }
absent_pipeline() { grep -Fq -- "$1" "$PIPELINE" && fail "$2" || pass "$2"; }

echo '[estatico] frontera neutral'
contains 'RUN_AGENT_BIN_DEFAULT="$RUNTIME_DIR/mefisto-run-agent.sh"' 'bootstrap localiza el runner neutral'
contains 'source "$RUNTIME_LIB_DIR/mefisto-runtime.sh"' 'bootstrap carga discovery neutral'
contains 'source "$RUNTIME_LIB_DIR/mefisto-models.sh"' 'bootstrap carga modelos neutrales'
contains 'MEFISTO_AGENT_TIMEOUT_SECONDS="${MEFISTO_AGENT_TIMEOUT_SECONDS:-1800}"' 'valida timeout neutral'
contains 'runtime_cli_available "$MEFISTO_RUNTIME_RESUELTO"' 'valida el CLI mediante el adaptador'
contains 'agent_events_completed_successfully "$events_file"' 'exige terminal exitoso neutral'
contains 'classify_neutral_agent_failure "$run_exit" "$events_file"' 'clasifica el terminal neutral'
contains 'agent_hold_wait "$EVENTS_LOG_ABS" "$failure_type" "$hold_started" "$(agent_events_resets_at "$events_file")"' 'hold consume resets_at neutral'
contains 'args+=(--resume-session "$resume_session")' 'sonda reanuda por session_id'
contains 'agent_events_denials "$events_file"' 'retry unico consume denegaciones neutrales'
contains 'TIMEOUT|KILLED|STREAM_CUT|PROTOCOL_INVALID' 'terminales incompletos excluyen recuperacion'
contains 'attempt-${attempt}.events.jsonl' 'cada intento conserva eventos propios'
absent_run_agent 'claude ' 'run_agent no nombra el CLI de Claude'
absent_run_agent '--permission-mode' 'run_agent no fija permisos de un runtime'
absent_run_agent '--output-format' 'run_agent no conoce formatos del runtime'
absent_run_agent '--append-system-prompt' 'run_agent inyecta el system prompt por archivo'
absent_run_agent 'PIPELINE_CAPTURE_STREAM' 'run_agent no bifurca por captura legacy'
absent_run_agent 'stream_file' 'run_agent no conserva streams privados'
absent_run_agent 'stderr_file' 'run_agent no conserva stderr privado'
absent_run_agent 'kill -9' 'run_agent delega watchdog al runner'
absent_run_agent 'agent_session_transcript_count' 'run_agent no inspecciona transcripts privados'
absent_run_agent 'agent_resume_prompt' 'run_agent no construye reanudacion legacy'
absent_run_agent 'RESUME_ARGS' 'run_agent no usa argv legacy de reanudacion'
contains 'invoke_agent_once() {' 'Stage 0 y remediaciones comparten helper neutral sin hold'
contains 'invoke_agent_once "domain-scaffolder"' 'Stage 0 usa el helper neutral'
contains 'invoke_agent_once "$STAGE1_AGENT"' 'remediacion 4b usa el helper neutral'
contains 'invoke_agent_once "$STAGE2_AGENT"' 'remediacion 4c usa el helper neutral'
contains 'agent_events_completed_successfully "$EVENTS_SCAFFOLD"' 'Stage 0 exige terminal neutral exitoso'
contains 'agent_events_completed_successfully "$EVENTS_CG_TW"' '4b exige terminal neutral exitoso y conserva continuidad'
contains 'agent_events_completed_successfully "$EVENTS_CG_IM"' '4c exige terminal neutral exitoso y conserva continuidad'
absent_pipeline 'PIPELINE_CAPTURE_STREAM' 'TDD no conserva bifurcacion legacy de captura'
absent_pipeline 'claude -p' 'TDD no invoca un CLI de runtime directamente'
absent_pipeline '--permission-mode' 'TDD no fija permisos de un runtime'
absent_pipeline '--output-format' 'TDD no conoce formatos de un runtime'

echo '[regresion] contrato ejecutable de run_agent'
TMP="$(mktemp -d -t mefisto-tdd-neutral)"
trap 'rm -rf "$TMP"' EXIT
WT="$TMP/worktree"
mkdir -p "$WT/tests" "$WT/src" "$WT/.claude/pipeline/summaries"
git -C "$WT" init -q
git -C "$WT" config user.email test@example.invalid
git -C "$WT" config user.name Test
printf 'base\n' > "$WT/tests/base.txt"
git -C "$WT" add tests/base.txt
git -C "$WT" commit -qm base

export TMP WT ROOT
cat > "$TMP/runner" <<'EOF'
#!/usr/bin/env bash
count=$(cat "$TMP/calls" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s' "$count" > "$TMP/calls"
printf '%s\n' "$@" > "$TMP/call-${count}.args"
event=""; cwd=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --event-log) event="$2"; shift 2 ;;
        --cwd) cwd="$2"; shift 2 ;;
        *) shift ;;
    esac
done
case "$SCENARIO:$count" in
    success:1|denials:2)
        printf '%s\n' '{"type":"run.completed","status":"success","session_id":null,"denials":0,"error":null}' > "$event"
        exit 0 ;;
    hold:1)
        printf '%s\n' '{"type":"run.failed","status":"failed","session_id":"session-1360","denials":0,"error":{"kind":"rate_limit","resets_at":null}}' > "$event"
        exit 1 ;;
    hold:2)
        printf '%s\n' '{"type":"run.completed","status":"success","session_id":"session-1360","denials":0,"error":null}' > "$event"
        exit 0 ;;
    denials:1)
        printf '%s\n' '{"type":"run.completed","status":"success","session_id":null,"denials":2,"error":null}' > "$event"
        exit 0 ;;
    timeout:1)
        printf 'parcial\n' > "$cwd/src/partial.txt"
        printf '%s\n' '{"type":"run.failed","status":"failed","session_id":"session-timeout","denials":0,"error":{"kind":"timeout"}}' > "$event"
        exit 124 ;;
    terminal-failure:1)
        printf '%s\n' '{"type":"run.completed","status":"failed","session_id":null,"denials":0,"error":{"kind":"protocol_invalid"}}' > "$event"
        exit 0 ;;
esac
exit 70
EOF
chmod +x "$TMP/runner"

{
    printf '%s\n' 'set -uo pipefail'
    run_agent_body
    cat <<'EOF'
LOG_DIR_ABS="$TMP/logs"
TIMESTAMP=20260914-120000
ISSUE_LOG_TAG=1360
PIPELINE_TMP_DIR="$TMP/pipeline"
WORKTREE_PATH="$WT"
RUN_AGENT_BIN="$TMP/runner"
MEFISTO_RUNTIME_RESUELTO=fake
MEFISTO_AGENT_TIMEOUT_SECONDS=60
EVENTS_LOG_ABS="$TMP/events"
PIPELINE_DIR_ABS="$TMP/state"
LOG_FILE="$TMP/pipeline.log"
mkdir -p "$LOG_DIR_ABS" "$PIPELINE_TMP_DIR" "$PIPELINE_DIR_ABS/metrics"
log(){ :; }
warn(){ :; }
abort(){ printf 'ABORT:%s\n' "$1" > "$TMP/abort"; exit 99; }
update_status(){ :; }
derive_stage_log_from_stream(){ : > "$3"; }
compute_stage_metrics(){ printf '{}'; }
agent_events_value(){ jq -r -s "$2" "$1" 2>/dev/null || true; }
agent_events_kind(){ agent_events_value "$1" '[.[] | select(.type == "run.failed" or .type == "run.completed") | .error.kind // empty] | last // empty'; }
agent_events_resets_at(){ agent_events_value "$1" '[.[] | select(.type == "run.failed" or .type == "run.completed") | .error.resets_at // .resets_at // empty] | last // empty'; }
agent_events_session_id(){ agent_events_value "$1" '[.[] | select(.type == "run.failed" or .type == "run.completed") | .session_id // empty] | last // empty'; }
agent_events_denials(){ agent_events_value "$1" '[.[] | select(.type == "run.failed" or .type == "run.completed") | .denials // 0] | last // 0'; }
agent_events_completed_successfully(){ jq -e -s '[.[] | select(.type == "run.failed" or .type == "run.completed")] | last | .type == "run.completed" and .status == "success"' "$1" >/dev/null 2>&1; }
classify_neutral_agent_failure(){ case "$1" in 124) printf TIMEOUT;; *) printf '%s' "$(agent_events_kind "$2" | tr '[:lower:]' '[:upper:]')";; esac; }
agent_failure_is_holdable(){ [ "$1" = RATE_LIMIT ] || [ "$1" = PROVIDER_UNAVAILABLE ]; }
agent_hold_wait(){ printf 0; }
runtime_supports_resume(){ return 0; }
resolve_stage_model(){ [ "${WITH_MODEL:-false}" = true ] && printf 'vendor/model'; return 0; }
resolve_declared_agent_model(){ :; }
run_tests_projects(){ printf called > "$TMP/gate-called"; return 0; }
dotnet(){ printf called > "$TMP/gate-called"; return 0; }
AGENT_TW_RES=pending; AGENT_IM_RES=pending; AGENT_ST_RES=pending; AGENT_RV_RES=pending
AGENT_TW_METRICS_JSON=; AGENT_IM_METRICS_JSON=; AGENT_ST_METRICS_JSON=; AGENT_RV_METRICS_JSON=
LAST_AGENT_DURATION=0; LAST_AGENT_METRICS_JSON=
run_agent "$STAGE" "$AGENT" 'prompt de regresion'
EOF
} > "$TMP/case.sh"

reset_case() {
    rm -f "$TMP"/call-*.args "$TMP/calls" "$TMP/abort" "$TMP/gate-called" "$WT/src/partial.txt"
    rm -f "$WT/.claude/pipeline/summaries"/*.md
}
run_case() {
    SCENARIO="$1" STAGE="${2:-1}" AGENT="${3:-test-writer}" WITH_MODEL="${4:-false}" bash "$TMP/case.sh"
}

reset_case
EXPECTED="$TMP/expected.args"
printf '%s\n' \
    --runtime fake \
    --agent test-writer \
    --cwd "$WT" \
    --prompt-file "$TMP/pipeline/1-test-writer.prompt.md" \
    --system-file "$TMP/pipeline/1-test-writer.system.md" \
    --event-log "$TMP/logs/stage-1-test-writer-20260914-120000-issue-1360-attempt-1.events.jsonl" \
    --events-log "$TMP/events" \
    --redact-observability \
    --timeout 60 \
    --model vendor/model > "$EXPECTED"
if run_case success 1 test-writer true && [ "$(cat "$TMP/calls")" = 1 ] \
    && cmp -s "$EXPECTED" "$TMP/call-1.args" \
    && [ "$(cat "$TMP/pipeline/1-test-writer.prompt.md")" = 'prompt de regresion' ] \
    && [ -s "$TMP/pipeline/1-test-writer.system.md" ]; then
    pass 'exito envia el argv exacto, incluido --model condicional'
else
    fail 'argv neutral de exito distinto al contrato'
fi

reset_case
if run_case hold && [ "$(cat "$TMP/calls")" = 2 ] \
    && ! grep -Fxq -- '--resume-session' "$TMP/call-1.args" \
    && grep -A1 -Fx -- '--resume-session' "$TMP/call-2.args" | grep -Fxq -- 'session-1360'; then
    pass 'fallo holdable sondea y reanuda por session_id neutral'
else
    fail 'hold no produjo una unica sonda reanudada'
fi

reset_case
if run_case denials && [ "$(cat "$TMP/calls")" = 2 ] \
    && ! grep -Fq -- '--resume-session' "$TMP/call-2.args"; then
    pass 'denials sin trabajo reintenta una sola vez desde cero incluso tras success'
else
    fail 'retry por denegaciones no fue unico o intento reanudar'
fi

reset_case
timeout_rc=0
run_case timeout 2 implementer || timeout_rc=$?
if [ "$timeout_rc" -eq 99 ] && [ "$(cat "$TMP/calls")" = 1 ] \
    && [ ! -e "$TMP/gate-called" ] && grep -Fq 'TIMEOUT' "$TMP/abort"; then
    pass 'TIMEOUT descarta trabajo parcial sin ejecutar el atajo de recuperacion'
else
    fail 'TIMEOUT entro al gate de recuperacion o no aborto'
fi

echo '[regresion] invocacion unica para Stage 0 y remediaciones'
{
    printf '%s\n' 'set -uo pipefail'
    invoke_agent_once_body
    cat <<'EOF'
PIPELINE_TMP_DIR="$TMP/pipeline-once"
MEFISTO_RUNTIME_RESUELTO=fake
WORKTREE_PATH="$WT"
RUN_AGENT_BIN="$TMP/runner"
EVENTS_LOG_ABS="$TMP/events-once"
MEFISTO_AGENT_TIMEOUT_SECONDS=60
LAST_AGENT_DURATION=0
LAST_AGENT_METRICS_JSON=null
mkdir -p "$PIPELINE_TMP_DIR"
derive_stage_log_from_stream(){ : > "$3"; }
compute_stage_metrics(){ printf '{}'; }
invoke_agent_once domain-scaffolder "$TMP/prompt" "$TMP/stage-0.events.jsonl" "$TMP/stage-0.log" "${MODEL:-}"
EOF
} > "$TMP/once-case.sh"
printf 'prompt Stage 0' > "$TMP/prompt"
reset_case
if SCENARIO=success MODEL=vendor/model bash "$TMP/once-case.sh" \
    && grep -A1 -Fx -- '--agent' "$TMP/call-1.args" | grep -Fxq domain-scaffolder \
    && grep -A1 -Fx -- '--model' "$TMP/call-1.args" | grep -Fxq vendor/model \
    && [ -f "$TMP/stage-0.log" ]; then
    pass 'Stage 0 exitoso usa el argv neutral y deriva su log desde JSONL'
else
    fail 'Stage 0 exitoso no uso el contrato neutral esperado'
fi

reset_case
once_rc=0
SCENARIO=timeout bash "$TMP/once-case.sh" || once_rc=$?
if [ "$once_rc" -eq 124 ] && [ "$(cat "$TMP/calls")" = 1 ]; then
    pass 'fallo de runner en Stage 0/remediacion retorna sin hold ni reintento'
else
    fail 'fallo de runner en Stage 0/remediacion no conserva la semantica unica'
fi

echo '[regresion] politicas ejecutables de Stage 0 y remediacion 4b'
# El bloque real de Stage 0 queda despues de sus dobles y variables en el caso
# ejecutable; se recompone en ese orden para no sustituir su politica.
{
    printf '%s\n' 'set -uo pipefail'
    invoke_agent_once_body
    cat <<'EOF'
PIPELINE_TMP_DIR="$TMP/pipeline-stage-zero"
MEFISTO_RUNTIME_RESUELTO=fake
MEFISTO_AGENT_TIMEOUT_SECONDS=60
WORKTREE_PATH="$WT"
RUN_AGENT_BIN="$TMP/runner"
EVENTS_LOG_ABS="$TMP/events-stage-zero"
LOG_DIR_ABS="$TMP/logs-stage-zero"
PIPELINE_DIR_ABS="$TMP/state-stage-zero"
TIMESTAMP=20260914-120000
ISSUE_LOG_TAG=1361
SCAFFOLD_DOMAIN=catalogo
HARNESS_NAMESPACE_PREFIX=Test
LAST_AGENT_DURATION=0
LAST_AGENT_METRICS_JSON=null
AGENT_SCAFFOLD_DUR=
AGENT_SCAFFOLD_METRICS_JSON=
mkdir -p "$PIPELINE_TMP_DIR" "$LOG_DIR_ABS" "$PIPELINE_DIR_ABS/metrics"
header(){ :; }
update_status(){ :; }
log(){ :; }
success(){ :; }
resolve_declared_agent_model(){ printf 'vendor/frontmatter'; }
derive_stage_log_from_stream(){ : > "$3"; }
compute_stage_metrics(){ printf '{"tokens":{"input":1}}'; }
agent_events_completed_successfully(){ jq -e -s '[.[] | select(.type == "run.completed")] | last | .status == "success"' "$1" >/dev/null 2>&1; }
abort(){ printf 'ABORT:%s\n' "$1" > "$TMP/stage-zero-abort"; exit 99; }
EOF
    stage_zero_body
} > "$TMP/stage-zero-case.sh"

reset_case
rm -rf "$WT/src/Test.Catalogo" "$TMP/state-stage-zero" "$TMP/logs-stage-zero" "$TMP/pipeline-stage-zero"
mkdir -p "$WT/src/Test.Catalogo"
if SCENARIO=success bash "$TMP/stage-zero-case.sh" \
    && [ "$(cat "$TMP/calls")" = 1 ] \
    && ! grep -Fxq -- '--model' "$TMP/call-1.args" \
    && [ -s "$TMP/state-stage-zero/metrics/tdd-20260914-120000-issue-1361-stage-0-domain-scaffolder.json" ]; then
    pass 'Stage 0 exitoso ejecuta el bloque real, no fuerza modelo y respalda metricas'
else
    fail 'Stage 0 exitoso no conservo su politica completa'
fi

reset_case
rm -f "$TMP/stage-zero-abort"
stage_zero_rc=0
SCENARIO=terminal-failure bash "$TMP/stage-zero-case.sh" || stage_zero_rc=$?
if [ "$stage_zero_rc" -eq 99 ] && grep -Fq 'El scaffold del dominio' "$TMP/stage-zero-abort"; then
    pass 'Stage 0 aborta ante terminal neutral sin status success aunque el runner retorne cero'
else
    fail 'Stage 0 acepto un terminal neutral fallido o no aborto'
fi

{
    printf '%s\n' 'set -uo pipefail'
    invoke_agent_once_body
    cat <<'EOF'
PIPELINE_TMP_DIR="$TMP/pipeline-remediation"
MEFISTO_RUNTIME_RESUELTO=fake
MEFISTO_AGENT_TIMEOUT_SECONDS=60
WORKTREE_PATH="$WT"
RUN_AGENT_BIN="$TMP/runner"
EVENTS_LOG_ABS="$TMP/events-remediation"
PIPELINE_DIR_ABS="$TMP/state-remediation"
TIMESTAMP=20260914-120000
ISSUE_LOG_TAG=1361
STAGE1_AGENT=test-writer
PATCH_TW_PROMPT_FILE="$TMP/prompt"
EVENTS_CG_TW="$TMP/remediation.events.jsonl"
LOG_CG_TW="$TMP/remediation.log"
PATCH_TW_MODEL_OVERRIDE=
LAST_AGENT_DURATION=0
LAST_AGENT_METRICS_JSON=null
COV_REMEDIATION_SUMMARY=
mkdir -p "$PIPELINE_TMP_DIR" "$PIPELINE_DIR_ABS/metrics"
warn(){ :; }
derive_stage_log_from_stream(){ : > "$3"; }
compute_stage_metrics(){ printf '{"tokens":{"input":1}}'; }
agent_events_completed_successfully(){ jq -e -s '[.[] | select(.type == "run.completed")] | last | .status == "success"' "$1" >/dev/null 2>&1; }
EOF
    remediation_4b_failure_body
    cat <<'EOF'
printf 'CONTINUA:%s\n' "$COV_REMEDIATION_SUMMARY"
EOF
} > "$TMP/remediation-case.sh"

reset_case
rm -rf "$TMP/state-remediation" "$TMP/pipeline-remediation"
remediation_output=$(SCENARIO=terminal-failure bash "$TMP/remediation-case.sh")
if printf '%s' "$remediation_output" | grep -Fq 'CONTINUA:El test-writer de remediacion fallo (exit 0)' \
    && grep -Fq 'REMEDIATION_FAILED: test-writer exit 0' "$TMP/events-remediation" \
    && [ -s "$TMP/state-remediation/metrics/tdd-20260914-120000-issue-1361-stage-4b-test-writer.json" ]; then
    pass 'remediacion 4b fallida registra evidencia y continua sin abortar ni reintentar'
else
    fail 'remediacion 4b fallida no conservo advertir-y-continuar con evidencia'
fi

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
