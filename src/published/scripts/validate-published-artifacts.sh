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
    local file="$1" rel="${1#"$REPO_ROOT"/}" basename_no_ext frontmatter rc instance_json schema_json errors status=0 id skill skill_file declared_skills available_skills body_validation has_guard=0 agent agent_file command_mcp agent_mcp
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
    declared_skills="|$(printf '%s' "$instance_json" | jq -r '.skills[]?' | tr '\n' '|')"
    available_skills='|'
    for skill_file in "$REPO_ROOT"/skills/*/SKILL.md; do
        [ -f "$skill_file" ] || continue
        available_skills="${available_skills}$(basename "$(dirname "$skill_file")")|"
    done
    # Una sola pasada interpreta todas las reglas del cuerpo. Las excepciones se
    # seleccionan por artefacto, no por línea, para evitar procesos por hallazgo.
    body_validation="$(awk -v id="$id" -v rel="$rel" -v declared_skills="$declared_skills" -v available_skills="$available_skills" '
        function allowed_placeholder(value) {
            if (value == "$ARGUMENTS") return 1
            if (id == "domain-scaffolder" && value ~ /^\$(1|2|3|AJENOS|CSPROJ|ESPERA|GITHUB_OUTPUT|INTENTOS|INTRUSOS|JOB_STATUS|PENDIENTES|PR_NUM|REPO|REPO_ROOT|RUN|RUN_ID|SECONDS|SHA|TIMEOUT|archivo|destino|f|i|paquete|presupuesto|proj|temporal|version_esperada)$/) return 1
            if (id == "domain-scaffolder" && (value == "${PR_NUM}" || value == "${TIMEOUT}" || value == "${archivo}")) return 1
            if (id == "projection-test-writer" && (value == "$PLUGIN_ROOT" || value == "$HOME" || value == "$2")) return 1
            if (id == "reviewer" && (value == "$PLUGIN_ROOT" || value == "$HOME")) return 1
            if (id == "runtimes" && (value == "$MEFISTO_LIFECYCLE_LAUNCHER" || value == "$MEFISTO_LIFECYCLE_CONFIG_ROOT")) return 1
            if (id == "batch-stop" && value == "$REPO_ROOT") return 1
            if (id == "draft" && value == "$HARNESS_REPO_SLUG") return 1
            if (id == "planner" && value ~ /^\$(SESSION_ID|INITIAL_HEAD_SHA|INITIAL_DEFAULT_BRANCH|INITIAL_STATUS|HARNESS_REPO_SLUG|CLOSING_TIMESTAMP|GLOSSARY_PATH|FIELD_NOTE_LOCAL|GLOSSARY_LOCAL|FIELD_NOTE_GLOSSARY_ARGS)$/) return 1
            if (id == "planner" && value == "${SESSION_ID}") return 1
            return 0
        }
        function valid_directive(value) {
            return value ~ /^\{\{mefisto:(launch-agent|command) [a-z0-9]+(-[a-z0-9]+)*\}\}$/ || value ~ /^\{\{mefisto:run [a-z0-9][a-z0-9._\/-]* [^{}]+\}\}$/ || value ~ /^\{\{mefisto:state-path [A-Za-z0-9][A-Za-z0-9._\/-]*\}\}$/
        }
        NR == 1 { next }
        $0 == "---" && !body { body=1; next }
        !body { next }
        {
            line=NR; text=$0; lower=tolower(text); runtime_text=lower
            legacy=(id == "test-writer" || id == "reviewer" || id == "projection-test-writer" || id == "projection-implementer" || id == "domain-scaffolder")
            runtime_pattern="claude|opencode|\\.claude|\\.opencode|marketplace|(^|[/[:space:].])cache([/[:space:]]|$)|(^|[^[:alnum:]_-])(model|tools|allowed-tools|permission)[[:space:]]*:"
            if (id == "domain-scaffolder") sub(/azure functions core tools:/, "azure functions core tools", runtime_text)
            if ((id == "runtimes" && lower ~ /\.claude|\.opencode|marketplace|(^|[\/[:space:].])cache([\/[:space:]]|$)|(^|[^[:alnum:]_-])(model|tools|allowed-tools|permission)[[:space:]]*:/) || (legacy && runtime_text ~ /opencode|\.opencode|(^|[^[:alnum:]_-])(model|tools|allowed-tools|permission)[[:space:]]*:/) || (!legacy && id != "runtimes" && lower ~ runtime_pattern)) {
                print rel ": body: linea " line " referencia un runtime, CLI, cache, directorio o metadata propia de runtime"
            }
            rest=text
            while (match(rest, /\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@*#?!-]/)) {
                placeholder=substr(rest, RSTART, RLENGTH)
                if (!allowed_placeholder(placeholder)) print rel ": body: linea " line " placeholder no permitido: " placeholder " (solo se admite $ARGUMENTS)"
                rest=substr(rest, RSTART + RLENGTH)
            }
            if (index(text, "{{mefisto:") > 0) {
                markers=0; rest=text
                while ((position=index(rest, "{{mefisto:")) > 0) { markers++; rest=substr(rest, position + 10) }
                directives=0; rest=text
                while (match(rest, /\{\{mefisto:[^}]*\}\}/)) {
                    directives++
                    rest=substr(rest, RSTART + RLENGTH)
                }
                if (markers != directives || text ~ /\{\{mefisto:[^{}]*\}\}\}/) print rel ": body: linea " line " directiva mefisto mal formada"
                rest=text
                while (match(rest, /\{\{mefisto:[^}]*\}\}/)) {
                    directive=substr(rest, RSTART, RLENGTH)
                    if (directive == "{{mefisto:assert-consumer-repo}}") guard=1
                    else if (directive == "{{mefisto:package-root}}" || directive == "{{mefisto:config-path}}" || directive == "{{mefisto:instructions-path}}" || directive == "{{mefisto:lifecycle-launcher}}") {}
                    else if (directive ~ /^\{\{mefisto:skill-root /) {
                        if (directive !~ /^\{\{mefisto:skill-root [a-z0-9]+(-[a-z0-9]+)*\}\}$/ || directive ~ /^\{\{mefisto:skill-root mefisto-/) print rel ": body: linea " line " directiva mefisto mal formada: " directive
                        else {
                            skill=directive
                            sub(/^\{\{mefisto:skill-root /, "", skill)
                            sub(/\}\}$/, "", skill)
                            if (index(declared_skills, "|" skill "|") == 0) print rel ": body: linea " line " directiva skill-root " skill " no esta declarada en skills"
                            if (index(available_skills, "|" skill "|") == 0) print rel ": body: linea " line " directiva skill-root " skill " no resuelve a skills/" skill "/SKILL.md"
                        }
                    }
                    else if (directive ~ /^\{\{mefisto:(launch-agent|command|run|state-path) /) {
                        if (!valid_directive(directive) || directive ~ /(^|\/)\.\.([\/[:space:]]|\}\})/ || directive ~ /^\{\{mefisto:(launch-agent|command) mefisto-/) print rel ": body: linea " line " directiva mefisto mal formada: " directive
                    } else print rel ": body: linea " line " directiva mefisto desconocida: " directive
                    rest=substr(rest, RSTART + RLENGTH)
                }
            }
        }
        END { if (guard) print "__MEFISTO_GUARD__" }
    ' "$file")"
    case "$body_validation" in *"$rel: "*) printf '%s\n' "$body_validation" | grep -v '^__MEFISTO_GUARD__$'; status=1 ;; esac
    case "$body_validation" in *'__MEFISTO_GUARD__'*) has_guard=1 ;; esac
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
