#!/usr/bin/env bash
# Valida fuentes neutrales publicadas; no consulta ni importa politicas internas.
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONTRACT_DIR="$REPO_ROOT/src/published/contract"
SCHEMA_FILE="$CONTRACT_DIR/published-artifact.schema.json"
JSONSCHEMA_LITE="$SCRIPT_DIR/lib/jsonschema-lite.jq"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq no esta instalado" >&2; exit 1; }
for required in "$SCHEMA_FILE" "$JSONSCHEMA_LITE"; do [ -f "$required" ] || { echo "ERROR: no existe '$required'" >&2; exit 1; }; done

extract_frontmatter() { awk 'NR==1 { if ($0 != "---") exit 1; next } $0 == "---" { closed=1; exit } { print } END { if (!closed) exit 2 }' "$1"; }
body_lines() { awk 'NR==1 { next } $0 == "---" && !seen { seen=1; next } seen { print NR ":" $0 }' "$1"; }

validate_file() {
    local file="$1" rel="${1#"$REPO_ROOT"/}" basename_no_ext frontmatter rc instance_json schema_json errors status=0 id skill line text directive
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
    while IFS= read -r skill; do
        [ -z "$skill" ] || [ -f "$REPO_ROOT/skills/$skill/SKILL.md" ] || { echo "$rel: skills: '$skill' no resuelve a un Skill publicado real"; status=1; }
    done <<EOF
$(printf '%s' "$instance_json" | jq -r '.skills[]?')
EOF
    while IFS=: read -r line text; do
        case "$text" in
            *claude*|*Claude*|*opencode*|*OpenCode*|*CLAUDE_PLUGIN_ROOT*|*.claude/*|*marketplace*|*cache*) echo "$rel: body: linea $line referencia un runtime, CLI, variable o ruta propia de runtime"; status=1 ;;
        esac
        if printf '%s' "$text" | grep -q '{{mefisto:'; then
            directives="$(printf '%s\n' "$text" | grep -o '{{mefisto:[^}]*}}' || true)"
            [ -n "$directives" ] || { echo "$rel: body: linea $line directiva mefisto mal formada"; status=1; continue; }
            while IFS= read -r directive; do
                case "$directive" in
                    '{{mefisto:assert-consumer-repo}}'|'{{mefisto:package-root}}'|'{{mefisto:config-path}}') ;;
                    '{{mefisto:launch-agent '*'}}'|'{{mefisto:command '*'}}'|'{{mefisto:run '*'}}'|'{{mefisto:state-path '*'}}')
                        if ! printf '%s' "$directive" | grep -Eq '^\{\{mefisto:(launch-agent|command) [a-z0-9]+(-[a-z0-9]+)*\}\}$|^\{\{mefisto:run [^[:space:]}]+ [^}]+\}\}$|^\{\{mefisto:state-path [^[:space:]}]+\}\}$'; then echo "$rel: body: linea $line directiva mefisto mal formada: $directive"; status=1; fi ;;
                    *) echo "$rel: body: linea $line directiva mefisto desconocida: $directive"; status=1 ;;
                esac
            done <<EOF
$directives
EOF
        fi
    done < <(body_lines "$file")
    grep -qF '{{mefisto:assert-consumer-repo}}' "$file" || { echo "$rel: body: falta {{mefisto:assert-consumer-repo}}"; status=1; }
    return "$status"
}

FILES=("$@")
if [ "$#" -eq 0 ]; then FILES=(); while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done < <(find "$REPO_ROOT/src/published/agents" "$REPO_ROOT/src/published/commands" -name '*.md' 2>/dev/null | sort); fi
STATUS=0
for f in ${FILES[@]+"${FILES[@]}"}; do validate_file "$f" || STATUS=1; done
exit "$STATUS"
