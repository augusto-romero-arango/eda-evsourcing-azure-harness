#!/usr/bin/env bash
# Broker de contexto de ejecucion del consumidor (MEF-ADR-0055): prepara, reserva,
# vincula y valida contextos durables y handoffs. Request JSON schemaVersion 1 por
# stdin, respuesta JSON por stdout. Exit: 0 ready/disabled/finished, 75 busy,
# 1 conflicto, 2 uso/protocolo. No guarda prompts, modelos, tokens ni config cruda.
# El modo local no vuelve el archivo inaccesible a un proceso del mismo usuario:
# un hash no es identidad humana ni sandbox; la autoedicion se detecta contra el
# digest que viaja en la referencia de uso, no contra el checksum del propio archivo.
set -uo pipefail
export LC_ALL=C
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PACKAGE_ROOT="${EC_PACKAGE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
CATALOG_FILE="$PACKAGE_ROOT/src/published/contract/command-entry.json"
ROLES_FILE="$PACKAGE_ROOT/src/published/contract/agent-execution.json"
RELEASE_FILE="$PACKAGE_ROOT/src/published/release-identity.json"
AUTONOMY_CMD="${EC_AUTONOMY_PROFILE_CMD:-$SCRIPT_DIR/autonomy-profile.sh}"

EMPTY_OBJ='{}'
emit() { # status reasonCode exit [extra-json]
    local extra="${4-}"; [ -n "$extra" ] || extra="$EMPTY_OBJ"
    jq -cn --arg s "$1" --arg r "$2" --argjson x "$extra" '{schemaVersion:1,status:$s,reasonCode:$r} + $x'
    exit "$3"
}
usage_err() { emit error "$1" 2; }
conflict() { emit conflict "$1" 1 "${2-}"; }

