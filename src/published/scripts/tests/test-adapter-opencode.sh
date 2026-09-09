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
assets="$($ADAPTER assets)"; rc=$?
[ "$rc" -eq 0 ] && pass 'enumera assets de Skills publicados' || fail 'no enumero assets de Skills publicados'
skill_file_count="$(find "$REPO_ROOT/skills" -type f | wc -l | tr -d '[:space:]')"
jq -e --argjson count "$skill_file_count" 'length == ($count + 2) and ([.[] | select(.source == "skills/projections/SKILL.md" and .destination == "skills/mefisto-projections/SKILL.md")] | length) == 1 and ([.[] | select(.id == "interactive-observability" and .source == "src/published/hooks/interactive-hooks.json" and .destination == "plugins/mefisto-observability.js" and .mode == "0644")] | length) == 1 and ([.[] | select(.id == "mcp-config" and .source == "src/published/contract/mcp-servers.json" and .destination == "plugins/mefisto-mcp.js" and .mode == "0644")] | length) == 1 and ([.[] | select(.destination == "mefisto-manifest.json")] | length) == 0' <<< "$assets" >/dev/null && pass 'assets preservan Skills, observabilidad y MCP sin usurpar el manifiesto del packager' || fail 'inventario de assets incompleto'
"$ADAPTER" render-asset interactive-observability "$REPO_ROOT/src/published/hooks/interactive-hooks.json" > "$WORK/mefisto-observability.js"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'session.model-observed' "$WORK/mefisto-observability.js" && grep -q 'plan.completed no soportado' "$WORK/mefisto-observability.js" && pass 'renderiza el plugin de observabilidad desde el contrato' || fail 'plugin de observabilidad no renderizado'
"$ADAPTER" render-asset skills/projections/SKILL.md "$REPO_ROOT/skills/projections/SKILL.md" > "$WORK/projections-skill.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^name: mefisto-projections$' "$WORK/projections-skill.md" && ! grep -q '^name: projections$' "$WORK/projections-skill.md" && pass 'SKILL.md adapta solo el name OpenCode' || fail 'SKILL.md no adapta el name OpenCode'
cmp -s "$REPO_ROOT/skills/projections/read-apis.md" <("$ADAPTER" render-asset skills/projections/read-apis.md "$REPO_ROOT/skills/projections/read-apis.md") && pass 'recursos Nivel 3 se conservan byte a byte' || fail 'recurso Nivel 3 fue transformado'

printf '%s\n' '[skills] enumeracion abierta y validacion fail-closed'
SKILL_REPO="$WORK/skill-repo"; FIXTURE_ADAPTER="$SKILL_REPO/src/published/scripts/adapters/adapter-opencode.sh"
    mkdir -p "$SKILL_REPO/src/published/scripts/adapters" "$SKILL_REPO/src/published/hooks" "$SKILL_REPO/src/published/contract" "$SKILL_REPO/skills/futuro"
cp "$ADAPTER" "$FIXTURE_ADAPTER"; chmod +x "$FIXTURE_ADAPTER"
    cp "$REPO_ROOT/src/published/scripts/validate-interactive-hooks.sh" "$SKILL_REPO/src/published/scripts/"
    cp "$REPO_ROOT/src/published/scripts/validate-published-mcp.sh" "$SKILL_REPO/src/published/scripts/"
    mkdir -p "$SKILL_REPO/src/published/scripts/lib"
    cp "$REPO_ROOT/src/published/scripts/lib/jsonschema-lite.jq" "$SKILL_REPO/src/published/scripts/lib/"
    cp "$REPO_ROOT/src/published/contract/mcp-servers.json" "$REPO_ROOT/src/published/contract/mcp-servers.schema.json" "$REPO_ROOT/src/published/contract/published-artifact.schema.json" "$SKILL_REPO/src/published/contract/"
    cp "$REPO_ROOT/.mcp.json" "$SKILL_REPO/.mcp.json"
cp "$REPO_ROOT/src/published/hooks/interactive-hooks.json" "$REPO_ROOT/src/published/hooks/interactive-hooks.schema.json" "$SKILL_REPO/src/published/hooks/"
    chmod +x "$SKILL_REPO/src/published/scripts/validate-interactive-hooks.sh" "$SKILL_REPO/src/published/scripts/validate-published-mcp.sh"
