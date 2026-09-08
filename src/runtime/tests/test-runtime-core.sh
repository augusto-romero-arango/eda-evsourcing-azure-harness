#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUNNER="$ROOT/src/runtime/mefisto-run-agent.sh"
RESOLVER="$ROOT/src/runtime/lib/mefisto-runtime.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Discovery abierto: los ids salen de archivos y la disponibilidad de probes.
LIBS="$TMP/libs"; mkdir -p "$LIBS"
cat > "$LIBS/runtime-alpha.sh" <<'EOF'
runtime_alpha_is_available() { [ "${ALPHA_AVAILABLE:-}" = 1 ]; }
EOF
cat > "$LIBS/runtime-beta.sh" <<'EOF'
runtime_beta_is_available() { [ "${BETA_AVAILABLE:-}" = 1 ]; }
EOF
unset MEFISTO_RUNTIME
MEFISTO_RUNTIME_LIB_DIR="$LIBS"; source "$RESOLVER"
if mefisto_resolve_runtime "" >/dev/null; then fail "cero disponibles debe fallar"; else case "$MEFISTO_RUNTIME_ERROR" in *alpha*beta*MEFISTO_RUNTIME*) pass ;; *) fail "cero no lista ids y accion" ;; esac; fi
ALPHA_AVAILABLE=1
mefisto_resolve_runtime "" >/dev/null && [ "$MEFISTO_RESOLVED_RUNTIME" = alpha ] && pass || fail "probe unico"
BETA_AVAILABLE=1
if mefisto_resolve_runtime "" >/dev/null; then fail "varios disponibles debe fallar"; else case "$MEFISTO_RUNTIME_ERROR" in *alpha*beta*desambiguar*) pass ;; *) fail "varios no lista ids" ;; esac; fi
unset ALPHA_AVAILABLE BETA_AVAILABLE
MEFISTO_RUNTIME=beta; mefisto_resolve_runtime alpha >/dev/null && [ "$MEFISTO_RESOLVED_RUNTIME" = alpha ] && pass || fail "explicito gana"
mefisto_resolve_runtime "" >/dev/null && [ "$MEFISTO_RESOLVED_RUNTIME" = beta ] && pass || fail "entorno gana"
unset MEFISTO_RUNTIME MEFISTO_RUNTIME_LIB_DIR

# Runner comun: no crea estado por omision y conserva outputs/opciones.
mkdir -p "$TMP/wt" "$TMP/state"; printf 'prompt\n' > "$TMP/prompt"; printf 'system\n' > "$TMP/system"
ARGS="$TMP/args"; EVENTS="$TMP/events.jsonl"; HUMAN="$TMP/human.log"
MEFISTO_STATE_DIR="$TMP/state" MEFISTO_FAKE_SCRIPT=success MEFISTO_FAKE_ARGS_FILE="$ARGS" \
    "$RUNNER" --runtime fake --agent a --cwd "$TMP/wt" --prompt-file "$TMP/prompt" \
    --system-file "$TMP/system" --resume-session session-x --model provider/model \
    --event-log "$EVENTS" --raw-log "$TMP/raw" --stderr-log "$TMP/stderr" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass || fail "runner success"
[ -f "$TMP/raw" ] && [ -f "$TMP/stderr" ] && pass || fail "raw/stderr"
[ ! -e "$TMP/state/events.log" ] && pass || fail "nucleo invento default de estado"
grep -qx -- '--fake-resume' "$ARGS" && grep -qx -- 'session-x' "$ARGS" && grep -qx -- "$TMP/system" "$ARGS" && pass || fail "system/resume"
[ "$(jq -r 'select(.type=="run.completed") | .model' "$EVENTS")" = provider/model ] && pass || fail "modelo opaco"

MEFISTO_FAKE_SCRIPT=success "$RUNNER" --runtime fake --agent a --cwd "$TMP/wt" \
    --prompt-file "$TMP/prompt" --event-log "$TMP/events-human.jsonl" --events-log "$HUMAN" >/dev/null 2>&1
grep -q '\[stage\] a success' "$HUMAN" && pass || fail "telemetria explicita"

MEFISTO_FAKE_SCRIPT=hang "$RUNNER" --runtime fake --agent a --cwd "$TMP/wt" \
    --prompt-file "$TMP/prompt" --event-log "$TMP/timeout.jsonl" --timeout 1 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 124 ] && jq -e 'select(.type=="run.failed") | .status=="timeout" and .error.kind=="timeout"' "$TMP/timeout.jsonl" >/dev/null && pass || fail "timeout"

echo "RESULTADO runtime comun: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
