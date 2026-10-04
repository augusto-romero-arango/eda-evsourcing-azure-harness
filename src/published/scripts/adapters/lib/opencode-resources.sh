#!/usr/bin/env bash
# Ensamblador del snapshot de recursos efectivos del borde OpenCode. Cargar esta
# biblioteca no escribe, no toma locks ni concede acceso: describe recursos ya
# verificables y delega en las piezas que los observan (consentimiento, roots
# del host/release y NuGet). Requiere resource-paths.sh y opencode-resource-roots.sh.

_ores_diag() {
    _ores_diagnostics="$(jq -c --arg code "$1" 'if any(.[]; .code == $code) then . else . + [{code:$code}] end' <<< "$_ores_diagnostics")"
}

_ores_git() {
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE -u GIT_CEILING_DIRECTORIES git "$@"
}

_ores_common_dir() {
    local root="$1" common
    common="$(_ores_git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || return 1
    case "$common" in /*) ;; *) common="$root/$common" ;; esac
    (cd -P "$common" 2>/dev/null && pwd -P)
}

_ores_toplevel() {
    local top
    top="$(_ores_git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
    (cd -P "$top" 2>/dev/null && pwd -P)
}

_ores_hash() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d ' ' -f 1; else sha256sum | cut -d ' ' -f 1; fi
}

# El matcher de permisos no representa estos caracteres literalmente.
_ores_unrepresentable() {
    case "$1" in *'*'*|*'?'*|*'\'*|*[[:cntrl:]]*) return 0 ;; esac
    return 1
}

_ores_phys() {
    local record
    record="$(resource_path_resolve "$1" "$2" 2>/dev/null)" || return 1
    jq -r .physicalRoot <<< "$record"
}

_ores_overlap() {
    resource_path_contains "$1" "$2" >/dev/null 2>&1 || resource_path_contains "$2" "$1" >/dev/null 2>&1
}

_ores_relative() {
    resource_path_relative "$_ores_worktree_logical" "$1" 2>/dev/null
}

_ores_emit() {
    local status="$1" digest="${2:-null}"
    jq -cn --arg status "$status" --argjson projectId "$_ores_project_id" --argjson profileDigest "$_ores_profile_digest" \
        --argjson resourcesDigest "$digest" --argjson release "$_ores_release" --argjson project "$_ores_project" \
        --argjson permissionBase "$_ores_base" --argjson resources "$_ores_resources" --argjson protectedRoots "$_ores_protected" \
        --argjson projection "$_ores_projection" --argjson nuget "$_ores_nuget" --argjson diagnostics "$_ores_diagnostics" \
        '{schemaVersion:1,resolutionScope:"resources",status:$status,projectId:$projectId,profileDigest:$profileDigest,resourcesDigest:$resourcesDigest,
          release:$release,project:$project,permissionBase:$permissionBase,resources:$resources,protectedRoots:$protectedRoots,
          projection:$projection,nuget:$nuget,diagnostics:$diagnostics}'
}

_ores_conflict() {
    _ores_diag "$1"
    _ores_resources='[]'; _ores_protected='[]'
    _ores_emit conflict
    return 1
}

# _ores_add_resource <id> <root> <exists> <maxAccess> <provenance-json> <excluded-json> <aliases-json>
_ores_add_resource() {
    local relative
    relative="$(_ores_relative "$2")" || return 1
    _ores_resources="$(jq -c --arg id "$1" --arg root "$2" --argjson exists "$3" --arg max "$4" --argjson rel "$relative" \
        --argjson prov "$5" --argjson excluded "$6" --argjson aliases "$7" \
        '. + [{id:$id,root:$root,exists:$exists,maxAccess:$max,relativeRoot:$rel,aliases:$aliases,excludedPaths:$excluded,provenance:$prov}]' <<< "$_ores_resources")"
}

# _ores_aliases <project-physical> <subpath-or-empty>: alias logicos observados
# cuya resolucion fisica coincide con la raiz; nunca se infieren.
_ores_aliases() {
    local physical="$1" sub="$2" index logical rel result='[]'
    for index in "${!_ores_alias_logical[@]}"; do
        [ "${_ores_alias_physical[$index]}" = "$physical" ] || continue
        logical="${_ores_alias_logical[$index]}"
        [ "$logical" != "$physical" ] || continue
        _ores_unrepresentable "$logical$sub" && continue
        rel="$(_ores_relative "$logical$sub")" || continue
        result="$(jq -c --arg root "$logical$sub" --argjson rel "$rel" 'if any(.[]; .root == $root) then . else . + [{root:$root,relativeRoot:$rel}] end' <<< "$result")"
    done
    printf '%s\n' "$result"
}

# opencode_resources_resolve <release-root> <approved-root> <execution-root> <scripts-dir>
#
# Recibe por stdin el envelope cerrado de entrada. <release-root> y <scripts-dir>
# pertenecen a la release que contiene al wrapper; nunca provienen del modelo.
opencode_resources_resolve() {
    [ "$#" -eq 4 ] || return 2
    local release_root="$1" approved_input="$2" execution_input="$3" scripts_dir="$4"
    local input approved_phys execution_phys inspect_out inspect_rc status reason
    local ctx roots_out roots_rc roots_status code worktree_logical directory_input
    local common_dir exec_common work_common work_phys dir_phys top registered line wt_phys found
    local required_nuget=false
    local -a nuget_assets=()

    input="$(command cat)" || return 2
    jq -e '
      type == "object" and (keys | sort) == ["nugetAssetsFiles","requiredResources","runtimeContext","schemaVersion"] and .schemaVersion == 1 and
      (.runtimeContext | type == "object" and (keys | sort) == ["directory","home","opencodeConfigDir","osHome","platform","worktree","xdgConfigHome","xdgDataHome"] and
        (.platform == "darwin" or .platform == "linux") and (.osHome | type == "string") and (.home | type == "string") and
        (.directory | type == "string") and (.worktree | type == "string") and
        all(.xdgDataHome, .xdgConfigHome, .opencodeConfigDir; . == null or type == "string")) and
      (.requiredResources | type == "array" and all(.[]; . == "release" or . == "project" or . == "state" or . == "runtime-tool-output" or . == "nuget-packages") and
        length == (unique | length) and ((["release","project","state","runtime-tool-output"] - .) | length == 0)) and
      (.nugetAssetsFiles | type == "array" and all(.[]; type == "string") and (length == 0 or (($input_required | index("nuget-packages")) != null)))
    ' --argjson input_required "$(jq -c '.requiredResources // []' <<< "$input" 2>/dev/null || printf '[]')" >/dev/null 2>&1 <<< "$input" || return 2

    _ores_diagnostics='[]'; _ores_project_id='null'; _ores_profile_digest='null'; _ores_release='null'; _ores_project='null'
    _ores_base='null'; _ores_resources='[]'; _ores_protected='[]'; _ores_projection='null'; _ores_nuget='null'
    _ores_alias_logical=(); _ores_alias_physical=()
    jq -e '.requiredResources | index("nuget-packages") != null' >/dev/null <<< "$input" && required_nuget=true
    while IFS= read -r line; do nuget_assets+=("$line"); done < <(jq -r '.nugetAssetsFiles[]' <<< "$input")

    # 1. Guard de consumidor e inspect del consentimiento; no escribe ni repara.
    case "$approved_input" in /*) ;; *) return 2 ;; esac
    case "$execution_input" in /*) ;; *) return 2 ;; esac
    approved_phys="$(_ores_phys "$approved_input" existing)" || { _ores_conflict APPROVED_ROOT_UNRESOLVABLE; return 1; }
    if [ ! -f "$approved_phys/.mefisto/harness.config.json" ] && [ ! -f "$approved_phys/.claude/harness.config.json" ]; then
        _ores_diag NO_PROFILE; _ores_emit disabled; return 0
    fi
    if [ -f "$approved_phys/.claude-plugin/plugin.json" ]; then
        _ores_diag NOT_CONSUMER; _ores_emit disabled; return 0
    fi
    [ -x "$scripts_dir/autonomy-profile.sh" ] || { _ores_conflict INSPECT_UNAVAILABLE; return 1; }
    inspect_out="$(cd "$approved_phys" && "$scripts_dir/autonomy-profile.sh" inspect --project-root "$approved_phys" 2>/dev/null)"; inspect_rc=$?
    if [ "$inspect_rc" -gt 1 ] || ! jq -e 'type == "object" and (.status | type == "string") and (.reasonCode | type == "string")' >/dev/null 2>&1 <<< "$inspect_out"; then
        _ores_conflict INSPECT_FAILED; return 1
    fi
    status="$(jq -r .status <<< "$inspect_out")"; reason="$(jq -r .reasonCode <<< "$inspect_out")"
    _ores_project_id="$(jq -c '.projectId // null' <<< "$inspect_out")"
    _ores_profile_digest="$(jq -c '.profileDigest // null' <<< "$inspect_out")"
    case "$status" in
        disabled) _ores_diag "$reason"; _ores_emit disabled; return 0 ;;
        needs-approval) _ores_diag "$reason"; _ores_emit needs-approval; return 1 ;;
        ready) ;;
        *) _ores_conflict "${reason:-INSPECT_CONFLICT}"; return 1 ;;
    esac

    # 2. Identidad del proyecto: un unico Git common dir fisico.
    ctx="$(jq -c '.runtimeContext' <<< "$input")"
    worktree_logical="$(jq -r .worktree <<< "$ctx")"; directory_input="$(jq -r .directory <<< "$ctx")"
    for line in "$worktree_logical" "$directory_input"; do
        case "$line" in /*) ;; *) _ores_conflict RUNTIME_CONTEXT_INVALID; return 1 ;; esac
        _ores_unrepresentable "$line" && { _ores_conflict RESOURCE_PATH_UNREPRESENTABLE; return 1; }
    done
    _ores_worktree_logical="$(resource_path_normalize_input "$worktree_logical" 2>/dev/null)" || { _ores_conflict RUNTIME_CONTEXT_INVALID; return 1; }
    execution_phys="$(_ores_phys "$execution_input" existing)" || { _ores_conflict EXECUTION_ROOT_UNRESOLVABLE; return 1; }
    work_phys="$(_ores_phys "$_ores_worktree_logical" existing)" || { _ores_conflict RUNTIME_WORKTREE_UNRESOLVABLE; return 1; }
    dir_phys="$(_ores_phys "$directory_input" existing)" || { _ores_conflict RUNTIME_DIRECTORY_UNRESOLVABLE; return 1; }
    for line in "$approved_phys" "$execution_phys"; do
        top="$(_ores_toplevel "$line")" && [ "$top" = "$line" ] || { _ores_conflict PROJECT_ROOT_NOT_WORKTREE_ROOT; return 1; }
    done
    common_dir="$(_ores_common_dir "$approved_phys")" || { _ores_conflict GIT_IDENTITY_UNRESOLVABLE; return 1; }
    exec_common="$(_ores_common_dir "$execution_phys")" || { _ores_conflict GIT_IDENTITY_UNRESOLVABLE; return 1; }
    work_common="$(_ores_common_dir "$work_phys")" || { _ores_conflict GIT_IDENTITY_UNRESOLVABLE; return 1; }
    [ "$common_dir" = "$exec_common" ] && [ "$common_dir" = "$work_common" ] || { _ores_conflict PROJECT_IDENTITY_MISMATCH; return 1; }
    resource_path_contains "$work_phys" "$dir_phys" >/dev/null 2>&1 || { _ores_conflict DIRECTORY_OUTSIDE_WORKTREE; return 1; }
    found=false
    if [ "$execution_phys" = "$approved_phys" ]; then found=true; else
        registered="$(_ores_git -C "$approved_phys" worktree list --porcelain 2>/dev/null)" || { _ores_conflict WORKTREE_LIST_UNAVAILABLE; return 1; }
        while IFS= read -r line; do
            case "$line" in 'worktree '*) wt_phys="$(_ores_phys "${line#worktree }" existing)" || continue; [ "$wt_phys" != "$execution_phys" ] || found=true ;; esac
        done <<< "$registered"
    fi
    [ "$found" = true ] || { _ores_conflict EXECUTION_ROOT_NOT_REGISTERED; return 1; }

    # 3. Roots del host y release (#1843): la release cargada es la del wrapper.
    roots_out="$(jq -c '{schemaVersion:1} + del(.directory, .worktree)' <<< "$ctx" | opencode_resource_roots "$release_root" 2>/dev/null)"; roots_rc=$?
    jq -e 'type == "object" and .schemaVersion == 1 and (.status | type == "string")' >/dev/null 2>&1 <<< "$roots_out" || { _ores_conflict ROOTS_UNAVAILABLE; return 1; }
    _ores_projection="$(jq -c '.projection' <<< "$roots_out")"
    _ores_release="$(jq -c '.release' <<< "$roots_out")"
    roots_status="$(jq -r .status <<< "$roots_out")"
    while IFS= read -r code; do [ -z "$code" ] || _ores_diag "$code"; done < <(jq -r '.diagnostics[].code' <<< "$roots_out")
    if [ "$roots_status" != resolved ] || [ "$roots_rc" -ne 0 ]; then _ores_resources='[]'; _ores_emit conflict; return 1; fi
    case "$(jq -r .status <<< "$_ores_projection")" in
        aligned) ;;
        absent) _ores_conflict PROJECTION_ABSENT; return 1 ;;
        drift) _ores_conflict PROJECTION_DRIFT; return 1 ;;
        *) _ores_conflict PROJECTION_CONFLICT; return 1 ;;
    esac

    local mefisto_root config_root runtime_root tool_root release_phys os_home
    mefisto_root="$(jq -r .paths.mefistoDataRoot.physicalRoot <<< "$roots_out")"
    config_root="$(jq -r .paths.configRoot.physicalRoot <<< "$roots_out")"
    runtime_root="$(jq -r .paths.runtimeDataRoot.physicalRoot <<< "$roots_out")"
    tool_root="$(jq -r .paths.toolOutputRoot.physicalRoot <<< "$roots_out")"
    release_phys="$(jq -r .root <<< "$_ores_release")"
    os_home="$(jq -r .runtimeContext.osHome <<< "$input")"

    _ores_base="$(jq -cn --arg logical "$_ores_worktree_logical" --arg physical "$work_phys" --arg directory "$dir_phys" '{worktree:{logical:$logical,physical:$physical},directory:$directory}')"
    _ores_project="$(jq -cn --arg approved "$approved_phys" --arg execution "$execution_phys" --arg common "$common_dir" '{approvedRoot:$approved,executionRoot:$execution,gitCommonDir:$common}')"

    # Raices protegidas: se rechaza cualquier recurso que las contenga o invada.
    local protected_rows='[]' entry sub_id sub_path home_phys resolved
    home_phys="$(_ores_phys "$os_home" existing)" || { _ores_conflict OS_HOME_UNRESOLVABLE; return 1; }
    for entry in "config:$config_root" "runtime-data:$runtime_root" "runtime-use:$mefisto_root/runtime-use" \
                 "ssh:$home_phys/.ssh" "aws:$home_phys/.aws" "nuget-config:$home_phys/.nuget/NuGet" "xdg-nuget-config:$home_phys/.config/NuGet"; do
        sub_id="${entry%%:*}"; sub_path="${entry#*:}"
        resolved="$(_ores_phys "$sub_path" planned)" || { _ores_conflict PROTECTED_ROOT_UNRESOLVABLE; return 1; }
        protected_rows="$(jq -c --arg id "$sub_id" --arg root "$resolved" '. + [{id:$id,root:$root,exceptions:[]}]' <<< "$protected_rows")"
    done
    protected_rows="$(jq -c --arg tool "$tool_root" 'map(if .id == "runtime-data" then .exceptions = [$tool] else . end)' <<< "$protected_rows")"

    # 4. Recursos base. maxAccess es un limite de clase, no un grant.
    local roots_seen='[]' target row_root row_exists max_access resolved_row excluded aliases prov index
    local candidates_input
    for candidates_input in "$approved_input" "$execution_input" "$_ores_worktree_logical"; do
        case "$candidates_input" in *[[:cntrl:]]*) continue ;; esac
        line="$(resource_path_normalize_input "$candidates_input" 2>/dev/null)" || continue
        wt_phys="$(_ores_phys "$line" existing)" || continue
        found=false
        for index in "${!_ores_alias_logical[@]}"; do [ "${_ores_alias_logical[$index]}" = "$line" ] && found=true; done
        [ "$found" = true ] || { _ores_alias_logical+=("$line"); _ores_alias_physical+=("$wt_phys"); }
    done

    prov="$(jq -cn --arg version "$(jq -r .version <<< "$_ores_release")" --arg commit "$(jq -r .commit <<< "$_ores_release")" '{source:"loaded-release",version:$version,commit:$commit}')"
    _ores_add_resource release "$release_phys" true read "$prov" '[]' '[]' || { _ores_conflict RESOURCE_PATH_INVALID; return 1; }

    local project_rows=("$execution_phys:project" )
    [ "$approved_phys" = "$execution_phys" ] || project_rows+=("$approved_phys:read")
    for row in "${project_rows[@]}"; do
        row_root="${row%:*}"; max_access="${row##*:}"; [ "$max_access" = project ] || max_access=read
        excluded="$(jq -cn --arg r "$row_root" '[$r+"/.mefisto/pipeline/autonomy",$r+"/.mefisto/harness.config.json",$r+"/.claude/harness.config.json",$r+"/.mefisto/pipeline/batch-stop"]')"
        aliases="$(_ores_aliases "$row_root" '')"
        prov="$(jq -cn --arg role "$([ "$row_root" = "$execution_phys" ] && printf execution || printf approved)" '{source:"project-identity",role:$role}')"
        _ores_add_resource project "$row_root" true "$max_access" "$prov" "$excluded" "$aliases" || { _ores_conflict RESOURCE_PATH_INVALID; return 1; }
    done

    local state_dirs=() state_phys state_parent state_legacy legacy_phys
    for row in "$execution_phys" "$approved_phys"; do
        state_phys="$(_ores_phys "$row/.mefisto/pipeline" planned)" || { _ores_conflict STATE_ROOT_UNRESOLVABLE; return 1; }
        resource_path_contains "$row" "$state_phys" >/dev/null 2>&1 || { _ores_conflict STATE_ROOT_ESCAPES_PROJECT; return 1; }
        found=false
        for entry in ${state_dirs[@]+"${state_dirs[@]}"}; do [ "${entry%%$'\x1f'*}" = "$state_phys" ] && found=true; done
        [ "$found" = true ] || state_dirs+=("$state_phys"$'\x1f'"$row")
    done
    for entry in ${state_dirs[@]+"${state_dirs[@]}"}; do
        state_phys="${entry%%$'\x1f'*}"; state_parent="${entry#*$'\x1f'}"
        row_exists=false; [ -d "$state_phys" ] && row_exists=true
        excluded="$(jq -cn --arg r "$state_phys" '[$r+"/autonomy",$r+"/batch-stop"]')"
        aliases="$(_ores_aliases "$state_parent" '/.mefisto/pipeline')"
        prov="$(jq -cn --arg state "$([ "$row_exists" = true ] && printf canonical || printf planned)" '{source:"project-state",state:$state}')"
        _ores_add_resource state "$state_phys" "$row_exists" state "$prov" "$excluded" "$aliases" || { _ores_conflict RESOURCE_PATH_INVALID; return 1; }
        # El fallback legacy es solo lectura y solo si el canonico aun no existe.
        if [ "$row_exists" = false ] && [ -d "$state_parent/.claude/pipeline" ]; then
            legacy_phys="$(_ores_phys "$state_parent/.claude/pipeline" existing)" || continue
            resource_path_contains "$state_parent" "$legacy_phys" >/dev/null 2>&1 || { _ores_conflict STATE_ROOT_ESCAPES_PROJECT; return 1; }
            prov='{"source":"project-state","state":"legacy-fallback"}'
            _ores_add_resource state "$legacy_phys" true read "$prov" '[]' "$(_ores_aliases "$state_parent" '/.claude/pipeline')" || { _ores_conflict RESOURCE_PATH_INVALID; return 1; }
        fi
    done

    row_exists=false; [ -d "$tool_root" ] && row_exists=true
    prov='{"source":"runtime-data","class":"tool-output","scope":"all-sessions"}'
    _ores_add_resource runtime-tool-output "$tool_root" "$row_exists" read "$prov" '[]' '[]' || { _ores_conflict RESOURCE_PATH_INVALID; return 1; }

    # 5. NuGet solo cuando el caller lo declara; se consume tal cual (#1844).
    if [ "$required_nuget" = true ]; then
        local nuget_args=() nuget_out nuget_rc nuget_status nuget_coverage nuget_roots nuget_count
        nuget_args=(--worktree-root "$execution_phys")
        for line in ${nuget_assets[@]+"${nuget_assets[@]}"}; do nuget_args+=(--assets-file "$line"); done
        [ -x "$scripts_dir/resolve-nuget-resources.sh" ] || { _ores_conflict NUGET_UNAVAILABLE; return 1; }
        nuget_out="$("$scripts_dir/resolve-nuget-resources.sh" "${nuget_args[@]}" 2>/dev/null)"; nuget_rc=$?
        jq -e '
          type == "object" and .schemaVersion == 1 and (.status | type == "string") and (.coverage == "global-only" or .coverage == "observed-assets") and
          (.assets | type == "array" and all(.[]; (.path | type == "string") and (.sha256 | type == "string"))) and
          (.roots | type == "array" and all(.[]; (.physicalRoot | type == "string") and (.exists | type == "boolean") and (.sources | type == "array")))
        ' >/dev/null 2>&1 <<< "$nuget_out" || { _ores_conflict NUGET_OUTPUT_INVALID; return 1; }
        nuget_status="$(jq -r .status <<< "$nuget_out")"
        if [ "$nuget_status" != resolved ] || [ "$nuget_rc" -ne 0 ]; then
            if [ "$nuget_status" = unavailable ]; then _ores_conflict NUGET_UNAVAILABLE; else _ores_conflict NUGET_CONFLICT; fi
            return 1
        fi
        nuget_coverage="$(jq -r .coverage <<< "$nuget_out")"
        nuget_roots="$(jq -c '.roots' <<< "$nuget_out")"
        nuget_count="$(jq 'length' <<< "$nuget_roots")"
        index=0
        while [ "$index" -lt "$nuget_count" ]; do
            row_root="$(jq -r ".[$index].physicalRoot" <<< "$nuget_roots")"
            row_exists="$(jq -c ".[$index].exists" <<< "$nuget_roots")"
            prov="$(jq -c ".[$index] | {source:\"nuget\",coverage:\"$nuget_coverage\",sources:.sources}" <<< "$nuget_roots")"
            _ores_unrepresentable "$row_root" && { _ores_conflict RESOURCE_PATH_UNREPRESENTABLE; return 1; }
            _ores_add_resource nuget-packages "$row_root" "$row_exists" read "$prov" '[]' '[]' || { _ores_conflict RESOURCE_PATH_INVALID; return 1; }
            index=$((index + 1))
        done
        _ores_nuget="$(jq -c '{status:.status,coverage:.coverage,worktreeRoot:.worktreeRoot,assets:[.assets[] | {path:.path,sha256:.sha256}]}' <<< "$nuget_out")"
    fi

    # 6. Validaciones comunes a todos los recursos: representables, sin raiz
    # amplia y sin solaparse con las raices protegidas ni cubrir el proyecto.
    local resource_count resource_id resource_root protected_root protected_exceptions exception_ok p_index p_count alias_root
    resource_count="$(jq 'length' <<< "$_ores_resources")"
    p_count="$(jq 'length' <<< "$protected_rows")"
    index=0
    while [ "$index" -lt "$resource_count" ]; do
        resource_id="$(jq -r ".[$index].id" <<< "$_ores_resources")"; resource_root="$(jq -r ".[$index].root" <<< "$_ores_resources")"
        while IFS= read -r alias_root; do
            _ores_unrepresentable "$alias_root" && { _ores_conflict RESOURCE_PATH_UNREPRESENTABLE; return 1; }
        done < <(jq -r ".[$index].aliases[].root" <<< "$_ores_resources"; printf '%s\n' "$resource_root")
        { [ "$resource_root" = / ] || [ "$resource_root" = "$home_phys" ]; } && { _ores_conflict RESOURCE_ROOT_TOO_BROAD; return 1; }
        case "$resource_id" in
            release|runtime-tool-output|nuget-packages)
                for target in "$approved_phys" "$execution_phys"; do
                    resource_path_contains "$resource_root" "$target" >/dev/null 2>&1 && { _ores_conflict RESOURCE_ROOT_TOO_BROAD; return 1; }
                done ;;
        esac
        p_index=0
        while [ "$p_index" -lt "$p_count" ]; do
            protected_root="$(jq -r ".[$p_index].root" <<< "$protected_rows")"
            exception_ok=false
            if jq -e --argjson i "$p_index" --arg root "$resource_root" '.[$i].exceptions | index($root) != null' >/dev/null <<< "$protected_rows"; then
                [ "$resource_id" = runtime-tool-output ] && exception_ok=true
            fi
            if [ "$exception_ok" = false ] && [ "$resource_id" = runtime-tool-output ] && [ "$(jq -r ".[$p_index].id" <<< "$protected_rows")" = runtime-data ]; then
                resource_path_contains "$protected_root" "$resource_root" >/dev/null 2>&1 && exception_ok=true
            fi
            if [ "$exception_ok" = false ] && _ores_overlap "$resource_root" "$protected_root"; then
                _ores_conflict PROTECTED_ROOT_OVERLAP; return 1
            fi
            p_index=$((p_index + 1))
        done
        index=$((index + 1))
    done
    # El estado propio del harness (contextos y recibos) tampoco es escritorio del modelo.
    for row in "$execution_phys" "$approved_phys"; do
        protected_rows="$(jq -c --arg root "$row/.mefisto/pipeline/autonomy" '. + [{id:"autonomy-context",root:$root,exceptions:[]}]' <<< "$protected_rows")"
    done
    _ores_protected="$(jq -c 'unique_by(.id, .root)' <<< "$protected_rows")"

    # 7. Digest del snapshot de datos: excluye existencia, listado y timestamps.
    local digest data
    data="$(jq -cnS --argjson projectId "$_ores_project_id" --argjson profileDigest "$_ores_profile_digest" --argjson release "$_ores_release" \
        --argjson base "$_ores_base" --argjson project "$_ores_project" --argjson resources "$_ores_resources" --argjson protected "$_ores_protected" \
        --argjson projection "$_ores_projection" --argjson nuget "$_ores_nuget" '
        {schemaVersion:1,projectId:$projectId,profileDigest:$profileDigest,release:$release,permissionBase:$base.worktree,project:$project,
         resources:($resources | map(del(.exists)) | sort_by(.id, .root)),protectedRoots:($protected | sort_by(.id, .root)),
         projection:{status:$projection.status,ledgerDigest:$projection.ledgerDigest},
         nuget:(if $nuget == null then null else {coverage:$nuget.coverage,assets:($nuget.assets | sort_by(.path))} end)}')" || { _ores_conflict DIGEST_UNAVAILABLE; return 1; }
    digest="$(printf '%s' "$data" | _ores_hash)"
    _ores_emit ready "\"$digest\""
}
