#!/usr/bin/env bash
# Contrato del agente planner neutral y sus dos proyecciones publicadas
# (issue #1640: migracion desde agents/planner.md hand-escrito Claude-only).
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/agents/planner.md"
CLAUDE="$REPO_ROOT/dist/claude/agents/planner.md"
OPENCODE="$REPO_ROOT/dist/opencode/agents/planner.md"
MIRROR="$REPO_ROOT/agents/planner.md"
FIELD_NOTE_SOURCE="$REPO_ROOT/scripts/field-note.sh"
FIELD_NOTE_OPENCODE="$REPO_ROOT/dist/opencode/scripts/field-note.sh"
FIELD_NOTE_CLAUDE="$REPO_ROOT/dist/claude/scripts/field-note.sh"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[fuente] contrato neutral, perfil, skill y mcp'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "agent" and .id == "planner" and .mode == "all" and .profile == "deep" and (.capabilities | index("read") != null and index("edit") != null and index("shell") != null) and .skills == ["projections"] and .mcp == ["microsoft-learn"]' >/dev/null; then
    pass 'metadata declara agent/planner/all/deep/skills-projections/mcp-microsoft-learn'
else
    fail 'metadata neutral invalida'
fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:package-root}}/docs/adr/' 'resuelve ADRs via package-root'
contains "$body" '{{mefisto:skill-root projections}}' 'resuelve recursos de Nivel 3 del Skill via skill-root'
contains "$body" '{{mefisto:config-path}}' 'lee el config efectivo via config-path'
contains "$body" '{{mefisto:state-path summaries}}' 'redacta los borradores bajo state-path summaries'
contains "$body" '{{mefisto:run field-note.sh' 'el cierre delega en field-note.sh via directiva run'
absent "$body" '/tmp/planner-' 'fuente no escribe borradores en /tmp'
absent "$body" '.plugin-root' 'fuente no resuelve .plugin-root'
absent "$body" 'plugins/cache' 'fuente no busca el cache del marketplace'
absent "$body" '.claude/' 'fuente no referencia rutas .claude/'
absent "$body" 'CLAUDE_' 'fuente no referencia variables CLAUDE_*'
absent "$body" 'PLUGIN_ROOT' 'fuente no reconstruye PLUGIN_ROOT a mano'

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"

contains "$claude_body" 'name: "planner"' 'Claude expone el id del agente'
contains "$claude_body" 'model: "opus"' 'Claude materializa el perfil deep como opus'
contains "$claude_body" 'skills: ["projections"]' 'Claude declara el Skill projections'
contains "$claude_body" 'mcp__plugin_mefisto_microsoft-learn__*' 'Claude declara el matcher MCP scoped de microsoft-learn (plugin bundleado)'
absent "$opencode_body" 'model:' 'OpenCode no emite model (hereda la configuracion interactiva del usuario)'
contains "$opencode_body" 'mode: "all"' 'OpenCode conserva mode all'
contains "$opencode_body" 'mefisto-projections' 'OpenCode solicita la carga nativa de mefisto-projections'
contains "$opencode_body" '"microsoft-learn_*":true' 'OpenCode habilita las tools de microsoft-learn'
contains "$opencode_body" '"terraform_*":false' 'OpenCode deniega las tools de terraform (no solicitado)'

# El preambulo compartido de resolucion de MEFISTO_PACKAGE_ROOT/MEFISTO_CONFIG_PATH
# (identico en todo artefacto que use {{mefisto:package-root}}/{{mefisto:config-path}},
# p. ej. merge.md) SI menciona '.plugin-root' y el fallback legacy '.claude/harness.config.json'
# como parte de su propia mecanica de resolucion -- eso no es responsabilidad de este
# agente y queda fuera de este chequeo. Lo que se exige es que el CUERPO PROPIO de
# planner (fuera de ese preambulo compartido) no reimplemente esa mecanica a mano.
for body_var in claude_body opencode_body; do
    text="${!body_var}"
    absent "$text" '/tmp/planner-' "salida $body_var no escribe borradores en /tmp"
    absent "$text" 'plugins/cache' "salida $body_var no busca el cache del marketplace"
done
absent "$claude_body" 'CONFIG="$REPO_ROOT' 'el cuerpo propio no reconstruye la ruta del config a mano (CONFIG=$REPO_ROOT/...)'
absent "$opencode_body" 'CONFIG="$REPO_ROOT' 'el cuerpo propio no reconstruye la ruta del config a mano (CONFIG=$REPO_ROOT/...)'

echo '[cierre] invocacion de field-note.sh'
contains "$claude_body" '"${MEFISTO_PACKAGE_ROOT}/scripts/field-note.sh"' 'Claude invoca field-note.sh via MEFISTO_PACKAGE_ROOT'
contains "$opencode_body" '"${MEFISTO_PACKAGE_ROOT}/scripts/field-note.sh"' 'OpenCode invoca field-note.sh via MEFISTO_PACKAGE_ROOT'
contains "$claude_body" 'MEFISTO_RUNTIME=claude "${MEFISTO_PACKAGE_ROOT}/scripts/field-note.sh"' 'Claude fija su propio runtime al invocar field-note.sh'
contains "$opencode_body" 'MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/field-note.sh"' 'OpenCode fija su propio runtime al invocar field-note.sh'
contains "$claude_body" '--session-id "$SESSION_ID" --timestamp "$CLOSING_TIMESTAMP" --field-note "$FIELD_NOTE_LOCAL"' 'Claude conserva los flags obligatorios del cierre'
contains "$opencode_body" '--session-id "$SESSION_ID" --timestamp "$CLOSING_TIMESTAMP" --field-note "$FIELD_NOTE_LOCAL"' 'OpenCode conserva los flags obligatorios del cierre'

echo '[scripts/field-note.sh] paridad de la clausura de tooling'
if [ -x "$FIELD_NOTE_SOURCE" ]; then pass 'scripts/field-note.sh conserva el bit de ejecucion'; else fail 'scripts/field-note.sh sin bit de ejecucion'; fi
if [ -f "$FIELD_NOTE_OPENCODE" ] && cmp -s "$FIELD_NOTE_SOURCE" "$FIELD_NOTE_OPENCODE"; then
    pass 'dist/opencode/scripts/field-note.sh es identico a scripts/field-note.sh'
else
    fail 'dist/opencode/scripts/field-note.sh diverge de scripts/field-note.sh'
fi
if [ -f "$FIELD_NOTE_CLAUDE" ] && cmp -s "$FIELD_NOTE_SOURCE" "$FIELD_NOTE_CLAUDE"; then
    pass 'dist/claude/scripts/field-note.sh es identico a scripts/field-note.sh'
else
    fail 'dist/claude/scripts/field-note.sh diverge de scripts/field-note.sh'
fi
for inventory in "$REPO_ROOT/dist/claude/.mefisto-generated-assets.json" "$REPO_ROOT/dist/opencode/.mefisto-generated-assets.json"; do
    if jq -e '.assets[] | select(.destination == "scripts/field-note.sh" and .mode == "0755")' "$inventory" >/dev/null 2>&1; then
        pass "$(basename "$(dirname "$inventory")")/.mefisto-generated-assets.json lista scripts/field-note.sh en 0755"
    else
        fail "$(basename "$(dirname "$inventory")")/.mefisto-generated-assets.json no lista scripts/field-note.sh en 0755"
    fi
done

echo '[mirror] agents/planner.md pasa a generado'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
contains "$(< "$MIRROR")" '<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/agents/planner.md. No editar a mano. -->' 'mirror conserva marcador generado'
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
