#!/usr/bin/env bash
# Prueba aislada: Bash 3.2 + jq, sin red ni cargar Claude Code.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
ADAPTER="$REPO_ROOT/src/published/scripts/adapters/adapter-claude.sh"
FIXTURES="$HERE/fixtures/claude"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }
render() { bash "$ADAPTER" render "$1" '<!-- GENERADO por prueba desde fixture. No editar a mano. -->'; }
make_agent() { printf '%s\n' '---' "{\"kind\":\"agent\",\"id\":\"$1\",\"description\":\"Prueba.\",\"mode\":\"subagent\",\"capabilities\":$2${3:-}}" '---' '{{mefisto:assert-consumer-repo}}' > "$WORK/$1.md"; }
render_fails_without_output() {
    local source="$1" expected="$2" label="$3" rc
    render "$source" > "$WORK/failure.stdout" 2> "$WORK/failure.stderr"; rc=$?
    if [ "$rc" -ne 0 ] && [ ! -s "$WORK/failure.stdout" ]; then
        contains "$(< "$WORK/failure.stderr")" "$expected" "$label"
    else
        fail "$label"
    fi
}

printf '%s\n' '[pre] interfaz'
bash -n "$ADAPTER" && bash -n "$REPO_ROOT/src/published/scripts/lib/adapter-claude.sh" && pass 'sintaxis Bash valida' || fail 'sintaxis Bash invalida'
[ "$(bash "$ADAPTER" root)" = dist/claude ] && pass 'raiz Claude' || fail 'raiz incorrecta'
[ "$(bash "$ADAPTER" path src/published/commands/orden.md)" = commands/orden.md ] && pass 'id de comando sin prefijo interno' || fail 'path de comando incorrecto'

printf '%s\n' '[render] snapshots y directivas'
if render "$FIXTURES/command-delegado.md" > "$WORK/command.md" && cmp -s "$FIXTURES/expected-command-delegado.md" "$WORK/command.md"; then pass 'snapshot byte a byte del comando'; else fail 'snapshot byte a byte del comando'; fi
if render "$FIXTURES/agent-completo.md" > "$WORK/agent.md" && cmp -s "$FIXTURES/expected-agent-completo.md" "$WORK/agent.md"; then pass 'snapshot byte a byte del agente'; else fail 'snapshot byte a byte del agente'; fi
agent="$(< "$WORK/agent.md")"
contains "$agent" 'name: "agent-completo"' 'name de agente sin mefisto-'
contains "$agent" 'description: "Lee: \"edita\"."' 'escaping de comillas y dos puntos'
contains "$agent" 'tools: "Read, Glob, Grep, Edit, Write, Bash, WebFetch, WebSearch, Skill, Task, mcp__microsoft-learn__*, mcp__terraform__*"' 'tools y MCP cerrados'
contains "$agent" 'skills: ["projections"]' 'Skill publicado preservado'
contains "$agent" 'model: "sonnet"' 'perfil con modelo'
contains "$agent" '.mefisto/harness.config.json y ${CLAUDE_PLUGIN_ROOT}.' 'config-path y package-root'
contains "$agent" '.mefisto/pipeline/logs/con-espacio.log' 'state-path'
contains "$agent" '${CLAUDE_PLUGIN_ROOT}/scripts/prueba.sh "$ARGUMENTS con espacios"' 'run conserva argumentos y espacios'
contains "$agent" '/mefisto:otra-orden' 'command con namespace del plugin'
contains "$agent" 'Guard inline: Antes de continuar' 'assert-consumer-repo conserva texto circundante'
absent "$agent" '{{mefisto:' 'las siete directivas quedan resueltas'
absent "$agent" '/Users/' 'sin rutas de maquina'
absent "$agent" 'mefisto-agent-completo' 'sin prefijo interno'

printf '%s\n' '[fallos] fail-closed'
make_agent capacidad '["desconocida"]'
render_fails_without_output "$WORK/capacidad.md" 'capabilities: capacidad '\''desconocida'\'' sin mapping Claude' 'capacidad desconocida falla sin salida parcial'
make_agent mcp '[]' ',"mcp":["desconocido"]'
render_fails_without_output "$WORK/mcp.md" 'mcp: servidor MCP '\''desconocido'\'' sin matcher Claude' 'MCP desconocido falla sin salida parcial'
make_agent skill '[]' ',"skills":["no-existe"]'
render_fails_without_output "$WORK/skill.md" 'skills: Skill publicado '\''no-existe'\'' no resuelve' 'Skill desconocido falla sin salida parcial'
make_agent perfil '[]' ',"profile":"desconocido"'
render_fails_without_output "$WORK/perfil.md" 'profile: perfil '\''desconocido'\'' sin mapping Claude' 'perfil desconocido falla sin salida parcial'
make_agent hereda '[]' ',"profile":"deep"'
deep="$(render "$WORK/hereda.md")"; rc=$?
[ "$rc" -eq 0 ] && absent "$deep" 'model:' 'perfil deep hereda sin clave model' || fail 'perfil deep debio renderizar'
make_agent directiva '[]'; printf '%s\n' '{{mefisto:desconocida}}' >> "$WORK/directiva.md"
render_fails_without_output "$WORK/directiva.md" 'body: directiva sin mapping Claude' 'directiva desconocida falla sin salida parcial'

printf '%s\n' '[integracion] fallo atomico del generador'
FAKE="$WORK/repo"
mkdir -p "$FAKE/src/published/scripts/adapters" "$FAKE/src/published/scripts/lib" "$FAKE/src/published/contract" "$FAKE/src/published/agents" "$FAKE/dist/claude"
cp "$REPO_ROOT/src/published/scripts/generate-published-adapters.sh" "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$FAKE/src/published/scripts/"
cp "$REPO_ROOT/src/published/scripts/adapters/adapter-claude.sh" "$FAKE/src/published/scripts/adapters/"
cp "$REPO_ROOT/src/published/scripts/lib/adapter-claude.sh" "$REPO_ROOT/src/published/scripts/lib/jsonschema-lite.jq" "$FAKE/src/published/scripts/lib/"
jq '(.oneOf[].properties.mcp.items.enum) += ["nuevo"]' "$REPO_ROOT/src/published/contract/published-artifact.schema.json" > "$FAKE/src/published/contract/published-artifact.schema.json"
printf '%s\n' 'salida anterior' > "$FAKE/dist/claude/anterior.md"
printf '%s\n' '---' '{"kind":"agent","id":"atomico","description":"Prueba.","mode":"subagent","mcp":["nuevo"]}' '---' '{{mefisto:assert-consumer-repo}}' > "$FAKE/src/published/agents/atomico.md"
out="$(bash "$FAKE/src/published/scripts/generate-published-adapters.sh" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(< "$FAKE/dist/claude/anterior.md")" = 'salida anterior' ] && [ ! -e "$FAKE/dist/claude/agents/atomico.md" ]; then
    contains "$out" "mcp: servidor MCP 'nuevo' sin matcher Claude" 'generador propaga el mapping fallido sin reemplazar dist'
else
    fail 'generador propaga el mapping fallido sin reemplazar dist'
fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
