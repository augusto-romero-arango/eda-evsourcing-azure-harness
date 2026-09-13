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
extract_preamble() { awk '/^```bash$/{inside=1; next} /^```$/{if (inside) exit} inside' "$1"; }
make_plugin_root() {
    local root="$1" name="${2:-mefisto}" version="${3:-1.2.3}"
    mkdir -p "$root/.claude-plugin" "$root/scripts"
    jq -n --arg name "$name" --arg version "$version" '{name: $name, version: $version}' > "$root/.claude-plugin/plugin.json"
    printf '%s\n' '#!/bin/sh' 'printf invoked > "$MEFISTO_TEST_TRACE"' > "$root/scripts/probe.sh"
    chmod +x "$root/scripts/probe.sh"
}
make_opencode_root() {
    local root="$1"
    mkdir -p "$root"
    jq -n '{schemaVersion:1,runtime:"opencode",version:"1.2.3",commit:"0123456789abcdef0123456789abcdef01234567",minimumRuntimeVersion:"1.18.29"}' > "$root/mefisto-manifest.json"
}
resolve_claude() {
    local cwd="$1" runtime_root="$2" trace="$3"
    (cd "$cwd" && CLAUDE_PLUGIN_ROOT="$runtime_root" MEFISTO_TEST_TRACE="$trace" bash -c "$PREAMBLE_CODE"$'\n''printf "ROOT=%s\\n" "$MEFISTO_PACKAGE_ROOT"; "$MEFISTO_PACKAGE_ROOT/scripts/probe.sh"')
}
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
contains "$agent" '.mefisto/harness.config.json y ${MEFISTO_PACKAGE_ROOT}.' 'config-path y package-root'
contains "$agent" '.mefisto/pipeline/logs/con-espacio.log' 'state-path'
contains "$agent" '"${MEFISTO_PACKAGE_ROOT}/scripts/prueba.sh" "$ARGUMENTS con espacios"' 'run cita la ruta y conserva argumentos con espacios'
contains "$agent" 'MEFISTO_PACKAGE_ROOT="$mefisto_claude_root"' 'preambulo Claude exporta la raiz efectiva'
contains "$agent" '/mefisto:otra-orden' 'command con namespace del plugin'
contains "$agent" 'Guard inline: Antes de continuar' 'assert-consumer-repo conserva texto circundante'
absent "$agent" '{{mefisto:' 'las siete directivas quedan resueltas'
absent "$agent" '/Users/' 'sin rutas de maquina'
absent "$agent" 'mefisto-agent-completo' 'sin prefijo interno'
command="$(< "$WORK/command.md")"
absent "$command" 'MEFISTO_PACKAGE_ROOT' 'body sin directivas de raiz no recibe preambulo'

printf '%s\n' '[resolucion] precedencia, normalizacion y fallos Claude'
PREAMBLE_CODE="$(extract_preamble "$WORK/agent.md")"
CONSUMER="$WORK/consumidor con espacios"; SUBDIR="$CONSUMER/sub/directorio"; mkdir -p "$SUBDIR"
RUNTIME_ROOT="$WORK/plugin runtime"; CANONICAL_ROOT="$WORK/plugin canonico"; LEGACY_ROOT="$WORK/plugin legacy"; OPENCODE_ROOT="$WORK/plugin OpenCode"
make_plugin_root "$RUNTIME_ROOT"; make_plugin_root "$CANONICAL_ROOT"; make_plugin_root "$LEGACY_ROOT"
make_opencode_root "$OPENCODE_ROOT"
RUNTIME_PHYSICAL="$(cd "$RUNTIME_ROOT" && pwd -P)"; CANONICAL_PHYSICAL="$(cd "$CANONICAL_ROOT" && pwd -P)"; LEGACY_PHYSICAL="$(cd "$LEGACY_ROOT" && pwd -P)"
mkdir -p "$CONSUMER/.mefisto/pipeline" "$CONSUMER/.claude/pipeline"
printf '%s/\n' "$CANONICAL_ROOT" > "$CONSUMER/.mefisto/pipeline/.plugin-root"
printf '%s\n' "$LEGACY_ROOT" > "$CONSUMER/.claude/pipeline/.plugin-root"
out="$(resolve_claude "$SUBDIR" "$RUNTIME_ROOT/" "$WORK/runtime.trace" 2> "$WORK/runtime.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ROOT=$RUNTIME_PHYSICAL" ] && [ -f "$WORK/runtime.trace" ] && pass 'variable runtime prevalece y normaliza paths con espacios' || fail 'variable runtime no prevalecio o no ejecuto el script'
out="$(resolve_claude "$SUBDIR" '' "$WORK/canonical.trace" 2> "$WORK/canonical.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ROOT=$CANONICAL_PHYSICAL" ] && pass 'marker canonico se resuelve desde un subdirectorio' || fail 'marker canonico no se resolvio desde subdirectorio'
printf '%s\n' "$OPENCODE_ROOT" > "$CONSUMER/.mefisto/pipeline/.plugin-root"
printf '%s\n' "$LEGACY_ROOT" > "$CONSUMER/.claude/pipeline/.plugin-root"
out="$(resolve_claude "$CONSUMER" '' "$WORK/contaminacion.trace" 2> "$WORK/contaminacion.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ROOT=$LEGACY_PHYSICAL" ] && [ -f "$WORK/contaminacion.trace" ] && [ "$(< "$CONSUMER/.mefisto/pipeline/.plugin-root")" = "$OPENCODE_ROOT" ] && pass 'marker OpenCode valido continua al mirror Claude sin mutarlo' || fail 'marker OpenCode no continuo al mirror Claude'
printf '%s\n' "$CANONICAL_ROOT" > "$CONSUMER/.mefisto/pipeline/.plugin-root"
printf '%s\n' "$OPENCODE_ROOT" > "$CONSUMER/.claude/pipeline/.plugin-root"
out="$(resolve_claude "$CONSUMER" '' "$WORK/claude-despues.trace" 2> "$WORK/claude-despues.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ROOT=$CANONICAL_PHYSICAL" ] && pass 'marker canonico Claude prevalece tras una sesion OpenCode' || fail 'marker canonico Claude no prevalecio'
BAD_CANONICAL="$WORK/plugin canonico malformado"; mkdir -p "$BAD_CANONICAL"; printf '%s\n' '{' > "$BAD_CANONICAL/mefisto-manifest.json"
printf '%s\n' "$BAD_CANONICAL" > "$CONSUMER/.mefisto/pipeline/.plugin-root"
printf '%s\n' "$LEGACY_ROOT" > "$CONSUMER/.claude/pipeline/.plugin-root"
resolve_claude "$SUBDIR" '' "$WORK/malformed.trace" > "$WORK/malformed.stdout" 2> "$WORK/malformed.err"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$WORK/malformed.trace" ] && contains "$(< "$WORK/malformed.err")" 'marker canonico invalida' 'marker canonico malformado no acepta el fallback' || fail 'marker canonico malformado no debio ejecutar codigo'
printf '%s\n' "$OPENCODE_ROOT" > "$CONSUMER/.mefisto/pipeline/.plugin-root"
printf '%s\n' "$LEGACY_ROOT" > "$CONSUMER/.claude/pipeline/.plugin-root"
rm "$CONSUMER/.mefisto/pipeline/.plugin-root"
out="$(resolve_claude "$SUBDIR" '' "$WORK/legacy.trace" 2> "$WORK/legacy.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ROOT=$LEGACY_PHYSICAL" ] && pass 'marker legacy queda como fallback' || fail 'marker legacy no se resolvio'

