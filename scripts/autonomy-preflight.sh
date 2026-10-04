#!/usr/bin/env bash
# Validador de admision previa de autonomia (MEF-ADR-0055, issue #1870).
# Decide lo observable ANTES de crear el primer worktree; no certifica la sesion
# headless futura (eso es el handshake de etapa, run-published-agent.sh/#1858).
# Solo consulta interfaces de inspeccion: nunca escribe logs, config, consentimiento,
# contexto, worktrees ni estado, y no invoca prepare/approve/project/install/restore.
#
# Uso: autonomy-preflight.sh --project-root <raiz-Git> --runtime <id> [--context <ruta>]
#      (plan JSON schemaVersion 1 por stdin)
# Exit: 0 ready-to-dispatch|legacy, 1 blocked|incomplete, 2 protocolo/uso.
set -uo pipefail
export LC_ALL=C
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ROLES_FILE="$PACKAGE_ROOT/src/published/contract/agent-execution.json"
CATALOG_FILE="$PACKAGE_ROOT/src/published/contract/command-entry.json"
SOURCES_FILE="$PACKAGE_ROOT/src/published/contract/source-verification.json"
RELEASE_FILE="$PACKAGE_ROOT/src/published/release-identity.json"
STAGE_OWNER='run-published-agent.sh/#1858'

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }
usage() { fail 'uso: autonomy-preflight.sh --project-root <raiz-Git> --runtime <id> [--context <ruta>] (plan JSON por stdin)'; }
command -v jq >/dev/null 2>&1 || fail 'jq no esta instalado'
hash_stdin() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d ' ' -f 1
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d ' ' -f 1
    else fail 'no se encontro una implementacion de SHA-256'; fi
}
valid_id() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'; }

PROJECT_ROOT=""; RUNTIME=""; CONTEXT=""; SEEN_CTX=0
while [ $# -gt 0 ]; do
    case "$1" in
        --project-root) [ $# -ge 2 ] && [ -z "$PROJECT_ROOT" ] || usage; PROJECT_ROOT="$2"; shift 2 ;;
        --runtime) [ $# -ge 2 ] && [ -z "$RUNTIME" ] || usage; RUNTIME="$2"; shift 2 ;;
        --context) [ $# -ge 2 ] && [ "$SEEN_CTX" -eq 0 ] || usage; CONTEXT="$2"; SEEN_CTX=1; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$PROJECT_ROOT" ] && [ -n "$RUNTIME" ] || usage
printf '%s' "$RUNTIME" | grep -Eq '^[a-z][a-z0-9_]{0,31}$' || fail 'runtime invalido'
[ ! -e "$PACKAGE_ROOT/src/runtime/lib/runtime-$RUNTIME.sh" ] && fail 'el runtime no tiene adaptador en esta release'
[ -f "$ROLES_FILE" ] && [ -f "$CATALOG_FILE" ] && [ -f "$SOURCES_FILE" ] && [ -f "$RELEASE_FILE" ] || fail 'la release no incluye los contratos publicados'

# --- plan (stdin) ------------------------------------------------------------
PLAN_RAW="$(cat)"
printf '%s' "$PLAN_RAW" | jq -e '
  type == "object"
  and ((keys | sort) == ["issues","launchKind","requestedOperations","schemaVersion","source"])
  and .schemaVersion == 1
  and (.launchKind | IN("sequential","parallel","pane"))
  and (.source | IN("command","direct"))
  and .requestedOperations == []
  and (.issues | type == "array" and length > 0 and all(.[];
        type == "object" and ((keys | sort) == ["number","pipelineKind"])
        and (.number | type == "number" and . > 0 and . == floor)
        and (.pipelineKind | type == "string")))
  and ((.issues | map(.number) | unique | length) == (.issues | length))' >/dev/null 2>&1 || fail 'plan invalido: schema, ids, unicidad u operaciones no admitidas'
PLAN="$(printf '%s' "$PLAN_RAW" | jq -cS '.issues |= sort_by(.number)')"
LAUNCH="$(printf '%s' "$PLAN" | jq -r .launchKind)"
SOURCE="$(printf '%s' "$PLAN" | jq -r .source)"
case "$LAUNCH" in pane) ROOT_COMMAND=parallel ;; *) ROOT_COMMAND="$LAUNCH" ;; esac
if [ "$SOURCE" = command ]; then [ -n "$CONTEXT" ] || fail 'source:command exige --context'
else [ "$SEEN_CTX" -eq 0 ] || fail 'source:direct no admite --context'; fi
PIPELINES="$(printf '%s' "$PLAN" | jq -cS '[.issues[].pipelineKind] | unique')"
jq -e --arg c "$ROOT_COMMAND" --argjson p "$PIPELINES" '($p - (.roots[$c] // [])) | length == 0' "$ROLES_FILE" >/dev/null 2>&1 || fail 'pipelineKind desconocido o inconsistente con el catalogo'
ROLES="$(jq -cS --argjson p "$PIPELINES" '[$p[] as $k | .pipelines[$k][]?] | unique' "$ROLES_FILE")"
PLAN_DIGEST="$(printf '%s' "$PLAN" | hash_stdin)"

