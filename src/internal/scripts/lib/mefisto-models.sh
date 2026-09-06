#!/usr/bin/env bash
# mefisto-models.sh -- Resuelve el modelo concreto a usar para un
# agente/comando interno a partir de su perfil logico (fast|balanced|deep,
# MEF-ADR-0049 CA-4 enmendada, issue #857).
#
# mefisto_resolve_model() es la libreria que #859 (adaptador Claude headless)
# y #869 (tooling) migraran a usar en vez del `case` fijo de defaults que hoy
# vive en mefisto-tooling-pipeline.sh -- este archivo NO migra el pipeline,
# solo entrega la funcion, la tabla por adaptador y el mapping local.
#
# Precedencia de mefisto_resolve_model (de mayor a menor prioridad):
#   1. Override --models (resolve_stage_model, issue #709, definida en
#      .claude/scripts/_mefisto-common.sh) -- se reutiliza sin cambios. Si el
#      proceso llamador no la tiene sourceada, este paso se omite sin error:
#      es el unico opcional de los cuatro.
#   2. Mapping local (.mefisto/models.json, NUNCA versionado): primero
#      <runtime>.agents.<agent-id>, luego <runtime>.profiles.<profile>.
#   3. Tabla por defecto del adaptador (adapter_<runtime>_default_model,
#      definida en adapter-claude.sh/adapter-opencode.sh).
#   4. Cadena vacia ("" = heredar el modelo activo de la sesion/CLI).
#
# El generador de adaptadores (generate-internal-adapters.sh, #854) NO invoca
# esta funcion ni lee el mapping local: consulta la tabla del paso 3
# directamente (adapter_claude_default_model), para que la salida versionada
# sea determinista entre maquinas -- decision de refinamiento del issue #857
# (2026-09-05).
#
# Bash 3.2 (macOS): sin arrays asociativos, el mapping local se consulta con
# jq -r --arg por clave, nunca con declare -A.

_MEFISTO_MODELS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MEFISTO_MODELS_JSONSCHEMA_LITE="$_MEFISTO_MODELS_LIB_DIR/jsonschema-lite.jq"
: "${MEFISTO_MODELS_SCHEMA_FILE:=$_MEFISTO_MODELS_LIB_DIR/../../contract/models.schema.json}"

# _mefisto_models_file
#
# Imprime la ruta resuelta del mapping local: MEFISTO_MODELS_FILE si esta
# fijado (uso principal: tests, contra un archivo temporal), o
# "<root>/.mefisto/models.json" contra MEFISTO_REPO_ROOT si esta fijado, o el
# toplevel git, o el cwd como ultimo recurso -- mismo patron de resolucion en
# capas que mefisto-state.sh.
_mefisto_models_file() {
    if [ -n "${MEFISTO_MODELS_FILE:-}" ]; then
        printf '%s' "$MEFISTO_MODELS_FILE"
        return 0
    fi
    local root="${MEFISTO_REPO_ROOT:-}"
    [ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null)"
    [ -n "$root" ] || root="$(pwd)"
    printf '%s/.mefisto/models.json' "$root"
}

# _mefisto_models_validate_local_file
#
# Valida el mapping local resuelto por _mefisto_models_file: JSON valido y
# conforme a models.schema.json. Archivo ausente NUNCA es error (CA-5):
# retorna 0 sin validar nada. Deja el motivo en MEFISTO_MODELS_ERROR si es
# invalido -- por eso el caller (mefisto_resolve_model) la invoca DIRECTO,
# nunca dentro de "$(...)": una asignacion a MEFISTO_MODELS_ERROR hecha en el
# subshell que crea una sustitucion de comando se pierde al volver al shell
# que la invoco, y el caller quedaria con el motivo vacio pese a retornar 1.
_mefisto_models_validate_local_file() {
    local file raw errors_json errors_count
    file="$(_mefisto_models_file)"
    [ -f "$file" ] || return 0

    raw="$(cat "$file" 2>/dev/null)"
    if ! printf '%s' "$raw" | jq -e '.' >/dev/null 2>&1; then
        MEFISTO_MODELS_ERROR="$file: no es JSON valido"
        return 1
    fi

    errors_json="$(jq -n --argjson schema "$(cat "$MEFISTO_MODELS_SCHEMA_FILE")" \
        --argjson instance "$raw" -f "$_MEFISTO_MODELS_JSONSCHEMA_LITE" 2>/dev/null)"
    errors_count="$(printf '%s' "$errors_json" | jq 'length' 2>/dev/null)"
    if [ -z "$errors_count" ] || [ "$errors_count" != "0" ]; then
        MEFISTO_MODELS_ERROR="$file: $(printf '%s' "$errors_json" | jq -r 'join("; ")' 2>/dev/null)"
        return 1
    fi
    return 0
}

