#!/usr/bin/env bash
# Regresion focalizada de #1360/#1361: TDD solo consume el contrato JSONL.
# Extendida por #1363: identidad neutral, metricas por stage enriquecidas y
# retiro del parche de .claude/settings.json (MEF-ADR-0050/0053/0054).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PIPELINE="$ROOT/scripts/tdd-pipeline.sh"
COMMON="$ROOT/scripts/_pipeline-common.sh"
PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { grep -Fq -- "$1" "$PIPELINE" && pass "$2" || fail "$2"; }
run_agent_body() { awk '/^run_agent\(\) \{/{p=1} p{print} p && /^}/{p=0}' "$PIPELINE"; }
collect_summary_body() { awk '/^collect_summary\(\) \{/{p=1} p{print} p && /^}/{p=0}' "$PIPELINE"; }
# CA-4 (issue #1363): la implementacion REAL de derive_stage_log_from_stream
# (no un stub) para el caso de redaccion -- necesita el filtro autentico para
# comprobar que el .log derivado no expone message/input_summary/error.detail.
derive_stage_log_from_stream_body() { awk '/^derive_stage_log_from_stream\(\) \{/{p=1} p{print} p && /^}/{p=0}' "$COMMON"; }
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
contains 'update_status "$stage-$agent" "hold"' 'hold estructurado: run_agent actualiza el status antes de esperar (issue #1600)'
contains 'HOLD_CAUSE_JSON="null"; HOLD_NEXT_PROBE_JSON="null"; HOLD_CEILING_JSON="null"; HOLD_TOTAL="$hold_total"' 'hold estructurado: run_agent limpia cause/next_probe/ceiling al terminar (issue #1600)'
contains '"hold": {"cause": $HOLD_CAUSE_JSON, "next_probe": $HOLD_NEXT_PROBE_JSON, "ceiling_seconds": $HOLD_CEILING_JSON, "accumulated_seconds": $HOLD_TOTAL}' 'hold estructurado: update_status incluye el bloque hold (issue #1600)'
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

echo '[estatico] identidad, enrich por stage y observabilidad neutralizada (issue #1363)'
contains 'HARNESS_IDENTITY_JSON="$(get_harness_identity_json)"' 'identidad se inicializa desde el paquete tras load_harness_config'
contains 'HARNESS_IDENTITY_JSON="$(get_harness_identity_json "$MEFISTO_RUNTIME_RESUELTO")"' 'identidad se revalida contra el runtime resuelto'
contains 'enrich_stage_metrics "tdd" "$events_file" "$metrics_json"' 'run_agent enriquece las metricas por stage (ruta 1/4)'
contains 'enrich_stage_metrics "tdd" "$EVENTS_SCAFFOLD"' 'Stage 0 enriquece las metricas del scaffold (ruta 2/4)'
contains 'enrich_stage_metrics "tdd" "$EVENTS_CG_TW"' 'remediacion 4b enriquece sus metricas (ruta 3/4)'
contains 'enrich_stage_metrics "tdd" "$EVENTS_CG_IM"' 'remediacion 4c enriquece sus metricas (ruta 4/4)'
absent_pipeline 'WORKTREE_PATH/.claude/settings.json' 'TDD no parchea settings.json del worktree (MEF-ADR-0050)'
absent_pipeline 'checkout -- .claude' 'TDD no restaura .claude/ del worktree con git checkout'

echo '[regresion] contrato ejecutable de run_agent'
TMP="$(mktemp -d -t mefisto-tdd-neutral)"
trap 'rm -rf "$TMP"' EXIT
WT="$TMP/worktree"
mkdir -p "$WT/tests" "$WT/src" "$WT/.mefisto/pipeline/summaries" "$WT/.claude/pipeline/summaries"
git -C "$WT" init -q
git -C "$WT" config user.email test@example.invalid
git -C "$WT" config user.name Test
printf 'base\n' > "$WT/tests/base.txt"
git -C "$WT" add tests/base.txt
git -C "$WT" commit -qm base

