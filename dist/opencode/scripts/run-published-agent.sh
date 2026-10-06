#!/usr/bin/env bash
# Launcher publicado de una etapa OpenCode preparada (#1858, MEF-ADR-0055).
#
#   run-published-agent.sh --pipeline <tdd|tooling|iac|scaffold> \
#       --context <ruta-del-contexto> --context-digest <sha256> \
#       [--startup-timeout <s>] -- <argv del runner neutral>
#
# Inicia una instancia privada hija (reserva antes del spawn), espera evidencia de
# ESA misma instancia (runtime-ready por nonce + observacion efectiva del servicio)
# y solo entonces invoca el runner de la propia release con el alias de ejecucion.
# Sin evidencia no hay prompt: exit 78 y resultado protegido `not-started`.
# Exit: 78 preflight no iniciado, 75 busy; despues de iniciar, el exit del runner.
# No aprueba perfiles, no mata procesos por patron, no adopta servidores ajenos y
# nunca vuelca respuestas de SDK/config ni credenciales (solo codigos sanitizados).
set -uo pipefail
export LC_ALL=C
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RELEASE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
EC="$SCRIPT_DIR/execution-context.sh"
RESOLVE_AGENT="$SCRIPT_DIR/resolve-agent-execution.sh"
RESOLVE_RES="$SCRIPT_DIR/resolve-opencode-resources.sh"
RUNNER="$RELEASE_ROOT/src/runtime/mefisto-run-agent.sh"
RUNTIME_LIB_DIR="$RELEASE_ROOT/src/runtime/lib"
ROLES_FILE="$RELEASE_ROOT/src/published/contract/agent-execution.json"
MANIFEST="$RELEASE_ROOT/agent-execution-manifest.json"
RELEASE_FILE="$RELEASE_ROOT/mefisto-manifest.json"

PIPELINE=""; CONTEXT=""; CTX_DIGEST=""; STARTUP_TIMEOUT=30
RUNNER_ARGS=()
ATTEMPT="att-$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
RUN_DIR=""; LAUNCH_DIR=""; WORK=""
CHILD=""; CHILD_PATH=""; CHILD_DIGEST=""; BASE=""; RUN_ID=""; PARENT=""
SERVICE_UP=0; STARTED=0; RUNNER_PID=""; CANCELLED=""; CLEANUP="complete"
RESUME=""; ROLE=""; ALIAS=""; CWD=""

hash_stdin() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d ' ' -f 1; else sha256sum | cut -d ' ' -f 1; fi; }

write_result() { # invocationStatus codigo exit-del-runner
    [ -n "$LAUNCH_DIR" ] && [ -d "$LAUNCH_DIR" ] || return 0
    jq -cn --arg a "$ATTEMPT" --arg s "$1" --arg c "$2" --arg r "${3:-}" --arg cl "$CLEANUP" --arg ctx "$CHILD" \
        '{schemaVersion:1,attempt:$a,invocationStatus:$s,reasonCode:$c,contextId:(if $ctx=="" then null else $ctx end),runnerExit:(if $r=="" then null else ($r|tonumber) end),cleanup:$cl}' \
        > "$LAUNCH_DIR/$ATTEMPT.json" 2>/dev/null || true
}

ec_call() { # op json -> EC_OUT / EC_RC
    EC_OUT="$(printf '%s' "$2" | "$EC" "$1" 2>/dev/null)"; EC_RC=$?
}

child_req() { # extras-json
    local extra="${1-}"; [ -n "$extra" ] || extra='{}'
    jq -cn --arg r "$BASE" --arg run "$RUN_ID" --arg c "$CHILD" --arg d "$CHILD_DIGEST" --argjson x "$extra" \
        '{schemaVersion:1,projectRoot:$r,runId:$run,contextId:$c,digest:$d} + $x'
}

stop_service() { # deja CLEANUP=unknown si no se acredita el cierre propio
    [ "$SERVICE_UP" = 1 ] || return 0
    if runtime_service_stop opencode >/dev/null 2>&1; then SERVICE_UP=0; else CLEANUP="unknown"; fi
    return 0
}

