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
    jq -n --arg version "$version" '{schemaVersion:1,runtime:"claude",version:$version,commit:"0123456789abcdef0123456789abcdef01234567"}' > "$root/mefisto-manifest.json"
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
bash -n "$ADAPTER" && bash -n "$REPO_ROOT/src/published/scripts/lib/adapter-claude.sh" && bash -n "$REPO_ROOT/src/published/scripts/lib/effective-contract.sh" && pass 'sintaxis Bash valida' || fail 'sintaxis Bash invalida'
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
contains "$agent" 'Rutas: ${MEFISTO_CONFIG_PATH}, ${MEFISTO_INSTRUCTIONS_PATH} y ${MEFISTO_PACKAGE_ROOT}.' 'config-path, instructions-path y package-root traducen a variables'
contains "$agent" 'MEFISTO_CONFIG_PATH=".mefisto/harness.config.json"' 'preambulo del contrato efectivo resuelve config canonico'
contains "$agent" 'MEFISTO_INSTRUCTIONS_PATH="AGENTS.md"' 'preambulo del contrato efectivo resuelve instructions canonico'
[ "$(printf '%s\n' "$agent" | grep -c '^```bash$')" -eq 2 ] && pass 'config-path e instructions-path comparten un unico preambulo adicional' || fail 'config-path e instructions-path no comparten preambulo'
contains "$agent" '.mefisto/pipeline/logs/con-espacio.log' 'state-path'
contains "$agent" '"${MEFISTO_PACKAGE_ROOT}/scripts/prueba.sh" "$ARGUMENTS con espacios"' 'run cita la ruta y conserva argumentos con espacios'
contains "$agent" 'MEFISTO_PACKAGE_ROOT="$mefisto_claude_root"' 'preambulo Claude exporta la raiz efectiva'
contains "$agent" '/mefisto:otra-orden' 'command con namespace del plugin'
contains "$agent" 'Guard inline: Antes de continuar' 'assert-consumer-repo conserva texto circundante'
absent "$agent" '{{mefisto:' 'las directivas quedan resueltas'
absent "$agent" '/Users/' 'sin rutas de maquina'
absent "$agent" 'mefisto-agent-completo' 'sin prefijo interno'
command="$(< "$WORK/command.md")"
absent "$command" 'MEFISTO_PACKAGE_ROOT' 'body sin directivas de raiz no recibe preambulo'
make_agent raiz-skill '["skill"]' ',"skills":["projections"]'
printf '%s\n' 'Recursos: {{mefisto:skill-root projections}}/read-apis.md y {{mefisto:skill-root projections}}/recipes.md; paquete {{mefisto:package-root}}; ejecuta {{mefisto:run prueba.sh "$ARGUMENTS con espacios"}}.' >> "$WORK/raiz-skill.md"
skill_root_rendered="$(render "$WORK/raiz-skill.md")"; rc=$?
skill_root_preambles="$(printf '%s\n' "$skill_root_rendered" | grep -c 'MEFISTO_PACKAGE_ROOT="$mefisto_claude_root"')"
[ "$rc" -eq 0 ] && contains "$skill_root_rendered" '"${MEFISTO_PACKAGE_ROOT}/skills/projections"/read-apis.md' 'skill-root Claude resuelve el Skill lógico' || fail 'skill-root Claude debio renderizar'
[ "$rc" -eq 0 ] && contains "$skill_root_rendered" 'paquete ${MEFISTO_PACKAGE_ROOT}; ejecuta MEFISTO_RUNTIME=claude "${MEFISTO_PACKAGE_ROOT}/scripts/prueba.sh" "$ARGUMENTS con espacios"' 'skill-root convive con package-root y run en Claude' || fail 'directivas de raiz combinadas no se tradujeron en Claude'
[ "$skill_root_preambles" -eq 1 ] && pass 'varias directivas skill-root emiten un solo preambulo Claude' || fail 'skill-root Claude duplico el preambulo'

printf '%s\n' '[contrato-efectivo] config-path e instructions-path'
make_agent contrato-config '["read"]'
printf '%s\n' '{{mefisto:config-path}}' >> "$WORK/contrato-config.md"
render "$WORK/contrato-config.md" > "$WORK/contrato-config.rendered.md"
CONFIG_PREAMBLE_CODE="$(extract_preamble "$WORK/contrato-config.rendered.md")"
make_agent contrato-instrucciones '["read"]'
printf '%s\n' '{{mefisto:instructions-path}}' >> "$WORK/contrato-instrucciones.md"
render "$WORK/contrato-instrucciones.md" > "$WORK/contrato-instrucciones.rendered.md"
INSTRUCTIONS_PREAMBLE_CODE="$(extract_preamble "$WORK/contrato-instrucciones.rendered.md")"
resolve_config() { local cwd="$1"; (cd "$cwd" && bash -c "$CONFIG_PREAMBLE_CODE"$'\n''printf "%s\n" "$MEFISTO_CONFIG_PATH"'); }
resolve_instructions() { local cwd="$1"; (cd "$cwd" && bash -c "$INSTRUCTIONS_PREAMBLE_CODE"$'\n''printf "%s\n" "$MEFISTO_INSTRUCTIONS_PATH"'); }