assert_claude_resolution_fails() {
    local candidate="$1" label="$2" trace="$WORK/failure.trace" rc
    rm -f "$trace"
    resolve_claude "$WORK" "$candidate" "$trace" > "$WORK/failure.stdout" 2> "$WORK/failure.stderr"; rc=$?
    if [ "$rc" -ne 0 ] && [ ! -e "$trace" ]; then
        contains "$(< "$WORK/failure.stderr")" 'ERROR Claude:' "$label"
        contains "$(< "$WORK/failure.stderr")" 'reabra o reinstale' "$label incluye accion concreta"
    else
        fail "$label"; fail "$label incluye accion concreta"
    fi
}
assert_claude_resolution_fails 'relativa/plugin' 'raiz relativa aborta antes del script'
assert_claude_resolution_fails "$WORK/no-existe" 'raiz ausente aborta antes del script'
BROKEN="$WORK/plugin roto"; ln -s "$WORK/no-existe" "$BROKEN"
assert_claude_resolution_fails "$BROKEN" 'symlink roto aborta antes del script'
WRONG_NAME="$WORK/plugin nombre ajeno"; make_plugin_root "$WRONG_NAME" otro 1.2.3
assert_claude_resolution_fails "$WRONG_NAME" 'nombre inesperado aborta antes del script'
WRONG_VERSION="$WORK/plugin version invalida"; make_plugin_root "$WRONG_VERSION" mefisto version-invalida
assert_claude_resolution_fails "$WRONG_VERSION" 'version no SemVer aborta antes del script'
UNREADABLE="$WORK/plugin metadata ilegible"; make_plugin_root "$UNREADABLE"; printf '%s\n' '{' > "$UNREADABLE/.claude-plugin/plugin.json"
assert_claude_resolution_fails "$UNREADABLE" 'metadata ilegible aborta antes del script'

WORKTREE="$WORK/worktree consumidor/directorio"; mkdir -p "$WORKTREE/.mefisto/pipeline" "$WORKTREE/sub"
printf '%s\n' "$CANONICAL_ROOT" > "$WORKTREE/.mefisto/pipeline/.plugin-root"
out="$(resolve_claude "$WORKTREE/sub" '' "$WORK/worktree.trace" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ROOT=$CANONICAL_PHYSICAL" ] && pass 'marker funciona desde worktree' || fail 'marker no funciona desde worktree'

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
mkdir -p "$FAKE/src/published/scripts/adapters" "$FAKE/src/published/scripts/lib" "$FAKE/src/published/contract" "$FAKE/src/published/agents" "$FAKE/src/published" "$FAKE/.claude-plugin" "$FAKE/dist/claude"
cp "$REPO_ROOT/src/published/scripts/generate-published-adapters.sh" "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$FAKE/src/published/scripts/"
cp "$REPO_ROOT/src/published/scripts/adapters/adapter-claude.sh" "$FAKE/src/published/scripts/adapters/"
cp "$REPO_ROOT/src/published/scripts/lib/adapter-claude.sh" "$REPO_ROOT/src/published/scripts/lib/jsonschema-lite.jq" "$FAKE/src/published/scripts/lib/"
jq '(.oneOf[].properties.mcp.items.enum) += ["nuevo"]' "$REPO_ROOT/src/published/contract/published-artifact.schema.json" > "$FAKE/src/published/contract/published-artifact.schema.json"
printf '%s\n' '{"name":"mefisto","version":"1.2.3"}' > "$FAKE/.claude-plugin/plugin.json"
printf '%s\n' '{"schemaVersion":1,"version":"1.2.3","commit":"0123456789abcdef0123456789abcdef01234567"}' > "$FAKE/src/published/release-identity.json"
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