cleanup_work() { [ -n "$WORK" ] && [ -d "$WORK" ] && rm -rf "$WORK"; WORK=""; }

# finish_child <outcome>: solo libera la referencia propia y solo con cierre acreditado.
finish_child() {
    [ -n "$CHILD" ] || return 0
    [ "$CLEANUP" = complete ] || return 0
    ec_call finish "$(child_req "$(jq -cn --arg o "$1" '{outcome:$o}')")"
}

fail_preflight() { # CODIGO
    stop_service
    finish_child failed
    write_result not-started "$1"
    cleanup_work
    printf 'ERROR: preflight de etapa publicada fallo (%s); no se envio prompt\n' "$1" >&2
    exit 78
}

usage() { printf '%s\n' 'uso: run-published-agent.sh --pipeline <tdd|tooling|iac|scaffold> --context <ruta> --context-digest <sha256> [--startup-timeout <s>] -- <argv del runner>' >&2; exit 78; }

# --- argumentos -----------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --pipeline) [ "$#" -ge 2 ] || usage; PIPELINE="$2"; shift 2 ;;
        --context) [ "$#" -ge 2 ] || usage; CONTEXT="$2"; shift 2 ;;
        --context-digest) [ "$#" -ge 2 ] || usage; CTX_DIGEST="$2"; shift 2 ;;
        --startup-timeout) [ "$#" -ge 2 ] || usage; STARTUP_TIMEOUT="$2"; shift 2 ;;
        --) shift; RUNNER_ARGS=("$@"); break ;;
        *) usage ;;
    esac
done
command -v jq >/dev/null 2>&1 || { printf 'ERROR: jq no esta instalado (JQ_MISSING)\n' >&2; exit 78; }
case "$PIPELINE" in tdd|tooling|iac|scaffold) ;; *) usage ;; esac
case "$STARTUP_TIMEOUT" in ''|*[!0-9]*) usage ;; esac
[ "$STARTUP_TIMEOUT" -ge 1 ] && [ "$STARTUP_TIMEOUT" -le 300 ] || usage
printf '%s' "$CTX_DIGEST" | grep -Eq '^[0-9a-f]{64}$' || usage
[ "${#RUNNER_ARGS[@]}" -gt 0 ] || usage

# Un override del runner distinto de la clausura verificada no es un bypass: es incompatible.
if [ -n "${MEFISTO_RUN_AGENT_CMD:-}" ] || [ -n "${MEFISTO_RUNNER:-}" ]; then
    printf 'ERROR: override de runner incompatible con la etapa publicada (RUNNER_OVERRIDE)\n' >&2; exit 78
fi

# argv del runner: el caller no suministra endpoint ni alias.
i=0; n=${#RUNNER_ARGS[@]}
while [ "$i" -lt "$n" ]; do
    a="${RUNNER_ARGS[$i]}"
    case "$a" in
        --runtime-endpoint|--execution-agent) printf 'ERROR: el caller no suministra endpoint ni alias (CALLER_SUPPLIED_TARGET)\n' >&2; exit 78 ;;
        --agent) ROLE="${RUNNER_ARGS[$((i + 1))]:-}"; i=$((i + 2)) ;;
        --cwd) CWD="${RUNNER_ARGS[$((i + 1))]:-}"; i=$((i + 2)) ;;
        --resume-session) RESUME="${RUNNER_ARGS[$((i + 1))]:-}"; i=$((i + 2)) ;;
        --runtime) [ "${RUNNER_ARGS[$((i + 1))]:-}" = opencode ] || { printf 'ERROR: runtime distinto de opencode (RUNTIME_MISMATCH)\n' >&2; exit 78; }; i=$((i + 2)) ;;
        *) i=$((i + 1)) ;;
    esac
done
[ -n "$ROLE" ] && [ -n "$CWD" ] && [ -d "$CWD" ] || usage
CWD="$(cd "$CWD" && pwd -P)"

# --- clausura de la release -----------------------------------------------
for f in "$EC" "$RESOLVE_AGENT" "$RESOLVE_RES" "$RUNNER" "$RUNTIME_LIB_DIR/mefisto-runtime.sh" "$ROLES_FILE" "$MANIFEST"; do
    [ -f "$f" ] || { printf 'ERROR: la release no contiene la clausura del launcher (CLOSURE_INCOMPLETE)\n' >&2; exit 78; }
