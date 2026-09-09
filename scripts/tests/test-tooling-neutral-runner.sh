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

echo '[contrato] helpers JSONL'
# shellcheck source=/dev/null
source "$ROOT/scripts/_pipeline-common.sh"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
printf '%s\n' '{"type":"run.failed","session_id":"s 1","denials":2,"error":{"kind":"rate_limit","resets_at":"2030-01-01T00:00:00Z"}}' > "$TMP"
[ "$(agent_events_session_id "$TMP")" = 's 1' ] && pass 'lee session_id' || fail 'no lee session_id'
[ "$(agent_events_denials "$TMP")" = 2 ] && pass 'lee denials' || fail 'no lee denials'
[ "$(classify_neutral_agent_failure 1 "$TMP")" = RATE_LIMIT ] && pass 'clasifica error.kind' || fail 'no clasifica error.kind'

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
