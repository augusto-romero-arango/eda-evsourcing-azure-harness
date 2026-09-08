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

printf '%s\n' '[pre] interfaz'
bash -n "$ADAPTER" && bash -n "$REPO_ROOT/src/published/scripts/lib/adapter-claude.sh" && pass 'sintaxis Bash valida' || fail 'sintaxis Bash invalida'
[ "$(bash "$ADAPTER" root)" = dist/claude ] && pass 'raiz Claude' || fail 'raiz incorrecta'
[ "$(bash "$ADAPTER" path src/published/commands/orden.md)" = commands/orden.md ] && pass 'id de comando sin prefijo interno' || fail 'path de comando incorrecto'

printf '%s\n' '[render] snapshots y directivas'
if render "$FIXTURES/command-delegado.md" > "$WORK/command.md" && cmp -s "$FIXTURES/expected-command-delegado.md" "$WORK/command.md"; then pass 'snapshot byte a byte del comando'; else fail 'snapshot byte a byte del comando'; fi
render "$FIXTURES/agent-completo.md" > "$WORK/agent.md"; rc=$?
[ "$rc" -eq 0 ] && pass 'render del agente completo' || fail 'render del agente completo'
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
absent "$agent" '{{mefisto:' 'las siete directivas quedan resueltas'
absent "$agent" '/Users/' 'sin rutas de maquina'
absent "$agent" 'mefisto-agent-completo' 'sin prefijo interno'

printf '%s\n' '[fallos] fail-closed'
make_agent capacidad '[]'; sed -i '' 's/\[\]/["desconocida"]/' "$WORK/capacidad.md"
out="$(render "$WORK/capacidad.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && contains "$out" 'capabilities: capacidad '\''desconocida'\'' sin mapping Claude' 'capacidad desconocida falla con campo' || fail 'capacidad desconocida debio fallar'
make_agent mcp '[]' ',"mcp":["desconocido"]'
out="$(render "$WORK/mcp.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && contains "$out" 'mcp: servidor MCP '\''desconocido'\'' sin matcher Claude' 'MCP desconocido falla con campo' || fail 'MCP desconocido debio fallar'
make_agent directiva '[]'; printf '%s\n' '{{mefisto:desconocida}}' >> "$WORK/directiva.md"
out="$(render "$WORK/directiva.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && contains "$out" 'body: directiva sin mapping Claude' 'directiva desconocida falla con campo' || fail 'directiva desconocida debio fallar'

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