done
[ -f "$RELEASE_FILE" ] || { printf 'ERROR: la release no contiene mefisto-manifest.json (RELEASE_UNKNOWN)\n' >&2; exit 78; }
RELEASE_VERSION="$(jq -r '.version // empty' "$RELEASE_FILE" 2>/dev/null)"
[ -n "$RELEASE_VERSION" ] || { printf 'ERROR: mefisto-manifest.json sin version valida (RELEASE_UNKNOWN)\n' >&2; exit 78; }

# --- contexto, rol, pipeline ----------------------------------------------
case "$CONTEXT" in
    */.mefisto/pipeline/autonomy/runs/*/contexts/*.json) ;;
    *) printf 'ERROR: ruta de contexto invalida (CONTEXT_PATH)\n' >&2; exit 78 ;;
esac
BASE="${CONTEXT%/.mefisto/pipeline/autonomy/runs/*}"
tail_="${CONTEXT#*/.mefisto/pipeline/autonomy/runs/}"
RUN_ID="${tail_%%/*}"; PARENT="${tail_##*/}"; PARENT="${PARENT%.json}"
RUN_DIR="$BASE/.mefisto/pipeline/autonomy/runs/$RUN_ID"
mkdir -p "$RUN_DIR/launcher" 2>/dev/null && LAUNCH_DIR="$RUN_DIR/launcher"

jq -e --arg r "$ROLE" --arg p "$PIPELINE" '(.roles | map(.id) | index($r)) != null and ([.roots[][]] | index($p)) != null' "$ROLES_FILE" >/dev/null 2>&1 \
    || { write_result not-started ROLE_OR_PIPELINE_UNKNOWN; printf 'ERROR: rol o pipeline fuera del catalogo (ROLE_OR_PIPELINE_UNKNOWN)\n' >&2; exit 78; }
ALIAS="autonomy-$ROLE"

BASE_REQ="$(jq -cn --arg r "$BASE" --arg run "$RUN_ID" --arg c "$PARENT" --arg d "$CTX_DIGEST" --arg p "$PIPELINE" \
    '{schemaVersion:1,projectRoot:$r,runId:$run,contextId:$c,digest:$d,pipelineKind:$p,runtime:{id:"opencode"}}')"
ec_call validate "$BASE_REQ"
if [ "$EC_RC" -eq 75 ]; then write_result not-started BUSY; printf 'ERROR: contexto ocupado (BUSY)\n' >&2; exit 75; fi
[ "$EC_RC" -eq 0 ] && [ "$(printf '%s' "$EC_OUT" | jq -r '.status // empty')" = ready ] \
    || { write_result not-started CONTEXT_INVALID; printf 'ERROR: contexto no valido (CONTEXT_INVALID)\n' >&2; exit 78; }

# Cancelacion: antes de entregar el prompt aborta el preflight (78, sin runner); despues
# solo senaliza al runner propio por su PID y deja que el cierre normal registre el desenlace.
on_signal() {
    CANCELLED="${1:-TERM}"
    if [ "$STARTED" = 0 ]; then
        [ -z "${MEFISTO_RUNTIME_SERVICE_PID:-}" ] || SERVICE_UP=1
        fail_preflight CANCELLED
    fi
    if [ -n "$RUNNER_PID" ]; then kill -TERM "$RUNNER_PID" 2>/dev/null || true; fi
}
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT

# --- reserva del intento hijo antes del spawn -------------------------------
CHILD="ctx-$ATTEMPT"
EXEC_ROOT_REAL="$CWD"
ec_call reserve-child "$(jq -cn --arg r "$BASE" --arg run "$RUN_ID" --arg c "$PARENT" --arg d "$CTX_DIGEST" --arg ch "$CHILD" --arg res "res-$ATTEMPT" \
    --arg st "$ROLE" --arg p "$PIPELINE" --arg ag "$ROLE" --arg al "$ALIAS" --arg ex "$EXEC_ROOT_REAL" \
    '{schemaVersion:1,projectRoot:$r,runId:$run,contextId:$c,digest:$d,childContextId:$ch,reservationId:$res,logicalStage:$st,pipelineKind:$p,originalAgent:$ag,alias:$al,executionRoot:$ex}')"