# --- proyecto ----------------------------------------------------------------
ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P)" || fail 'la raiz de proyecto no existe'
TOP="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || fail 'la raiz indicada no es un repositorio Git'
TOP="$(cd "$TOP" 2>/dev/null && pwd -P)"
[ "$ROOT" = "$TOP" ] || fail 'project-root debe ser la raiz del worktree o repositorio'
[ ! -f "$ROOT/.claude-plugin/plugin.json" ] || fail 'el preflight es del plugin publicado y solo aplica al consumidor'

REL_VERSION="$(jq -r '.version // empty' "$RELEASE_FILE" 2>/dev/null)"
REL_COMMIT="$(jq -r '.commit // empty' "$RELEASE_FILE" 2>/dev/null)"
REL_ROOT_SAFE="$PACKAGE_ROOT"
case "$PACKAGE_ROOT" in "${HOME:-/nonexistent}"/*) REL_ROOT_SAFE="~${PACKAGE_ROOT#"$HOME"}" ;; esac

CHECKS=""; HARD_BLOCK=0; EVIDENCE_GAP=0
add() { # code state owner action [evidence]
    CHECKS="$CHECKS$(jq -cn --arg c "$1" --arg s "$2" --arg o "$3" --arg a "$4" '{code:$c,state:$s,owner:$o,actionCode:$a}')"$'\n'
    if [ "$2" = block ]; then
        if [ "${5-}" = evidence ]; then EVIDENCE_GAP=1; else HARD_BLOCK=1; fi
    fi
}

PROJECT_ID=""; PROFILE_DIGEST=""; RESOURCES_DIGEST=""
emit() { # status exit
    local checks diag
    checks="$(printf '%s' "$CHECKS" | jq -cs '.')"
    diag="$(printf '%s' "$checks" | jq -c '[.[] | select(.state == "block" or .state == "deferred") | "\(.code):\(.actionCode)"]')"
    jq -cn --arg status "$1" --arg pid "$PROJECT_ID" --arg pd "$PROFILE_DIGEST" --arg rt "$RUNTIME" --arg rr "$REL_ROOT_SAFE" \
        --arg rv "$REL_VERSION" --arg rc "$REL_COMMIT" --arg plan "$PLAN_DIGEST" --arg res "$RESOURCES_DIGEST" \
        --argjson checks "$checks" --argjson diag "$diag" \
        '{schemaVersion:1,admissionScope:"pre-dispatch",status:$status,
          projectId:(if $pid=="" then null else $pid end),profileDigest:(if $pd=="" then null else $pd end),
          release:{runtime:$rt,root:$rr,version:$rv,commit:$rc},planDigest:$plan,
          resourcesDigest:(if $res=="" then null else $res end),checks:$checks,diagnostics:$diag}'
    exit "$2"
}
finish() {
    if [ "$HARD_BLOCK" -eq 1 ]; then emit blocked 1
    elif [ "$EVIDENCE_GAP" -eq 1 ]; then emit incomplete 1
    else emit ready-to-dispatch 0; fi
}

# --- perfil / consentimiento (solo inspect) -----------------------------------
INSPECT="$(cd "$ROOT" && "$SCRIPT_DIR/autonomy-profile.sh" inspect --project-root "$ROOT" 2>/dev/null)"
printf '%s' "$INSPECT" | jq -e 'type == "object" and has("status") and has("reasonCode")' >/dev/null 2>&1 || INSPECT=""
I_STATUS=""; I_REASON=""
if [ -n "$INSPECT" ]; then
    I_STATUS="$(printf '%s' "$INSPECT" | jq -r '.status // empty')"
    I_REASON="$(printf '%s' "$INSPECT" | jq -r '.reasonCode // empty')"
    PROJECT_ID="$(printf '%s' "$INSPECT" | jq -r '.projectId // empty')"
    PROFILE_DIGEST="$(printf '%s' "$INSPECT" | jq -r '.profileDigest // empty')"
fi
HAS_CONFIG=0
[ -f "$ROOT/.mefisto/harness.config.json" ] || [ -f "$ROOT/.claude/harness.config.json" ] && HAS_CONFIG=1

# Ruta legacy: Claude sin contexto, o sin perfil y sin contexto. No exige CLI/config de otro runtime.
if [ "$SEEN_CTX" -eq 0 ]; then
    if [ "$RUNTIME" = claude ] || { [ "$I_STATUS" = disabled ] && [ "$I_REASON" = NO_PROFILE ]; } || { [ -z "$INSPECT" ] && [ "$HAS_CONFIG" -eq 0 ]; }; then
        add ENTRY_ADMISSION not-applicable preflight LEGACY_FLOW
        emit legacy 0
    fi
fi
if [ "$RUNTIME" = claude ] && [ "$SEEN_CTX" -eq 1 ]; then
    add CONTEXT_RUNTIME block preflight CONTEXT_RUNTIME_MISMATCH
    finish
fi
if [ -z "$INSPECT" ]; then
    add PROFILE_INSPECT block preflight INSPECT_UNAVAILABLE evidence
    finish
fi
case "$I_STATUS/$I_REASON" in
    ready/*) add PROFILE_CONSENT pass preflight NONE ;;
    disabled/NO_PROFILE) add PROFILE_CONSENT block preflight NO_PROFILE_WITH_CONTEXT ;;
    disabled/CONSENT_REVOKED) add PROFILE_CONSENT block preflight CONSENT_REVOKED ;;
    needs-approval/*) add PROFILE_CONSENT block preflight NEEDS_APPROVAL ;;
    *) add PROFILE_CONSENT block preflight "${I_REASON:-INSPECT_CONFLICT}" ;;
esac
[ "$HARD_BLOCK" -eq 0 ] || finish

if printf '%s' "$INSPECT" | jq -e --arg c "$ROOT_COMMAND" '(.profile.commands // []) | index($c) != null' >/dev/null 2>&1; then
    add ROOT_COMMAND pass preflight NONE
else
    add ROOT_COMMAND block preflight ROOT_COMMAND_NOT_APPROVED
fi
jq -e --arg c "$ROOT_COMMAND" '[.commands[] | select(.id == $c)] | length == 1' "$CATALOG_FILE" >/dev/null 2>&1 || add CATALOG block preflight ROOT_COMMAND_NOT_IN_CATALOG

# --- contexto / entrada (source:command) --------------------------------------
if [ "$SOURCE" = command ]; then
    CTX_DOC=""
    if [ -f "$CONTEXT" ] && [ ! -L "$CONTEXT" ]; then CTX_DOC="$(jq -cS . "$CONTEXT" 2>/dev/null)"; fi
    if ! printf '%s' "$CTX_DOC" | jq -e '(.contract|type)=="object" and (.state|type)=="object" and (.contractDigest|type)=="string"' >/dev/null 2>&1; then
        add CONTEXT block preflight CONTEXT_UNREADABLE
        finish
    fi
    C_RUN="$(printf '%s' "$CTX_DOC" | jq -r '.contract.runId // empty')"
    C_ID="$(printf '%s' "$CTX_DOC" | jq -r '.contract.contextId // empty')"
    C_DIGEST="$(printf '%s' "$CTX_DOC" | jq -r '.contractDigest')"
    CTX_DIR="$(cd "$(dirname "$CONTEXT")" 2>/dev/null && pwd -P)"
    if valid_id "$C_RUN" && valid_id "$C_ID" && [ "$CTX_DIR/$(basename "$CONTEXT")" = "$ROOT/.mefisto/pipeline/autonomy/runs/$C_RUN/contexts/$C_ID.json" ]; then
        add CONTEXT_ORIGIN pass preflight NONE
    else
        add CONTEXT_ORIGIN block preflight CONTEXT_ORIGIN_MISMATCH
        finish
    fi
    if [ "$(printf '%s' "$CTX_DOC" | jq -r '.contract.runtime.id // empty')" != "$RUNTIME" ]; then
        add CONTEXT_RUNTIME block preflight CONTEXT_RUNTIME_MISMATCH
        finish
    fi
    V_REQ="$(jq -cn --arg r "$C_RUN" --arg c "$C_ID" --arg d "$C_DIGEST" --arg rt "$RUNTIME" --arg root "$ROOT" '{schemaVersion:1,projectRoot:$root,runId:$r,contextId:$c,digest:$d,runtime:{id:$rt}}')"
    V_OUT="$(printf '%s' "$V_REQ" | "$SCRIPT_DIR/execution-context.sh" validate 2>/dev/null)"; V_RC=$?
    V_STATUS="$(printf '%s' "$V_OUT" | jq -r '.status // empty' 2>/dev/null)"
    if [ "$V_RC" -eq 0 ] && [ "$V_STATUS" = ready ]; then
        add CONTEXT_VALID pass preflight NONE
    elif [ "$V_RC" -eq 1 ]; then
        add CONTEXT_VALID block preflight "$(printf '%s' "$V_OUT" | jq -r '.reasonCode // "CONTEXT_CONFLICT"')"
    else
        add CONTEXT_VALID block preflight CONTEXT_VALIDATE_UNAVAILABLE evidence
    fi
    if printf '%s' "$CTX_DOC" | jq -e --arg c "$ROOT_COMMAND" --argjson p "$PIPELINES" --argjson r "$ROLES" '
        .contract.source == "command" and .contract.rootCommand == $c
        and (($p - (.contract.allowedPipelines // [])) | length == 0)
        and (($r - (.contract.allowedRoles // [])) | length == 0)' >/dev/null 2>&1; then
        add CONTEXT_SCOPE pass preflight NONE
    else
        add CONTEXT_SCOPE block preflight CONTEXT_SCOPE_MISMATCH
    fi
    EA="$(printf '%s' "$CTX_DOC" | jq -c '.state.entryAdmission // null')"
    if [ "$EA" = null ] || [ "$(printf '%s' "$CTX_DOC" | jq -r '.state.status')" != attached ]; then
        add ENTRY_ADMISSION block "callback#1855" ENTRY_ADMISSION_MISSING evidence
    elif [ "$(printf '%s' "$EA" | jq -r '.policyResult // empty')" != allowed ]; then
        add ENTRY_ADMISSION block "callback#1855" ENTRY_POLICY_DENIED
    elif ! printf '%s' "$EA" | jq -e --arg p "$PROJECT_ID" --arg d "$PROFILE_DIGEST" --arg c "$ROOT_COMMAND" --argjson s "$(printf '%s' "$CTX_DOC" | jq -c '[.state.sessions[]?.sessionID]')" '
        .projectId == $p and .profileDigest == $d and .commandId == $c and ((.sessionID // "") as $i | $s | index($i) != null)
        and ((.ownership // null) | . != null and . != "" and . != false)
        and ((.resourcesDigest // "") | type == "string" and length > 0)
        and ((.permissionImageDigest // "") | type == "string" and length > 0)' >/dev/null 2>&1; then
        add ENTRY_ADMISSION block "callback#1855" ENTRY_EVIDENCE_INCOMPLETE evidence
    else
        add ENTRY_ADMISSION pass preflight NONE
        RESOURCES_DIGEST="$(printf '%s' "$EA" | jq -r '.resourcesDigest')"
    fi
else
    add ENTRY_ADMISSION not-applicable preflight DIRECT_INVOCATION
fi
[ "$HARD_BLOCK" -eq 0 ] || finish

# --- clausura local: scripts y binarios (consultas sin efectos) ----------------
case "$LAUNCH" in sequential) LAUNCHER=batch-pipeline.sh ;; *) LAUNCHER=parallel-pipeline.sh ;; esac
NEEDED="$LAUNCHER run-published-agent.sh execution-context.sh autonomy-profile.sh $(printf '%s' "$PIPELINES" | jq -r '.[] | . + "-pipeline.sh"' | tr '\n' ' ')"
MISSING_SCRIPTS=""
for s in $NEEDED; do [ -x "$SCRIPT_DIR/$s" ] || MISSING_SCRIPTS="$MISSING_SCRIPTS$s "; done
if [ -z "$MISSING_SCRIPTS" ]; then add RELEASE_SCRIPTS pass preflight NONE; else add RELEASE_SCRIPTS block preflight RELEASE_SCRIPT_MISSING; fi

BINARIES="git gh"
printf '%s' "$PIPELINES" | jq -e 'index("tdd") != null or index("scaffold") != null' >/dev/null && BINARIES="$BINARIES dotnet"
printf '%s' "$PIPELINES" | jq -e 'index("iac") != null' >/dev/null && BINARIES="$BINARIES terraform"
for b in $BINARIES; do
    if command -v "$b" >/dev/null 2>&1; then add "BINARY_$b" pass preflight NONE; else add "BINARY_$b" block preflight BINARY_MISSING evidence; fi
done

# --- fuentes por rol (matriz #1822): capacidad disponible, no consulta hecha ----
HAVE_DOTNET=0; command -v dotnet >/dev/null 2>&1 && HAVE_DOTNET=1
LOCAL_SEEN=0
SRC_ROWS="$(jq -c --argjson r "$ROLES" '.roles[] | select(.id as $i | $r | index($i) != null) | . as $role | .cases[] | {role:$role.id,caseId,when,onMissing,kinds:[.options[].kind]}' "$SOURCES_FILE")"
while IFS= read -r row; do
    [ -n "$row" ] || continue
    role="$(printf '%s' "$row" | jq -r .role)"; case_id="$(printf '%s' "$row" | jq -r .caseId)"
    kinds="$(printf '%s' "$row" | jq -r '.kinds | join(" ")')"; on_missing="$(printf '%s' "$row" | jq -r .onMissing)"
    case " $kinds " in
        *" local-artifact "*) LOCAL_SEEN=1; continue ;;
    esac
    avail=0
    case " $kinds " in *" package-cli "*) [ "$HAVE_DOTNET" -eq 1 ] && avail=1 ;; esac
    code="SOURCE_${role}_${case_id}"
    if [ "$avail" -eq 1 ]; then add "$code" deferred "$STAGE_OWNER" CONDITIONAL_SOURCE_AT_STAGE
    elif [ "$on_missing" = block ]; then add "$code" block preflight SOURCE_ALTERNATIVE_MISSING
    else add "$code" deferred "$STAGE_OWNER" SOURCE_CAPABILITY_UNVERIFIED; fi
done <<EOF
$SRC_ROWS
EOF
[ "$LOCAL_SEEN" -eq 0 ] || add SOURCE_LOCAL deferred "$STAGE_OWNER" WORKTREE_NOT_YET_AVAILABLE

# --- diferidos con owner verificable --------------------------------------------
if [ -x "$SCRIPT_DIR/run-published-agent.sh" ] && grep -q 'execution-context' "$SCRIPT_DIR/run-published-agent.sh" 2>/dev/null; then
    add STAGE_ACTOR_GUARD deferred "$STAGE_OWNER" ACTOR_AND_PERMISSIONS_AT_STAGE
else
    add STAGE_ACTOR_GUARD block preflight STAGE_GUARD_MISSING
fi
[ "$SOURCE" = command ] || add RESOURCES_SNAPSHOT deferred "$STAGE_OWNER" SNAPSHOT_AT_STAGE
add REMOTE_ACCESS deferred "$STAGE_OWNER" REMOTE_UNVERIFIED

finish
