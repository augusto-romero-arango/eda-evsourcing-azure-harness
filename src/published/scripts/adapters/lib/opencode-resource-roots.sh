#!/usr/bin/env bash
# Descubrimiento puntual de roots OpenCode. Cargar esta biblioteca no escribe,
# no toma locks y no concede acceso a los recursos que describe.

_opencode_roots_add_diag() {
    _opencode_roots_diag="$(jq -c --arg code "$1" '. + [{code:$code}]' <<< "$_opencode_roots_diag")"
}

_opencode_roots_record() {
    local path="$1" mode="$2" result
    result="$(resource_path_resolve "$path" "$mode" 2>/dev/null)" || return 1
    printf '%s\n' "$result"
}

_opencode_roots_semver() {
    printf '%s\n' "$1" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
}

_opencode_roots_safe_relative() {
    local value="$1" rest part
    case "$value" in ''|/*|*/|*//*|*$'\n'*|*$'\r'*) return 1 ;; esac
    rest="$value"
    while :; do
        case "$rest" in */*) part="${rest%%/*}"; rest="${rest#*/}" ;; *) part="$rest"; rest='' ;; esac
        case "$part" in ''|.|..) return 1 ;; esac
        [ -n "$rest" ] || break
    done
    case "$value" in commands/*|agents/*|skills/*|plugins/*) return 0 ;; *) return 1 ;; esac
}

_opencode_roots_digest() {
    shasum -a 256 "$1" 2>/dev/null | cut -d ' ' -f 1
}

# resource-paths resuelve directorios deliberadamente. Los enlaces del ledger
# nombran archivos, por lo que se observa su metadata y su directorio padre.
_opencode_roots_link_target_physical() {
    local link="$1" value candidate parent name parent_record
    [ -L "$link" ] || return 1
    value="$(readlink "$link")" || return 1
    case "$value" in /*) candidate="$value" ;; *) candidate="${link%/*}/$value" ;; esac
    parent="${candidate%/*}"; name="${candidate##*/}"
    [ -n "$parent" ] && [ -n "$name" ] || return 1
    parent_record="$(_opencode_roots_record "$parent" existing)" || return 1
    printf '%s/%s\n' "$(jq -r .physicalRoot <<< "$parent_record")" "$name"
}

_opencode_roots_emit() {
    local status="$1" release="$2" paths="$3" projection="$4"
    jq -cn --arg status "$status" --argjson release "$release" --argjson paths "$paths" \
        --argjson projection "$projection" --argjson diagnostics "$_opencode_roots_diag" \
        '{schemaVersion:1,status:$status,release:$release,paths:$paths,projection:$projection,diagnostics:$diagnostics}'
}

