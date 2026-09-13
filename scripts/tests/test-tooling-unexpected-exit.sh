#!/usr/bin/env bash
# Regresion focalizada de #1286: el cierre EXIT reconcilia estados activos
# cuando Bash termina por un error no controlado.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PIPELINE="$ROOT/scripts/tooling-pipeline.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

# Extrae las funciones reales del pipeline para que el test ejecute exactamente
# el handler publicado, sin arrancar GitHub, worktrees ni un runtime de agente.
FUNCTIONS="$TMP/finalization-functions.sh"
awk '/^cleanup_pipeline_temporaries\(\)/,/^_strip_ansi\(\)/ { if ($0 !~ /^_strip_ansi\(\)/) print }' "$PIPELINE" > "$FUNCTIONS"
awk '/^abort\(\)/,/^update_status\(\)/ { if ($0 !~ /^update_status\(\)/) print }' "$PIPELINE" >> "$FUNCTIONS"
awk '/^update_status\(\)/,/^# extract_test_count/ { if ($0 !~ /^# extract_test_count/) print }' "$PIPELINE" >> "$FUNCTIONS"

run_case() {
    local name="$1" body="$2" case_dir output rc
    case_dir="$TMP/$name"
    mkdir -p "$case_dir"
    cat > "$case_dir/case.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$ROOT/scripts/_pipeline-common.sh"
MEFISTO_STATE_DIR="$case_dir/state"
export MEFISTO_STATE_DIR
STATUS_FILENAME="pipeline-status-tooling-1286.json"
PIPELINE_DIR_ABS="\$MEFISTO_STATE_DIR"
HISTORY_FILE="\$(mefisto_state_path pipeline-history.jsonl)"
LOG_FILE_ABS="\$(mefisto_state_path logs/tooling.log)"
TAIL_LOG_LINES=20
TIMESTAMP="20260912-000000"
ISSUE_NUM=1286; ISSUE_TITLE="fixture"; VARIANT_LABEL_JSON="null"
HARNESS_IDENTITY_JSON='{"harness_version":null,"harness_commit":null,"identity_state":"metadata_missing"}'
MEFISTO_RUNTIME_RESUELTO=""; MEFISTO_RUNTIME_JSON="null"
AGENT_WR_DUR=""; AGENT_RV_DUR=""; AGENT_WR_RES="pending"; AGENT_RV_RES="pending"
AGENT_WR_METRICS="null"; AGENT_RV_METRICS="null"; PIPELINE_TESTS=""; PIPELINE_PR=""; PIPELINE_ERROR=""
CURRENT_STAGE="setup"; HOLD_CAUSE_JSON="null"; HOLD_NEXT_PROBE_JSON="null"; HOLD_CEILING_JSON="null"; HOLD_TOTAL=0
PIPELINE_TMP_DIR="\$(mktemp -d "$case_dir/pipeline.XXXXXX")"; PIPELINE_ABORTING=false
RED=''; BOLD=''; NC=''; YELLOW=''
source "$FUNCTIONS"
_tail_log_for_abort() { return 0; }
$body
EOF
    chmod +x "$case_dir/case.sh"
    output="$($case_dir/case.sh 2>&1)"; rc=$?
    CASE_DIR="$case_dir" CASE_RC="$rc" CASE_OUTPUT="$output"
}

run_case unhandled 'update_status setup running; printf "%s" "$PIPELINE_TMP_DIR" > "$PIPELINE_DIR_ABS/tmp-path"; bash -c "printf unhandled-diagnostic >&2; exit 23"'
UNHANDLED_TMP="$(<"$CASE_DIR/state/tmp-path")"
if [ "$CASE_RC" -eq 23 ] && [[ "$CASE_OUTPUT" == *unhandled-diagnostic* ]] \
   && jq -e '.state == "failed" and .stage == "setup"' "$CASE_DIR/state/pipeline-status-tooling-1286.json" >/dev/null \
   && [ ! -d "$UNHANDLED_TMP" ] && [ "$(wc -l < "$CASE_DIR/state/pipeline-history.jsonl" | tr -d ' ')" = 1 ]; then
    pass 'fallo no controlado conserva codigo, diagnostico y stage; registra una historia y limpia temporales'
else
    fail "fallo no controlado no se reconcilio (rc=$CASE_RC): $CASE_OUTPUT"
fi

run_case unhandled-hold 'update_status 2-reviewer hold; false'
if [ "$CASE_RC" -eq 1 ] && jq -e '.state == "failed" and .stage == "2-reviewer"' "$CASE_DIR/state/pipeline-status-tooling-1286.json" >/dev/null \
   && [ "$(wc -l < "$CASE_DIR/state/pipeline-history.jsonl" | tr -d ' ')" = 1 ]; then
    pass 'fallo no controlado reconcilia tambien un estado hold y conserva su stage'
else
    fail "fallo no controlado desde hold no se reconcilio (rc=$CASE_RC): $CASE_OUTPUT"
fi

run_case prior-status 'printf "%s" "$PIPELINE_TMP_DIR" > "$PIPELINE_DIR_ABS/tmp-path"; false'
PRIOR_TMP="$(<"$CASE_DIR/state/tmp-path")"
if [ "$CASE_RC" -ne 0 ] && [ ! -e "$CASE_DIR/state/pipeline-status-tooling-1286.json" ] \
   && [ ! -e "$CASE_DIR/state/pipeline-history.jsonl" ] && [ ! -d "$PRIOR_TMP" ]; then
    pass 'fallo previo al status no crea evidencia incompleta y limpia temporales'
else
    fail 'fallo previo al status dejo evidencia o temporales'
fi

run_case explicit-abort 'update_status setup running; abort "error especifico"'
if [ "$CASE_RC" -eq 1 ] && jq -e '.state == "failed" and (.last_error | startswith("error especifico"))' "$CASE_DIR/state/pipeline-status-tooling-1286.json" >/dev/null \
   && [ "$(wc -l < "$CASE_DIR/state/pipeline-history.jsonl" | tr -d ' ')" = 1 ] \
   && jq -e '.error | startswith("error especifico")' "$CASE_DIR/state/pipeline-history.jsonl" >/dev/null; then
    pass 'abort explicito conserva su error, codigo y una sola historia'
else
    fail "abort explicito fue sobrescrito o duplicado (rc=$CASE_RC): $CASE_OUTPUT"
fi

run_case success 'update_status setup running; exit 0'
if [ "$CASE_RC" -eq 0 ] && jq -e '.state == "running"' "$CASE_DIR/state/pipeline-status-tooling-1286.json" >/dev/null \
   && [ ! -e "$CASE_DIR/state/pipeline-history.jsonl" ] && [ ! -d "$CASE_DIR"/pipeline.* ]; then
    pass 'salida exitosa no muta status ni historial y conserva la limpieza'
else
    fail 'salida exitosa muto evidencia'
fi

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