CONTRATO="$WORK/contrato consumidor"; mkdir -p "$CONTRATO/.mefisto" "$CONTRATO/.claude"

printf '{}' > "$CONTRATO/.mefisto/harness.config.json"
out="$(resolve_config "$CONTRATO" 2>"$WORK/config-canonico.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = '.mefisto/harness.config.json' ] && [ ! -s "$WORK/config-canonico.err" ] && pass 'config-path: solo canonico resuelve sin aviso' || fail 'config-path: solo canonico'

rm -f "$CONTRATO/.mefisto/harness.config.json"
printf '{}' > "$CONTRATO/.claude/harness.config.json"
out="$(resolve_config "$CONTRATO" 2>"$WORK/config-legacy.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = '.claude/harness.config.json' ] && [ ! -s "$WORK/config-legacy.err" ] && pass 'config-path: solo legacy resuelve como fallback' || fail 'config-path: solo legacy'

printf '{}' > "$CONTRATO/.mefisto/harness.config.json"
out="$(resolve_config "$CONTRATO" 2>"$WORK/config-ambos.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = '.mefisto/harness.config.json' ] && grep -qF 'se usara el config canonico .mefisto/harness.config.json; se ignora el legacy .claude/harness.config.json' "$WORK/config-ambos.err" && pass 'config-path: coexistencia elige canonico y avisa sin mezclar' || fail 'config-path: coexistencia'

rm -f "$CONTRATO/.mefisto/harness.config.json" "$CONTRATO/.claude/harness.config.json"
out="$(resolve_config "$CONTRATO" 2>"$WORK/config-ausente.err")"; rc=$?
[ "$rc" -ne 0 ] && [ -z "$out" ] && grep -qF 'no se encontro el config canonico requerido .mefisto/harness.config.json' "$WORK/config-ausente.err" && grep -qF 'fallback legacy .claude/harness.config.json' "$WORK/config-ausente.err" && pass 'config-path: ausencia total aborta nombrando canonico y legacy' || fail 'config-path: ausencia total'

printf '{}' > "$CONTRATO/.mefisto/harness.config.json"; chmod 000 "$CONTRATO/.mefisto/harness.config.json"
out="$(resolve_config "$CONTRATO" 2>"$WORK/config-ilegible.err")"; rc=$?
if [ "$(id -u)" -eq 0 ]; then
    pass 'config-path: no legible (omitido bajo root, sin aplicacion de permisos)'
else
    [ "$rc" -eq 0 ] && [ "$out" = '.mefisto/harness.config.json' ] && pass 'config-path: canonico no legible se sigue seleccionando, igual que resolve_harness_config_path' || fail 'config-path: canonico no legible'
fi
chmod 644 "$CONTRATO/.mefisto/harness.config.json"

printf '%s\n' '@AGENTS.md' > "$CONTRATO/AGENTS.md"
out="$(resolve_instructions "$CONTRATO" 2>"$WORK/instrucciones-canonico.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = 'AGENTS.md' ] && [ ! -s "$WORK/instrucciones-canonico.err" ] && pass 'instructions-path: solo canonico resuelve sin aviso' || fail 'instructions-path: solo canonico'

rm -f "$CONTRATO/AGENTS.md"
printf '%s\n' '@AGENTS.md' > "$CONTRATO/CLAUDE.md"
out="$(resolve_instructions "$CONTRATO" 2>"$WORK/instrucciones-legacy.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = 'CLAUDE.md' ] && [ ! -s "$WORK/instrucciones-legacy.err" ] && pass 'instructions-path: solo legacy resuelve como fallback' || fail 'instructions-path: solo legacy'

printf '%s\n' '@AGENTS.md' > "$CONTRATO/AGENTS.md"
out="$(resolve_instructions "$CONTRATO" 2>"$WORK/instrucciones-ambos.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = 'AGENTS.md' ] && grep -qF 'se usara AGENTS.md; se ignora el legacy CLAUDE.md' "$WORK/instrucciones-ambos.err" && pass 'instructions-path: coexistencia elige canonico y avisa sin mezclar' || fail 'instructions-path: coexistencia'

