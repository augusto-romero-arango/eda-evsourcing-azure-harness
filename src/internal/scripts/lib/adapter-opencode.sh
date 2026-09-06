#!/usr/bin/env bash
# adapter-opencode.sh -- Traduce un artefacto neutral (frontmatter JSON +
# body, ver src/internal/contract/README.md) al formato que OpenCode 1.18.29
# consume: `description`, `mode` (agente); `description`, `agent`, `subtask`
# (comando). Sin `model` (issue #857) ni `tools`/`permission` (issue #862).
# Issue #854.
#
# Se `source`a desde generate-internal-adapters.sh. Ninguna funcion de aqui
# escribe en disco: todas imprimen a stdout el contenido completo del archivo
# de salida, o fallan (return 1, mensaje ya impreso en stderr) sin imprimir
# nada por stdout.

# opencode_translate_body <rel_source> <body> -- imprime el body con las
# directivas neutrales (CA-3) traducidas a su forma OpenCode:
#   {{mefisto:launch-agent <id>}}   -> "Actua como `<id>` con este mensaje inicial: $ARGUMENTS"
#                                      (solo cuando la directiva ocupa toda la linea)
#   {{mefisto:run <script> <args>}} -> MEFISTO_RUNTIME=opencode ./.claude/scripts/<script> <args>
#   {{mefisto:command-path <id>}}   -> .opencode/commands/<id>.md
# Las ultimas dos se traducen en el lugar exacto de la linea donde aparecen,
# preservando el texto que las rodea. Cualquier otra directiva
# "{{mefisto:...}}" aborta (return 1, mensaje en stderr citando rel_source y
# la linea) sin imprimir nada mas.
opencode_translate_body() {
    local rel_source="$1" body="$2" line
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^[[:space:]]*\{\{mefisto:launch-agent[[:space:]]+([A-Za-z0-9_-]+)\}\}[[:space:]]*$ ]]; then
            printf 'Actua como `%s` con este mensaje inicial: $ARGUMENTS\n' "${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^(.*)\{\{mefisto:run[[:space:]]+([^[:space:]]+)[[:space:]]*([^}]*)\}\}(.*)$ ]]; then
            local prefix="${BASH_REMATCH[1]}" script="${BASH_REMATCH[2]}" args suffix="${BASH_REMATCH[4]}"
            args="$(printf '%s' "${BASH_REMATCH[3]}" | sed -E 's/[[:space:]]+$//')"
            if [ -n "$args" ]; then
                printf '%sMEFISTO_RUNTIME=opencode ./.claude/scripts/%s %s%s\n' "$prefix" "$script" "$args" "$suffix"
            else
                printf '%sMEFISTO_RUNTIME=opencode ./.claude/scripts/%s%s\n' "$prefix" "$script" "$suffix"
            fi
        elif [[ "$line" =~ ^(.*)\{\{mefisto:command-path[[:space:]]+([A-Za-z0-9_-]+)\}\}(.*)$ ]]; then
            printf '%s.opencode/commands/%s.md%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        elif [[ "$line" == *"{{mefisto:"* ]]; then
            echo "$rel_source: directiva de body desconocida: '$line'" >&2
            return 1
        else
            printf '%s\n' "$line"
        fi
    done <<< "$body"
    return 0
}

# opencode_extract_launch_agent_id <body> -- imprime el <id> de la primera
# directiva {{mefisto:launch-agent <id>}} que ocupe una linea completa del
# body, o nada si no hay ninguna. Usado para poblar el `agent` de un comando
# OpenCode cuando la fuente no declaro su propio campo `agent` (CA-3b) pero si
# usa la directiva (CA-3).
opencode_extract_launch_agent_id() {
    local body="$1" line
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^[[:space:]]*\{\{mefisto:launch-agent[[:space:]]+([A-Za-z0-9_-]+)\}\}[[:space:]]*$ ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <<< "$body"
}

# opencode_render <rel_source> <instance_json> <marker_line> <body> --
# imprime el archivo OpenCode completo (frontmatter + marcador + body
# traducido) para un agente o comando. Retorna 1 sin imprimir nada si la
# traduccion del body falla (el motivo ya se imprimio en stderr).
opencode_render() {
    local rel_source="$1" instance_json="$2" marker_line="$3" body="$4"
    local kind translated_body
    kind="$(printf '%s' "$instance_json" | jq -r '.kind')"

    translated_body="$(opencode_translate_body "$rel_source" "$body")" || return 1

    local fm_lines=()
    fm_lines+=("description: $(printf '%s' "$instance_json" | jq -r '.description | @json')")
    if [ "$kind" = "agent" ]; then
        fm_lines+=("mode: $(printf '%s' "$instance_json" | jq -r '.mode | @json')")
    else
        local agent_id
        agent_id="$(printf '%s' "$instance_json" | jq -r 'if (.agent != null) then .agent else empty end')"
        if [ -z "$agent_id" ]; then
            agent_id="$(opencode_extract_launch_agent_id "$body")"
        fi
        if [ -n "$agent_id" ]; then
            fm_lines+=("agent: $(printf '%s' "$agent_id" | jq -Rr '@json')")
            fm_lines+=("subtask: true")
        fi
    fi

    printf '%s\n' "---"
    printf '%s\n' "${fm_lines[@]}"
    printf '%s\n' "---"
    printf '%s\n' "$marker_line"
    printf '%s\n' "$translated_body"
}