if [ "$EC_RC" -eq 75 ]; then CHILD=""; write_result not-started BUSY; printf 'ERROR: reserva ocupada (BUSY)\n' >&2; exit 75; fi
if [ "$EC_RC" -ne 0 ]; then CHILD=""; write_result not-started RESERVE_FAILED; printf 'ERROR: no se pudo reservar el intento (RESERVE_FAILED)\n' >&2; exit 78; fi
CHILD_PATH="$(printf '%s' "$EC_OUT" | jq -r '.path // empty')"; CHILD_DIGEST="$(printf '%s' "$EC_OUT" | jq -r '.digest // empty')"
[ -n "$CHILD_PATH" ] && [ -f "$CHILD_PATH" ] && [ -n "$CHILD_DIGEST" ] || fail_preflight RESERVE_INCOMPLETE
ec_call attach "$(child_req "$(jq -cn --argjson p "$$" '{ownerPid:$p}')")"
[ "$EC_RC" -eq 0 ] || fail_preflight ATTACH_FAILED

CHILD_NONCE="$(jq -r '.contract.nonce // empty' "$CHILD_PATH" 2>/dev/null)"
CHILD_PROJECT="$(jq -r '.contract.projectId // empty' "$CHILD_PATH" 2>/dev/null)"
CHILD_ALIAS="$(jq -r '.contract.alias // empty' "$CHILD_PATH" 2>/dev/null)"
[ -n "$CHILD_NONCE" ] && [ -n "$CHILD_PROJECT" ] && [ "$CHILD_ALIAS" = "$ALIAS" ] || fail_preflight CHILD_CONTRACT_MISMATCH
READY_DIR="$(dirname "$CHILD_PATH")/$CHILD"
READY_FILE="$READY_DIR/runtime-ready.json"
[ ! -e "$READY_FILE" ] || fail_preflight STALE_READY

# --- instancia privada -------------------------------------------------------
WORK="$(mktemp -d "$LAUNCH_DIR/work.XXXXXX" 2>/dev/null)" || fail_preflight WORKDIR_FAILED
export MEFISTO_RUNTIME_LIB_DIR="$RUNTIME_LIB_DIR"
# shellcheck source=/dev/null
source "$RUNTIME_LIB_DIR/mefisto-runtime.sh" || fail_preflight RUNTIME_LIB_UNAVAILABLE

MEFISTO_EXECUTION_CONTEXT="$CHILD_PATH" MEFISTO_EXECUTION_DIGEST="$CHILD_DIGEST" MEFISTO_LOADED_RELEASE_ROOT="$RELEASE_ROOT"
export MEFISTO_EXECUTION_CONTEXT MEFISTO_EXECUTION_DIGEST MEFISTO_LOADED_RELEASE_ROOT
DEADLINE=$(( $(date +%s) + STARTUP_TIMEOUT ))
runtime_service_start opencode "$CWD" "$WORK" "$STARTUP_TIMEOUT" >/dev/null 2>&1 || fail_preflight SERVICE_START_FAILED
SERVICE_UP=1
[ -n "${MEFISTO_RUNTIME_SERVICE_ENDPOINT:-}" ] && [ -n "${MEFISTO_RUNTIME_SERVICE_PID:-}" ] || fail_preflight SERVICE_HANDLE_MISSING

# --- calentamiento: GET /agent y seleccion del alias esperado -----------------
AGENTS="$(runtime_service_request opencode GET /agent "$WORK" 2>/dev/null)" || fail_preflight AGENT_LIST_UNAVAILABLE
printf '%s' "$AGENTS" | jq -e 'type == "array"' >/dev/null 2>&1 || fail_preflight AGENT_LIST_UNAVAILABLE
printf '%s' "$AGENTS" | jq -e --arg a "$ALIAS" '[.[] | select(.name == $a)] | length == 1' >/dev/null 2>&1 || fail_preflight ALIAS_ABSENT
printf '%s' "$AGENTS" | jq -e --arg a "$ALIAS" '.[] | select(.name == $a) | (.mode // "") != "subagent" and (.mode // "") != ""' >/dev/null 2>&1 || fail_preflight ALIAS_NOT_PRIMARY

