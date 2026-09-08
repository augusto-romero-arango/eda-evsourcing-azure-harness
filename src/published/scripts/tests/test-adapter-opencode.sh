#!/usr/bin/env bash
# Prueba aislada del adaptador publicado: Bash 3.2 + jq, sin red ni OpenCode.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
ADAPTER="$REPO_ROOT/src/published/scripts/adapters/adapter-opencode.sh"
MAPPING="$REPO_ROOT/src/published/contract/opencode-permissions.json"
FIXTURES="$HERE/fixtures/opencode"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }
render() { "$ADAPTER" render "$1" '<!-- GENERADO por prueba desde fixture. No editar a mano. -->'; }
extract_preamble() { awk '/^```bash$/{inside=1; next} /^```$/{if (inside) exit} inside' "$1"; }
make_agent() {
    local name="$1" capabilities="$2" extras="${3:-}"
    printf '%s\n' '---' "{\"kind\":\"agent\",\"id\":\"$name\",\"description\":\"Prueba.\",\"mode\":\"subagent\",\"capabilities\":$capabilities$extras}" '---' '{{mefisto:assert-consumer-repo}}' > "$WORK/$name.md"
}
permission_of() {
    render "$1" | while IFS= read -r line; do
        case "$line" in 'permission: '*) printf '%s\n' "${line#permission: }"; return 0 ;; esac
    done
}

printf '%s\n' '[pre] adaptador, rutas y vocabulario'
bash -n "$ADAPTER" && pass 'sintaxis Bash valida' || fail 'sintaxis Bash invalida'
[ -x "$ADAPTER" ] && pass 'adaptador ejecutable' || fail 'adaptador no ejecutable'
[ "$("$ADAPTER" root)" = dist/opencode ] && pass 'raiz dist/opencode' || fail 'raiz incorrecta'
agent_path="$("$ADAPTER" path src/published/agents/agent-minimo.md)"
command_path="$("$ADAPTER" path src/published/commands/command-delegado.md)"
[ "$agent_path" = agents/agent-minimo.md ] && pass 'path de agente' || fail 'path de agente incorrecto'
[ "$command_path" = commands/mefisto:command-delegado.md ] && pass 'namespace literal del comando' || fail 'namespace incorrecto'
assert_not_contains "$command_path" 'mefisto-command' 'no usa id interno mefisto-<id>'
[ "$command_path" != commands/command-delegado.md ] && pass 'no publica comando sin namespace' || fail 'publico comando sin namespace'
permission_count="$(jq -r '.supported_permissions | length' "$MAPPING")"
[ "$permission_count" -eq 17 ] && pass 'mapping declara los 17 permisos soportados' || fail 'mapping no declara 17 permisos'

printf '%s\n' '[render] snapshots y frontmatter'
if render "$FIXTURES/agent-minimo.md" > "$WORK/minimo.md" && cmp -s "$FIXTURES/expected-agent-minimo.md" "$WORK/minimo.md"; then
    pass 'snapshot byte a byte de agente minimo'
else
    fail 'snapshot byte a byte de agente minimo'
fi
if render "$FIXTURES/command-delegado.md" > "$WORK/comando.md" && cmp -s "$FIXTURES/expected-command-delegado.md" "$WORK/comando.md"; then
    pass 'snapshot byte a byte de comando delegado'
else
    fail 'snapshot byte a byte de comando delegado'
fi
comando="$(< "$WORK/comando.md")"
assert_contains "$comando" 'agent: "agent-completo"' 'agent inferido de launch-agent'
assert_contains "$comando" 'subtask: true' 'subtask del comando delegado'
assert_not_contains "$comando" 'permission:' 'comando sin campo permission'
assert_not_contains "$comando" 'model:' 'comando hereda modelo'

