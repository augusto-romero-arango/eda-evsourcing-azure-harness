#!/usr/bin/env bash
# Pruebas del launcher publicado de etapas preparadas (#1858) contra una clausura
# doble propia: broker, runtime/servicio, resolvers y runner son stubs. Sin
# runtime, LLM ni red reales. El contador de prompts es la unidad de evidencia.
set -uo pipefail
export LC_ALL=C
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(cd -P "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
check() { local l="$1"; shift; if "$@"; then pass; else fail "$l"; fi; }

REL="$TMP/release"; PROJ="$TMP/proj"; WT="$TMP/wt"; LOG="$TMP/log"
mkdir -p "$REL/scripts" "$REL/src/runtime/lib" "$REL/src/published/contract" "$PROJ" "$WT" "$LOG"
cp "$REPO/scripts/run-published-agent.sh" "$REL/scripts/"
echo '{"version":"9.9.9"}' > "$REL/src/published/release-identity.json"
echo '{"schemaVersion":1,"roles":[{"id":"tooling-writer"},{"id":"implementer"}],"roots":{"tooling":["tooling"],"implement":["tdd"]}}' > "$REL/src/published/contract/agent-execution.json"
echo '{"schemaVersion":1,"roles":[{"id":"tooling-writer","sourceDigest":"h","metadata":{"mode":"subagent","permission":{},"tools":{}}}]}' > "$REL/agent-execution-manifest.json"

cat > "$REL/scripts/execution-context.sh" <<'EOF'
#!/usr/bin/env bash
op="$1"; req="$(cat)"
printf '%s\n' "$op" >> "$STUB_LOG/ops"
printf '%s\n' "$req" >> "$STUB_LOG/reqs"
case "$op" in
  validate) [ "${STUB_VALIDATE_RC:-0}" = 0 ] || exit "$STUB_VALIDATE_RC"; echo '{"status":"ready"}' ;;
  reserve-child)
    [ "${STUB_RESERVE_RC:-0}" = 0 ] || exit "$STUB_RESERVE_RC"
    root="$(jq -r .projectRoot <<<"$req")"; run="$(jq -r .runId <<<"$req")"; c="$(jq -r .childContextId <<<"$req")"
    f="$root/.mefisto/pipeline/autonomy/runs/$run/contexts/$c.json"
    jq -n --arg c "$c" --arg a "$(jq -r .alias <<<"$req")" --arg obs "${STUB_OBS_PROJECTION:-}" \
      '{contract:{nonce:"nonce-1",projectId:"project-a",alias:$a,contextId:$c},contractDigest:("d"*64),observations:(if $obs=="" then {} else {"nonce-1":{projection:$obs}} end)}' > "$f"
    jq -n --arg p "$f" '{status:"ready",path:$p,digest:("d"*64)}' ;;
  bind-session) [ "${STUB_BIND_RC:-0}" = 0 ] || exit "$STUB_BIND_RC"; echo '{"status":"ready"}' ;;
  *) echo '{"status":"ready"}' ;;
