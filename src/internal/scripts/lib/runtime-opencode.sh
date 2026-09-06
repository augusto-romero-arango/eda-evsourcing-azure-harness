#!/usr/bin/env bash
# runtime-opencode.sh -- Adaptador de runtime OpenCode (MEF-ADR-0049, issue
# #860). Unico lugar del repo (fuera de tests/fixtures/shims generados) que
# compone la invocacion `opencode run` y traduce su `--format json` ("raw
# JSON events", verificado en OpenCode 1.18.29) al JSONL neutral de
# src/internal/contract/run-events.schema.json -- ver
# src/internal/contract/README.md, "Protocolo de ejecucion y eventos".
#
# OpenCode es el runtime del dogfooding interno (MEF-ADR-0049 CA-5, #851):
# ningun otro archivo del harness debe nombrar `opencode`, `--agent`, `--auto`
# ni `--format json` -- eso vive aqui. Autenticacion/credenciales (el
# almacen de credenciales local de OpenCode, OAuth de proveedor) son
# responsabilidad EXCLUSIVA de OpenCode: este adaptador no los lee, copia,
# valida ni menciona (CA-5 de #860, verificado por
# .claude/scripts/tests/test-runtime-opencode.sh seccion [E]: ni la ruta de
# ese almacen ni ninguna variable de API key de proveedor aparecen en este
# archivo ni en runtime-opencode.jq) -- la disponibilidad del provider la
# valida OpenCode al ejecutar, no Mefisto.
#
# Implementa la interfaz de dos funciones que todo adaptador de runtime debe
# exponer (ver src/internal/contract/README.md, "Interfaz de adaptador: dos
# funciones por runtime"):
#   runtime_opencode_build_cmd <agent> <cwd> <prompt_file> <model> <system_file>
#     Rellena MEFISTO_RUNTIME_CMD con el argv de `opencode run` (sin `eval`,
#     paridad con run_agent_with_watchdog): el mensaje viaja como UN elemento
#     del array bash, sin volver a interpretarse. A diferencia de
#     runtime-claude.sh, aqui <agent> y <cwd> SI participan del argv
#     (`--agent <id> --dir <cwd>`) porque `opencode run` los exige como flags
#     propios -- `run_agent_with_watchdog` sigue haciendo `cd "$workdir"`
#     antes de invocar, pero OpenCode ademas necesita que se le diga
#     explicitamente donde correr (CA-1).
#   runtime_opencode_translate <raw_file> <runtime_id> <model>
#                              [<exit_code>] [<stderr_file>]
#     Delega en runtime-opencode.jq (`jq -R -s -c`, mismo idiom que
#     runtime-claude.sh). Nunca emite `run.started` -- eso lo hace
#     mefisto-run-agent.sh directo (issue #858).
#     A diferencia de Claude Code, el wire format de OpenCode no trae ninguna
#     senal propia de exito/fallo (no hay equivalente a `is_error`/`subtype`/
#     `stop_reason`): la clasificacion completa de CA-3 depende del exit code
#     y del stderr crudo que este runner SIEMPRE pasa (ver
#     src/internal/contract/README.md, "Interfaz de adaptador"), asi que los
#     dos ultimos argumentos son mucho mas centrales aqui que en el adaptador
#     Claude Code.
#
# Flags que compone build_cmd (CA-1): `--agent <agent> --dir <cwd> --format
# json --auto` siempre; `-m <model>` solo si el runner entrego un modelo no
# vacio (heredar = el CLI real nunca ve un `-m` vacio); el mensaje final es
# SIEMPRE el ultimo elemento del argv. `--auto` ("auto-approve permissions
# that are not explicitly denied") es el UNICO flag de permisos que este
# adaptador conoce -- la politica deny-por-defecto la genera #862 en el
# frontmatter del agente, nunca este archivo.
#
# `--system-file` no tiene flag equivalente en `opencode run` (verificado:
# `opencode run --help` no lista nada parecido a `--append-system-prompt`):
# se inyecta como PREFIJO del mensaje ("$system\n\n$prompt"), paridad con
# `claude -p "$prompt"` en que el prompt completo viaja como un unico
# argumento posicional, nunca como flag.
#
# El valor de <model> es OPACO para este adaptador (CA-1): viaja tal cual a
# `-m`, con `/`, `.`, `-` o espacios, sin interpretarlo ni validarlo -- la
# disponibilidad real del provider/modelo la resuelve OpenCode al ejecutar.
#
# Bash 3.2 (macOS): sin arrays asociativos, sin novedades de bash 4+.

# --- runtime_opencode_build_cmd ---------------------------------------------

runtime_opencode_build_cmd() {
    local agent="$1" cwd="$2" prompt_file="$3" model="$4" system_file="$5"
    local prompt message

    prompt="$(cat "$prompt_file")"
    if [ -n "$system_file" ]; then
        message="$(cat "$system_file")"$'\n\n'"$prompt"
    else
        message="$prompt"
    fi

    MEFISTO_RUNTIME_CMD=(opencode run --agent "$agent" --dir "$cwd" --format json --auto)

    if [ -n "$model" ]; then
        MEFISTO_RUNTIME_CMD+=(-m "$model")
    fi

    MEFISTO_RUNTIME_CMD+=("$message")
}

# --- runtime_opencode_translate ----------------------------------------------

runtime_opencode_translate() {
    local raw_file="$1" runtime_id="$2" model="$3" exit_code="${4:-}" stderr_file="${5:-}"
    [ -f "$raw_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    local self_dir
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local jq_program="$self_dir/runtime-opencode.jq"
    [ -f "$jq_program" ] || return 0

    # `--rawfile` exige un archivo legible: sin stderr conocido se apunta a
    # /dev/null, que jq lee como cadena vacia (ningun patron casa y la
    # clasificacion cae en lo que el exit code/stream si permitan afirmar).
    local stderr_src="/dev/null"
    if [ -n "$stderr_file" ] && [ -f "$stderr_file" ]; then
        stderr_src="$stderr_file"
    fi

    jq -R -s -c \
        --arg runtime "$runtime_id" \
        --arg model_param "$model" \
        --arg exit_code "$exit_code" \
        --rawfile stderr_text "$stderr_src" \
        -f "$jq_program" \
        "$raw_file" 2>/dev/null
    return 0
}
