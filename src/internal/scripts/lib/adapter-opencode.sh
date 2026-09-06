#!/usr/bin/env bash
# adapter-opencode.sh -- Traduce un artefacto neutral (frontmatter JSON +
# body, ver src/internal/contract/README.md) al formato que OpenCode 1.18.29
# consume: `description`, `mode`, `permission` (agente); `description`,
# `agent`, `subtask` (comando). Sin `model` -- decision de MEF-ADR-0049 (CA-4
# enmendada, issue #857): el adaptador OpenCode no tiene tabla por defecto,
# siempre hereda el modelo activo de la sesion salvo mapping local o
# override. Sin `tools` -- OpenCode no tiene un equivalente declarativo de
# restriccion de tools mas alla de `permission` (issue #862, que si define la
# emision de ese bloque). Issue #854.
#
# Se `source`a desde generate-internal-adapters.sh. Ninguna funcion de aqui
# escribe en disco: todas imprimen a stdout el contenido completo del archivo
# de salida, o fallan (return 1, mensaje ya impreso en stderr) sin imprimir
# nada por stdout.

# adapter_opencode_default_model <perfil> -- el adaptador OpenCode no tiene
# tabla por defecto (MEF-ADR-0049 CA-4 enmendada, issue #857): imprime
# siempre cadena vacia ("" = hereda) para cualquier perfil del vocabulario
# cerrado. Existe solo para que mefisto_resolve_model (src/internal/scripts/
# lib/mefisto-models.sh) trate a los dos runtimes con la misma interfaz
# adapter_<runtime>_default_model -- no porque OpenCode necesite una tabla.
# Retorna 1 sin imprimir nada si <perfil> no esta en el vocabulario cerrado
# fast|balanced|deep (no ocurre en la practica: ver adapter_claude_default_model).
adapter_opencode_default_model() {
    case "$1" in
        fast|balanced|deep) printf '%s' "" ;;
        *)                  return 1 ;;
    esac
}

# OPENCODE_PERMISSIONS_MAPPING -- ruta al mapping declarativo capacidad ->
# permiso (issue #862), resuelta relativa a este propio archivo (mismo patron
# BASH_SOURCE que mefisto-state.sh usa desde _mefisto-common.sh) para que
# resuelva sea cual sea el cwd desde el que corra el generador.
OPENCODE_PERMISSIONS_MAPPING="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../contract/opencode-permissions.json"

# opencode_capability_known <capacidad> -- 0 si <capacidad> tiene mapeo a
# `permission` de OpenCode (read, edit, shell, web, skill, task); 1 en
# cualquier otro caso, incluida `mcp` -- CA-5: sin mapeo definido todavia
# (mismo criterio que claude_map_capability_tools con `mcp` en
# adapter-claude.sh, aqui sin degradar nunca a un permiso inventado).
opencode_capability_known() {
    case "$1" in
        read|edit|shell|web|skill|task) return 0 ;;
        *) return 1 ;;
    esac
}

# opencode_permission_json <rel_source> <capabilities_json> <mode> -- imprime
# el objeto JSON compacto (orden de claves preservado, sin jq -S -- MEF-ADR-0049
# CA-6, issue #862 notas tecnicas) del bloque `permission` para un agente:
# valor explicito en las 17 claves del vocabulario de OpenCode 1.18.29
# (CA-1), derivado de <capabilities_json> (array neutral, puede llegar
# null/vacio -- capabilities: [] o ausente da un permiso cerrado por
# completo) y de <mode> (solo afecta `question`: allow en primary, deny en
# cualquier otro valor). Aborta (return 1, mensaje en stderr citando
# rel_source) si <capabilities_json> declara una capacidad sin mapeo OpenCode
# (CA-5): "<rel_source>: capacidad <x> sin mapeo OpenCode" -- sin imprimir
# nada por stdout.
opencode_permission_json() {
    local rel_source="$1" capabilities_json="${2:-[]}" mode="$3"
    [ "$capabilities_json" = "null" ] && capabilities_json="[]"

    local cap
    while IFS= read -r cap; do
        [ -n "$cap" ] || continue
        if ! opencode_capability_known "$cap"; then
            echo "$rel_source: capacidad $cap sin mapeo OpenCode" >&2
            return 1
        fi
    done < <(printf '%s' "$capabilities_json" | jq -r '.[]')

    jq -c -n \
        --slurpfile mapping_arr "$OPENCODE_PERMISSIONS_MAPPING" \
        --argjson capabilities "$capabilities_json" \
        --arg mode "$mode" '
        ($mapping_arr[0]) as $m
        | (reduce ($m.always_deny[]) as $k ({}; . + {($k): "deny"}))
        + {"question": ($m.question[$mode] // "deny")}
        + (reduce ($m.capability_scalar | to_entries[]) as $e (
             {};
             . + (reduce ($e.value[]) as $k (
                    {};
                    . + {($k): (if ($capabilities | index($e.key)) then "allow" else "deny" end)}
                 ))
           ))
        + (reduce ($m.capability_map | to_entries[]) as $e (
             {};
             ($e.value) as $spec
             | (if ($capabilities | index($e.key))
                then ({"*": $spec.catch_all} + (reduce ($spec.rules[]) as $r ({}; . + {($r.pattern): $r.value})))
                else {"*": "deny"}
                end) as $obj
             | . + (reduce ($spec.keys[]) as $k ({}; . + {($k): $obj}))
           ))
        '
}

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
        local mode
        mode="$(printf '%s' "$instance_json" | jq -r '.mode')"
        fm_lines+=("mode: $(printf '%s' "$instance_json" | jq -r '.mode | @json')")

        local permission_json
        permission_json="$(opencode_permission_json "$rel_source" "$(printf '%s' "$instance_json" | jq -c '.capabilities')" "$mode")" || return 1
        fm_lines+=("permission: $permission_json")
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