# El chequeo estatico de los cuatro call sites se complementa con el contrato
# ejecutable del helper generalizado: evita que el wrapper de tooling siga
# verde mientras la ruta pipeline=tdd pierde alguna dimension de correlacion.
cat > "$TMP/enrich.events.jsonl" <<'EOF'
{"type":"run.started","runtime":"opencode","model":"vendor/requested"}
{"type":"run.completed","runtime":"opencode","model":"vendor/effective","session_id":"session-tdd","status":"success","error":null}
EOF
ENRICHED_TDD="$(bash -c 'source "$1"; enrich_stage_metrics tdd "$2" '\''{"tokens":{"input":7}}'\'' 1363 '\''"variante-a"'\'' 4b projection-test-writer balanced '\''{"harness_version":"1.2.3","harness_commit":"0123456789abcdef0123456789abcdef01234567","identity_state":"complete"}'\''' _ "$COMMON" "$TMP/enrich.events.jsonl")"
if printf '%s' "$ENRICHED_TDD" | jq -e '
    .pipeline == "tdd" and .issue == "1363" and .variant == "variante-a"
    and .stage == "4b" and .agent == "projection-test-writer"
    and .profile == "balanced" and .runtime == "opencode"
    and .requested_model == "vendor/requested"
    and .effective_model == "vendor/effective"
    and .session_id == "session-tdd" and .result == "success"
    and .error_kind == null and .harness_version == "1.2.3"
    and .harness_commit == "0123456789abcdef0123456789abcdef01234567"
    and .identity_state == "complete" and .tokens.input == 7
' >/dev/null; then
    pass 'enrich_stage_metrics conserva metricas base y agrega todas las dimensiones de TDD'
else
    fail "enrich_stage_metrics no produjo el contrato TDD esperado: $ENRICHED_TDD"
fi

export TMP WT ROOT
cat > "$TMP/runner" <<'EOF'
#!/usr/bin/env bash
count=$(cat "$TMP/calls" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s' "$count" > "$TMP/calls"
printf '%s\n' "$@" > "$TMP/call-${count}.args"
event=""; cwd=""; redact=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --event-log) event="$2"; shift 2 ;;
        --cwd) cwd="$2"; shift 2 ;;
        --redact-observability) redact=true; shift ;;
        *) shift ;;
    esac
done
case "$SCENARIO:$count" in
    success:1|denials:2)
        printf '%s\n' '{"type":"run.completed","status":"success","session_id":null,"denials":0,"error":null}' > "$event"
        exit 0 ;;
    legacy-summary:1)
        mkdir -p "$cwd/.claude/pipeline/summaries"
        printf 'summary legacy\n' > "$cwd/.claude/pipeline/summaries/stage-1-test-writer.md"
        printf '%s\n' '{"type":"run.completed","status":"success","session_id":null,"denials":0,"error":null}' > "$event"
        exit 0 ;;
    denials-state:1)
        mkdir -p "$cwd/.mefisto/pipeline"
        printf 'estado transitorio\n' > "$cwd/.mefisto/pipeline/agent-state.txt"
        git -C "$cwd" add -f .mefisto/pipeline/agent-state.txt
        git -C "$cwd" commit -qm 'test: estado transitorio'
        printf '%s\n' '{"type":"run.completed","status":"success","session_id":null,"denials":2,"error":null}' > "$event"
        exit 0 ;;
    denials-state:2)
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
    redact:1)
        # CA-4 (issue #1363): el doble aplica el MISMO filtro que
        # redact_observability_events (src/runtime/mefisto-run-agent.sh)
        # cuando recibe --redact-observability, sobre eventos crudos con
        # contenido sensible -- verifica que run_agent() no reintroduce ese
        # contenido en el events.jsonl persistido ni en el .log derivado.
        : > "$event"
        for raw in \
            '{"type":"message","text":"SECRETO_PROMPT_TEXT"}' \
            '{"type":"tool.started","tool":"Bash","input_summary":"SECRETO_INPUT_SUMMARY"}' \
            '{"type":"run.failed","status":"failed","session_id":null,"denials":0,"error":{"kind":"protocol_invalid","detail":"SECRETO_ERROR_DETAIL"}}'; do
            if [ "$redact" = true ]; then
                printf '%s\n' "$raw" | jq -c '
                    select(type == "object")
                    | if .type == "message" then empty
                      elif .type == "tool.started" then .input_summary = null
                      elif ((.error? | type) == "object") then
                          .error.detail = ("detalle redactado: " + .error.kind)
                      else .
                      end
                ' >> "$event"
            else
                printf '%s\n' "$raw" >> "$event"
            fi
        done
        exit 1 ;;
