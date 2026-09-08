#!/usr/bin/env bash
# Prueba aislada del adaptador publicado: Bash 3.2 + jq, sin red ni OpenCode.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
ADAPTER="$REPO_ROOT/src/published/scripts/adapters/adapter-opencode.sh"
FIXTURES="$HERE/fixtures/opencode"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[pre] adaptador y rutas'
bash -n "$ADAPTER" && pass 'sintaxis Bash valida' || fail 'sintaxis Bash invalida'
[ "$(bash "$ADAPTER" root)" = dist/opencode ] && pass 'raiz dist/opencode' || fail 'raiz incorrecta'
[ "$(bash "$ADAPTER" path src/published/agents/agent-minimo.md)" = agents/agent-minimo.md ] && pass 'path de agente' || fail 'path de agente incorrecto'
[ "$(bash "$ADAPTER" path src/published/commands/command-delegado.md)" = commands/mefisto:command-delegado.md ] && pass 'namespace literal del comando' || fail 'namespace incorrecto'

echo '[render] frontmatter, permisos y directivas'
marker='<!-- GENERADO por prueba desde fixture. No editar a mano. -->'
bash "$ADAPTER" render "$FIXTURES/agent-minimo.md" "$marker" > "$WORK/minimo.md"; rc=$?
[ "$rc" -eq 0 ] && pass 'render minimo' || fail 'render minimo'
minimo="$(< "$WORK/minimo.md")"
assert_contains "$minimo" 'mode: "primary"' 'mode de agente emitido'
assert_contains "$minimo" '"external_directory":"deny"' 'external_directory denegado'
assert_contains "$minimo" '"bash":{"*":"deny"}' 'shell deny por defecto'
assert_not_contains "$minimo" 'model:' 'modelo heredado, no emitido'
assert_not_contains "$minimo" 'tools:' 'campo Claude omitido'

bash "$ADAPTER" render "$FIXTURES/agent-completo.md" "$marker" > "$WORK/completo.md"; rc=$?
[ "$rc" -eq 0 ] && pass 'render de capacidades combinadas' || fail 'render de capacidades combinadas'
completo="$(< "$WORK/completo.md")"
assert_contains "$completo" '"edit":{"*":"allow"' 'edicion sobre alcance consumidor'
assert_contains "$completo" '"read":{"*":"allow"' 'lectura sobre consumidor'
assert_contains "$completo" '"webfetch":"allow"' 'capacidad web'
assert_contains "$completo" '${MEFISTO_PACKAGE_ROOT}/scripts/prueba.sh "$ARGUMENTS con espacios"' 'run preserva argumentos con espacios'
assert_contains "$completo" '.mefisto/harness.config.json' 'config-path traducida'
assert_contains "$completo" '.mefisto/pipeline/logs/con-espacio.log' 'state-path traducida'
assert_contains "$completo" '/mefisto:otra-orden' 'command conserva namespace'
assert_not_contains "$completo" '{{mefisto:' 'siete directivas resueltas'
assert_not_contains "$completo" '.claude/' 'sin ruta Claude'

bash "$ADAPTER" render "$FIXTURES/command-delegado.md" "$marker" > "$WORK/comando.md"; rc=$?
[ "$rc" -eq 0 ] && pass 'render de comando' || fail 'render de comando'
comando="$(< "$WORK/comando.md")"
assert_contains "$comando" 'agent: "agent-completo"' 'agent de comando'
assert_contains "$comando" 'subtask: true' 'subtask de comando'
assert_not_contains "$comando" 'permission:' 'comando sin permisos vacios'

echo '[fallos] fail-closed'
cp "$FIXTURES/agent-minimo.md" "$WORK/con-skill.md"
perl -0pi -e 's/"mode":"primary"/"mode":"primary","skills":["algo"]/' "$WORK/con-skill.md"
out="$(bash "$ADAPTER" render "$WORK/con-skill.md" "$marker" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && assert_contains "$out" 'skills: OpenCode no implementa' 'skills no desaparecen' || fail 'skills debieron fallar'
cp "$FIXTURES/agent-minimo.md" "$WORK/directiva.md"
printf '\n{{mefisto:desconocida}}\n' >> "$WORK/directiva.md"
out="$(bash "$ADAPTER" render "$WORK/directiva.md" "$marker" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && assert_contains "$out" 'body: directiva sin mapping OpenCode' 'directiva sin mapping falla' || fail 'directiva debio fallar'

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
