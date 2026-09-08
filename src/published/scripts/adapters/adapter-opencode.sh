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
    [ -f "$MAPPING" ] || { error "$rel: capabilities: no existe el mapping de permisos OpenCode"; return 1; }
    if ! jq -e '
      . as $mapping |
      ([.always_deny[], "question", .capability_scalar[][],
        .capability_map[].keys[]] | unique) as $mapped |
      (.supported_permissions | length) == 17 and
      (.supported_permissions | unique | length) == 17 and
      (.supported_permissions | all(. as $key | $mapped | index($key) != null)) and
      ($mapped | all(. as $key | $mapping.supported_permissions | index($key) != null))
    ' "$MAPPING" >/dev/null 2>&1; then
        error "$rel: capabilities: mapping OpenCode incompleto o invalido"
        return 1
    fi
    while IFS= read -r cap; do
        [ -z "$cap" ] && continue
        if ! jq -e --arg cap "$cap" '((.capability_scalar | keys) + (.capability_map | keys)) | index($cap) != null' "$MAPPING" >/dev/null 2>&1; then
            error "$rel: capabilities: capacidad '$cap' sin mapping OpenCode"
            return 1
        fi
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
    local rel="$1" input="$2" line original prefix suffix script args translated
    while IFS= read -r line || [ -n "$line" ]; do
        original="$line"
        if [[ "$line" =~ ^[[:space:]]*\{\{mefisto:assert-consumer-repo\}\}[[:space:]]*$ ]]; then
            printf '%s\n' 'Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.'
        elif [[ "$line" =~ ^[[:space:]]*\{\{mefisto:launch-agent[[:space:]]+([a-z0-9-]+)\}\}[[:space:]]*$ ]]; then
            printf 'Actua como el agente `%s` con este mensaje inicial: $ARGUMENTS\n' "${BASH_REMATCH[1]}"
        else
            # Se reemplaza de derecha a izquierda para admitir varias
            # directivas inline sin perder el texto que las rodea.
            while [[ "$line" == *'{{mefisto:'* ]]; do
                translated=""
                if [[ "$line" =~ ^(.*)\{\{mefisto:run[[:space:]]+([^[:space:]]+)[[:space:]]+([^}]*)\}\}(.*)$ ]]; then
                    prefix="${BASH_REMATCH[1]}"; script="${BASH_REMATCH[2]}"; args="${BASH_REMATCH[3]}"; suffix="${BASH_REMATCH[4]}"
                    args="$(printf '%s' "$args" | sed -E 's/[[:space:]]+$//')"
                    translated="${prefix}"'${MEFISTO_PACKAGE_ROOT}'"/scripts/${script} ${args}${suffix}"
                elif [[ "$line" =~ ^(.*)\{\{mefisto:package-root\}\}(.*)$ ]]; then
                    translated="${BASH_REMATCH[1]}"'${MEFISTO_PACKAGE_ROOT}'"${BASH_REMATCH[2]}"
                elif [[ "$line" =~ ^(.*)\{\{mefisto:config-path\}\}(.*)$ ]]; then
                    translated="${BASH_REMATCH[1]}.mefisto/harness.config.json${BASH_REMATCH[2]}"
                elif [[ "$line" =~ ^(.*)\{\{mefisto:state-path[[:space:]]+([A-Za-z0-9][A-Za-z0-9._/-]*)\}\}(.*)$ ]]; then
                    translated="${BASH_REMATCH[1]}.mefisto/pipeline/${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
                elif [[ "$line" =~ ^(.*)\{\{mefisto:command[[:space:]]+([a-z0-9-]+)\}\}(.*)$ ]]; then
                    translated="${BASH_REMATCH[1]}/mefisto:${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
                else
                    error "$rel: body: directiva sin mapping OpenCode: '$original'"
                    return 1
                fi
                line="$translated"
            done
            printf '%s\n' "$line"
        fi
    done <<< "$input"
}

launch_agent_id() {
    local input="$1" line
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^[[:space:]]*\{\{mefisto:launch-agent[[:space:]]+([a-z0-9-]+)\}\}[[:space:]]*$ ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <<< "$input"
}

render() {
    local source="$1" marker="$2" rel fm instance kind artifact_id raw_body translated mode permissions agent
    rel="${source#*/src/published/}"
    rel="src/published/$rel"
    fm="$(frontmatter "$source")" || { error "$rel: frontmatter: no se pudo extraer"; return 1; }
    instance="$(printf '%s\n' "$fm" | jq -c '.')" || { error "$rel: frontmatter: no es JSON valido"; return 1; }
    kind="$(printf '%s' "$instance" | jq -r '.kind')"
    artifact_id="$(printf '%s' "$instance" | jq -r '.id')"
    raw_body="$(body "$source")" || { error "$rel: body: no se pudo extraer"; return 1; }
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
        [ -n "$agent" ] || agent="$(launch_agent_id "$raw_body")"
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
