#!/usr/bin/env bash
# Ensamblador de la proyeccion OpenCode de entrada por comando (#1836). Cargar
# esta biblioteca no escribe, no toma locks, no invoca el SDK, un LLM ni la red:
# lee el perfil por inspect, delega los recursos en resolve-opencode-resources.sh
# de la misma release y compone con opencode-entry-permissions.jq (#1838) sin
# aproximar permisos. La logica pura vive en opencode-command-entry.jq.
# Requiere jq.

_oce_hash() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d ' ' -f 1; else sha256sum | cut -d ' ' -f 1; fi
}

# _oce_emit <status> <phase> <reason|""> <bindings-json> <extra-diag-code|"">
_oce_emit() {
    jq -cn --arg status "$1" --arg phase "${_oce_phase:-config}" --arg reason "$2" --argjson bindings "${3:-[]}" --arg code "${4:-}" \
        --argjson pid "${_oce_pid:-null}" --argjson pdig "${_oce_pdig:-null}" --argjson mfp "${_oce_catalog:-null}" '
        {schemaVersion:1,phase:$phase,admissionScope:"entry",status:$status,projectId:$pid,profileDigest:$pdig,
         catalogDigest:$mfp,resourcesDigest:null,projectionDigest:null,release:null,agents:[],bindings:$bindings,
         diagnostics:([ (if $reason != "" then {code:$reason} else empty end), (if $code != "" then {code:$code} else empty end) ])}
        + (if $reason != "" then {reasonCode:$reason} else {} end)'
}