write_future_skill() {
    printf '%s\n' '---' 'name: futuro' 'description: Skill futuro.' '---' '' '# Futuro' '[detalle](detalle.md)' > "$SKILL_REPO/skills/futuro/SKILL.md"
    printf 'detalle futuro\n' > "$SKILL_REPO/skills/futuro/detalle.md"
}
assert_skill_failure() {
    local label="$1" output rc
    output="$("$FIXTURE_ADAPTER" assets 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && [ -n "$output" ] && pass "$label" || fail "$label"
}
write_future_skill
    future_assets="$("$FIXTURE_ADAPTER" assets)"; rc=$?
    [ "$rc" -eq 0 ] && jq -e 'length == 4 and ([.[] | select(.source == "skills/futuro/SKILL.md" and .destination == "skills/mefisto-futuro/SKILL.md")] | length) == 1 and ([.[] | select(.destination == "skills/mefisto-futuro/detalle.md")] | length) == 1 and ([.[] | select(.id == "interactive-observability")] | length) == 1 and ([.[] | select(.id == "mcp-config")] | length) == 1' <<< "$future_assets" >/dev/null && pass 'un Skill futuro converge sin inventario hardcodeado' || fail 'un Skill futuro no fue enumerado'
"$FIXTURE_ADAPTER" render-asset skills/futuro/SKILL.md "$SKILL_REPO/skills/futuro/SKILL.md" > "$WORK/futuro-rendered.md"
awk 'NR == 2 { print "name: mefisto-futuro"; next } { print }' "$SKILL_REPO/skills/futuro/SKILL.md" > "$WORK/futuro-expected.md"
cmp -s "$WORK/futuro-expected.md" "$WORK/futuro-rendered.md" && pass 'render futuro cambia exclusivamente name' || fail 'render futuro altero campos o body'
printf '%s\n' '---' 'name: otro' 'description: Valida.' '---' > "$SKILL_REPO/skills/futuro/SKILL.md"
assert_skill_failure 'rechaza name distinto del directorio'
write_future_skill; printf '\n[roto](ausente.md)\n' >> "$SKILL_REPO/skills/futuro/SKILL.md"
assert_skill_failure 'rechaza link local no resoluble'
write_future_skill; printf 'ajeno\n' > "$WORK/ajeno.md"; rm "$SKILL_REPO/skills/futuro/detalle.md"; ln -s "$WORK/ajeno.md" "$SKILL_REPO/skills/futuro/detalle.md"
assert_skill_failure 'rechaza recursos symlink'
rm "$SKILL_REPO/skills/futuro/detalle.md"; write_future_skill; rm "$SKILL_REPO/skills/futuro/SKILL.md"
assert_skill_failure 'rechaza Skill sin SKILL.md'
write_future_skill; awk 'NR == 3 { print "name: futuro" } { print }' "$SKILL_REPO/skills/futuro/SKILL.md" > "$WORK/duplicado.md"; mv "$WORK/duplicado.md" "$SKILL_REPO/skills/futuro/SKILL.md"
assert_skill_failure 'rechaza frontmatter ambiguo'
write_future_skill; printf '%s\n' '---' 'name: futuro' 'description: ""' '---' > "$SKILL_REPO/skills/futuro/SKILL.md"
assert_skill_failure 'rechaza description vacia aunque este entre comillas'
long_id="$(printf 'a%.0s' {1..57})"; rm -rf "$SKILL_REPO/skills/futuro"; mkdir "$SKILL_REPO/skills/$long_id"; printf '%s\n' '---' "name: $long_id" 'description: Valida.' '---' > "$SKILL_REPO/skills/$long_id/SKILL.md"
assert_skill_failure 'rechaza nombre OpenCode mayor de 64 caracteres'
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
assert_contains "$comando" 'usa la tool nativa `skill` para cargar, en este orden: `mefisto-projections`' 'comando solicita carga nativa del Skill'
assert_not_contains "$comando" '## Projections' 'comando no copia doctrina del Skill'

render "$FIXTURES/agent-completo.md" > "$WORK/completo.md"; rc=$?
[ "$rc" -eq 0 ] && pass 'render de capacidades combinadas' || fail 'render de capacidades combinadas'
if [ "$rc" -eq 0 ] && cmp -s "$FIXTURES/expected-agent-completo.md" "$WORK/completo.md"; then
    pass 'snapshot byte a byte de agente con varios Skills'
else
    fail 'snapshot byte a byte de agente con varios Skills'