# runtime-ready de esta misma instancia, dentro del plazo de startup.
while :; do
    [ -f "$READY_FILE" ] && [ ! -L "$READY_FILE" ] && break
    [ "$(date +%s)" -lt "$DEADLINE" ] || fail_preflight READY_TIMEOUT
    kill -0 "$MEFISTO_RUNTIME_SERVICE_PID" 2>/dev/null || fail_preflight SERVICE_EXITED
    sleep 0.1
done
READY="$(jq -c . "$READY_FILE" 2>/dev/null)" || fail_preflight READY_UNREADABLE
printf '%s' "$READY" | jq -e --arg n "$CHILD_NONCE" --arg d "$CHILD_DIGEST" --arg rel "$RELEASE_VERSION" --arg p "$CHILD_PROJECT" --arg a "$ALIAS" --argjson pid "$MEFISTO_RUNTIME_SERVICE_PID" '
    .schemaVersion == 1 and .result == "ready" and .nonce == $n and .contractDigest == $d and .release == $rel
    and .projectId == $p and .alias == $a and (.projectionDigest | type == "string" and length > 0) and .instance.pid == $pid' >/dev/null 2>&1 \
    || fail_preflight READY_MISMATCH
READY_PROJECTION="$(printf '%s' "$READY" | jq -r '.projectionDigest')"

# La observacion registrada por el binding en el broker debe coincidir con el ready.
RECORDED="$(jq -r --arg n "$CHILD_NONCE" '.observations[$n].projection // empty' "$CHILD_PATH" 2>/dev/null)"
[ -z "$RECORDED" ] || [ "$RECORDED" = "$READY_PROJECTION" ] || fail_preflight PROJECTION_MISMATCH

