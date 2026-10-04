#!/usr/bin/env bash
# Consultas puntuales de rutas para los pipelines publicados. Esta biblioteca no
# autoriza recursos ni sustituye una defensa contra cambios concurrentes.

resource_path_error() {
    printf '%s\n' "resource-paths: $1" >&2
}

# Normaliza solo separadores repetidos y la barra final. Los componentes . y ..
# se rechazan antes: no hay interpretacion lexica de rutas ambiguas.
resource_path_normalize_input() {
    local input="$1" normalized='' component rest
    case "$input" in /*) ;; *) return 1 ;; esac
    case "$input" in *[[:cntrl:]]*) return 1 ;; esac

    rest="${input#/}"
    while :; do
        case "$rest" in
            */*) component="${rest%%/*}"; rest="${rest#*/}" ;;
            *) component="$rest"; rest='';;
        esac
        case "$component" in
            '' ) ;;
            .|..) return 1 ;;
            *) normalized="${normalized:+$normalized/}$component" ;;
        esac
        [ -n "$rest" ] || break
    done
    if [ -n "$normalized" ]; then printf '/%s\n' "$normalized"; else printf '/\n'; fi
}

resource_path_validate_arguments() {
    [ "$2" -eq "$1" ] || { resource_path_error INVALID_ARGUMENTS; return 2; }
}

# resource_path_resolve <absolute-path> <existing|planned>
#
# Sigue exclusivamente directorios ya existentes. Al encontrar el primer
# componente ausente en modo planned conserva el sufijo sin crearlo; un enlace
# roto, ciclo, archivo o acceso denegado ocurre antes como error de filesystem.
resource_path_resolve() {
    resource_path_validate_arguments 2 "$#" || return $?
    local logical mode rest component physical candidate next exists=true
    logical="$(resource_path_normalize_input "$1")" || { resource_path_error INVALID_PATH; return 2; }
    mode="$2"
    case "$mode" in existing|planned) ;; *) resource_path_error INVALID_MODE; return 2 ;; esac

    physical='/'
    rest="${logical#/}"
    while [ -n "$rest" ]; do
        case "$rest" in
            */*) component="${rest%%/*}"; rest="${rest#*/}" ;;
            *) component="$rest"; rest='';;
        esac
        candidate="${physical%/}/$component"
        if [ -e "$candidate" ] || [ -L "$candidate" ]; then
            next="$(cd -P "$candidate" 2>/dev/null && pwd -P)" || { resource_path_error FILESYSTEM_UNRESOLVABLE; return 1; }
            physical="$next"
        elif [ "$mode" = planned ]; then
            physical="$candidate"
            [ -z "$rest" ] || physical="$physical/$rest"
            exists=false
            rest=''
        else
            resource_path_error FILESYSTEM_UNRESOLVABLE
            return 1
        fi
    done
    jq -cn --arg logicalRoot "$logical" --arg physicalRoot "$physical" --argjson exists "$exists" \
        '{logicalRoot:$logicalRoot,physicalRoot:$physicalRoot,exists:$exists}'
}

# resource_path_relative <absolute-base> <absolute-target>
resource_path_relative() {
    resource_path_validate_arguments 2 "$#" || return $?
    local base target base_rest target_rest base_component target_component common=0 result='' index
    local -a base_parts target_parts
    base="$(resource_path_normalize_input "$1")" || { resource_path_error INVALID_PATH; return 2; }
    target="$(resource_path_normalize_input "$2")" || { resource_path_error INVALID_PATH; return 2; }
    base_rest="${base#/}"; target_rest="${target#/}"
    if [ -n "$base_rest" ]; then IFS=/ read -r -a base_parts <<< "$base_rest"; else base_parts=(); fi
    if [ -n "$target_rest" ]; then IFS=/ read -r -a target_parts <<< "$target_rest"; else target_parts=(); fi
    while [ "$common" -lt "${#base_parts[@]}" ] && [ "$common" -lt "${#target_parts[@]}" ] && [ "${base_parts[$common]}" = "${target_parts[$common]}" ]; do
        common=$((common + 1))
    done
    index="$common"
    while [ "$index" -lt "${#base_parts[@]}" ]; do
        result="${result:+$result/}.."
        index=$((index + 1))
    done
    index="$common"
    while [ "$index" -lt "${#target_parts[@]}" ]; do
        result="${result:+$result/}${target_parts[$index]}"
        index=$((index + 1))
    done
    jq -Rn --arg relative "$result" '$relative'
}

# resource_path_contains <absolute-parent> <absolute-child>
resource_path_contains() {
    resource_path_validate_arguments 2 "$#" || return $?
    local parent child
    parent="$(resource_path_normalize_input "$1")" || { resource_path_error INVALID_PATH; return 2; }
    child="$(resource_path_normalize_input "$2")" || { resource_path_error INVALID_PATH; return 2; }
    [ "$parent" = / ] && return 0
    [ "$child" = "$parent" ] || case "$child" in "$parent"/*) return 0 ;; *) return 1 ;; esac
}
