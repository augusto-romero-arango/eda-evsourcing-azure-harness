#!/usr/bin/env bash
# Discovery abierto de adaptadores de runtime (MEF-ADR-0050, issue #1045).
# Bash 3.2: no usa arrays asociativos ni enumera runtimes concretos.

_mefisto_runtime_computed_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MEFISTO_RUNTIME_LIB_DIR:=$_mefisto_runtime_computed_lib_dir}"
export MEFISTO_RUNTIME_LIB_DIR
unset _mefisto_runtime_computed_lib_dir
MEFISTO_RUNTIME_ERROR=""
MEFISTO_RESOLVED_RUNTIME=""
MEFISTO_RUNTIME_SERVICE_RUNTIME=""
MEFISTO_RUNTIME_SERVICE_PID=""
MEFISTO_RUNTIME_SERVICE_IDENTITY=""
MEFISTO_RUNTIME_SERVICE_ENDPOINT=""
MEFISTO_RUNTIME_SERVICE_VERSION=""
MEFISTO_RUNTIME_SERVICE_ERROR=""

mefisto_resolve_runtime() {
    local explicit="${1:-}" runtime="" lib=""
    local adapter="" base="" id="" probe="" candidates="" known="" count=0
    MEFISTO_RUNTIME_ERROR=""
    MEFISTO_RESOLVED_RUNTIME=""

    if [ -n "$explicit" ]; then
        runtime="$explicit"
    elif [ -n "${MEFISTO_RUNTIME:-}" ]; then
        runtime="$MEFISTO_RUNTIME"
    else
        for adapter in "$MEFISTO_RUNTIME_LIB_DIR"/runtime-*.sh; do
            [ -f "$adapter" ] || continue
            base=${adapter##*/}; id=${base#runtime-}; id=${id%.sh}
            case "$id" in ''|*[!a-z0-9_]*) continue ;; esac
            if [ -z "$known" ]; then known="$id"; else known="$known, $id"; fi
            probe="runtime_${id}_is_available"
            if ( source "$adapter" && declare -F "$probe" >/dev/null 2>&1 && "$probe" ); then
                candidates="${candidates}${id} "
                count=$((count + 1))
            fi
        done
        if [ "$count" -eq 0 ]; then
            MEFISTO_RUNTIME_ERROR="no se detecto ningun runtime disponible entre los adaptadores ($known): fija MEFISTO_RUNTIME o --runtime"
            return 1
        elif [ "$count" -gt 1 ]; then
            MEFISTO_RUNTIME_ERROR="se detectaron varios runtimes disponibles (${candidates% }): fija MEFISTO_RUNTIME o --runtime para desambiguar"
            return 1
        fi
        runtime=${candidates% }
    fi

    case "$runtime" in ''|*[!a-z0-9_]*)
        MEFISTO_RUNTIME_ERROR="runtime invalido: '$runtime'"
        return 1 ;;
    esac
    lib="$MEFISTO_RUNTIME_LIB_DIR/runtime-${runtime}.sh"
    if [ ! -f "$lib" ]; then
        MEFISTO_RUNTIME_ERROR="runtime '$runtime' no tiene adaptador ($lib): fija MEFISTO_RUNTIME a un runtime soportado"
        return 1
    fi
    MEFISTO_RESOLVED_RUNTIME="$runtime"
    printf '%s\n' "$runtime"
}

# Servicio opt-in: el handle solo existe en este shell y nunca adopta procesos.
runtime_service_start() {
    local runtime="$1" cwd="$2" work_dir="$3" timeout_s="$4" fn lib
    MEFISTO_RUNTIME_SERVICE_ERROR=""
    if ! mefisto_resolve_runtime "$runtime" >/dev/null; then MEFISTO_RUNTIME_SERVICE_ERROR="$MEFISTO_RUNTIME_ERROR"; return 1; fi
    runtime="$MEFISTO_RESOLVED_RUNTIME"; lib="$MEFISTO_RUNTIME_LIB_DIR/runtime-${runtime}.sh"
    source "$lib"; fn="runtime_${runtime}_service_start"
    if ! declare -F "$fn" >/dev/null 2>&1; then MEFISTO_RUNTIME_SERVICE_ERROR="runtime '$runtime' no soporta servicio preparado"; return 1; fi
    "$fn" "$cwd" "$work_dir" "$timeout_s" || return $?
    MEFISTO_RUNTIME_SERVICE_RUNTIME="$runtime"
}

runtime_service_request() {
    local runtime="$1" method="$2" relative_path="$3" directory="$4" fn
    MEFISTO_RUNTIME_SERVICE_ERROR=""
    if [ -z "$MEFISTO_RUNTIME_SERVICE_RUNTIME" ] || [ "$runtime" != "$MEFISTO_RUNTIME_SERVICE_RUNTIME" ]; then MEFISTO_RUNTIME_SERVICE_ERROR="no existe un servicio preparado propio para runtime '$runtime'"; return 1; fi
    fn="runtime_${runtime}_service_request"
    if ! declare -F "$fn" >/dev/null 2>&1; then MEFISTO_RUNTIME_SERVICE_ERROR="runtime '$runtime' no soporta peticiones al servicio preparado"; return 1; fi
    "$fn" "$method" "$relative_path" "$directory"
}

runtime_service_stop() {
    local runtime="$1" fn rc=0
    MEFISTO_RUNTIME_SERVICE_ERROR=""
    if [ -z "$MEFISTO_RUNTIME_SERVICE_RUNTIME" ] || [ "$runtime" != "$MEFISTO_RUNTIME_SERVICE_RUNTIME" ]; then MEFISTO_RUNTIME_SERVICE_ERROR="no existe un servicio preparado propio para runtime '$runtime'"; return 1; fi
    fn="runtime_${runtime}_service_stop"
    if ! declare -F "$fn" >/dev/null 2>&1; then MEFISTO_RUNTIME_SERVICE_ERROR="runtime '$runtime' no soporta detener el servicio preparado"; return 1; fi
    "$fn" || rc=$?
    MEFISTO_RUNTIME_SERVICE_RUNTIME=""
    return "$rc"
}
