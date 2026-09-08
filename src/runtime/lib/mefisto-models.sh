#!/usr/bin/env bash
# Resolucion comun de modelos. El caller entrega tanto el override como el
# mapping: este nucleo no conoce estado, cwd, Git ni stages (MEF-ADR-0019).

_mefisto_models_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MEFISTO_RUNTIME_LIB_DIR:=$_mefisto_models_lib_dir}"
: "${MEFISTO_MODELS_VALIDATOR:=$_mefisto_models_lib_dir/../contract/models.validate.jq}"
export MEFISTO_RUNTIME_LIB_DIR
unset _mefisto_models_lib_dir

MEFISTO_MODELS_ERROR=""
MEFISTO_RESOLVED_MODEL=""

_mefisto_models_validate_mapping() {
    local file="$1" errors
    [ -n "$file" ] || return 0
    [ -f "$file" ] || return 0

    if [ ! -s "$file" ]; then
        return 0
    fi
    if [ ! -f "$MEFISTO_MODELS_VALIDATOR" ]; then
        MEFISTO_MODELS_ERROR="$MEFISTO_MODELS_VALIDATOR: no existe el validador del mapping de modelos"
        return 1
    fi
    if ! errors="$(jq -r -f "$MEFISTO_MODELS_VALIDATOR" "$file" 2>/dev/null)"; then
        MEFISTO_MODELS_ERROR="$file: no es JSON valido"
        return 1
    fi
    if [ -n "$errors" ]; then
        MEFISTO_MODELS_ERROR="$file: $errors"
        return 1
    fi
}

_mefisto_models_lookup() {
    local file="$1" runtime="$2" agent_id="$3" profile="$4" model
    [ -n "$file" ] && [ -s "$file" ] && [ -f "$file" ] || return 0
    model="$(jq -r --arg runtime "$runtime" --arg agent "$agent_id" \
        '.[$runtime].agents[$agent] // empty' "$file" 2>/dev/null)"
    if [ -z "$model" ]; then
        model="$(jq -r --arg runtime "$runtime" --arg profile "$profile" \
            '.[$runtime].profiles[$profile] // empty' "$file" 2>/dev/null)"
    fi
    printf '%s' "$model"
}

# mefisto_resolve_model <runtime> <agent-id> <profile> [explicit-model] [mapping-file]
#
# Fija MEFISTO_RESOLVED_MODEL y conserva MEFISTO_MODELS_ERROR en el shell
# caller. Tambien imprime el resultado para conservar compatibilidad con
# callers que ya lo redirigian a un archivo.
mefisto_resolve_model() {
    local runtime="${1:-}" agent_id="${2:-}" profile="${3:-}"
    local explicit_model="${4:-}" mapping_file="${5:-}" adapter fn model=""
    MEFISTO_MODELS_ERROR=""
    MEFISTO_RESOLVED_MODEL=""

    case "$profile" in
        fast|balanced|deep) ;;
        *) MEFISTO_MODELS_ERROR="profile: '$profile' no esta en el vocabulario fast|balanced|deep"; return 1 ;;
    esac
    case "$runtime" in
        ''|*[!a-z0-9_]*) MEFISTO_MODELS_ERROR="runtime invalido: '$runtime'"; return 1 ;;
    esac

    adapter="$MEFISTO_RUNTIME_LIB_DIR/runtime-$runtime.sh"
    if [ ! -f "$adapter" ]; then
        MEFISTO_MODELS_ERROR="runtime '$runtime' no tiene adaptador ($adapter)"
        return 1
    fi
    if ! source "$adapter"; then
        MEFISTO_MODELS_ERROR="runtime '$runtime': no se pudo cargar el adaptador ($adapter)"
        return 1
    fi

    if [ -n "$explicit_model" ]; then
        model="$explicit_model"
    else
        _mefisto_models_validate_mapping "$mapping_file" || return 1
        model="$(_mefisto_models_lookup "$mapping_file" "$runtime" "$agent_id" "$profile")"
        if [ -z "$model" ]; then
            fn="runtime_${runtime}_default_model"
            if declare -F "$fn" >/dev/null 2>&1; then
                model="$($fn "$profile")" || {
                    MEFISTO_MODELS_ERROR="$fn: no acepta el perfil '$profile'"
                    return 1
                }
            fi
        fi
    fi

    MEFISTO_RESOLVED_MODEL="$model"
    printf '%s\n' "$MEFISTO_RESOLVED_MODEL"
}