esac
exit 70
EOF
chmod +x "$TMP/runner"

{
    printf '%s\n' 'set -uo pipefail'
    run_agent_body
    collect_summary_body
    derive_stage_log_from_stream_body
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
PIPELINE_OWN_WRITES=(':!.mefisto/pipeline')
mefisto_state_path(){ local rel="$1" root="${2:-}"; local base; if [ -n "$root" ]; then base="$root/.mefisto/pipeline"; else base="$PIPELINE_DIR_ABS"; fi; mkdir -p "$(dirname "$base/$rel")"; printf '%s\n' "$base/$rel"; }
mefisto_state_read_first(){ local rel="$1" root="$2"; local canonical="$root/.mefisto/pipeline/$rel" legacy="$root/.claude/pipeline/$rel"; [ -e "$canonical" ] && { printf '%s\n' "$canonical"; return 0; }; [ -e "$legacy" ] && printf '%s\n' "$legacy"; }
log(){ :; }
warn(){ :; }
abort(){ printf 'ABORT:%s\n' "$1" > "$TMP/abort"; exit 99; }
# update_status persiste cada invocacion como una linea jsonl con el bloque
# hold vigente al momento de la llamada (issue #1600, CA-4): asi el test puede
# inspeccionar el estado "hold" intermedio sin depender de un status file real.
update_status(){ printf '{"stage":"%s","state":"%s","hold":{"cause":%s,"next_probe":%s,"ceiling_seconds":%s,"accumulated_seconds":%s}}\n' "$1" "$2" "$HOLD_CAUSE_JSON" "$HOLD_NEXT_PROBE_JSON" "$HOLD_CEILING_JSON" "$HOLD_TOTAL" >> "$TMP/status-calls.jsonl"; }
compute_stage_metrics(){ printf '{}'; }
HARNESS_IDENTITY_JSON='null'
enrich_stage_metrics(){ printf '%s' "${3:-null}"; }
agent_events_value(){ jq -r -s "$2" "$1" 2>/dev/null || true; }
agent_events_kind(){ agent_events_value "$1" '[.[] | select(.type == "run.failed" or .type == "run.completed") | .error.kind // empty] | last // empty'; }
agent_events_resets_at(){ agent_events_value "$1" '[.[] | select(.type == "run.failed" or .type == "run.completed") | .error.resets_at // .resets_at // empty] | last // empty'; }
agent_events_session_id(){ agent_events_value "$1" '[.[] | select(.type == "run.failed" or .type == "run.completed") | .session_id // empty] | last // empty'; }
agent_events_denials(){ agent_events_value "$1" '[.[] | select(.type == "run.failed" or .type == "run.completed") | .denials // 0] | last // 0'; }
agent_events_completed_successfully(){ jq -e -s '[.[] | select(.type == "run.failed" or .type == "run.completed")] | last | .type == "run.completed" and .status == "success"' "$1" >/dev/null 2>&1; }
classify_neutral_agent_failure(){ case "$1" in 124) printf TIMEOUT;; *) printf '%s' "$(agent_events_kind "$2" | tr '[:lower:]' '[:upper:]')";; esac; }
agent_failure_is_holdable(){ [ "$1" = RATE_LIMIT ] || [ "$1" = PROVIDER_UNAVAILABLE ]; }
agent_hold_wait(){ printf 1; }
runtime_supports_resume(){ return 0; }
resolve_stage_model(){ [ "${WITH_MODEL:-false}" = true ] && printf 'vendor/model'; return 0; }
resolve_declared_agent_model(){ :; }
_tdd_agent_profile(){ printf 'balanced'; }
resolve_tdd_model(){ RESOLVED_TDD_MODEL=""; [ "${WITH_MODEL:-false}" = true ] && RESOLVED_TDD_MODEL='vendor/model'; }
run_tests_projects(){ printf called > "$TMP/gate-called"; return 0; }
dotnet(){ printf called > "$TMP/gate-called"; return 0; }
AGENT_TW_RES=pending; AGENT_IM_RES=pending; AGENT_ST_RES=pending; AGENT_RV_RES=pending
AGENT_TW_METRICS_JSON=; AGENT_IM_METRICS_JSON=; AGENT_ST_METRICS_JSON=; AGENT_RV_METRICS_JSON=
LAST_AGENT_DURATION=0; LAST_AGENT_METRICS_JSON=
HOLD_CAUSE_JSON="null" HOLD_NEXT_PROBE_JSON="null" HOLD_CEILING_JSON="null" HOLD_TOTAL=0
run_agent "$STAGE" "$AGENT" "${PROMPT:-prompt de regresion}"
collect_summary "$STAGE" "$AGENT" > "$TMP/collected-summary"
printf '%s\n%s\n%s\n' "$HOLD_CAUSE_JSON" "$HOLD_NEXT_PROBE_JSON" "$HOLD_TOTAL" > "$TMP/hold-after"
EOF
} > "$TMP/case.sh"