esac
EOF
cat > "$REL/scripts/resolve-opencode-resources.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null; [ "${STUB_SNAP_FAIL:-0}" = 0 ] || exit 2
echo '{"status":"ready","projectId":"project-a","profileDigest":"p","resourcesDigest":"r"}'
EOF
cat > "$REL/scripts/resolve-agent-execution.sh" <<'EOF'
#!/usr/bin/env bash
cat > "$STUB_LOG/verify-envelope"
if [ "${STUB_VERIFY_FAIL:-0}" = 1 ]; then echo '{"status":"conflict","phase":null}'; exit 1; fi
echo '{"status":"ready","phase":"verify","observations":[{"alias":"autonomy-tooling-writer","observationDigest":"o"}]}'
EOF
cat > "$REL/src/runtime/lib/mefisto-runtime.sh" <<'EOF'
MEFISTO_RUNTIME_SERVICE_RUNTIME=""; MEFISTO_RUNTIME_SERVICE_PID=""; MEFISTO_OPENCODE_SERVICE_PASSWORD="SECRET-CRED-123"
runtime_service_start() {
  [ "${STUB_START_FAIL:-0}" = 0 ] || return 1
  sleep 120 & MEFISTO_RUNTIME_SERVICE_PID=$!; MEFISTO_RUNTIME_SERVICE_RUNTIME=opencode
  MEFISTO_RUNTIME_SERVICE_ENDPOINT="http://127.0.0.1:43999"
  echo "$MEFISTO_RUNTIME_SERVICE_PID" > "$STUB_LOG/service-pid"
  printf '%s|%s\n' "$MEFISTO_EXECUTION_CONTEXT" "$MEFISTO_EXECUTION_DIGEST" > "$STUB_LOG/service-env"
  local dir; dir="$(dirname "$MEFISTO_EXECUTION_CONTEXT")/$(basename "$MEFISTO_EXECUTION_CONTEXT" .json)"
  mkdir -p "$dir"
  [ "${STUB_READY:-ok}" = absent ] && return 0
  jq -n --arg pid "$MEFISTO_RUNTIME_SERVICE_PID" --arg n "${STUB_READY_NONCE:-nonce-1}" --arg rel "${STUB_READY_RELEASE:-9.9.9}" \
    --arg p "${STUB_READY_PROJECT:-project-a}" --arg proj "${STUB_READY_PROJ-proj-digest}" --argjson ipid "${STUB_READY_PID:-$MEFISTO_RUNTIME_SERVICE_PID}" \
    '{schemaVersion:1,nonce:$n,contractDigest:("d"*64),release:$rel,projectId:$p,alias:"autonomy-tooling-writer",projectionDigest:(if $proj=="" then null else $proj end),instance:{pid:$ipid},result:"ready"}' > "$dir/runtime-ready.json"
  return 0
}
runtime_service_request() {
  printf '%s %s\n' "$2" "$3" >> "$STUB_LOG/requests"
  case "$3" in
    /agent) case "${STUB_AGENTS:-ok}" in
        ok) echo '[{"name":"tooling-writer","mode":"subagent","prompt":"p","permission":[]},{"name":"autonomy-tooling-writer","mode":"primary","prompt":"p","permission":[]},{"name":"build","mode":"primary"}]' ;;
        absent) echo '[{"name":"tooling-writer","mode":"subagent"}]' ;;
        subagent) echo '[{"name":"autonomy-tooling-writer","mode":"subagent"}]' ;;
        empty) echo '[]' ;;
        error) return 1 ;;
      esac ;;
    /session/*/abort) echo true ;;
    /session/*) echo "{\"id\":\"${3#/session/}\",\"directory\":\"${STUB_SESSION_DIR:-$WT_REAL}\"}" ;;
  esac
}
runtime_service_stop() {
  echo stop >> "$STUB_LOG/stops"
  [ "${STUB_STOP_FAIL:-0}" = 0 ] || return 1
  kill "$MEFISTO_RUNTIME_SERVICE_PID" 2>/dev/null; wait "$MEFISTO_RUNTIME_SERVICE_PID" 2>/dev/null
  MEFISTO_RUNTIME_SERVICE_PID=""; MEFISTO_RUNTIME_SERVICE_RUNTIME=""; return 0
}
EOF
cat > "$REL/src/runtime/mefisto-run-agent.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_LOG/runner-argv"
echo prompt >> "$STUB_LOG/prompts"
echo '{"type":"run.completed"}'
[ -z "${STUB_RUNNER_SLEEP:-}" ] || { sleep "$STUB_RUNNER_SLEEP" & wait $!; }
exit "${STUB_RUNNER_RC:-0}"
EOF
chmod +x "$REL"/scripts/*.sh "$REL/src/runtime/mefisto-run-agent.sh"

CTXDIR="$PROJ/.mefisto/pipeline/autonomy/runs/run-1/contexts"; mkdir -p "$CTXDIR"
echo '{}' > "$CTXDIR/ctx-parent.json"
printf 'prompt\n' > "$TMP/prompt"
WT_REAL="$(cd "$WT" && pwd -P)"; export WT_REAL
DIGEST="$(printf 'a%.0s' $(seq 64))"

# run <env...> -- <launcher-args...>: deja RC/OUT/ERR y limpia el log por caso.
launch() {
    rm -rf "$LOG"; mkdir -p "$LOG"; rm -rf "$PROJ/.mefisto/pipeline/autonomy/runs/run-1/launcher"
    find "$CTXDIR" -mindepth 1 ! -name ctx-parent.json -exec rm -rf {} + 2>/dev/null
    local envs=(STUB_Z=1)
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
    OUT="$(env STUB_LOG="$LOG" "${envs[@]}" "$REL/scripts/run-published-agent.sh" "$@" 2>"$TMP/err")"; RC=$?
    ERR="$(cat "$TMP/err")"
}
STD=(--pipeline tooling --context "$CTXDIR/ctx-parent.json" --context-digest "$DIGEST" --)
RUNARGS=(--agent tooling-writer --cwd "$WT" --prompt-file "$TMP/prompt" --event-log "$TMP/events" --model opaco/modelo)
prompts() { [ -f "$LOG/prompts" ] && wc -l < "$LOG/prompts" | tr -d ' ' || echo 0; }
result_status() { jq -r .invocationStatus "$PROJ"/.mefisto/pipeline/autonomy/runs/run-1/launcher/att-*.json 2>/dev/null | head -1; }
negative() { # etiqueta env... -- args
    local label="$1"; shift; launch "$@"
    check "$label: exit 78" test "$RC" -eq 78
    check "$label: cero prompts" test "$(prompts)" = 0
    check "$label: not-started protegido" test "$(result_status)" = not-started
}

# 1. Positivo: secuencia completa y argv conservado.
launch STUB_X=1 -- "${STD[@]}" "${RUNARGS[@]}"
check "positivo: exit 0" test "$RC" -eq 0
check "positivo: un prompt" test "$(prompts)" = 1
check "positivo: stdout del runner" grep -q run.completed <<<"$OUT"
check "positivo: alias de ejecucion" grep -qx -- 'autonomy-tooling-writer' "$LOG/runner-argv"
check "positivo: endpoint del servicio propio" grep -qx -- 'http://127.0.0.1:43999' "$LOG/runner-argv"
check "positivo: rol logico y modelo opacos" bash -c "grep -qx tooling-writer '$LOG/runner-argv' && grep -qx 'opaco/modelo' '$LOG/runner-argv'"
check "positivo: instancia hija con contexto propio" grep -q 'ctx-att-' "$LOG/service-env"
check "positivo: reserva antes del servicio" bash -c "sed -n 1,3p '$LOG/ops' | tr '\n' ' ' | grep -q 'validate reserve-child attach'"
check "positivo: hijo finalizado, padre intacto" bash -c "[ \"\$(grep -c '^finish$' '$LOG/ops')\" = 1 ] && jq -e '.contextId|startswith(\"ctx-att-\")' <<<\"\$(grep outcome '$LOG/reqs')\" >/dev/null"
check "positivo: resultado started" test "$(result_status)" = started
check "positivo: servicio cerrado" test "$(cat "$LOG/stops" | wc -l | tr -d ' ')" = 1
check "positivo: verify con observacion acotada" jq -e '.phase=="verify" and (.observed|length==2) and (.observed[0]|keys|sort)==["available","mode","name","promptHash","rules"]' "$LOG/verify-envelope"
check "positivo: sin credencial en salida/argv/resultado" bash -c "! grep -rq SECRET-CRED-123 '$LOG' '$PROJ' <<<''; ! grep -q SECRET-CRED-123 <<<\"\$OUT\$ERR\""

# 2. Negativos de evidencia: cero prompts.
negative "alias ausente" STUB_AGENTS=absent -- "${STD[@]}" "${RUNARGS[@]}"
negative "alias subagent" STUB_AGENTS=subagent -- "${STD[@]}" "${RUNARGS[@]}"
negative "lista vacia" STUB_AGENTS=empty -- "${STD[@]}" "${RUNARGS[@]}"
negative "SDK error no es lista vacia conocida" STUB_AGENTS=error -- "${STD[@]}" "${RUNARGS[@]}"
negative "plugin ausente (sin ready)" STUB_READY=absent -- "${STD[@]}" --startup-timeout 1 "${RUNARGS[@]}"
negative "nonce equivocado" STUB_READY_NONCE=otro -- "${STD[@]}" "${RUNARGS[@]}"
negative "release equivocada" STUB_READY_RELEASE=0.0.1 -- "${STD[@]}" "${RUNARGS[@]}"
negative "proyecto equivocado" STUB_READY_PROJECT=project-b -- "${STD[@]}" "${RUNARGS[@]}"
negative "projectionDigest ausente" STUB_READY_PROJ= -- "${STD[@]}" "${RUNARGS[@]}"
negative "instancia distinta" STUB_READY_PID=1 -- "${STD[@]}" "${RUNARGS[@]}"
negative "observacion del broker distinta" STUB_OBS_PROJECTION=otra -- "${STD[@]}" "${RUNARGS[@]}"
negative "verify en conflicto" STUB_VERIFY_FAIL=1 -- "${STD[@]}" "${RUNARGS[@]}"
negative "snapshot no disponible" STUB_SNAP_FAIL=1 -- "${STD[@]}" "${RUNARGS[@]}"
negative "servicio no inicia" STUB_START_FAIL=1 -- "${STD[@]}" "${RUNARGS[@]}"
negative "contexto invalido" STUB_VALIDATE_RC=1 -- "${STD[@]}" "${RUNARGS[@]}"
launch STUB_OBS_PROJECTION=proj-digest -- "${STD[@]}" "${RUNARGS[@]}"
check "observacion del broker coincidente: ok" test "$RC" -eq 0

# 3. Clausura: caller no fija destino, override y rol/pipeline desconocidos.
launch -- "${STD[@]}" "${RUNARGS[@]}" --runtime-endpoint http://127.0.0.1:1
check "endpoint del caller: 78 sin prompt" bash -c "[ $RC -eq 78 ] && [ '$(prompts)' = 0 ]"
launch -- "${STD[@]}" "${RUNARGS[@]}" --execution-agent build
check "alias del caller: 78 sin prompt" test "$RC" -eq 78
launch MEFISTO_RUN_AGENT_CMD=/bin/true -- "${STD[@]}" "${RUNARGS[@]}"
check "override de runner: 78 sin prompt" bash -c "[ $RC -eq 78 ] && [ '$(prompts)' = 0 ]"
launch -- --pipeline infra --context "$CTXDIR/ctx-parent.json" --context-digest "$DIGEST" -- "${RUNARGS[@]}"
check "pipeline invalido: 78" test "$RC" -eq 78
launch -- --pipeline tooling --context "$CTXDIR/ctx-parent.json" --context-digest "$DIGEST" -- --agent no-existe --cwd "$WT"
check "rol fuera del catalogo: 78" test "$RC" -eq 78
launch -- --pipeline tooling --context "$CTXDIR/ctx-parent.json" --context-digest corto -- "${RUNARGS[@]}"
check "digest invalido: 78" test "$RC" -eq 78

# 4. Busy: 75 sin prompt ni servicio.
launch STUB_RESERVE_RC=75 -- "${STD[@]}" "${RUNARGS[@]}"
check "busy: exit 75" test "$RC" -eq 75
check "busy: sin servicio ni prompt" bash -c "[ ! -e '$LOG/service-pid' ] && [ '$(prompts)' = 0 ]"

# 5. Resume.
launch -- "${STD[@]}" "${RUNARGS[@]}" --resume-session ses_abc
check "resume: bind + metadata, conserva el flag" bash -c "[ $RC -eq 0 ] && grep -qx ses_abc '$LOG/runner-argv' && grep -q 'GET /session/ses_abc' '$LOG/requests' && jq -e 'select(.mode==\"resume\")' '$LOG/reqs' >/dev/null"
negative "resume ajeno/otro stage (conflicto del broker)" STUB_BIND_RC=1 -- "${STD[@]}" "${RUNARGS[@]}" --resume-session ses_ajena
negative "resume con directorio distinto en metadata SDK" STUB_SESSION_DIR=/otro -- "${STD[@]}" "${RUNARGS[@]}" --resume-session ses_abc
check "resume fallido no inicia otra sesion en silencio" test "$(prompts)" = 0

# 6. Despues de iniciar: se conserva el exit del runner, cleanup desconocido no es success.
launch STUB_RUNNER_RC=3 -- "${STD[@]}" "${RUNARGS[@]}"
check "runner falla: conserva exit 3" test "$RC" -eq 3
check "runner falla: resultado started" test "$(result_status)" = started
launch STUB_STOP_FAIL=1 -- "${STD[@]}" "${RUNARGS[@]}"
check "cleanup fallido: no libera la referencia" bash -c "! grep -q '^finish$' '$LOG/ops'"
check "cleanup fallido: cleanup unknown persistido" bash -c "jq -e '.cleanup==\"unknown\"' '$PROJ'/.mefisto/pipeline/autonomy/runs/run-1/launcher/att-*.json >/dev/null"
check "cleanup fallido: avisa por stderr" grep -q CLEANUP_UNKNOWN <<<"$ERR"
launch STUB_START_FAIL=1 STUB_RUNNER_RC=0 -- "${STD[@]}" "${RUNARGS[@]}"
check "preflight fallido jamas es success" test "$RC" -ne 0

# 7. Cancelacion: solo el runner y el servicio propios.
rm -rf "$LOG"; mkdir -p "$LOG"; find "$CTXDIR" -mindepth 1 ! -name ctx-parent.json -exec rm -rf {} + 2>/dev/null
STUB_LOG="$LOG" STUB_RUNNER_SLEEP=30 STUB_STOP_FAIL=1 "$REL/scripts/run-published-agent.sh" "${STD[@]}" "${RUNARGS[@]}" --resume-session ses_abc >"$TMP/out" 2>"$TMP/err" &
LPID=$!
for _ in $(seq 100); do [ -s "$LOG/runner-argv" ] && break; sleep 0.1; done
kill -TERM "$LPID"; wait "$LPID"; CRC=$?
check "cancelacion: sale distinto de 0" test "$CRC" -ne 0
check "cancelacion: aborta la sesion propia" grep -q 'POST /session/ses_abc/abort' "$LOG/requests"
check "cancelacion: no libera referencias si el cierre es desconocido" bash -c "! grep -q '^finish$' '$LOG/ops'"
kill "$(cat "$LOG/service-pid")" 2>/dev/null; wait 2>/dev/null

# 8. Cancelacion durante el preflight: aborta sin runner, 78 y servicio propio cerrado.
rm -rf "$LOG"; mkdir -p "$LOG"; rm -rf "$PROJ/.mefisto/pipeline/autonomy/runs/run-1/launcher"
find "$CTXDIR" -mindepth 1 ! -name ctx-parent.json -exec rm -rf {} + 2>/dev/null
STUB_LOG="$LOG" STUB_READY=absent "$REL/scripts/run-published-agent.sh" "${STD[@]}" --startup-timeout 20 "${RUNARGS[@]}" >"$TMP/out" 2>"$TMP/err" &
LPID=$!
for _ in $(seq 100); do [ -s "$LOG/service-pid" ] && break; sleep 0.1; done
sleep 0.3; kill -TERM "$LPID"; wait "$LPID"; CRC=$?
check "cancelacion en preflight: exit 78" test "$CRC" -eq 78
check "cancelacion en preflight: cero prompts" test "$(prompts)" = 0
check "cancelacion en preflight: not-started protegido" test "$(result_status)" = not-started
check "cancelacion en preflight: cierra el servicio propio" test -s "$LOG/stops"

# 9. CA-3: el launcher entrega el par rol logico + alias tecnico; el rechazo del
# fallback a default lo certifica el guard real chat.params en
# src/published/scripts/tests/test-opencode-binding-guard.sh (caso defaultFallback).
launch -- "${STD[@]}" "${RUNARGS[@]}"
check "CA-3: --execution-agent seguido del alias exacto" bash -c "grep -A1 -x -- --execution-agent '$LOG/runner-argv' | tail -1 | grep -qx autonomy-tooling-writer"
check "CA-3: --agent conserva el rol logico" bash -c "grep -A1 -x -- --agent '$LOG/runner-argv' | tail -1 | grep -qx tooling-writer"
check "CA-3: el guard real cubre el fallback a default" grep -q 'defaultFallback' "$REPO/src/published/scripts/tests/test-opencode-binding-guard.sh"

echo "RESULTADO run-published-agent: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
