#!/usr/bin/env bash
# Valida fuentes neutrales publicadas; no consulta ni importa politicas internas.
# Uso: validate-published-artifacts.sh [archivo...]
# Cada rechazo de artefacto imprime "<archivo>: <campo|body>: <motivo>".
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONTRACT_DIR="$REPO_ROOT/src/published/contract"
SCHEMA_FILE="$CONTRACT_DIR/published-artifact.schema.json"
JSONSCHEMA_LITE="$SCRIPT_DIR/lib/jsonschema-lite.jq"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq no esta instalado" >&2; exit 1; }
for required in "$SCHEMA_FILE" "$JSONSCHEMA_LITE"; do [ -f "$required" ] || { echo "ERROR: no existe '$required'" >&2; exit 1; }; done

extract_frontmatter() {
    awk '
        NR == 1 {
            if ($0 != "---") { invalid_start=1; next }
            opened=1
            next
        }
        invalid_start { next }
        opened && $0 == "---" { closed=1; exit }
        opened { print }
        END {
            if (invalid_start) exit 1
            if (!closed) exit 2
        }
    ' "$1"
}
body_lines() { awk 'NR==1 { next } $0 == "---" && !seen { seen=1; next } seen { print NR ":" $0 }' "$1"; }

validate_file() {
    local file="$1" rel="${1#"$REPO_ROOT"/}" basename_no_ext frontmatter rc instance_json schema_json errors status=0 id skill line text directive directives directive_count marker_count placeholders placeholder has_guard=0 agent agent_file command_mcp agent_mcp
    [ -f "$file" ] || { echo "$rel: archivo: no existe o no es un archivo regular"; return 1; }
    basename_no_ext="$(basename "$file" .md)"
    frontmatter="$(extract_frontmatter "$file")"; rc=$?
    [ "$rc" -eq 0 ] || { [ "$rc" -eq 1 ] && echo "$rel: frontmatter: ausente (se esperaba un bloque '---' JSON al inicio del archivo)" || echo "$rel: frontmatter: sin delimitador de cierre"; return 1; }
    [ -n "$frontmatter" ] || { echo "$rel: frontmatter: bloque vacio (se esperaba un objeto JSON)"; return 1; }
    instance_json="$(printf '%s\n' "$frontmatter" | jq -c '.' 2>/dev/null)" || { echo "$rel: frontmatter: no es JSON valido"; return 1; }
    schema_json="$(cat "$SCHEMA_FILE")"
    errors="$(jq -n --argjson schema "$schema_json" --argjson instance "$instance_json" -f "$JSONSCHEMA_LITE" 2>&1)" || { echo "$rel: schema: el validador jq fallo: $errors"; return 1; }
    if [ "$(printf '%s' "$errors" | jq 'length')" -gt 0 ]; then printf '%s' "$errors" | jq -r --arg rel "$rel" '.[] | "\($rel): \(.)"'; status=1; fi
    id="$(printf '%s' "$instance_json" | jq -r 'if (.id? | type) == "string" then .id else empty end')"
    [ -z "$id" ] || [ "$id" = "$basename_no_ext" ] || { echo "$rel: id: '$id' distinto del nombre de archivo '$basename_no_ext'"; status=1; }
    if [ "$(printf '%s' "$instance_json" | jq '[.mcp[]?] | length')" -ne "$(printf '%s' "$instance_json" | jq '[.mcp[]?] | unique | length')" ]; then
        echo "$rel: mcp: referencias MCP duplicadas"
        status=1
    fi
    while IFS= read -r skill; do
        [ -z "$skill" ] || [ -f "$REPO_ROOT/skills/$skill/SKILL.md" ] || { echo "$rel: skills: '$skill' no resuelve a un Skill publicado real"; status=1; }
    done <<EOF
$(printf '%s' "$instance_json" | jq -r '.skills[]?')
EOF
    while IFS=: read -r line text; do
        if printf '%s\n' "$text" | grep -Eiq 'claude|opencode|\.claude|\.opencode|marketplace|(^|[/[:space:].])cache([/[:space:]]|$)|(^|[^[:alnum:]_-])(model|tools|allowed-tools|permission)[[:space:]]*:'; then
            echo "$rel: body: linea $line referencia un runtime, CLI, cache, directorio o metadata propia de runtime"
            status=1
        fi

        placeholders="$(printf '%s\n' "$text" | grep -Eo '\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@*#?!-]' || true)"
        while IFS= read -r placeholder; do
            [ -z "$placeholder" ] && continue
            if [ "$placeholder" != '$ARGUMENTS' ]; then
                echo "$rel: body: linea $line placeholder no permitido: $placeholder (solo se admite \$ARGUMENTS)"
                status=1
            fi
        done <<EOF
$placeholders
EOF

        if printf '%s' "$text" | grep -q '{{mefisto:'; then
            directives="$(printf '%s\n' "$text" | grep -o '{{mefisto:[^}]*}}' || true)"
            marker_count="$(printf '%s\n' "$text" | awk '{ n=0; s=$0; needle="{{mefisto:"; while ((p=index(s, needle)) > 0) { n++; s=substr(s, p + length(needle)) } print n }')"
            directive_count=0
            [ -z "$directives" ] || directive_count="$(printf '%s\n' "$directives" | wc -l | tr -d '[:space:]')"
            if [ "$marker_count" -ne "$directive_count" ] || printf '%s\n' "$text" | grep -Eq '\{\{mefisto:[^{}]*\}\}\}'; then
                echo "$rel: body: linea $line directiva mefisto mal formada"
                status=1
            fi
            while IFS= read -r directive; do
                [ -z "$directive" ] && continue
                case "$directive" in
                    '{{mefisto:assert-consumer-repo}}') has_guard=1 ;;
                    '{{mefisto:package-root}}'|'{{mefisto:config-path}}') ;;
                    '{{mefisto:launch-agent '*'}}'|'{{mefisto:command '*'}}'|'{{mefisto:run '*'}}'|'{{mefisto:state-path '*'}}')
                        if ! printf '%s' "$directive" | grep -Eq '^\{\{mefisto:(launch-agent|command) [a-z0-9]+(-[a-z0-9]+)*\}\}$|^\{\{mefisto:run [a-z0-9][a-z0-9._/-]* [^{}]+\}\}$|^\{\{mefisto:state-path [A-Za-z0-9][A-Za-z0-9._/-]*\}\}$' || printf '%s' "$directive" | grep -Eq '(^|/)\.\.(/|[[:space:]]|\}\})' || printf '%s' "$directive" | grep -Eq '^\{\{mefisto:(launch-agent|command) mefisto-'; then echo "$rel: body: linea $line directiva mefisto mal formada: $directive"; status=1; fi ;;
                    *) echo "$rel: body: linea $line directiva mefisto desconocida: $directive"; status=1 ;;
                esac
            done <<EOF
