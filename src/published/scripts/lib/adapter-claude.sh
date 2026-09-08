#!/usr/bin/env bash
# Funciones del renderizador Claude Code. Solo imprimen stdout; el generador
# publica el staging completo de forma atomica.

published_claude_error() { printf '%s: %s: %s\n' "$1" "$2" "$3" >&2; return 1; }
published_claude_model() { case "$1" in fast) printf haiku ;; balanced) printf sonnet ;; deep) printf '' ;; *) return 1 ;; esac; }
published_claude_capability_tools() { case "$1" in read) printf 'Read, Glob, Grep' ;; edit) printf 'Edit, Write' ;; shell) printf Bash ;; web) printf 'WebFetch, WebSearch' ;; skill) printf Skill ;; task) printf Task ;; *) return 1 ;; esac; }
published_claude_mcp_tools() { case "$1" in microsoft-learn) printf 'mcp__microsoft-learn__*' ;; terraform) printf 'mcp__terraform__*' ;; *) return 1 ;; esac; }

published_claude_tools() {
    local rel="$1" instance="$2" item mapped output=''
    while IFS= read -r item; do
        [ -z "$item" ] && continue
        if ! mapped="$(published_claude_capability_tools "$item")"; then published_claude_error "$rel" capabilities "capacidad '$item' sin mapping Claude"; return 1; fi
        [ -z "$output" ] || output="$output, "; output="$output$mapped"
    done < <(printf '%s' "$instance" | jq -r '.capabilities[]?')
    while IFS= read -r item; do
        [ -z "$item" ] && continue
        if ! mapped="$(published_claude_mcp_tools "$item")"; then published_claude_error "$rel" mcp "servidor MCP '$item' sin matcher Claude"; return 1; fi
        [ -z "$output" ] || output="$output, "; output="$output$mapped"
    done < <(printf '%s' "$instance" | jq -r '.mcp[]?')
    printf '%s' "$output"
}

published_claude_validate_skills() {
    local rel="$1" instance="$2" repo_root="$3" skill
    while IFS= read -r skill; do
        [ -z "$skill" ] && continue
        [ -f "$repo_root/skills/$skill/SKILL.md" ] || { published_claude_error "$rel" skills "Skill publicado '$skill' no resuelve"; return 1; }
    done < <(printf '%s' "$instance" | jq -r '.skills[]?')
}

# Reemplaza de derecha a izquierda para conservar texto circundante y permitir
# varias directivas inline en una misma linea.
published_claude_translate_body() {
    local rel="$1" input="$2" line original translated prefix suffix script args
    while IFS= read -r line || [ -n "$line" ]; do
        original="$line"
        if [[ "$line" =~ ^[[:space:]]*\{\{mefisto:assert-consumer-repo\}\}[[:space:]]*$ ]]; then
            printf '%s\n' 'Antes de continuar, verifica que el directorio actual sea un proyecto consumidor; si es el repositorio de Mefisto, aborta.'
        elif [[ "$line" =~ ^[[:space:]]*\{\{mefisto:launch-agent[[:space:]]+([a-z0-9-]+)\}\}[[:space:]]*$ ]]; then
            printf 'Actua como el agente `%s` con este mensaje inicial: $ARGUMENTS\n' "${BASH_REMATCH[1]}"
        else
            while [[ "$line" == *'{{mefisto:'* ]]; do
                translated=''
                if [[ "$line" =~ ^(.*)\{\{mefisto:run[[:space:]]+([^[:space:]]+)[[:space:]]+([^}]*)\}\}(.*)$ ]]; then
                    prefix="${BASH_REMATCH[1]}"; script="${BASH_REMATCH[2]}"; args="${BASH_REMATCH[3]}"; suffix="${BASH_REMATCH[4]}"
                    args="$(printf '%s' "$args" | sed -E 's/[[:space:]]+$//')"
                    translated="${prefix}\${CLAUDE_PLUGIN_ROOT}/scripts/${script} ${args}${suffix}"
                elif [[ "$line" =~ ^(.*)\{\{mefisto:package-root\}\}(.*)$ ]]; then
                    translated="${BASH_REMATCH[1]}\${CLAUDE_PLUGIN_ROOT}${BASH_REMATCH[2]}"
                elif [[ "$line" =~ ^(.*)\{\{mefisto:config-path\}\}(.*)$ ]]; then
                    translated="${BASH_REMATCH[1]}.mefisto/harness.config.json${BASH_REMATCH[2]}"
                elif [[ "$line" =~ ^(.*)\{\{mefisto:state-path[[:space:]]+([A-Za-z0-9][A-Za-z0-9._/-]*)\}\}(.*)$ ]]; then
                    translated="${BASH_REMATCH[1]}.mefisto/pipeline/${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
                elif [[ "$line" =~ ^(.*)\{\{mefisto:command[[:space:]]+([a-z0-9-]+)\}\}(.*)$ ]]; then
                    translated="${BASH_REMATCH[1]}/mefisto:${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
                else
                    published_claude_error "$rel" body "directiva sin mapping Claude: '$original'"; return 1
                fi
                line="$translated"
            done
            printf '%s\n' "$line"
        fi
    done <<< "$input"
}

published_claude_render() {
    local source="$1" marker="$2" repo_root="$3" rel fm instance kind raw_body translated tools profile model
    rel="${source#"$repo_root"/}"
    fm="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$source")"
    instance="$(printf '%s\n' "$fm" | jq -c '.')" || { published_claude_error "$rel" frontmatter 'no es JSON valido'; return 1; }
    kind="$(printf '%s' "$instance" | jq -r '.kind')"
    raw_body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$source")"
    translated="$(published_claude_translate_body "$rel" "$raw_body")" || return 1
    tools="$(published_claude_tools "$rel" "$instance")" || return 1
    published_claude_validate_skills "$rel" "$instance" "$repo_root" || return 1
    printf '%s\n' '---'
    if [ "$kind" = agent ]; then
        printf 'name: %s\ndescription: %s\n' "$(printf '%s' "$instance" | jq -r '.id | @json')" "$(printf '%s' "$instance" | jq -r '.description | @json')"
        [ -z "$tools" ] || printf 'tools: %s\n' "$(printf '%s' "$tools" | jq -Rr '@json')"
        [ "$(printf '%s' "$instance" | jq '.skills // [] | length')" -eq 0 ] || printf 'skills: %s\n' "$(printf '%s' "$instance" | jq -c '.skills')"
    else
        printf 'description: %s\n' "$(printf '%s' "$instance" | jq -r '.description | @json')"
        [ "$(printf '%s' "$instance" | jq -r '.arguments != null')" = true ] && printf 'argument-hint: %s\n' "$(printf '%s' "$instance" | jq -r '.arguments | @json')"
        [ -z "$tools" ] || printf 'allowed-tools: %s\n' "$(printf '%s' "$tools" | jq -Rr '@json')"
    fi
    profile="$(printf '%s' "$instance" | jq -r '.profile // empty')"
    if [ -n "$profile" ]; then
        model="$(published_claude_model "$profile")" || { published_claude_error "$rel" profile "perfil '$profile' sin mapping Claude"; return 1; }
        [ -z "$model" ] || printf 'model: %s\n' "$(printf '%s' "$model" | jq -Rr '@json')"
    fi
    printf '%s\n%s\n%s\n' '---' "$marker" "$translated"
}