render "$FIXTURES/agent-completo.md" > "$WORK/completo.md"; rc=$?
[ "$rc" -eq 0 ] && pass 'render de capacidades combinadas' || fail 'render de capacidades combinadas'
completo="$(< "$WORK/completo.md")"
assert_contains "$completo" 'description: "Lee, \"edita\" y ejecuta."' 'description queda escapada como YAML valido'
assert_contains "$completo" '"edit":{"*":"allow"' 'edicion sobre alcance consumidor'
assert_contains "$completo" '"read":{"*":"allow"' 'lectura sobre consumidor'
assert_contains "$completo" '"webfetch":"allow"' 'capacidad web'
assert_contains "$completo" '"lsp":"deny"' 'read no habilita lsp implicitamente'
assert_contains "$completo" '"todowrite":"deny"' 'permiso sin capacidad neutral queda denegado'
assert_contains "$completo" '${MEFISTO_PACKAGE_ROOT}/scripts/prueba.sh "$ARGUMENTS con espacios"' 'run preserva argumentos con espacios'
assert_contains "$completo" 'package-root' 'preambulo OpenCode consulta el launcher activo'
assert_contains "$completo" 'export MEFISTO_PACKAGE_ROOT' 'preambulo OpenCode exporta la raiz efectiva'
assert_contains "$completo" 'Rutas: .mefisto/harness.config.json y ${MEFISTO_PACKAGE_ROOT}.' 'varias directivas preservan texto circundante'
assert_contains "$completo" '.mefisto/pipeline/logs/con-espacio.log' 'state-path traducida'
assert_contains "$completo" '/mefisto:otra-orden' 'command conserva namespace'
assert_not_contains "$completo" '{{mefisto:' 'siete directivas resueltas'
assert_not_contains "$completo" '.claude/' 'sin ruta Claude'
assert_not_contains "$completo" '/Users/' 'sin path de maquina'
assert_not_contains "$completo" 'model:' 'agente hereda modelo'
assert_not_contains "$completo" 'tools:' 'campo Claude omitido'
assert_not_contains "$comando" 'MEFISTO_PACKAGE_ROOT' 'body sin directivas de raiz no recibe preambulo'

printf '%s\n' '[resolucion] launcher XDG y fallos OpenCode'
PREAMBLE_CODE="$(extract_preamble "$WORK/completo.md")"
HOME="$WORK/home con espacios"; XDG_DATA_HOME="$HOME/datos con espacios"; export HOME XDG_DATA_HOME
FAKE_ROOT="$WORK/release activa con espacios"; mkdir -p "$FAKE_ROOT/scripts" "$XDG_DATA_HOME/mefisto/active/bin"
FAKE_ROOT_PHYSICAL="$(cd "$FAKE_ROOT" && pwd -P)"
printf '%s\n' '#!/bin/sh' '[ "$1" = package-root ] || exit 2' 'printf "%s\\n" "$MEFISTO_TEST_ROOT"' > "$XDG_DATA_HOME/mefisto/active/bin/mefisto-opencode"
chmod +x "$XDG_DATA_HOME/mefisto/active/bin/mefisto-opencode"
printf '%s\n' '#!/bin/sh' 'printf invoked > "$MEFISTO_TEST_TRACE"' > "$FAKE_ROOT/scripts/probe.sh"; chmod +x "$FAKE_ROOT/scripts/probe.sh"
run_opencode_resolution() {
    local root="$1" trace="$2"
    MEFISTO_TEST_ROOT="$root" MEFISTO_TEST_TRACE="$trace" bash -c "$PREAMBLE_CODE"$'\n''printf "ROOT=%s\\n" "$MEFISTO_PACKAGE_ROOT"; "$MEFISTO_PACKAGE_ROOT/scripts/probe.sh"'
}
out="$(run_opencode_resolution "$FAKE_ROOT/" "$WORK/opencode.trace" 2> "$WORK/opencode.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ROOT=$FAKE_ROOT_PHYSICAL" ] && [ -f "$WORK/opencode.trace" ] && pass 'XDG localiza launcher y normaliza release con espacios' || fail 'XDG no resolvio la release con espacios'
assert_opencode_resolution_fails() {
    local root="$1" label="$2" trace="$WORK/opencode-failure.trace" rc
    rm -f "$trace"
    run_opencode_resolution "$root" "$trace" > "$WORK/opencode-failure.stdout" 2> "$WORK/opencode-failure.stderr"; rc=$?
    if [ "$rc" -ne 0 ] && [ ! -e "$trace" ]; then
        assert_contains "$(< "$WORK/opencode-failure.stderr")" 'ERROR OpenCode:' "$label"
        assert_contains "$(< "$WORK/opencode-failure.stderr")" 'active la release OpenCode' "$label incluye accion concreta"
    else
        fail "$label"; fail "$label incluye accion concreta"
    fi
}
assert_opencode_resolution_fails 'release-relativa' 'salida relativa aborta antes del script'
assert_opencode_resolution_fails "$WORK/release ausente" 'release ausente aborta antes del script'
printf '%s\n' '#!/bin/sh' 'exit 7' > "$XDG_DATA_HOME/mefisto/active/bin/mefisto-opencode"; chmod +x "$XDG_DATA_HOME/mefisto/active/bin/mefisto-opencode"
assert_opencode_resolution_fails "$FAKE_ROOT" 'fallo del launcher aborta antes del script'
rm "$XDG_DATA_HOME/mefisto/active/bin/mefisto-opencode"
assert_opencode_resolution_fails "$FAKE_ROOT" 'launcher ausente aborta antes del script'
ln -s "$WORK/no-existe" "$XDG_DATA_HOME/mefisto/active/bin/mefisto-opencode"
assert_opencode_resolution_fails "$FAKE_ROOT" 'launcher roto aborta antes del script'