# opencode_command_entry_resolve <release-root> <project-root> <scripts-dir>
# Exit 0 disabled|ready, 1 needs-approval|conflict, 2 protocolo/uso.
opencode_command_entry_resolve() {
    [ "$#" -eq 3 ] || return 2
    local release_root="$1" project_root="$2" scripts_dir="$3" libdir input phase inspect_out inspect_rc status reason
    local manifest matrix shell_file project_phys dir top required res_in res_out res_rc result digest line
    libdir="$release_root/src/published/scripts/adapters/lib"
    manifest="$release_root/command-entry-manifest.json"
    matrix="$release_root/src/published/contract/command-entry.json"
    shell_file="$release_root/src/published/contract/command-shell-templates.json"
    _oce_phase=config; _oce_pid=null; _oce_pdig=null
    _oce_catalog="$(jq -c '.catalogFingerprint // null' "$manifest" 2>/dev/null)" || return 2

    input="$(command cat)" || return 2
    jq -e '
      def strs: type == "array" and all(.[]; type == "string");
      type == "object" and .schemaVersion == 1 and (.phase == "config" or .phase == "command") and
      (.home | type == "string") and (.configPolicyKnown | type == "boolean") and
      ((keys - ["schemaVersion","phase","home","configPolicyKnown","runtimeContext","nugetAssetsFiles","commands","delegateAgents","foreignEntryAgents","permission","requestedCommand","sessionPolicyKnown","sessionProjectMatches","sessionPermission"]) | length == 0) and
      (["schemaVersion","phase","home","configPolicyKnown","runtimeContext","commands","delegateAgents","foreignEntryAgents","permission"] - keys | length == 0) and
      (.runtimeContext | type == "object" and .home == $h and (.directory | type == "string") and (.osHome | type == "string")) and
      ((.nugetAssetsFiles // []) | strs) and
      (.commands | type == "array" and all(.[]; type == "object" and (keys | sort) == ["agent","name","sourceDigest","subtask"] and (.name | type == "string") and (.sourceDigest | type == "string"))) and
      (.delegateAgents | type == "array" and all(.[]; type == "object" and (keys | sort) == ["available","id","mode","sourceDigest"])) and
      (.foreignEntryAgents | strs) and
      (.permission == null or (.permission | type == "object")) and
      (if .phase == "command" then
         (.requestedCommand | type == "string") and (.sessionPolicyKnown | type == "boolean") and (.sessionProjectMatches | type == "boolean") and
         ((.sessionPolicyKnown | not) or (.sessionPermission | type == "array"))
       else ((has("requestedCommand") or has("sessionPolicyKnown") or has("sessionProjectMatches") or has("sessionPermission")) | not) end)
    ' --arg h "$(jq -r '.home // ""' <<< "$input" 2>/dev/null)" >/dev/null 2>&1 <<< "$input" || return 2
    phase="$(jq -r .phase <<< "$input")"; _oce_phase="$phase"

    # 1. Guard de consumidor e inspect: nunca approve/revoke ni reparacion.
    project_phys="$(cd -P "$project_root" 2>/dev/null && pwd -P)" || { _oce_emit conflict "" '[]' PROJECT_ROOT_UNRESOLVABLE; return 1; }
    if [ ! -f "$project_phys/.mefisto/harness.config.json" ] && [ ! -f "$project_phys/.claude/harness.config.json" ]; then
        _oce_emit disabled NO_PROFILE '[]' ""; return 0
    fi
    if [ -f "$project_phys/.claude-plugin/plugin.json" ]; then _oce_emit disabled NOT_CONSUMER '[]' ""; return 0; fi
    inspect_out="$(cd "$project_phys" && "$scripts_dir/autonomy-profile.sh" inspect --project-root "$project_phys" 2>/dev/null)"; inspect_rc=$?
    if [ "$inspect_rc" -gt 1 ] || ! jq -e 'type == "object" and (.status | type == "string") and (.reasonCode | type == "string")' >/dev/null 2>&1 <<< "$inspect_out"; then
        _oce_emit conflict "" '[]' INSPECT_FAILED; return 1
    fi
    status="$(jq -r .status <<< "$inspect_out")"; reason="$(jq -r .reasonCode <<< "$inspect_out")"
    _oce_pid="$(jq -c '.projectId // null' <<< "$inspect_out")"; _oce_pdig="$(jq -c '.profileDigest // null' <<< "$inspect_out")"
    local denied
    denied="$(jq -c --arg phase "$phase" '[.templates[] | select(.kind == "command") | {command:("mefisto:" + .id),agent:("command-entry-" + .id),subtask:false,sourceDigest:.sha256,admitted:false}]' "$manifest")" || return 2
    case "$status" in
        disabled)
            # NO_PROFILE inicial es legacy; cualquier otro motivo es no-admision con filas denegadas.
            if [ "$reason" = NO_PROFILE ]; then _oce_emit disabled "$reason" '[]' ""; else _oce_emit disabled "$reason" "$denied" ""; fi
            return 0 ;;
        needs-approval) _oce_emit needs-approval "$reason" "$denied" ""; return 1 ;;
        ready) ;;
        *) _oce_emit conflict "$reason" '[]' INSPECT_CONFLICT; return 1 ;;
    esac

    # 2. Recursos desde la misma release, derivados de las filas aprobadas.
    # Todas las filas aprobadas en ambas fases: resourcesDigest no depende de la fase (#2013).
    required="$(jq -c --argjson insp "$inspect_out" '
      ($insp.profile.commands // []) as $approved
      | [.commands[] | select(.id as $i | ($approved | index($i)) != null)] as $rows
      | ((["release","project","state","runtime-tool-output"] + [$rows[].resources[]]) | unique)' "$matrix")" || return 2
    dir="$(jq -r .runtimeContext.directory <<< "$input")"
    top="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || { _oce_emit conflict "" "$denied" RUNTIME_DIRECTORY_UNRESOLVABLE; return 1; }
    top="$(cd -P "$top" 2>/dev/null && pwd -P)" || { _oce_emit conflict "" "$denied" RUNTIME_DIRECTORY_UNRESOLVABLE; return 1; }
    res_in="$(jq -c --argjson req "$required" '{schemaVersion:1,runtimeContext:.runtimeContext,requiredResources:$req,nugetAssetsFiles:(.nugetAssetsFiles // [])}' <<< "$input")"
    res_out="$("$scripts_dir/resolve-opencode-resources.sh" --project-root "$project_phys" --worktree-root "$top" <<< "$res_in" 2>/dev/null)"; res_rc=$?
    if [ "$res_rc" -gt 1 ] || ! jq -e 'type == "object" and .schemaVersion == 1 and (.status | type == "string")' >/dev/null 2>&1 <<< "$res_out"; then
        _oce_emit conflict "" "$denied" RESOURCES_UNAVAILABLE; return 1
    fi
    case "$(jq -r .status <<< "$res_out")" in
        disabled) _oce_emit disabled "$(jq -r '.diagnostics[0].code // "RESOURCES_DISABLED"' <<< "$res_out")" "$denied" ""; return 0 ;;
        needs-approval) _oce_emit needs-approval "$(jq -r '.diagnostics[0].code // "RESOURCES_NEEDS_APPROVAL"' <<< "$res_out")" "$denied" ""; return 1 ;;
        ready) ;;
        *) _oce_emit conflict "" "$denied" RESOURCES_CONFLICT; return 1 ;;
    esac
    if ! jq -e --argjson i "$inspect_out" --arg r "$release_root" '.projectId == $i.projectId and .profileDigest == $i.profileDigest and .release.root == $r' >/dev/null <<< "$res_out"; then
        _oce_emit conflict "" "$denied" SNAPSHOT_IDENTITY_MISMATCH; return 1
    fi

    # 3-6. Cobertura, ownership, politica propia y composicion ordenada (jq puro).
    local shells='null'
    [ ! -f "$shell_file" ] || shells="$(jq -c . "$shell_file" 2>/dev/null)" || shells='null'
    result="$(jq -c -L "$libdir" --argjson snap "$res_out" --argjson insp "$inspect_out" --argjson man "$(jq -c . "$manifest")" \
        --argjson mat "$(jq -c . "$matrix")" --argjson shells "$shells" --slurpfile agents "$release_root/agent-execution-manifest.json" \
        -f "$libdir/opencode-command-entry.jq" <<< "$input" 2>/dev/null)" || { _oce_emit conflict "" "$denied" PROJECTION_UNAVAILABLE; return 1; }
    jq -e 'type == "object" and .admissionScope == "entry"' >/dev/null 2>&1 <<< "$result" || { _oce_emit conflict "" "$denied" PROJECTION_UNAVAILABLE; return 1; }

    if [ "$(jq -r .status <<< "$result")" = ready ]; then
        digest="$(jq -cS '._digestInput' <<< "$result" | tr -d '\n' | _oce_hash)"
        result="$(jq -c --arg d "$digest" '.projectionDigest = $d' <<< "$result")"
    fi
    jq -c 'del(._digestInput)' <<< "$result"
    [ "$(jq -r .status <<< "$result")" = ready ]
}
