#!/usr/bin/env bash
# Renderizador OpenCode de artefactos publicados neutrales. Se invoca mediante
# generate-published-adapters.sh; no escribe fuera de stdout.
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MAPPING="$SCRIPT_DIR/../../contract/opencode-permissions.json"

error() { printf '%s\n' "$1" >&2; return 1; }
frontmatter() { awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$1"; }
body() { awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$1"; }

permission_json() {
    local rel="$1" capabilities="$2" mode="$3" cap
    [ -f "$MAPPING" ] || error "$rel: capabilities: no existe el mapping de permisos OpenCode"
    while IFS= read -r cap; do
        [ -z "$cap" ] && continue
        jq -e --arg cap "$cap" '((.capability_scalar | keys) + (.capability_map | keys)) | index($cap) != null' "$MAPPING" >/dev/null 2>&1 || error "$rel: capabilities: capacidad '$cap' sin mapping OpenCode"
    done < <(printf '%s' "$capabilities" | jq -r '.[]')
    jq -cn --slurpfile mapping "$MAPPING" --argjson capabilities "$capabilities" --arg mode "$mode" '
      ($mapping[0]) as $m |
      (reduce ($m.always_deny[]) as $key ({}; . + {($key): "deny"})) +
      {question: ($m.question[$mode] // "deny")} +
      (reduce ($m.capability_scalar | to_entries[]) as $entry ({};
        . + (reduce ($entry.value[]) as $key ({};
          . + {($key): (if $capabilities | index($entry.key) then "allow" else "deny" end)})))) +
      (reduce ($m.capability_map | to_entries[]) as $entry ({};
        ($entry.value) as $spec |
        . + (reduce ($spec.keys[]) as $key ({};
          . + {($key): (if $capabilities | index($entry.key)
                         then ({"*": $spec.catch_all} + reduce ($spec.rules[]) as $rule ({}; . + {($rule.pattern): $rule.value}))
                         else {"*": "deny"} end)}))))'
}

translate_body() {
    local rel="$1" input="$2" line prefix suffix script args id
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^[[:space:]]*\{\{mefisto:assert-consumer-repo\}\}[[:space:]]*$ ]]; then
            printf '%s\n' 'Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.'
        elif [[ "$line" =~ ^[[:space:]]*\{\{mefisto:launch-agent[[:space:]]+([a-z0-9-]+)\}\}[[:space:]]*$ ]]; then
            printf 'Actua como el agente `%s` con este mensaje inicial: $ARGUMENTS\n' "${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^(.*)\{\{mefisto:run[[:space:]]+([^[:space:]]+)[[:space:]]*([^}]*)\}\}(.*)$ ]]; then
            prefix="${BASH_REMATCH[1]}"; script="${BASH_REMATCH[2]}"; args="${BASH_REMATCH[3]}"; suffix="${BASH_REMATCH[4]}"
            args="$(printf '%s' "$args" | sed -E 's/[[:space:]]+$//')"
            printf '%s${MEFISTO_PACKAGE_ROOT}/scripts/%s%s%s\n' "$prefix" "$script" "${args:+ }$args" "$suffix"
        elif [[ "$line" =~ ^(.*)\{\{mefisto:package-root\}\}(.*)$ ]]; then
            printf '%s${MEFISTO_PACKAGE_ROOT}%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        elif [[ "$line" =~ ^(.*)\{\{mefisto:config-path\}\}(.*)$ ]]; then
            printf '%s.mefisto/harness.config.json%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        elif [[ "$line" =~ ^(.*)\{\{mefisto:state-path[[:space:]]+([-A-Za-z0-9._/]+)\}\}(.*)$ ]]; then
            printf '%s.mefisto/pipeline/%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        elif [[ "$line" =~ ^(.*)\{\{mefisto:command[[:space:]]+([a-z0-9-]+)\}\}(.*)$ ]]; then
            printf '%s/mefisto:%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        elif [[ "$line" == *'{{mefisto:'* ]]; then
            error "$rel: body: directiva sin mapping OpenCode: '$line'" || return 1
        else
            printf '%s\n' "$line"
        fi
    done <<< "$input"
}

render() {
    local source="$1" marker="$2" rel fm instance kind artifact_id raw_body translated mode permissions agent
    rel="${source#*/src/published/}"
    rel="src/published/$rel"
    fm="$(frontmatter "$source")" || error "$rel: frontmatter: no se pudo extraer"
    instance="$(printf '%s\n' "$fm" | jq -c '.')" || error "$rel: frontmatter: no es JSON valido"
    kind="$(printf '%s' "$instance" | jq -r '.kind')"
    artifact_id="$(printf '%s' "$instance" | jq -r '.id')"
    raw_body="$(body "$source")"
    if [ "$(printf '%s' "$instance" | jq '[.skills[]?] | length')" -gt 0 ]; then error "$rel: skills: OpenCode no implementa Skills publicados todavia"; return 1; fi
    if [ "$(printf '%s' "$instance" | jq '[.mcp[]?] | length')" -gt 0 ]; then error "$rel: mcp: OpenCode no implementa MCP publicado todavia"; return 1; fi
    translated="$(translate_body "$rel" "$raw_body")" || return 1
    printf '%s\n' '---'
    printf 'description: %s\n' "$(printf '%s' "$instance" | jq -r '.description | @json')"
    if [ "$kind" = agent ]; then
        mode="$(printf '%s' "$instance" | jq -r '.mode')"
        permissions="$(permission_json "$rel" "$(printf '%s' "$instance" | jq -c '.capabilities // []')" "$mode")" || return 1
        printf 'mode: %s\npermission: %s\n' "$(printf '%s' "$mode" | jq -Rr '@json')" "$permissions"
    else
        agent="$(printf '%s' "$instance" | jq -r '.agent // empty')"
        [ -z "$agent" ] || printf 'agent: %s\nsubtask: true\n' "$(printf '%s' "$agent" | jq -Rr '@json')"
    fi
    printf '%s\n%s\n%s\n' '---' "$marker" "$translated"
}

case "${1:-}" in
    root) printf '%s\n' 'dist/opencode' ;;
    path)
        case "${2:-}" in src/published/agents/*.md) printf 'agents/%s\n' "$(basename "$2")" ;; src/published/commands/*.md) printf 'commands/mefisto:%s\n' "$(basename "$2")" ;; *) error "$2: path: fuente publicada desconocida" ;; esac ;;
    render) [ "$#" -eq 3 ] || error 'render: se esperaban fuente y marcador'; render "$2" "$3" ;;
    *) error 'uso: adapter-opencode.sh root|path|render' ;;
esac