rm -f "$CONTRATO/AGENTS.md" "$CONTRATO/CLAUDE.md"
out="$(resolve_instructions "$CONTRATO" 2>"$WORK/instrucciones-ausente.err")"; rc=$?
[ "$rc" -ne 0 ] && [ -z "$out" ] && grep -qF 'no se encontro AGENTS.md' "$WORK/instrucciones-ausente.err" && grep -qF 'fallback legacy CLAUDE.md' "$WORK/instrucciones-ausente.err" && grep -qF '/mefisto:onboard' "$WORK/instrucciones-ausente.err" && pass 'instructions-path: ausencia total aborta con diagnostico de onboarding' || fail 'instructions-path: ausencia total'

printf '%s\n' '@AGENTS.md' > "$CONTRATO/AGENTS.md"; chmod 000 "$CONTRATO/AGENTS.md"
out="$(resolve_instructions "$CONTRATO" 2>"$WORK/instrucciones-ilegible.err")"; rc=$?
if [ "$(id -u)" -eq 0 ]; then
    pass 'instructions-path: no legible (omitido bajo root, sin aplicacion de permisos)'
else
    [ "$rc" -eq 0 ] && [ "$out" = 'AGENTS.md' ] && pass 'instructions-path: canonico no legible se sigue seleccionando' || fail 'instructions-path: canonico no legible'
fi
chmod 644 "$CONTRATO/AGENTS.md"