reset_case() {
    rm -f "$TMP"/call-*.args "$TMP/calls" "$TMP/abort" "$TMP/gate-called" "$TMP/collected-summary" "$WT/src/partial.txt"
    rm -f "$TMP/status-calls.jsonl" "$TMP/hold-after"
    rm -f "$WT/.mefisto/pipeline/summaries"/*.md "$WT/.claude/pipeline/summaries"/*.md
    git -C "$WT" reset -q --hard HEAD~1 2>/dev/null || true
}
run_case() {
    SCENARIO="$1" STAGE="${2:-1}" AGENT="${3:-test-writer}" WITH_MODEL="${4:-false}" PROMPT="${5:-}" bash "$TMP/case.sh"
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
    && grep -Fqx 'prompt de regresion' "$TMP/pipeline/1-test-writer.prompt.md" \
    && grep -Fqx "Al cerrar este stage, deja tu resumen en: $WT/.mefisto/pipeline/summaries/stage-1-test-writer.md" "$TMP/pipeline/1-test-writer.prompt.md" \
    && [ -s "$TMP/pipeline/1-test-writer.system.md" ]; then
    pass 'exito envia el argv exacto, incluido --model condicional'
else
    fail 'argv neutral de exito distinto al contrato'
fi

reset_case
if run_case legacy-summary 1 test-writer false \
    && [ -f "$WT/.claude/pipeline/summaries/stage-1-test-writer.md" ] \
    && [ ! -f "$WT/.mefisto/pipeline/summaries/stage-1-test-writer.md" ] \
    && [ "$(cat "$TMP/collected-summary")" = 'summary legacy' ]; then
    pass 'collect_summary recolecta un summary presente solo en la ruta legacy'
else
    fail 'collect_summary no resolvio el summary legacy como fallback'
fi

reset_case
if run_case denials-state && [ "$(cat "$TMP/calls")" = 2 ]; then
    pass 'estado canonico commiteado no cuenta como trabajo util ante denegaciones'
else
    fail 'estado canonico commiteado impidio el retry sin trabajo util'
fi

reset_case
if run_case hold && [ "$(cat "$TMP/calls")" = 2 ] \
    && ! grep -Fxq -- '--resume-session' "$TMP/call-1.args" \
    && grep -A1 -Fx -- '--resume-session' "$TMP/call-2.args" | grep -Fxq -- 'session-1360'; then
    pass 'fallo holdable sondea y reanuda por session_id neutral'
else
    fail 'hold no produjo una unica sonda reanudada'
fi

# CA-4 (issue #1600): mismo escenario "hold" de arriba, verificando ademas el
# bloque hold estructurado del status -- (a) durante la espera, state=hold con
# cause/next_probe no nulos; (b) al completar, cause/next_probe vuelven a null
# y accumulated_seconds conserva el total esperado (agent_hold_wait stub
# duerme 1s, ver el stub en case.sh).
HOLD_STATUS_LINE="$(jq -c 'select(.state == "hold")' "$TMP/status-calls.jsonl" 2>/dev/null | tail -1)"
if [ -n "$HOLD_STATUS_LINE" ] \
    && printf '%s' "$HOLD_STATUS_LINE" | jq -e '.hold.cause == "RATE_LIMIT"' >/dev/null 2>&1 \
    && printf '%s' "$HOLD_STATUS_LINE" | jq -e '.hold.next_probe != null' >/dev/null 2>&1; then
    pass 'CA-4a: durante la espera el status queda en state=hold con cause/next_probe no nulos'
else
    fail "CA-4a: status durante la espera no cumple el contrato: $HOLD_STATUS_LINE"
fi
HOLD_AFTER_CAUSE="$(sed -n '1p' "$TMP/hold-after" 2>/dev/null)"
HOLD_AFTER_PROBE="$(sed -n '2p' "$TMP/hold-after" 2>/dev/null)"
HOLD_AFTER_TOTAL="$(sed -n '3p' "$TMP/hold-after" 2>/dev/null)"
if [ "$HOLD_AFTER_CAUSE" = "null" ] && [ "$HOLD_AFTER_PROBE" = "null" ] \
    && [ -n "$HOLD_AFTER_TOTAL" ] && [ "$HOLD_AFTER_TOTAL" -ge 1 ]; then
    pass 'CA-4b: al completar, cause/next_probe vuelven a null y accumulated_seconds conserva el total (>=1)'
else
    fail "CA-4b: hold tras completar no limpio (cause=$HOLD_AFTER_CAUSE next_probe=$HOLD_AFTER_PROBE total=$HOLD_AFTER_TOTAL)"
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

# CA-4 (issue #1363): runner doble que emite message/tool.started con
# input_summary/run.failed con error.detail crudos, aplicando el mismo filtro
# de --redact-observability que mefisto-run-agent.sh. Verifica que run_agent
# sigue pasando --redact-observability y que ni el events.jsonl persistido ni
# el .log derivado (derive_stage_log_from_stream) exponen ese contenido.
reset_case
redact_rc=0
PROMPT_SECRET=SECRETO_PROMPT_TEXT
run_case redact 1 test-writer false "$PROMPT_SECRET" || redact_rc=$?
EVENTS_REDACT="$TMP/logs/stage-1-test-writer-20260914-120000-issue-1360-attempt-1.events.jsonl"
LOG_REDACT="$TMP/logs/stage-1-test-writer-20260914-120000-issue-1360.log"
if [ "$redact_rc" -eq 99 ] \
    && grep -Fxq -- '--redact-observability' "$TMP/call-1.args" \
    && grep -Fqx "$PROMPT_SECRET" "$TMP/pipeline/1-test-writer.prompt.md" \
    && [ -s "$EVENTS_REDACT" ] && [ -s "$LOG_REDACT" ] \
    && ! grep -Eq 'SECRETO_PROMPT_TEXT|SECRETO_INPUT_SUMMARY|SECRETO_ERROR_DETAIL' "$EVENTS_REDACT" \
    && ! grep -Eq 'SECRETO_PROMPT_TEXT|SECRETO_INPUT_SUMMARY|SECRETO_ERROR_DETAIL' "$LOG_REDACT"; then
    pass 'run_agent pasa --redact-observability; ni el events.jsonl persistido ni el .log derivado exponen message/input_summary/error.detail crudos'
else
    fail 'la redaccion no se sostuvo: argv, events.jsonl persistido o el log derivado no coinciden con el contrato'
fi

echo '[regresion] contexto acotado del reviewer en Stage 3 (issue #1450)'
CTX_TMP="$(mktemp -d -t mefisto-tdd-reviewer-ctx)"
CTX_WT="$CTX_TMP/worktree"
mkdir -p "$CTX_WT"
git -C "$CTX_WT" init -q
git -C "$CTX_WT" config user.email test@example.invalid
git -C "$CTX_WT" config user.name Test
printf 'base\n' > "$CTX_WT/base.txt"
git -C "$CTX_WT" add base.txt
git -C "$CTX_WT" commit -qm base
CTX_SNAPSHOT="$(git -C "$CTX_WT" rev-parse HEAD)"
mkdir -p "$CTX_WT/tests"
# Texto, no binario: git no emite contenido para un blob binario, asi que un archivo
# binario grande dejaria el assert de tamano del prompt sin poder de deteccion.
awk 'BEGIN{for(i=0;i<50000;i++) printf "linea %d de contenido generado por el test-writer para inflar el diff\n", i}' > "$CTX_WT/tests/generated.txt"
printf 'contenido nuevo\n' > "$CTX_WT/tests/nota.md"
git -C "$CTX_WT" add tests/generated.txt tests/nota.md
git -C "$CTX_WT" commit -qm 'test-writer: fases roja y verde con archivo grande'
CTX_HEAD="$(git -C "$CTX_WT" rev-parse HEAD)"
CTX_RAW_DIFF_BYTES=$(git -C "$CTX_WT" diff "$CTX_SNAPSHOT"..HEAD | wc -c | tr -d ' ')
[ "$CTX_RAW_DIFF_BYTES" -ge 3145728 ] \
    || fail "premisa invalida: el diff completo mide ${CTX_RAW_DIFF_BYTES} bytes (< 3 MB), el caso no discriminaria el contexto acotado"
CTX_LOGS="$CTX_TMP/logs"
CTX_PIPELINE_TMP="$CTX_TMP/pipeline"
mkdir -p "$CTX_LOGS" "$CTX_PIPELINE_TMP"
export CTX_TMP CTX_WT CTX_SNAPSHOT CTX_LOGS CTX_PIPELINE_TMP

cat > "$CTX_TMP/run-agent-double" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
    case "$1" in
        --event-log) printf '%s\n' '{"type":"run.completed","status":"success","session_id":null,"denials":0,"error":null}' > "$2"; shift 2 ;;
        *) shift ;;
    esac
done
EOF
chmod +x "$CTX_TMP/run-agent-double"

{
    printf '%s\n' 'set -eu'
    run_agent_body
    derive_stage_log_from_stream_body
    cat <<'EOF'
LOG_DIR_ABS="$CTX_LOGS"
TIMESTAMP='20260918-000000'
ISSUE_LOG_TAG='1450'
PIPELINE_TMP_DIR="$CTX_PIPELINE_TMP"
WORKTREE_PATH="$CTX_WT"
SNAPSHOT_COMMIT="$CTX_SNAPSHOT"
RUN_AGENT_BIN="$CTX_TMP/run-agent-double"
MEFISTO_RUNTIME_RESUELTO='fake'
MEFISTO_AGENT_TIMEOUT_SECONDS=60
EVENTS_LOG_ABS="$CTX_TMP/events.log"
PIPELINE_DIR_ABS="$CTX_TMP/state"
LOG_FILE="$CTX_TMP/pipeline.log"
ISSUE_NUM=1450
HARNESS_PROJECT_NAME='proyecto-consumidor-test'
ISSUE_CONTEXT='# Issue de prueba con contexto minimo'
PIPELINE_OWN_WRITES=(':!.mefisto/pipeline')
mkdir -p "$LOG_DIR_ABS" "$PIPELINE_TMP_DIR" "$PIPELINE_DIR_ABS/metrics"
mefisto_state_path(){ local rel="$1" root="${2:-}"; local base; if [ -n "$root" ]; then base="$root/.mefisto/pipeline"; else base="$PIPELINE_DIR_ABS"; fi; mkdir -p "$(dirname "$base/$rel")"; printf '%s\n' "$base/$rel"; }
mefisto_state_read_first(){ local rel="$1" root="$2"; local canonical="$root/.mefisto/pipeline/$rel" legacy="$root/.claude/pipeline/$rel"; [ -e "$canonical" ] && { printf '%s\n' "$canonical"; return 0; }; [ -e "$legacy" ] && printf '%s\n' "$legacy"; }
log(){ :; }
warn(){ :; }
abort(){ printf 'ABORT:%s\n' "$1" > "$CTX_TMP/abort"; return 1; }
update_status(){ :; }
compute_stage_metrics(){ printf '{}'; }
HARNESS_IDENTITY_JSON='null'
enrich_stage_metrics(){ printf '%s' "${3:-null}"; }
agent_events_denials(){ printf '0'; }
agent_events_completed_successfully(){ return 0; }
classify_neutral_agent_failure(){ printf 'UNKNOWN'; }
agent_failure_is_holdable(){ return 1; }
_tdd_agent_profile(){ printf 'balanced'; }
resolve_tdd_model(){ RESOLVED_TDD_MODEL=""; }
AGENT_TW_RES=pending; AGENT_IM_RES=pending; AGENT_ST_RES=pending; AGENT_RV_RES=pending
AGENT_TW_METRICS_JSON=; AGENT_IM_METRICS_JSON=; AGENT_ST_METRICS_JSON=; AGENT_RV_METRICS_JSON=
EOF
    awk '/^        WRITER_HEAD_SHA=\$\(git -C "\$WORKTREE_PATH" rev-parse HEAD\)$/{p=1} p{print} p && /^PROHIBIDO hacer .git push. o .gh pr create. \(ni ninguna operacion de publicacion de rama\/PR\): eso es responsabilidad exclusiva del pipeline, nunca tuya\."$/{exit}' "$PIPELINE"
    printf '\n%s\n' 'run_agent "3" "reviewer" "$STAGE3_PROMPT"'
} > "$CTX_TMP/case.sh"

if bash "$CTX_TMP/case.sh"; then
    CTX_PROMPT="$CTX_PIPELINE_TMP/3-reviewer.prompt.md"
    CTX_SIZE=$(wc -c < "$CTX_PROMPT" 2>/dev/null | tr -d ' ')
    if [ -f "$CTX_PROMPT" ] && [ -n "$CTX_SIZE" ] && [ "$CTX_SIZE" -lt 65536 ] \
        && grep -Fq "$CTX_SNAPSHOT" "$CTX_PROMPT" \
        && grep -Fq "$CTX_HEAD" "$CTX_PROMPT" \
        && grep -Fq 'tests/generated.txt' "$CTX_PROMPT" \
        && grep -Fq 'tests/nota.md' "$CTX_PROMPT" \
        && ! grep -Fq 'diff --git' "$CTX_PROMPT" \
        && ! grep -Fq '@@' "$CTX_PROMPT"; then
        pass "prompt del reviewer Stage 3 acotado a SHA/stat/rutas: ${CTX_SIZE} bytes frente a un diff crudo de las fases roja y verde de ${CTX_RAW_DIFF_BYTES} bytes"
    else
        fail "prompt del reviewer Stage 3 no cumple el contrato acotado (tamano=${CTX_SIZE:-desconocido})"
    fi
else
    fail 'la construccion del prompt de Stage 3 (reviewer, rama no-refactor) fallo'
fi
rm -rf "$CTX_TMP"

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
mefisto_state_path(){ local rel="$1"; mkdir -p "$(dirname "$PIPELINE_DIR_ABS/$rel")"; printf '%s\n' "$PIPELINE_DIR_ABS/$rel"; }
header(){ :; }
update_status(){ :; }
log(){ :; }
success(){ :; }
_tdd_agent_profile(){ printf 'balanced'; }
resolve_tdd_model(){ RESOLVED_TDD_MODEL=""; }
derive_stage_log_from_stream(){ : > "$3"; }
compute_stage_metrics(){ printf '{"tokens":{"input":1}}'; }
HARNESS_IDENTITY_JSON='null'
enrich_stage_metrics(){ printf '%s' "${3:-null}"; }
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
PATCH_TW_PROFILE=balanced
LAST_AGENT_DURATION=0
LAST_AGENT_METRICS_JSON=null
COV_REMEDIATION_SUMMARY=
mkdir -p "$PIPELINE_TMP_DIR" "$PIPELINE_DIR_ABS/metrics"
mefisto_state_path(){ local rel="$1"; mkdir -p "$(dirname "$PIPELINE_DIR_ABS/$rel")"; printf '%s\n' "$PIPELINE_DIR_ABS/$rel"; }
warn(){ :; }
derive_stage_log_from_stream(){ : > "$3"; }
compute_stage_metrics(){ printf '{"tokens":{"input":1}}'; }
HARNESS_IDENTITY_JSON='null'
enrich_stage_metrics(){ printf '%s' "${3:-null}"; }
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