# opencode_resource_roots <loaded-release-root>
#
# Recibe un envelope cerrado por stdin. El root cargado pertenece al caller: no
# se deriva de active, que se observa solamente para detectar deriva.
opencode_resource_roots() {
    [ "$#" -eq 1 ] || return 2
    local loaded_input="$1" input platform os_home xdg_data xdg_config config_override
    local mefisto_logical config_logical runtime_logical tool_logical
    local mefisto_record config_record runtime_record tool_record loaded_record
    local paths release='null' projection status='resolved' version='' commit='' loaded_physical=''
    local expected_record expected_physical manifest active_record state rel target target_record expected_target

    input="$(command cat)" || return 2
    jq -e '
      type == "object" and (keys | sort) == ["home","opencodeConfigDir","osHome","platform","schemaVersion","xdgConfigHome","xdgDataHome"] and
      .schemaVersion == 1 and (.platform == "darwin" or .platform == "linux") and
      (.osHome | type == "string") and (.home | type == "string") and
      (.xdgDataHome == null or (.xdgDataHome | type == "string")) and
      (.xdgConfigHome == null or (.xdgConfigHome | type == "string")) and
      (.opencodeConfigDir == null or (.opencodeConfigDir | type == "string"))
    ' >/dev/null <<< "$input" || return 2

    platform="$(jq -r .platform <<< "$input")"; os_home="$(jq -r .osHome <<< "$input")"
    xdg_data="$(jq -r '.xdgDataHome // empty' <<< "$input")"; xdg_config="$(jq -r '.xdgConfigHome // empty' <<< "$input")"
    config_override="$(jq -r 'if .opencodeConfigDir == null then "__ABSENT__" else .opencodeConfigDir end' <<< "$input")"
    _opencode_roots_diag='[]'

    case "$os_home" in /*) ;; *) _opencode_roots_add_diag INVALID_OS_HOME; status='conflict' ;; esac
    case "$loaded_input" in /*) ;; *) _opencode_roots_add_diag INVALID_LOADED_RELEASE_ROOT; status='conflict' ;; esac
    if [ -n "$xdg_data" ]; then
        case "$xdg_data" in /*) mefisto_logical="$xdg_data/mefisto"; runtime_logical="$xdg_data/opencode" ;; *) _opencode_roots_add_diag INVALID_XDG_DATA_HOME; status='conflict' ;; esac
    elif [ "$platform" = darwin ]; then
        mefisto_logical="$os_home/Library/Application Support/mefisto"; runtime_logical="$os_home/.local/share/opencode"
    else
        mefisto_logical="$os_home/.local/share/mefisto"; runtime_logical="$os_home/.local/share/opencode"
    fi
    if [ "$config_override" != __ABSENT__ ]; then
        if [ -z "$config_override" ]; then _opencode_roots_add_diag EMPTY_OPENCODE_CONFIG_DIR; status='conflict'
        elif [ "${config_override#/}" = "$config_override" ]; then _opencode_roots_add_diag RELATIVE_OPENCODE_CONFIG_DIR; status='conflict'
        else config_logical="$config_override"; fi
    elif [ -n "$xdg_config" ]; then
        case "$xdg_config" in /*) config_logical="$xdg_config/opencode" ;; *) _opencode_roots_add_diag INVALID_XDG_CONFIG_HOME; status='conflict' ;; esac
    else
        config_logical="$os_home/.config/opencode"
    fi

    [ -z "$mefisto_logical" ] || mefisto_record="$(_opencode_roots_record "$mefisto_logical" planned)" || { _opencode_roots_add_diag MEFISTO_DATA_ROOT_UNRESOLVABLE; status='conflict'; }
    [ -z "$config_logical" ] || config_record="$(_opencode_roots_record "$config_logical" planned)" || { _opencode_roots_add_diag CONFIG_ROOT_UNRESOLVABLE; status='conflict'; }
    [ -z "$runtime_logical" ] || runtime_record="$(_opencode_roots_record "$runtime_logical" planned)" || { _opencode_roots_add_diag RUNTIME_DATA_ROOT_UNRESOLVABLE; status='conflict'; }
    [ -z "$runtime_logical" ] || tool_logical="$runtime_logical/tool-output"
    [ -z "$tool_logical" ] || tool_record="$(_opencode_roots_record "$tool_logical" planned)" || { _opencode_roots_add_diag TOOL_OUTPUT_ROOT_UNRESOLVABLE; status='conflict'; }
    paths="$(jq -cn --argjson mefistoDataRoot "${mefisto_record:-null}" --argjson configRoot "${config_record:-null}" --argjson runtimeDataRoot "${runtime_record:-null}" --argjson toolOutputRoot "${tool_record:-null}" '{mefistoDataRoot:$mefistoDataRoot,configRoot:$configRoot,runtimeDataRoot:$runtimeDataRoot,toolOutputRoot:$toolOutputRoot}')"

    if [ "$status" = resolved ]; then
        loaded_record="$(_opencode_roots_record "$loaded_input" existing)" || { _opencode_roots_add_diag LOADED_RELEASE_UNRESOLVABLE; status='conflict'; }
        if [ "$status" = resolved ]; then
            loaded_physical="$(jq -r .physicalRoot <<< "$loaded_record")"; manifest="$loaded_physical/mefisto-manifest.json"
            if [ ! -f "$manifest" ] || [ -L "$manifest" ] || ! jq -e '
                (keys | sort) == ["commit","minimumRuntimeVersion","runtime","schemaVersion","version"] and .schemaVersion == 1 and .runtime == "opencode" and
                (.version | type == "string") and (.commit | type == "string" and test("^[0-9a-f]{40}$")) and (.minimumRuntimeVersion | type == "string")
              ' "$manifest" >/dev/null 2>&1; then
                _opencode_roots_add_diag INVALID_LOADED_RELEASE_MANIFEST; status='conflict'
            else
                version="$(jq -r .version "$manifest")"; commit="$(jq -r .commit "$manifest")"
                _opencode_roots_semver "$version" || { _opencode_roots_add_diag INVALID_LOADED_RELEASE_VERSION; status='conflict'; }
                release="$(jq -cn --arg root "$loaded_physical" --arg version "$version" --arg commit "$commit" '{root:$root,version:$version,commit:$commit}')"
            fi
        fi
        if [ "$status" = resolved ]; then
            expected_record="$(_opencode_roots_record "$mefisto_logical/releases/$version" existing)" || { _opencode_roots_add_diag LOADED_RELEASE_NOT_IN_STORE; status='conflict'; }
            expected_physical="$(jq -r .physicalRoot <<< "${expected_record:-null}")"
            [ "$loaded_physical" = "$expected_physical" ] || { _opencode_roots_add_diag LOADED_RELEASE_NOT_IN_STORE; status='conflict'; }
        fi
    fi

    projection='{"status":"absent","ledgerDigest":null}'
    if [ "$status" = resolved ]; then
        active_record="$mefisto_logical/active"
        if [ -L "$active_record" ]; then
            target_record="$(_opencode_roots_record "$active_record" existing 2>/dev/null || true)"
            [ -n "$target_record" ] && [ "$(jq -r .physicalRoot <<< "$target_record")" = "$loaded_physical" ] || _opencode_roots_add_diag ACTIVE_RELEASE_DRIFT
        fi
        state="$config_logical/.mefisto-projection.json"
        if [ -e "$state" ] || [ -L "$state" ]; then
            if [ ! -f "$state" ] || [ -L "$state" ] || ! jq -e '
                (keys | sort) == ["directories","paths","release","schemaVersion"] and .schemaVersion == 1 and
                (.release | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$")) and
                (.paths | type == "array" and all(.[]; type == "string") and length == (unique | length)) and
                (.directories | type == "array" and all(.[]; type == "string") and length == (unique | length))
              ' "$state" >/dev/null 2>&1; then
                _opencode_roots_add_diag INVALID_PROJECTION_LEDGER; projection='{"status":"conflict","ledgerDigest":null}'
            else
                projection="$(jq -cn --arg digest "$(_opencode_roots_digest "$state")" '{status:"aligned",ledgerDigest:$digest}')"
                if [ "$(jq -r .release "$state")" != "$version" ]; then
                    _opencode_roots_add_diag PROJECTION_RELEASE_DRIFT; projection="$(jq -cn --arg digest "$(_opencode_roots_digest "$state")" '{status:"drift",ledgerDigest:$digest}')"
                else
                    while IFS= read -r rel; do
                        [ "$rel" = . ] || _opencode_roots_safe_relative "$rel/x" || { _opencode_roots_add_diag INVALID_PROJECTION_DIRECTORY; projection="$(jq -cn --arg digest "$(_opencode_roots_digest "$state")" '{status:"conflict",ledgerDigest:$digest}')"; break; }
                    done < <(jq -r '.directories[]' "$state")
                    while IFS= read -r rel; do
                        [ "$(jq -r .status <<< "$projection")" = conflict ] && break
                        _opencode_roots_safe_relative "$rel" || { _opencode_roots_add_diag INVALID_PROJECTION_PATH; projection="$(jq -cn --arg digest "$(_opencode_roots_digest "$state")" '{status:"conflict",ledgerDigest:$digest}')"; break; }
                        target="$config_logical/$rel"; expected_target="$loaded_physical/$rel"
                        [ -L "$target" ] || { _opencode_roots_add_diag PROJECTION_LINK_MISSING; projection="$(jq -cn --arg digest "$(_opencode_roots_digest "$state")" '{status:"conflict",ledgerDigest:$digest}')"; break; }
                        target_record="$(_opencode_roots_link_target_physical "$target")" || { _opencode_roots_add_diag PROJECTION_LINK_UNRESOLVABLE; projection="$(jq -cn --arg digest "$(_opencode_roots_digest "$state")" '{status:"conflict",ledgerDigest:$digest}')"; break; }
                        expected_record="$(_opencode_roots_record "${expected_target%/*}" existing)" || { _opencode_roots_add_diag LOADED_RELEASE_INCOMPLETE; projection="$(jq -cn --arg digest "$(_opencode_roots_digest "$state")" '{status:"conflict",ledgerDigest:$digest}')"; break; }
                        [ "$target_record" = "$(jq -r .physicalRoot <<< "$expected_record")/${expected_target##*/}" ] || { _opencode_roots_add_diag PROJECTION_LINK_TARGET_DRIFT; projection="$(jq -cn --arg digest "$(_opencode_roots_digest "$state")" '{status:"conflict",ledgerDigest:$digest}')"; break; }
                    done < <(jq -r '.paths[]' "$state")
                fi
            fi
        fi
    fi
    [ "$(jq -r .status <<< "$projection")" != conflict ] || status='conflict'
    _opencode_roots_emit "$status" "$release" "$paths" "$projection"
    [ "$status" = resolved ] || return 1
}
