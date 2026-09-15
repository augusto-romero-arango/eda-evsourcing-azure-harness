#!/usr/bin/env bash
# Regresion focalizada de #1360: run_agent TDD solo consume el contrato JSONL.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PIPELINE="$ROOT/scripts/tdd-pipeline.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { grep -Fq -- "$1" "$PIPELINE" && pass "$2" || fail "$2"; }
absent_run_agent() { awk '/^run_agent\(\) \{/{p=1} p{print} p && /^}/{p=0}' "$PIPELINE" | grep -Fq -- "$1" && fail "$2" || pass "$2"; }

echo '[estatico] frontera neutral'
contains 'RUN_AGENT_BIN_DEFAULT="$RUNTIME_DIR/mefisto-run-agent.sh"' 'bootstrap localiza el runner publicado'
contains 'mefisto_resolve_runtime' 'resuelve el runtime antes del worktree'
contains 'MEFISTO_AGENT_TIMEOUT_SECONDS="${MEFISTO_AGENT_TIMEOUT_SECONDS:-1800}"' 'valida timeout neutral'
contains 'agent_events_completed_successfully "$events_file"' 'exige terminal exitoso neutral'
contains 'classify_neutral_agent_failure "$run_exit" "$events_file"' 'clasifica el terminal neutral'
contains 'agent_hold_wait "$EVENTS_LOG_ABS" "$failure_type" "$hold_started" "$(agent_events_resets_at "$events_file")"' 'hold consume resets_at neutral'
contains 'args+=(--resume-session "$resume_session")' 'sonda reanuda por session_id'
contains 'agent_events_denials "$events_file"' 'retry unico consume denegaciones neutrales'
contains 'TIMEOUT|KILLED|STREAM_CUT|PROTOCOL_INVALID' 'terminales incompletos excluyen recuperacion'
contains 'attempt-${attempt}.events.jsonl' 'cada intento conserva eventos propios'
absent_run_agent 'claude ' 'run_agent no nombra el CLI de Claude'
absent_run_agent '--output-format' 'run_agent no conoce formatos del runtime'
absent_run_agent 'kill -9' 'run_agent delega watchdog al runner'
absent_run_agent 'agent_session_transcript_count' 'run_agent no inspecciona transcripts privados'

echo '[regresion] argv neutral ejecutable'
TMP="$(mktemp -d -t mefisto-tdd-neutral)"; trap 'rm -rf "$TMP"' EXIT
ARGS="$TMP/args"; CALLS="$TMP/calls"; export ARGS CALLS TMP ROOT
cat > "$TMP/runner" <<'EOF'
#!/usr/bin/env bash
n=$(cat "$CALLS" 2>/dev/null || printf 0); n=$((n + 1)); printf '%s' "$n" > "$CALLS"
printf '%s\n' "$@" > "$ARGS"
while [ "$#" -gt 0 ]; do
  case "$1" in --event-log) event="$2"; shift 2;; *) shift;; esac
done
printf '%s\n' '{"type":"run.completed","status":"success","session_id":null,"denials":0,"error":null}' > "$event"
EOF
chmod +x "$TMP/runner"
{
    printf '%s\n' 'set -eu'
    awk '/^run_agent\(\) \{/{p=1} p{print} p && /^}/{p=0}' "$PIPELINE"
    cat <<'EOF'
LOG_DIR_ABS="$TMP/logs"; TIMESTAMP=t; ISSUE_LOG_TAG=1360; PIPELINE_TMP_DIR="$TMP/pipeline"; WORKTREE_PATH="$ROOT"; RUN_AGENT_BIN="$TMP/runner"; MEFISTO_RUNTIME_RESUELTO=fake; MEFISTO_AGENT_TIMEOUT_SECONDS=60; EVENTS_LOG_ABS="$TMP/events"; PIPELINE_DIR_ABS="$TMP/state"; SNAPSHOT_COMMIT=HEAD
mkdir -p "$LOG_DIR_ABS" "$PIPELINE_TMP_DIR" "$PIPELINE_DIR_ABS/metrics" "$WORKTREE_PATH/.claude/pipeline/summaries"
log(){ :; }; warn(){ :; }; abort(){ return 1; }; update_status(){ :; }; derive_stage_log_from_stream(){ :; }; compute_stage_metrics(){ printf null; }; agent_events_denials(){ printf 0; }; agent_events_completed_successfully(){ return 0; }; classify_neutral_agent_failure(){ printf CLI_ERROR; }; agent_failure_is_holdable(){ return 1; }; agent_hold_wait(){ return 1; }; agent_events_resets_at(){ :; }; runtime_supports_resume(){ return 1; }; agent_events_session_id(){ :; }; resolve_stage_model(){ :; }; resolve_declared_agent_model(){ :; }; run_tests_projects(){ return 1; }
AGENT_TW_RES=pending; AGENT_IM_RES=pending; AGENT_RV_RES=pending; AGENT_TW_METRICS_JSON=; AGENT_IM_METRICS_JSON=; AGENT_ST_METRICS_JSON=; AGENT_RV_METRICS_JSON=; LAST_AGENT_DURATION=0; LAST_AGENT_METRICS_JSON=
run_agent 1 test-writer 'prompt de regresion'
EOF
} > "$TMP/case.sh"
if bash "$TMP/case.sh" && [ "$(cat "$CALLS")" = 1 ] \
    && grep -qxF -- '--runtime' "$ARGS" && grep -qxF -- 'fake' "$ARGS" \
    && grep -qxF -- '--agent' "$ARGS" && grep -qxF -- 'test-writer' "$ARGS" \
    && grep -qxF -- '--redact-observability' "$ARGS" && grep -qxF -- '--timeout' "$ARGS"; then
    pass 'runner doble recibe argv neutral en exito'
else
    fail 'run_agent no invoca el runner neutral esperado'
fi

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