printf '%s\n' '[permisos] deny por defecto y capacidades aisladas'
make_agent solo-read '["read"]'; read_permission="$(permission_of "$WORK/solo-read.md")"
jq -e '.read["*"] == "allow" and .list == "allow" and .glob == "allow" and .grep == "allow" and .edit["*"] == "deny" and .bash["*"] == "deny"' <<< "$read_permission" >/dev/null && pass 'combinacion read' || fail 'combinacion read'
make_agent solo-edit '["edit"]'; edit_permission="$(permission_of "$WORK/solo-edit.md")"
jq -e '.edit["*"] == "allow" and .write["*"] == "allow" and .patch["*"] == "allow" and .read["*"] == "deny"' <<< "$edit_permission" >/dev/null && pass 'combinacion edit' || fail 'combinacion edit'
make_agent solo-shell '["shell"]'; shell_permission="$(permission_of "$WORK/solo-shell.md")"
jq -e '.bash["*"] == "deny" and .bash["${MEFISTO_PACKAGE_ROOT}/scripts/*"] == "allow" and .external_directory == "deny"' <<< "$shell_permission" >/dev/null && pass 'combinacion shell acotada' || fail 'combinacion shell acotada'
keys="$(printf '%s' "$read_permission" | jq -c 'keys | sort')"
supported="$(jq -c '.supported_permissions | sort' "$MAPPING")"
[ "$keys" = "$supported" ] && pass 'todo permiso soportado tiene valor explicito' || fail 'faltan o sobran permisos emitidos'

printf '%s\n' '[fallos] fail-closed'
make_agent desconocida '["desconocida"]'
out="$(render "$WORK/desconocida.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && assert_contains "$out" 'capabilities: capacidad '\''desconocida'\'' sin mapping OpenCode' 'capacidad desconocida falla con campo' || fail 'capacidad desconocida debio fallar'
make_agent con-skill '[]' ',"skills":["algo"]'
out="$(render "$WORK/con-skill.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && assert_contains "$out" 'skills: OpenCode no implementa' 'skills no desaparecen' || fail 'skills debieron fallar'
make_agent con-mcp '[]' ',"mcp":["terraform"]'
out="$(render "$WORK/con-mcp.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && assert_contains "$out" 'mcp: OpenCode no implementa' 'mcp no desaparece' || fail 'mcp debio fallar'
make_agent directiva '[]'
printf '%s\n' '{{mefisto:desconocida}}' >> "$WORK/directiva.md"
out="$(render "$WORK/directiva.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && assert_contains "$out" 'body: directiva sin mapping OpenCode' 'directiva sin mapping falla con campo' || fail 'directiva debio fallar'

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