command -v jq >/dev/null 2>&1 || { printf '{"schemaVersion":1,"status":"error","reasonCode":"JQ_MISSING"}\n'; exit 2; }
hash_stdin() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d ' ' -f 1
    else sha256sum | cut -d ' ' -f 1; fi
}
valid_id() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'; }
valid_digest() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{64}$'; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
git_common_dir() {
    local root="$1" common
    common="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || return 1
    case "$common" in /*) cd "$common" 2>/dev/null && pwd -P ;; *) cd "$root/$common" 2>/dev/null && pwd -P ;; esac
}

OP="${1:-}"; [ $# -gt 0 ] && shift
OWNER_PID_FLAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --owner-pid) [ $# -ge 2 ] || usage_err USAGE; OWNER_PID_FLAG="$2"; shift 2 ;;
        *) usage_err USAGE ;;
    esac
done
case "$OP" in prepare|reserve-child|attach|validate|bind-session|record-entry-admission|refresh-observations|finish) ;; *) usage_err USAGE ;; esac
[ -z "$OWNER_PID_FLAG" ] || [ "$OP" = attach ] || usage_err USAGE

REQ="$(cat)"
printf '%s' "$REQ" | jq -e 'type == "object" and .schemaVersion == 1' >/dev/null 2>&1 || usage_err INVALID_REQUEST
rq() { printf '%s' "$REQ" | jq -r "$1 // empty" 2>/dev/null; }
rqj() { printf '%s' "$REQ" | jq -c "$1 // null" 2>/dev/null; }

ROOT_IN="$(rq .projectRoot)"
[ -n "$ROOT_IN" ] || usage_err INVALID_REQUEST
ROOT="$(cd "$ROOT_IN" 2>/dev/null && pwd -P)" || usage_err INVALID_ROOT
TOP="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || usage_err INVALID_ROOT
TOP="$(cd "$TOP" 2>/dev/null && pwd -P)"
[ "$ROOT" = "$TOP" ] || usage_err INVALID_ROOT
[ ! -f "$ROOT/.claude-plugin/plugin.json" ] || usage_err INVALID_ROOT

RUN_ID="$(rq .runId)"; CTX_ID="$(rq .contextId)"
valid_id "$RUN_ID" || usage_err INVALID_ID
valid_id "$CTX_ID" || usage_err INVALID_ID
RUNS_BASE="$ROOT/.mefisto/pipeline/autonomy/runs"
ctx_dir() { printf '%s/%s/contexts' "$RUNS_BASE" "$1"; }
ctx_file() { printf '%s/%s/contexts/%s.json' "$RUNS_BASE" "$1" "$2"; }

safe_path() { # no seguir symlinks en ningun componente bajo la raiz
    local cur="$ROOT" part
    for part in $(printf '%s' "${1#"$ROOT"/}" | tr '/' ' '); do
        cur="$cur/$part"
        [ ! -L "$cur" ] || return 1
    done
    return 0
}

# --- consentimiento / inspect -------------------------------------------------
INSPECT=""
run_inspect() {
    INSPECT="$(cd "$ROOT" && "$AUTONOMY_CMD" inspect --project-root "$ROOT" 2>/dev/null)"
    printf '%s' "$INSPECT" | jq -e 'type == "object" and has("status") and has("reasonCode")' >/dev/null 2>&1 || INSPECT=""
}
INSPECT_STATUS() { printf '%s' "$INSPECT" | jq -r '.status // empty'; }
INSPECT_REASON() { printf '%s' "$INSPECT" | jq -r '.reasonCode // empty'; }
require_ready_consent() {
    run_inspect
    [ -n "$INSPECT" ] || conflict INSPECT_UNAVAILABLE
    [ "$(INSPECT_STATUS)" = ready ] || conflict "$(INSPECT_REASON)" '{"newAdmissions":false}'
}

# --- lectura / escritura de contextos ----------------------------------------
DOC=""
load_ctx() { # runId contextId -> DOC
    local f; f="$(ctx_file "$1" "$2")"
    safe_path "$f" || conflict CONTEXT_PATH_UNSAFE
    [ -f "$f" ] && [ ! -L "$f" ] || conflict CONTEXT_NOT_FOUND
    DOC="$(jq -cS . "$f" 2>/dev/null)" || conflict CONTEXT_CORRUPT
    printf '%s' "$DOC" | jq -e '(.contract|type)=="object" and (.state|type)=="object" and (.contractDigest|type)=="string"' >/dev/null || conflict CONTEXT_CORRUPT
}
digest_of_contract() { printf '%s' "$1" | jq -cS '.contract' | tr -d '\n' | hash_stdin; }

# CAS bajo mkdir-lock: $1 ruta, $2 documento, $3 revision esperada (o "new").
# Sin limpieza por TTL: un lock huerfano se reporta busy, nunca se roba.
write_ctx() {
    local f="$1" doc="$2" want="$3" lock tmp cur
    safe_path "$f" || conflict CONTEXT_PATH_UNSAFE
    mkdir -p "$(dirname "$f")" || usage_err WRITE_FAILED
    safe_path "$f" || conflict CONTEXT_PATH_UNSAFE
    lock="$f.lock"
    mkdir "$lock" 2>/dev/null || emit busy CONTEXT_LOCKED 75
    if [ "$want" = new ]; then
        if [ -e "$f" ] || [ -L "$f" ]; then rmdir "$lock"; return 3; fi
    else
        cur="$(jq -r '.state.revision // empty' "$f" 2>/dev/null)"
        if [ "$cur" != "$want" ] || [ -L "$f" ]; then rmdir "$lock"; return 4; fi
    fi
    tmp="$(mktemp "$(dirname "$f")/.ctx.XXXXXX")" || { rmdir "$lock"; usage_err WRITE_FAILED; }
    if printf '%s\n' "$doc" > "$tmp" && mv -f "$tmp" "$f"; then rmdir "$lock"; return 0; fi
    rm -f "$tmp"; rmdir "$lock"; usage_err WRITE_FAILED
}
bump() { # DOC mutado con filtro jq ($1) y revision+1, updatedAt
    printf '%s' "$DOC" | jq -cS --arg now "$(now)" "$1 | .state.revision += 1 | .state.updatedAt = \$now" "${@:2}"
}
commit_ctx() { # runId contextId nuevo-doc
    local rev; rev="$(printf '%s' "$DOC" | jq -r '.state.revision')"
    write_ctx "$(ctx_file "$1" "$2")" "$3" "$rev"
    case $? in 0) return 0 ;; 4) conflict REVISION_CONFLICT ;; *) usage_err WRITE_FAILED ;; esac
}

ctx_field() { printf '%s' "$DOC" | jq -r "$1 // empty"; }

# Revalida identidad, referencias y consentimiento de un contexto ya cargado.
revalidate() { # digest-esperado
    local expected="$1" project_id profile_digest
    valid_digest "$expected" || usage_err INVALID_DIGEST
    [ "$(digest_of_contract "$DOC")" = "$(ctx_field .contractDigest)" ] || conflict CONTRACT_TAMPERED
    [ "$expected" = "$(ctx_field .contractDigest)" ] || conflict CONTRACT_DIGEST_MISMATCH
    [ "$(ctx_field .contract.runId)" = "$RUN_ID" ] && [ "$(ctx_field .contract.contextId)" = "$CTX_ID" ] || conflict CONTEXT_IDENTITY_MISMATCH
    [ "$(ctx_field .contract.approvedRoot)" = "$ROOT" ] || [ "$(ctx_field .contract.executionRoot)" = "$ROOT" ] || conflict ROOT_MISMATCH
    require_ready_consent
    project_id="$(printf '%s' "$INSPECT" | jq -r '.projectId // empty')"
    profile_digest="$(printf '%s' "$INSPECT" | jq -r '.profileDigest // empty')"
    [ "$project_id" = "$(ctx_field .contract.projectId)" ] || conflict PROJECT_MISMATCH '{"newAdmissions":false}'
    [ "$profile_digest" = "$(ctx_field .contract.profileDigest)" ] || conflict PROFILE_CHANGED '{"newAdmissions":false}'
    [ "$(release_id)" = "$(ctx_field .contract.release)" ] || conflict RELEASE_CHANGED '{"newAdmissions":false}'
    local parent; parent="$(ctx_field .contract.parentContextId)"
    if [ -n "$parent" ]; then
        local saved="$DOC" anchor
        load_ctx "$RUN_ID" "$parent"
        anchor="$(printf '%s' "$DOC" | jq -r --arg c "$CTX_ID" '[.state.children[]? | select(.contextId == $c)][0].contractDigest // empty')"
        DOC="$saved"
        [ "$anchor" = "$expected" ] || conflict PARENT_ANCHOR_MISMATCH
    fi
    return 0
}
release_id() { jq -r '.version // empty' "$RELEASE_FILE" 2>/dev/null; }

ctx_response() { # status reason exit
    emit "$1" "$2" "$3" "$(printf '%s' "$DOC" | jq -c --arg p "$(ctx_file "$RUN_ID" "$CTX_ID")" '{contextId:.contract.contextId,path:$p,digest:.contractDigest,state:.state.status,revision:.state.revision,newAdmissions:(.state.status=="prepared" or .state.status=="attached")}')"
}

new_nonce() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

# Subconjunto: todos los elementos de $1 (array JSON) deben estar en $2.
subset_of() { jq -ne --argjson a "$1" --argjson b "$2" '($a - $b) | length == 0' >/dev/null 2>&1; }

build_contract() { # parametros por jq --arg; ver prepare/reserve-child
    jq -cnS \
        --arg runId "$RUN_ID" --arg contextId "$CTX_ID" --arg parent "${PARENT:-}" \
        --arg projectId "$PROJECT_ID" --arg profileDigest "$PROFILE_DIGEST" \
        --arg rootCommand "$ROOT_COMMAND" --arg pipelineKind "${PIPELINE:-}" --arg stage "${STAGE:-}" \
        --arg agent "${AGENT:-}" --arg alias "${ALIAS:-}" --arg source "$SOURCE" --arg callId "${CALL_ID:-}" \
        --arg operation "$OPERATION" --arg release "$(release_id)" \
        --argjson roles "$ALLOWED_ROLES" --argjson pipelines "$ALLOWED_PIPELINES" --argjson resources "$RESOURCES" \
        --arg approved "$APPROVED_ROOT" --arg exec "$EXEC_ROOT" \
        --arg rtId "$RT_ID" --arg rtVer "$RT_VER" --arg lease "$LEASE_ID" --arg nonce "$(new_nonce)" \
        '{schemaVersion:1,runId:$runId,contextId:$contextId,parentContextId:(if $parent=="" then null else $parent end),
          projectId:$projectId,profileDigest:$profileDigest,rootCommand:$rootCommand,
          pipelineKind:(if $pipelineKind=="" then null else $pipelineKind end),
          logicalStage:(if $stage=="" then null else $stage end),
          originalAgent:(if $agent=="" then null else $agent end),alias:(if $alias=="" then null else $alias end),
          source:$source,callId:(if $callId=="" then null else $callId end),operation:$operation,release:$release,
          allowedRoles:$roles,allowedPipelines:$pipelines,resourceClasses:$resources,
          approvedRoot:$approved,executionRoot:$exec,runtime:{id:$rtId,version:$rtVer},leaseId:$lease,nonce:$nonce}'
}
new_doc() { # contract-json reservation-json
    local digest; digest="$(printf '%s' "$1" | jq -cS . | tr -d '\n' | hash_stdin)"
    jq -cnS --argjson c "$1" --arg d "$digest" --argjson r "$2" --arg now "$(now)" \
        '{contract:$c,contractDigest:$d,state:{status:"prepared",revision:1,sessions:[],children:[],handoffs:[],reservation:$r,attachment:null,entryAdmission:null,outcome:null,updatedAt:$now},observations:{}}'
}

# Valida ids opcionales del request (stage/agent/alias/callId/lease).
check_optional_ids() {
    local v
    for v in "$@"; do [ -z "$v" ] || valid_id "$v" || usage_err INVALID_ID; done
}

case "$OP" in
# ============================================================== prepare
prepare)
    ROOT_COMMAND="$(rq .rootCommand)"; PIPELINE="$(rq .pipelineKind)"; STAGE="$(rq .logicalStage)"
    AGENT="$(rq .originalAgent)"; ALIAS="$(rq .alias)"; SOURCE="$(rq .source)"; CALL_ID="$(rq .callId)"
    OPERATION="$(rq .operation)"; OPERATION="${OPERATION:-execute}"
    RT_ID="$(rq .runtime.id)"; RT_VER="$(rq .runtime.version)"; RT_VER="${RT_VER:-unknown}"; LEASE_ID="$(rq .leaseId)"
    check_optional_ids "$STAGE" "$AGENT" "$ALIAS" "$CALL_ID" "$LEASE_ID" "$ROOT_COMMAND" "$PIPELINE"
    [ -n "$ROOT_COMMAND" ] && [ -n "$LEASE_ID" ] && [ -n "$RT_ID" ] || usage_err INVALID_REQUEST
    case "$SOURCE" in command|tool-call|pipeline) ;; *) usage_err INVALID_REQUEST ;; esac
    [ "$SOURCE" != tool-call ] || [ -n "$CALL_ID" ] || usage_err INVALID_REQUEST
    [ -z "$(rq .parentContextId)" ] || usage_err INVALID_REQUEST
    # Legacy: runtime Claude o sin perfil no crea archivos ni requisitos OpenCode.
    [ "$RT_ID" != claude ] || emit disabled RUNTIME_LEGACY 0 '{"enabled":false}'
    run_inspect
    if [ -z "$INSPECT" ]; then
        [ -f "$ROOT/.mefisto/harness.config.json" ] || [ -f "$ROOT/.claude/harness.config.json" ] || emit disabled NO_PROFILE 0 '{"enabled":false}'
        conflict INSPECT_UNAVAILABLE
    fi
    if [ "$(INSPECT_STATUS)" = disabled ] && [ "$(INSPECT_REASON)" = NO_PROFILE ]; then emit disabled NO_PROFILE 0 '{"enabled":false}'; fi
    [ "$(INSPECT_STATUS)" = ready ] || conflict "$(INSPECT_REASON)" '{"newAdmissions":false}'
    PROJECT_ID="$(printf '%s' "$INSPECT" | jq -r '.projectId // empty')"
    PROFILE_DIGEST="$(printf '%s' "$INSPECT" | jq -r '.profileDigest // empty')"
    # rootCommand debe estar aprobado en el perfil y en el catalogo publicado.
    printf '%s' "$INSPECT" | jq -e --arg c "$ROOT_COMMAND" '(.profile.commands // []) | index($c) != null' >/dev/null || conflict ROOT_COMMAND_NOT_APPROVED
    ENTRY="$(jq -c --arg c "$ROOT_COMMAND" '[.commands[] | select(.id == $c)][0] // empty' "$CATALOG_FILE" 2>/dev/null)"
    [ -n "$ENTRY" ] || conflict ROOT_COMMAND_NOT_APPROVED
    CLASS_KIND="$(printf '%s' "$ENTRY" | jq -r '.executionClass.kind')"
    # La clase la deriva el catalogo; la operacion pedida solo puede coincidir con ella.
    case "$OPERATION" in
        execute) [ "$CLASS_KIND" = execute ] || [ "$CLASS_KIND" = by-operation ] || conflict EXECUTION_CLASS_MISMATCH ;;
        maintenance|query|prune) [ "$CLASS_KIND" = by-operation ] || conflict EXECUTION_CLASS_MISMATCH ;;
        *) usage_err INVALID_REQUEST ;;
    esac
    # Mantenimiento se prepara antes de la corrida: nunca dentro de un execute vivo del mismo run.
    if [ "$OPERATION" != execute ]; then
        for other in "$(ctx_dir "$RUN_ID")"/*.json; do
            [ -f "$other" ] || continue
            if jq -e '.contract.operation == "execute" and (.state.status == "prepared" or .state.status == "attached")' "$other" >/dev/null 2>&1; then
                conflict MAINTENANCE_INSIDE_EXECUTE
            fi
        done
    fi
    RESOURCES="$(printf '%s' "$ENTRY" | jq -cS '.resources // []')"
    if [ -n "$PIPELINE" ]; then
        jq -e --arg c "$ROOT_COMMAND" --arg p "$PIPELINE" '(.roots[$c] // []) | index($p) != null' "$ROLES_FILE" >/dev/null || conflict PIPELINE_NOT_ALLOWED
        PIPE_ROLES="$(jq -cS --arg p "$PIPELINE" '.pipelines[$p] // []' "$ROLES_FILE")"
        ALLOWED_PIPELINES="$(jq -cnS --arg p "$PIPELINE" '[$p]')"
    else
        PIPE_ROLES="$(jq -cS --arg c "$ROOT_COMMAND" '[(.roots[$c] // [])[] as $p | .pipelines[$p][]?] | unique' "$ROLES_FILE")"
        ALLOWED_PIPELINES="$(jq -cS --arg c "$ROOT_COMMAND" '.roots[$c] // [] | sort' "$ROLES_FILE")"
    fi
    if [ -n "$AGENT" ]; then
        jq -ne --arg a "$AGENT" --argjson r "$PIPE_ROLES" '$r | index($a) != null' >/dev/null || conflict ROLE_NOT_ALLOWED
    fi
    REQ_ROLES="$(rqj .allowedRoles)"
    if [ "$REQ_ROLES" != null ]; then
        subset_of "$REQ_ROLES" "$PIPE_ROLES" || conflict ROLE_NOT_ALLOWED
        ALLOWED_ROLES="$(printf '%s' "$REQ_ROLES" | jq -cS 'sort')"
    else
        ALLOWED_ROLES="$(printf '%s' "$PIPE_ROLES" | jq -cS 'sort')"
    fi
    APPROVED_ROOT="$ROOT"; EXEC_ROOT="$ROOT"
    CONTRACT="$(build_contract)"
    DOC="$(new_doc "$CONTRACT" null)"
    F="$(ctx_file "$RUN_ID" "$CTX_ID")"
    write_ctx "$F" "$DOC" new; rc=$?
    if [ "$rc" = 3 ]; then
        # Idempotente solo con el mismo contrato (nonce aparte): cualquier otra cosa es conflicto.
        EXISTING="$(jq -cS . "$F" 2>/dev/null)" || conflict CONTEXT_CORRUPT
        same="$(jq -nr --argjson a "$EXISTING" --argjson b "$CONTRACT" '($a.contract|del(.nonce)) == ($b|del(.nonce))')"
        [ "$same" = true ] || conflict CONTEXT_EXISTS
        DOC="$EXISTING"
    elif [ "$rc" != 0 ]; then usage_err WRITE_FAILED; fi
    ctx_response ready PREPARED 0
    ;;

# ============================================================== reserve-child
reserve-child)
    PARENT="$CTX_ID"; DIGEST="$(rq .digest)"
    CHILD="$(rq .childContextId)"; RES_ID="$(rq .reservationId)"
    STAGE="$(rq .logicalStage)"; PIPELINE="$(rq .pipelineKind)"; AGENT="$(rq .originalAgent)"; ALIAS="$(rq .alias)"
    CALL_ID="$(rq .callId)"; LEASE_ID="$(rq .leaseId)"; EXEC_ROOT_IN="$(rq .executionRoot)"
    valid_id "$CHILD" && valid_id "$RES_ID" || usage_err INVALID_ID
    check_optional_ids "$STAGE" "$PIPELINE" "$AGENT" "$ALIAS" "$CALL_ID" "$LEASE_ID"
    load_ctx "$RUN_ID" "$PARENT"; PDOC="$DOC"
    revalidate "$DIGEST"
    case "$(ctx_field .state.status)" in prepared|attached) ;; *) conflict PARENT_NOT_LIVE ;; esac
    [ "$(ctx_field .contract.source)" != tool-call ] || [ -n "$CALL_ID" ] || usage_err INVALID_REQUEST
    [ -n "$LEASE_ID" ] || LEASE_ID="$(ctx_field .contract.leaseId)"
    # El hijo solo reduce o deriva alcance: pipeline/rol dentro de lo permitido y worktree registrado.
    if [ -n "$PIPELINE" ]; then printf '%s' "$DOC" | jq -e --arg p "$PIPELINE" '.contract.allowedPipelines | index($p) != null' >/dev/null || conflict PIPELINE_NOT_ALLOWED
    else PIPELINE="$(ctx_field .contract.pipelineKind)"; fi
    if [ -n "$AGENT" ]; then printf '%s' "$DOC" | jq -e --arg a "$AGENT" '.contract.allowedRoles | index($a) != null' >/dev/null || conflict ROLE_NOT_ALLOWED; fi
    [ -n "$EXEC_ROOT_IN" ] || usage_err INVALID_REQUEST
    EXEC_ROOT="$(cd "$EXEC_ROOT_IN" 2>/dev/null && pwd -P)" || conflict EXECUTION_ROOT_UNREGISTERED
    REGISTERED="$(git -C "$ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | while IFS= read -r wt; do (cd "$wt" 2>/dev/null && pwd -P); done)"
    printf '%s\n' "$REGISTERED" | grep -Fxq "$EXEC_ROOT" || conflict EXECUTION_ROOT_UNREGISTERED
    # Mismo proyecto Git comun y mismo perfil/release: la identidad se hereda, no se reescribe.
    [ "$(git_common_dir "$EXEC_ROOT")" = "$(git_common_dir "$ROOT")" ] || conflict PROJECT_MISMATCH
    PROJECT_ID="$(ctx_field .contract.projectId)"; PROFILE_DIGEST="$(ctx_field .contract.profileDigest)"
    ROOT_COMMAND="$(ctx_field .contract.rootCommand)"; SOURCE="$(ctx_field .contract.source)"
    OPERATION="$(ctx_field .contract.operation)"; RESOURCES="$(printf '%s' "$DOC" | jq -cS '.contract.resourceClasses')"
    ALLOWED_PIPELINES="$(printf '%s' "$DOC" | jq -cS --arg p "$PIPELINE" 'if $p=="" then .contract.allowedPipelines else [$p] end')"
    if [ -n "$AGENT" ]; then ALLOWED_ROLES="$(jq -cn --arg a "$AGENT" '[$a]')"; else ALLOWED_ROLES="$(printf '%s' "$DOC" | jq -cS '.contract.allowedRoles')"; fi
    APPROVED_ROOT="$(ctx_field .contract.approvedRoot)"
    RT_ID="$(ctx_field .contract.runtime.id)"; RT_VER="$(ctx_field .contract.runtime.version)"
    CTX_ID="$CHILD"; PARENT_ID="$PARENT"
    CCONTRACT="$(PARENT="$PARENT_ID" build_contract)"
    CDOC="$(new_doc "$CCONTRACT" "$(jq -cn --arg i "$RES_ID" '{id:$i,status:"reserved"}')")"
    CDIGEST="$(printf '%s' "$CDOC" | jq -r .contractDigest)"
    CF="$(ctx_file "$RUN_ID" "$CHILD")"
    if [ -e "$CF" ]; then
        # Reserva repetida: idempotente solo con el mismo id de reserva y el mismo alcance.
        load_ctx "$RUN_ID" "$CHILD"
        [ "$(ctx_field .state.reservation.id)" = "$RES_ID" ] || conflict RESERVATION_EXISTS
        [ "$(printf '%s' "$DOC" | jq -c '.contract|del(.nonce)')" = "$(printf '%s' "$CCONTRACT" | jq -cS 'del(.nonce)')" ] || conflict RESERVATION_EXISTS
        ctx_response ready RESERVED 0
    fi
    # Primero el ancla en el padre (CAS); si falla no queda un hijo sin ancla.
    DOC="$PDOC"
    NEW_PARENT="$(bump '.state.children += [{contextId:$c,reservationId:$r,contractDigest:$d,status:"reserved"}]' --arg c "$CHILD" --arg r "$RES_ID" --arg d "$CDIGEST")"
    commit_ctx "$RUN_ID" "$PARENT" "$NEW_PARENT"
    write_ctx "$CF" "$CDOC" new || usage_err WRITE_FAILED
    DOC="$CDOC"; CTX_ID="$CHILD"
    ctx_response ready RESERVED 0
    ;;

# ============================================================== attach
attach)
    DIGEST="$(rq .digest)"; OWNER_PID="${OWNER_PID_FLAG:-$(rq .ownerPid)}"
    printf '%s' "$OWNER_PID" | grep -Eq '^[0-9]{1,10}$' || usage_err INVALID_REQUEST
    kill -0 "$OWNER_PID" 2>/dev/null || conflict OWNER_NOT_ALIVE
    load_ctx "$RUN_ID" "$CTX_ID"
    case "$(ctx_field .state.status)" in
        prepared) ;;
        attached)
            [ "$(ctx_field .state.attachment.ownerPid)" = "$OWNER_PID" ] || conflict ALREADY_ATTACHED
            revalidate "$DIGEST"; ctx_response ready ATTACHED 0 ;;
        finished) conflict HANDOFF_LATE ;;
        *) conflict CONTEXT_NOT_LIVE ;;
    esac
    [ "$(ctx_field .state.reservation.status)" != retired ] || conflict HANDOFF_LATE
    revalidate "$DIGEST"
    RT_ID="$(rq .runtime.id)"; RT_VER="$(rq .runtime.version)"
    [ -z "$RT_ID" ] || [ "$RT_ID" = "$(ctx_field .contract.runtime.id)" ] || conflict RUNTIME_MISMATCH
    NONCE="$(ctx_field .contract.nonce)"
    OBS="$(printf '%s' "$REQ" | jq -cS '(.observations // null) | if . == null then null else {resourcesDigest,permissionBase,permissionImageDigest,projection} end' 2>/dev/null)" || usage_err INVALID_REQUEST
    PGID="$(ps -o pgid= -p "$OWNER_PID" 2>/dev/null | tr -d ' ')"
    RECEIPT="$(printf '%s' "$REQ" | jq -cS --argjson pid "$OWNER_PID" --arg pgid "${PGID:-}" '{handoffId:(.handoffId // null),ownerPid:$pid,pgid:(if $pgid=="" then null else ($pgid|tonumber) end),descendantCoverage:(if (.descendantCoverage // "") == "complete" and (.handoffId // "") != "" then "complete" else "unknown" end)}')"
    NEW="$(bump '.state.status = "attached" | .state.attachment = {ownerPid:$pid,attachedAt:$now} | .state.handoffs += [$rec] | (if $obs != null then .observations[$n] = $obs else . end) | (if .state.reservation != null then .state.reservation.status = "consumed" else . end)' \
        --argjson pid "$OWNER_PID" --argjson rec "$RECEIPT" --argjson obs "$OBS" --arg n "$NONCE")"
    commit_ctx "$RUN_ID" "$CTX_ID" "$NEW"
    DOC="$NEW"
    ctx_response ready ATTACHED 0
    ;;

# ============================================================== validate
validate)
    DIGEST="$(rq .digest)"
    load_ctx "$RUN_ID" "$CTX_ID"
    revalidate "$DIGEST"
    [ "$(ctx_field .state.status)" != conflict ] || conflict CONTEXT_CONFLICT
    if [ "$(ctx_field .state.status)" = finished ]; then ctx_response finished FINISHED 0; fi
    EXP_RT="$(rq .runtime.id)"
    [ -z "$EXP_RT" ] || [ "$EXP_RT" = "$(ctx_field .contract.runtime.id)" ] || conflict RUNTIME_MISMATCH
    EXP_PL="$(rq .pipelineKind)"
    [ -z "$EXP_PL" ] || [ "$EXP_PL" = "$(ctx_field .contract.pipelineKind)" ] || conflict PIPELINE_NOT_ALLOWED
    ctx_response ready VALID 0
    ;;

# ============================================================== bind-session
bind-session)
    DIGEST="$(rq .digest)"; SESSION="$(rq .sessionID)"; ROLE="$(rq .role)"; STAGE="$(rq .stage)"; REL="$(rq .release)"
    MODE="$(rq .mode)"; MODE="${MODE:-bind}"
    valid_id "$SESSION" || usage_err INVALID_ID
    check_optional_ids "$ROLE" "$STAGE"
    case "$MODE" in bind|resume) ;; *) usage_err INVALID_REQUEST ;; esac
    load_ctx "$RUN_ID" "$CTX_ID"
    revalidate "$DIGEST"
    case "$(ctx_field .state.status)" in prepared|attached) ;; *) conflict CONTEXT_NOT_LIVE ;; esac
    [ -n "$REL" ] || REL="$(ctx_field .contract.release)"
    [ "$REL" = "$(ctx_field .contract.release)" ] || conflict RELEASE_MISMATCH
    [ -n "$ROLE" ] || ROLE="$(ctx_field .contract.originalAgent)"
    [ -n "$STAGE" ] || STAGE="$(ctx_field .contract.logicalStage)"
    [ -z "$ROLE" ] || printf '%s' "$DOC" | jq -e --arg a "$ROLE" '.contract.allowedRoles | index($a) != null' >/dev/null || conflict ROLE_NOT_ALLOWED
    [ -z "$(ctx_field .contract.logicalStage)" ] || [ "$STAGE" = "$(ctx_field .contract.logicalStage)" ] || conflict STAGE_MISMATCH
    # Busca el vinculo en todo el run: un id ajeno o de otro stage/release falla, nunca es fresh start.
    FOUND="$(for f in "$(ctx_dir "$RUN_ID")"/*.json; do [ -f "$f" ] && [ ! -L "$f" ] || continue; jq -c --arg s "$SESSION" '.state.sessions[]? | select(.sessionID == $s)' "$f" 2>/dev/null; done | head -1)"
    if [ -n "$FOUND" ]; then
        printf '%s' "$FOUND" | jq -e --arg p "$(ctx_field .contract.projectId)" --arg d "$(ctx_field .contract.profileDigest)" '.projectId == $p and .profileDigest == $d' >/dev/null || conflict SESSION_FOREIGN
        [ "$(printf '%s' "$FOUND" | jq -r .release)" = "$REL" ] || conflict RELEASE_MISMATCH
        [ "$(printf '%s' "$FOUND" | jq -r '.stage // ""')" = "$STAGE" ] || conflict STAGE_MISMATCH
        [ "$(printf '%s' "$FOUND" | jq -r '.role // ""')" = "$ROLE" ] || conflict ROLE_NOT_ALLOWED
    elif [ "$MODE" = resume ]; then
        conflict SESSION_UNKNOWN
    fi
    if printf '%s' "$DOC" | jq -e --arg s "$SESSION" '.state.sessions | map(.sessionID) | index($s) != null' >/dev/null; then ctx_response ready SESSION_BOUND 0; fi
    NEW="$(bump '.state.sessions += [{sessionID:$s,contextId:$c,role:$r,stage:$g,release:$l,projectId:.contract.projectId,profileDigest:.contract.profileDigest,nonce:.contract.nonce,boundAt:$now}]' \
        --arg s "$SESSION" --arg c "$CTX_ID" --arg r "$ROLE" --arg g "$STAGE" --arg l "$REL")"
    commit_ctx "$RUN_ID" "$CTX_ID" "$NEW"
    DOC="$NEW"
    ctx_response ready SESSION_BOUND 0
    ;;

# ============================================================== record-entry-admission
record-entry-admission)
    DIGEST="$(rq .digest)"; CALLER_NONCE="$(rq .controllerNonce)"
    load_ctx "$RUN_ID" "$CTX_ID"
    revalidate "$DIGEST"
    # Solo claves acotadas: sin prompts, reglas crudas ni valores sensibles.
    printf '%s' "$REQ" | jq -e '(.entryAdmission|type)=="object" and ((.entryAdmission|keys) - ["sessionID","commandId","release","permissionImageDigest","resourcesDigest","policyResult","ownership","revision"] | length == 0)' >/dev/null || usage_err INVALID_REQUEST
    [ "$(ctx_field .contract.source)" = command ] || conflict ENTRY_ADMISSION_NOT_COMMAND
    [ -z "$(ctx_field .contract.parentContextId)" ] || conflict ENTRY_ADMISSION_UNAUTHORIZED
    [ -n "$CALLER_NONCE" ] && [ "$CALLER_NONCE" = "$(ctx_field .contract.nonce)" ] || conflict ENTRY_ADMISSION_UNAUTHORIZED
    [ "$(ctx_field .state.status)" = attached ] || conflict ENTRY_ADMISSION_UNAUTHORIZED
    EA="$(rqj .entryAdmission)"
    ESESSION="$(printf '%s' "$EA" | jq -r '.sessionID // empty')"
    printf '%s' "$DOC" | jq -e --arg s "$ESESSION" '.state.sessions | map(.sessionID) | index($s) != null' >/dev/null || conflict SESSION_UNKNOWN
    [ "$(printf '%s' "$EA" | jq -r '.commandId // empty')" = "$(ctx_field .contract.rootCommand)" ] || conflict ENTRY_ADMISSION_UNAUTHORIZED
    [ "$(printf '%s' "$EA" | jq -r '.release // empty')" = "$(ctx_field .contract.release)" ] || conflict RELEASE_MISMATCH
    printf '%s' "$EA" | jq -e '.policyResult == "allowed" or .policyResult == "denied"' >/dev/null || usage_err INVALID_REQUEST
    EA="$(printf '%s' "$EA" | jq -cS --arg p "$(ctx_field .contract.projectId)" --arg d "$(ctx_field .contract.profileDigest)" --arg now "$(now)" '. + {projectId:$p,profileDigest:$d,recordedAt:$now}')"
    NEW="$(bump '.state.entryAdmission = $ea' --argjson ea "$EA")"
    commit_ctx "$RUN_ID" "$CTX_ID" "$NEW"
    DOC="$NEW"
    ctx_response ready ENTRY_ADMISSION_RECORDED 0
    ;;

# ============================================================== refresh-observations
refresh-observations)
    DIGEST="$(rq .digest)"; CALLER_NONCE="$(rq .controllerNonce)"
    load_ctx "$RUN_ID" "$CTX_ID"
    revalidate "$DIGEST"
    NONCE="$(ctx_field .contract.nonce)"
    [ "$CALLER_NONCE" = "$NONCE" ] || conflict OBSERVATION_UNAUTHORIZED
    [ "$(ctx_field .state.status)" = attached ] || conflict CONTEXT_NOT_LIVE
    NEWOBS="$(printf '%s' "$REQ" | jq -cS '.observations | select(type=="object") | {resourcesDigest,permissionBase,permissionImageDigest,projection}')" || usage_err INVALID_REQUEST
    [ -n "$NEWOBS" ] || usage_err INVALID_REQUEST
    OLD_IMG="$(printf '%s' "$DOC" | jq -r --arg n "$NONCE" '.observations[$n].permissionImageDigest // empty')"
    NEW_IMG="$(printf '%s' "$NEWOBS" | jq -r '.permissionImageDigest // empty')"
    # Solo evidencia tecnica del mismo nonce con la misma imagen de permisos; roots/politica nuevos requieren admision nueva.
    [ -n "$OLD_IMG" ] && [ "$OLD_IMG" = "$NEW_IMG" ] || conflict READMISSION_REQUIRED
    NEW="$(bump '.observations[$n] = $o' --arg n "$NONCE" --argjson o "$NEWOBS")"
    commit_ctx "$RUN_ID" "$CTX_ID" "$NEW"
    DOC="$NEW"
    ctx_response ready OBSERVATIONS_REFRESHED 0
    ;;

# ============================================================== finish
finish)
    DIGEST="$(rq .digest)"; OUTCOME="$(rq .outcome)"
    case "$OUTCOME" in succeeded|failed|aborted|held) ;; *) usage_err INVALID_REQUEST ;; esac
    load_ctx "$RUN_ID" "$CTX_ID"
    valid_digest "$DIGEST" || usage_err INVALID_DIGEST
    [ "$(digest_of_contract "$DOC")" = "$(ctx_field .contractDigest)" ] && [ "$DIGEST" = "$(ctx_field .contractDigest)" ] || conflict CONTRACT_TAMPERED
    if [ "$(ctx_field .state.status)" = finished ]; then ctx_response finished FINISHED 0; fi
    # Cierre del controlador, no prueba de cumplimiento de CAs. No toca hijos: se reporta cuantos siguen vivos.
    # Un hold conserva la referencia del parent-run para el reintento: nunca reporta el lease liberado.
    LIVE=0
    for c in $(printf '%s' "$DOC" | jq -r '.state.children[]?.contextId'); do
        cf="$(ctx_file "$RUN_ID" "$c")"
        if [ -f "$cf" ] && [ "$(jq -r '.state.status' "$cf" 2>/dev/null)" != finished ]; then LIVE=$((LIVE + 1)); fi
    done
    NEW="$(bump '.state.status = "finished" | .state.outcome = $o | .state.finishedAt = $now | (if .state.reservation != null and .state.reservation.status == "reserved" then .state.reservation.status = "retired" else . end)' --arg o "$OUTCOME")"
    commit_ctx "$RUN_ID" "$CTX_ID" "$NEW"
    DOC="$NEW"
    emit finished FINISHED 0 "$(printf '%s' "$DOC" | jq -c --argjson live "$LIVE" '{contextId:.contract.contextId,digest:.contractDigest,state:.state.status,revision:.state.revision,liveChildren:$live,leaseReleased:($live == 0 and .state.outcome != "held"),recovery:(if ([.state.handoffs[]? | select(.descendantCoverage != "complete")] | length) > 0 then "unknown" else "verified" end)}')"
    ;;
esac