$directives
EOF
        fi
    done < <(body_lines "$file")
    [ "$has_guard" -eq 1 ] || { echo "$rel: body: falta {{mefisto:assert-consumer-repo}}"; status=1; }
    if [[ "$rel" = src/published/commands/*.md ]] && [ "$(printf '%s' "$instance_json" | jq -r '.kind')" = command ] && [ "$(printf '%s' "$instance_json" | jq '[.mcp[]?] | length')" -gt 0 ]; then
        agent="$(printf '%s' "$instance_json" | jq -r '.agent // empty')"
        [ -n "$agent" ] || agent="$(body_lines "$file" | cut -d: -f2- | grep -Eo '\{\{mefisto:launch-agent [a-z0-9]+(-[a-z0-9]+)*\}\}' | sed -E 's/.*launch-agent ([a-z0-9-]+).*/\1/' | head -n 1)"
        if [ -z "$agent" ]; then
            echo "$rel: mcp: el comando declara MCP pero no delega a un agente neutral"
            status=1
        else
            agent_file="$REPO_ROOT/src/published/agents/$agent.md"
            if [ ! -f "$agent_file" ]; then
                echo "$rel: mcp: el agente delegado '$agent' no existe en src/published/agents"
                status=1
            else
                command_mcp="$(printf '%s' "$instance_json" | jq -c '.mcp // []')"
                agent_mcp="$(extract_frontmatter "$agent_file" | jq -c '.mcp // []' 2>/dev/null)" || agent_mcp='[]'
                if ! jq -en --argjson command "$command_mcp" --argjson agent "$agent_mcp" '$command - $agent | length == 0' >/dev/null; then
                    echo "$rel: mcp: el agente delegado '$agent' no declara todos los ids requeridos por el comando"
                    status=1
                fi
            fi
        fi
    fi
    return "$status"
}

FILES=("$@")
if [ "$#" -eq 0 ]; then FILES=(); while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done < <(find "$REPO_ROOT/src/published/agents" "$REPO_ROOT/src/published/commands" -name '*.md' 2>/dev/null | sort); fi
STATUS=0
for f in ${FILES[@]+"${FILES[@]}"}; do validate_file "$f" || STATUS=1; done
exit "$STATUS"