# --- verify de #1856 sobre la observacion efectiva acotada ---------------------
OBSERVED="$(printf '%s' "$AGENTS" | jq -c --arg a "$ALIAS" --arg o "$ROLE" '
    [.[] | select(.name == $a or .name == $o) | {available:(.available // true), mode:(.mode // ""), name:.name, promptHash:(.promptHash // ""), rules:(.permission // [])}]' 2>/dev/null)"
# promptHash: el SDK entrega el prompt; se reduce a su hash dentro de este proceso y no se persiste.
OBSERVED="$(printf '%s' "$AGENTS" | jq -r --arg a "$ALIAS" --arg o "$ROLE" '.[] | select(.name == $a or .name == $o) | [.name, ((.prompt // "") | @base64)] | @tsv' 2>/dev/null \
    | while IFS=$'\t' read -r nm b64; do
        h="$(printf '%s' "$b64" | { base64 -d 2>/dev/null || base64 -D 2>/dev/null; } | hash_stdin)"
        printf '%s\t%s\n' "$nm" "$h"
    done | jq -R -s -c --argjson obs "$OBSERVED" 'split("\n") | map(select(length>0) | split("\t")) as $h | $obs | map(. as $x | .promptHash = (($h[] | select(.[0] == $x.name) | .[1]) // ""))' 2>/dev/null)"
[ -n "$OBSERVED" ] || fail_preflight OBSERVATION_UNAVAILABLE

SNAP="$(jq -cn --arg d "$CWD" '{schemaVersion:1,runtimeContext:{directory:$d,worktree:$d},requiredResources:["release","project","state","runtime-tool-output"],nugetAssetsFiles:[]}' \
    | "$RESOLVE_RES" --project-root "$BASE" --worktree-root "$CWD" 2>/dev/null)" || fail_preflight SNAPSHOT_UNAVAILABLE
printf '%s' "$SNAP" | jq -e '.status == "ready"' >/dev/null 2>&1 || fail_preflight SNAPSHOT_NOT_READY
if [ -f "$BASE/opencode.json" ]; then
    GLOBAL_POLICY="$(jq -c '{permission:(.permission // {})}' "$BASE/opencode.json" 2>/dev/null)" || fail_preflight GLOBAL_POLICY_UNKNOWN
else
    GLOBAL_POLICY='{"permission":{}}'
fi
ENVELOPE="$(jq -cn --argjson snap "$SNAP" --argjson obs "$OBSERVED" --argjson g "$GLOBAL_POLICY" --arg role "$ROLE" --arg home "${HOME:-/}" --slurpfile man "$MANIFEST" '
    {schemaVersion:1,phase:"verify",profile:{projectId:$snap.projectId,profileDigest:$snap.profileDigest},snapshot:$snap,home:$home,
     roles:[{role:$role,taskTargets:[]}],
     originals:[$man[0].roles[] | select(.id == $role) | {id,mode:.metadata.mode,permission:.metadata.permission,tools:.metadata.tools,promptHash:.sourceDigest}],
     globalPolicy:$g,sessionPolicy:null,collisions:[],observed:$obs}' 2>/dev/null)" || fail_preflight VERIFY_ENVELOPE_FAILED
VERIFY="$(printf '%s' "$ENVELOPE" | "$RESOLVE_AGENT" 2>/dev/null)" || fail_preflight VERIFY_CONFLICT
printf '%s' "$VERIFY" | jq -e --arg a "$ALIAS" '.status == "ready" and .phase == "verify" and ([.observations[]? | select(.alias == $a)] | length == 1)' >/dev/null 2>&1 || fail_preflight VERIFY_CONFLICT

# --- resume: sesion vinculada al mismo stage/huellas -------------------------
if [ -n "$RESUME" ]; then
    ec_call bind-session "$(child_req "$(jq -cn --arg s "$RESUME" --arg r "$ROLE" --arg st "$ROLE" --arg l "$RELEASE_VERSION" '{sessionID:$s,role:$r,stage:$st,release:$l,mode:"resume"}')")"
    [ "$EC_RC" -eq 0 ] || fail_preflight SESSION_NOT_BOUND
    META="$(runtime_service_request opencode GET "/session/$RESUME" "$WORK" 2>/dev/null)" || fail_preflight SESSION_NOT_OBSERVABLE
    printf '%s' "$META" | jq -e --arg s "$RESUME" --arg d "$CWD" '.id == $s and ((.directory // $d) == $d)' >/dev/null 2>&1 || fail_preflight SESSION_NOT_OBSERVABLE
fi

# --- unico punto de entrega del prompt ----------------------------------------
STARTED=1
RUN_ARGV=("${RUNNER_ARGS[@]}")
case " ${RUNNER_ARGS[*]} " in *" --runtime "*) ;; *) RUN_ARGV=(--runtime opencode "${RUN_ARGV[@]}") ;; esac
"$RUNNER" "${RUN_ARGV[@]}" --runtime-endpoint "$MEFISTO_RUNTIME_SERVICE_ENDPOINT" --execution-agent "$ALIAS" &
RUNNER_PID=$!
RC=0
while :; do
    wait "$RUNNER_PID"; RC=$?
    kill -0 "$RUNNER_PID" 2>/dev/null || break
done
RUNNER_PID=""

# --- cierre ---------------------------------------------------------------------
if [ -n "$CANCELLED" ]; then
    # Cancelacion: solo la sesion propia conocida; nada de matar por patron ni liberar referencias.
    [ -z "$RESUME" ] || runtime_service_request opencode POST "/session/$RESUME/abort" "$WORK" >/dev/null 2>&1 || true
    OUTCOME=aborted
elif [ "$RC" -eq 0 ]; then OUTCOME=succeeded
else OUTCOME=failed; fi
stop_service
finish_child "$OUTCOME"
write_result started "RUNNER_EXIT" "$RC"
cleanup_work
[ "$CLEANUP" = complete ] || printf 'WARN: cierre de la instancia propia desconocido; la referencia se conserva (CLEANUP_UNKNOWN)\n' >&2
if [ -n "$CANCELLED" ] && [ "$RC" -eq 0 ]; then RC=143; fi
exit "$RC"