make_agent contrato-repetido '["read"]'
printf '%s\n' 'Primero {{mefisto:config-path}} y de nuevo {{mefisto:config-path}}; tambien {{mefisto:instructions-path}} y otra vez {{mefisto:instructions-path}}.' >> "$WORK/contrato-repetido.md"
repetido_rendered="$(render "$WORK/contrato-repetido.md")"; rc=$?
repetido_blocks="$(printf '%s\n' "$repetido_rendered" | grep -c '^```bash$')"
[ "$rc" -eq 0 ] && [ "$repetido_blocks" -eq 1 ] && pass 'usos repetidos de config-path/instructions-path comparten un unico preambulo Claude' || fail 'usos repetidos duplicaron el preambulo Claude'
[ "$(printf '%s\n' "$repetido_rendered" | grep -Fo '${MEFISTO_CONFIG_PATH}' | wc -l | tr -d '[:space:]')" -eq 2 ] && pass 'config-path conserva cada uso inline repetido' || fail 'config-path perdio un uso inline repetido'
[ "$(printf '%s\n' "$repetido_rendered" | grep -Fo '${MEFISTO_INSTRUCTIONS_PATH}' | wc -l | tr -d '[:space:]')" -eq 2 ] && pass 'instructions-path conserva cada uso inline repetido' || fail 'instructions-path perdio un uso inline repetido'

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
PARENT_ROOT="$WORK/plugin canonico padre"; make_plugin_root "$PARENT_ROOT"
mkdir -p "$WORK/.mefisto/pipeline"; printf '%s\n' "$PARENT_ROOT" > "$WORK/.mefisto/pipeline/.plugin-root"
out="$(resolve_claude "$SUBDIR" '' "$WORK/nearest.trace" 2> "$WORK/nearest.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ROOT=$LEGACY_PHYSICAL" ] && pass 'contaminacion local no salta a un marker canonico padre' || fail 'se uso un marker canonico padre antes del mirror Claude local'
rm "$WORK/.mefisto/pipeline/.plugin-root"
printf '%s\n' "$CANONICAL_ROOT" > "$CONSUMER/.mefisto/pipeline/.plugin-root"
printf '%s\n' "$OPENCODE_ROOT" > "$CONSUMER/.claude/pipeline/.plugin-root"
out="$(resolve_claude "$CONSUMER" '' "$WORK/claude-despues.trace" 2> "$WORK/claude-despues.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ROOT=$CANONICAL_PHYSICAL" ] && pass 'marker canonico Claude prevalece tras una sesion OpenCode' || fail 'marker canonico Claude no prevalecio'
BAD_CANONICAL="$WORK/plugin canonico malformado"; mkdir -p "$BAD_CANONICAL"; printf '%s\n' '{' > "$BAD_CANONICAL/mefisto-manifest.json"
printf '%s\n' "$BAD_CANONICAL" > "$CONSUMER/.mefisto/pipeline/.plugin-root"
printf '%s\n' "$LEGACY_ROOT" > "$CONSUMER/.claude/pipeline/.plugin-root"
resolve_claude "$SUBDIR" '' "$WORK/malformed.trace" > "$WORK/malformed.stdout" 2> "$WORK/malformed.err"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$WORK/malformed.trace" ] && contains "$(< "$WORK/malformed.err")" 'marker canonico invalida' 'marker canonico malformado no acepta el fallback' || fail 'marker canonico malformado no debio ejecutar codigo'
HYBRID_ROOT="$WORK/plugin OpenCode hibrido"; make_opencode_root "$HYBRID_ROOT"; mkdir -p "$HYBRID_ROOT/.claude-plugin" "$HYBRID_ROOT/scripts"
printf '%s\n' '{"name":"mefisto","version":"1.2.3"}' > "$HYBRID_ROOT/.claude-plugin/plugin.json"
printf '%s\n' '#!/bin/sh' 'printf invoked > "$MEFISTO_TEST_TRACE"' > "$HYBRID_ROOT/scripts/probe.sh"; chmod +x "$HYBRID_ROOT/scripts/probe.sh"
printf '%s\n' "$HYBRID_ROOT" > "$CONSUMER/.mefisto/pipeline/.plugin-root"
printf '%s\n' "$LEGACY_ROOT" > "$CONSUMER/.claude/pipeline/.plugin-root"
out="$(resolve_claude "$SUBDIR" '' "$WORK/hybrid.trace" 2> "$WORK/hybrid.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ROOT=$LEGACY_PHYSICAL" ] && [ -f "$WORK/hybrid.trace" ] && pass 'raiz OpenCode con metadata Claude espuria nunca se ejecuta' || fail 'se ejecuto una raiz identificada como OpenCode'
printf '%s\n' 'relativa/plugin' > "$CONSUMER/.mefisto/pipeline/.plugin-root"
resolve_claude "$SUBDIR" '' "$WORK/relative-marker.trace" > "$WORK/relative-marker.stdout" 2> "$WORK/relative-marker.err"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$WORK/relative-marker.trace" ] && contains "$(< "$WORK/relative-marker.err")" 'marker canonico invalida' 'marker canonico relativo aborta sin aceptar el fallback' || fail 'marker canonico relativo no debio ejecutar codigo'
printf '%s\n' "$OPENCODE_ROOT" > "$CONSUMER/.mefisto/pipeline/.plugin-root"
printf '%s\n' "$LEGACY_ROOT" > "$CONSUMER/.claude/pipeline/.plugin-root"
rm "$CONSUMER/.mefisto/pipeline/.plugin-root"
out="$(resolve_claude "$SUBDIR" '' "$WORK/legacy.trace" 2> "$WORK/legacy.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ROOT=$LEGACY_PHYSICAL" ] && pass 'marker legacy queda como fallback' || fail 'marker legacy no se resolvio'
printf '%s\n' "$OPENCODE_ROOT" > "$CONSUMER/.mefisto/pipeline/.plugin-root"; rm "$CONSUMER/.claude/pipeline/.plugin-root"
resolve_claude "$SUBDIR" '' "$WORK/only-opencode.trace" > "$WORK/only-opencode.stdout" 2> "$WORK/only-opencode.err"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$WORK/only-opencode.trace" ] && contains "$(< "$WORK/only-opencode.err")" 'distribucion OpenCode y no existe un mirror Claude valido' 'diagnostico distingue contaminacion sin mirror Claude' || fail 'contaminacion sin mirror Claude no debio ejecutar codigo'
rm "$CONSUMER/.mefisto/pipeline/.plugin-root"
resolve_claude "$SUBDIR" '' "$WORK/missing.trace" > "$WORK/missing.stdout" 2> "$WORK/missing.err"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$WORK/missing.trace" ] && contains "$(< "$WORK/missing.err")" 'no se encontro una raiz Claude valida' 'diagnostico distingue instalacion Claude faltante' || fail 'ausencia de distribucion Claude no debio ejecutar codigo'

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
make_agent profundo '[]' ',"profile":"deep"'
deep="$(render "$WORK/profundo.md")"; rc=$?
[ "$rc" -eq 0 ] && contains "$deep" 'model: "opus"' 'perfil deep declara model: "opus"' || fail 'perfil deep debio renderizar'
make_agent directiva '[]'; printf '%s\n' '{{mefisto:desconocida}}' >> "$WORK/directiva.md"
render_fails_without_output "$WORK/directiva.md" 'body: directiva sin mapping Claude' 'directiva desconocida falla sin salida parcial'

printf '%s\n' '[integracion] fallo atomico del generador'
FAKE="$WORK/repo"
mkdir -p "$FAKE/src/published/scripts/adapters" "$FAKE/src/published/scripts/lib" "$FAKE/src/published/contract" "$FAKE/src/published/agents" "$FAKE/src/published" "$FAKE/.claude-plugin" "$FAKE/dist/claude"
cp "$REPO_ROOT/src/published/scripts/generate-published-adapters.sh" "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$FAKE/src/published/scripts/"
cp "$REPO_ROOT/src/published/scripts/adapters/adapter-claude.sh" "$FAKE/src/published/scripts/adapters/"
cp "$REPO_ROOT/src/published/scripts/lib/adapter-claude.sh" "$REPO_ROOT/src/published/scripts/lib/jsonschema-lite.jq" "$REPO_ROOT/src/published/scripts/lib/effective-contract.sh" "$FAKE/src/published/scripts/lib/"
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