fi
completo="$(< "$WORK/completo.md")"
assert_contains "$completo" 'description: "Lee, \"edita\" y ejecuta."' 'description queda escapada como YAML valido'
assert_contains "$completo" '"edit":{"*":"allow"' 'edicion sobre alcance consumidor'
assert_contains "$completo" '"read":{"*":"allow"' 'lectura sobre consumidor'
assert_contains "$completo" '"webfetch":"allow"' 'capacidad web'
assert_contains "$completo" '"lsp":"deny"' 'read no habilita lsp implicitamente'
assert_contains "$completo" '"todowrite":"deny"' 'permiso sin capacidad neutral queda denegado'
assert_contains "$completo" '"${MEFISTO_PACKAGE_ROOT}/scripts/prueba.sh" "$ARGUMENTS con espacios"' 'run cita la ruta y preserva argumentos con espacios'
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
assert_contains "$completo" '"skill":{"*":"deny","mefisto-projections":"allow","mefisto-comment-cleanup":"allow"}' 'allowlist exacta de Skills adaptados'
assert_contains "$completo" 'usa la tool nativa `skill` para cargar, en este orden: `mefisto-projections`, `mefisto-comment-cleanup`' 'agente solicita carga nativa en orden fuente'
assert_not_contains "$completo" '## Projections' 'agente no copia doctrina del Skill'
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
[ "$rc" -ne 0 ] && assert_contains "$out" "Skill publicado 'algo' no existe" 'Skill inexistente falla antes de publicar' || fail 'Skill inexistente debio fallar'
make_agent sin-capacidad '[]' ',"skills":["projections"]'
out="$(render "$WORK/sin-capacidad.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && assert_contains "$out" "requiere la capacidad 'skill'" 'agente con Skills sin capacidad falla' || fail 'Skills sin capacidad debieron fallar'
make_agent duplicado '["skill"]' ',"skills":["projections","projections"]'
out="$(render "$WORK/duplicado.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && assert_contains "$out" "referencia duplicada 'projections'" 'Skill duplicado falla' || fail 'Skill duplicado debio fallar'
make_agent prefijado '["skill"]' ',"skills":["mefisto-projections"]'
out="$(render "$WORK/prefijado.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && assert_contains "$out" 'ya tiene prefijo OpenCode' 'Skill prefijado falla' || fail 'Skill prefijado debio fallar'
make_agent no-representable '["skill"]' ',"skills":["no_representable"]'
out="$(render "$WORK/no-representable.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && assert_contains "$out" "referencia no representable 'no_representable'" 'Skill no representable falla' || fail 'Skill no representable debio fallar'
make_agent vacio '["skill"]' ',"skills":[""]'
out="$(render "$WORK/vacio.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && assert_contains "$out" "referencia no representable ''" 'Skill vacio no desaparece silenciosamente' || fail 'Skill vacio debio fallar'
make_agent skill-sin-lista '["skill"]'
skill_sin_lista="$(permission_of "$WORK/skill-sin-lista.md")"
jq -e '.skill == "allow"' <<< "$skill_sin_lista" >/dev/null && pass 'capacidad skill sin referencias conserva politica general' || fail 'capacidad skill sin referencias altero politica'
make_agent read-skill-sin-lista '["read","skill"]'
make_agent read-skill-acotado '["read","skill"]' ',"skills":["projections"]'
read_skill_general="$(permission_of "$WORK/read-skill-sin-lista.md")"
read_skill_acotado="$(permission_of "$WORK/read-skill-acotado.md")"
[ "$(printf '%s' "$read_skill_general" | jq -c 'del(.skill)')" = "$(printf '%s' "$read_skill_acotado" | jq -c 'del(.skill)')" ] && pass 'allowlist de Skills no altera otros permisos' || fail 'allowlist de Skills altero otros permisos'
make_agent con-mcp '[]' ',"mcp":["terraform"]'
out="$(render "$WORK/con-mcp.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && assert_contains "$out" 'mcp: OpenCode no implementa' 'mcp no desaparece' || fail 'mcp debio fallar'
make_agent directiva '[]'
printf '%s\n' '{{mefisto:desconocida}}' >> "$WORK/directiva.md"
out="$(render "$WORK/directiva.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && assert_contains "$out" 'body: directiva sin mapping OpenCode' 'directiva sin mapping falla con campo' || fail 'directiva debio fallar'

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