# _mefisto_models_local_lookup <runtime> <agent-id> <profile>
#
# Imprime el modelo que .mefisto/models.json fija para (runtime, agent-id) o,
# si no hay entrada de agente, para (runtime, profile) -- CA-2 paso 2. Cadena
# vacia si el archivo no existe o no fija nada para esta clave. Asume que
# _mefisto_models_validate_local_file ya corrio con exito -- no vuelve a
# comprobar JSON/schema, solo extrae el valor. Segura de invocar dentro de
# "$(...)": a diferencia de la validacion, aqui no hay ningun motivo de error
# que perder en un subshell.
_mefisto_models_local_lookup() {
    local runtime="$1" agent_id="$2" profile="$3"
    local file raw val

    file="$(_mefisto_models_file)"
    [ -f "$file" ] || { printf ''; return 0; }

    raw="$(cat "$file" 2>/dev/null)"
    val="$(printf '%s' "$raw" | jq -r --arg rt "$runtime" --arg a "$agent_id" \
        '.[$rt].agents[$a] // empty' 2>/dev/null)"
    if [ -z "$val" ]; then
        val="$(printf '%s' "$raw" | jq -r --arg rt "$runtime" --arg p "$profile" \
            '.[$rt].profiles[$p] // empty' 2>/dev/null)"
    fi
    printf '%s' "$val"
    return 0
}

# _mefisto_models_adapter_default <runtime> <profile>
#
# Imprime la tabla por defecto del adaptador (CA-2 paso 3): delega en
# adapter_<runtime>_default_model, que el caller debe tener sourceada de
# antemano (adapter-claude.sh / adapter-opencode.sh). No sourcea esos
# archivos por si misma: mefisto-models.sh no asume cual de los dos runtimes
# esta en juego, y sourcear ambos incondicionalmente acoplaria esta libreria
# neutral a la implementacion concreta de cada adaptador. El caso `*)` no
# ocurre en la practica -- mefisto_resolve_model ya valido <runtime> antes de
# llamar aqui -- por eso no deja motivo en MEFISTO_MODELS_ERROR (se pierde en
# el subshell de "$(...)" igual que en _mefisto_models_local_lookup, pero sin
# consecuencia porque este camino es inalcanzable).
_mefisto_models_adapter_default() {
    local runtime="$1" profile="$2"
    case "$runtime" in
        claude)   adapter_claude_default_model "$profile" ;;
        opencode) adapter_opencode_default_model "$profile" ;;
        *)        return 1 ;;
    esac
}

# mefisto_resolve_model <runtime> <agent-id> <profile>
#
# Imprime por stdout el modelo a usar, o cadena vacia (= heredar). Retorna 1
# y deja el motivo en MEFISTO_MODELS_ERROR (formato "<origen>: <motivo>",
# listo para pasarle a abort()) si <profile> no esta en el vocabulario
# cerrado fast|balanced|deep, si <runtime> no es claude|opencode, o si el
# mapping local es invalido (CA-5) -- en ningun caso imprime nada por stdout
# cuando retorna 1. El caller debe invocarla para TODOS los stages al
# arrancar, antes de crear el worktree del issue (mismo contrato que
# parse_stage_models, issue #709).
mefisto_resolve_model() {
    local runtime="$1" agent_id="$2" profile="$3"
    MEFISTO_MODELS_ERROR=""

    case "$profile" in
        fast|balanced|deep) ;;
        *)
            MEFISTO_MODELS_ERROR="profile: '$profile' no esta en el vocabulario fast|balanced|deep"
            return 1
            ;;
    esac
    case "$runtime" in
        claude|opencode) ;;
        *)
            MEFISTO_MODELS_ERROR="runtime: '$runtime' no esta en el vocabulario claude|opencode"
            return 1
            ;;
    esac

    _mefisto_models_validate_local_file || return 1

    local model
    model="$(_mefisto_models_local_lookup "$runtime" "$agent_id" "$profile")"
    if [ -z "$model" ]; then
        model="$(_mefisto_models_adapter_default "$runtime" "$profile")" || return 1
    fi

    if command -v resolve_stage_model >/dev/null 2>&1; then
        resolve_stage_model "$agent_id" "$model"
    else
        printf '%s\n' "$model"
    fi
    return 0
}
