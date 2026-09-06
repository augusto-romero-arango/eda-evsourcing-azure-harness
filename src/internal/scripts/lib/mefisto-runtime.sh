#!/usr/bin/env bash
# mefisto-runtime.sh -- Resolucion del runtime activo (MEF-ADR-0049 CA-1/CA-2,
# issue #858). Fuente unica de mefisto_resolve_runtime: la consume
# mefisto-run-agent.sh y, por diseno, la reutilizaran el pipeline (#879) y el
# batch (#870) en su chequeo de dependencias -- una sola implementacion de la
# precedencia y del descubrimiento de la lib de adaptador, en vez de que cada
# consumidor la reinvente.
#
# Uso: source "$(dirname "${BASH_SOURCE[0]}")/mefisto-runtime.sh"
#
# Bash 3.2 (macOS): sin arrays asociativos, sin novedades de bash 4+.

# MEFISTO_RUNTIME_LIB_DIR -- directorio donde se busca "runtime-<id>.sh".
# `: "${VAR:=default}"` (mismo patron que mefisto-state.sh) respeta un valor
# ya fijado por el caller: un test apunta esta variable a un directorio
# temporal con adaptadores de prueba (p. ej. runtime-claude.sh/runtime-
# opencode.sh como stands-in) para ejercer la resolucion sin depender de que
# esos adaptadores reales ya existan en el repo (#859/#860 todavia no los
# entregan). En produccion resuelve, sin intervencion, al mismo directorio
# donde vive este propio archivo.
_mefisto_runtime_computed_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MEFISTO_RUNTIME_LIB_DIR:=$_mefisto_runtime_computed_lib_dir}"
export MEFISTO_RUNTIME_LIB_DIR
unset _mefisto_runtime_computed_lib_dir

# Inicializada al sourcear (mismo contrato que MEFISTO_MODELS_ERROR en
# mefisto-models.sh): un caller bajo `set -u` puede leerla aunque
# mefisto_resolve_runtime todavia no se haya invocado.
MEFISTO_RUNTIME_ERROR=""

# mefisto_resolve_runtime [<explicito>]
#
# Precedencia (CA-2): <explicito> (tipicamente el valor de --runtime del
# caller) > MEFISTO_RUNTIME (entorno) > autodeteccion (`command -v
# claude`/`opencode`: exactamente uno instalado lo selecciona). Imprime por
# stdout el id resuelto y retorna 0.
#
# Retorna 1 SIN imprimir nada y deja el motivo en MEFISTO_RUNTIME_ERROR (una
# linea, lista para abort(), nombrando siempre MEFISTO_RUNTIME) si:
#   - cero runtimes conocidos (claude, opencode) estan instalados y no hay
#     <explicito> ni MEFISTO_RUNTIME que desambigue;
#   - los dos estan instalados a la vez, en la misma situacion; o
#   - el id resuelto por CUALQUIER via (explicito, entorno o autodeteccion) no
#     tiene libreria de adaptador "$MEFISTO_RUNTIME_LIB_DIR/runtime-<id>.sh".
#
# Pura en el sentido de no abortar el proceso ni escribir en disco: es el
# caller (mefisto-run-agent.sh, y los futuros #879/#870) quien decide el exit
# code (69 en el runner) a partir del valor de retorno.
mefisto_resolve_runtime() {
    local explicit="${1:-}"
    MEFISTO_RUNTIME_ERROR=""

    local runtime=""
    if [ -n "$explicit" ]; then
        runtime="$explicit"
    elif [ -n "${MEFISTO_RUNTIME:-}" ]; then
        runtime="$MEFISTO_RUNTIME"
    else
        local has_claude=false has_opencode=false
        command -v claude >/dev/null 2>&1 && has_claude=true
        command -v opencode >/dev/null 2>&1 && has_opencode=true
        if [ "$has_claude" = true ] && [ "$has_opencode" = true ]; then
            MEFISTO_RUNTIME_ERROR="se detectaron ambos runtimes instalados (claude, opencode): fija MEFISTO_RUNTIME o --runtime para desambiguar"
            return 1
        elif [ "$has_claude" = true ]; then
            runtime="claude"
        elif [ "$has_opencode" = true ]; then
            runtime="opencode"
        else
            MEFISTO_RUNTIME_ERROR="no se detecto ningun runtime instalado (claude, opencode): fija MEFISTO_RUNTIME o --runtime"
            return 1
        fi
    fi

    local lib="$MEFISTO_RUNTIME_LIB_DIR/runtime-${runtime}.sh"
    if [ ! -f "$lib" ]; then
        MEFISTO_RUNTIME_ERROR="runtime '$runtime' no tiene libreria de adaptador ($lib): fija MEFISTO_RUNTIME a un runtime soportado"
        return 1
    fi

    printf '%s\n' "$runtime"
    return 0
}
