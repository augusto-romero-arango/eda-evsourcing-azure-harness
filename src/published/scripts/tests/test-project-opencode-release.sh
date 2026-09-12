#!/usr/bin/env bash
# Pruebas aisladas de la proyeccion global: Bash 3.2, jq y HOME temporales.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
PROJECTOR="$REPO_ROOT/src/published/scripts/project-opencode-release.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_rc() { [ "$1" -eq "$2" ] && pass "$3" || fail "$3 (exit $1)"; }
assert_projection_status() {
    local output="$1" expected="$2" active="$3" ledger="$4" label="$5"
    jq -e --arg expected "$expected" --arg config "$XDG_CONFIG_HOME/opencode" --argjson active "$active" --argjson ledger "$ledger" \
        '.schemaVersion == 1 and .status == $expected and .configRoot == $config and .activeVersion == $active and .ledgerRelease == $ledger and (keys == ["activeVersion", "configRoot", "ledgerRelease", "schemaVersion", "status"])' <<< "$output" >/dev/null && pass "$label" || fail "$label"
}
make_release() {
    local version="$1" root="$XDG_DATA_HOME/mefisto/releases/$1"
    mkdir -p "$root/commands" "$root/agents" "$root/plugins" "$root/skills/mefisto-projections" "$root/skills/mefisto-comment-cleanup"
    printf 'comando %s\n' "$version" > "$root/commands/mefisto:tooling.md"
    printf 'agente %s\n' "$version" > "$root/agents/mefisto-writer.md"
    printf 'plugin %s\n' "$version" > "$root/plugins/mefisto.js"
    printf 'mcp %s\n' "$version" > "$root/plugins/mefisto-mcp.js"
    printf '%s\n' '---' 'name: mefisto-projections' 'description: Proyecciones.' '---' '[read APIs](read-apis.md)' > "$root/skills/mefisto-projections/SKILL.md"
    printf 'recurso %s\n' "$version" > "$root/skills/mefisto-projections/read-apis.md"
    printf '%s\n' '---' 'name: mefisto-comment-cleanup' 'description: Comentarios.' '---' > "$root/skills/mefisto-comment-cleanup/SKILL.md"
    jq -n --arg version "$version" '{schemaVersion:1,runtime:"opencode",version:$version,commit:"0123456789abcdef0123456789abcdef01234567",minimumRuntimeVersion:"1.18.29"}' > "$root/mefisto-manifest.json"
}
activate_fixture() { rm -f "$XDG_DATA_HOME/mefisto/active"; ln -s "releases/$1" "$XDG_DATA_HOME/mefisto/active"; }

printf '[pre] sintaxis y entorno temporal\n'
bash -n "$PROJECTOR" && pass 'proyector Bash valido' || fail 'proyector Bash invalido'
HOME="$WORK/home con espacios"; XDG_DATA_HOME="$HOME/datos"; XDG_CONFIG_HOME="$HOME/configuracion"; export HOME XDG_DATA_HOME XDG_CONFIG_HOME
mkdir -p "$HOME"; make_release 1.2.3; make_release 2.0.0
rm -f "$XDG_DATA_HOME/mefisto/releases/2.0.0/plugins/mefisto.js" "$XDG_DATA_HOME/mefisto/releases/2.0.0/plugins/mefisto-mcp.js" "$XDG_DATA_HOME/mefisto/releases/2.0.0/skills/mefisto-projections/SKILL.md" "$XDG_DATA_HOME/mefisto/releases/2.0.0/skills/mefisto-projections/read-apis.md" "$XDG_DATA_HOME/mefisto/releases/2.0.0/skills/mefisto-comment-cleanup/SKILL.md"
activate_fixture 1.2.3
mkdir -p "$XDG_CONFIG_HOME/opencode/commands" "$XDG_CONFIG_HOME/opencode/plugins"
printf '%s\n' '{"provider":{"usuario":{}},"model":"usuario/modelo","permission":{"bash":"deny"},"mcp":{"propio":{"type":"remote","url":"https://example.invalid"}}}' > "$XDG_CONFIG_HOME/opencode/opencode.json"
CONFIG_SHA="$(shasum -a 256 "$XDG_CONFIG_HOME/opencode/opencode.json")"; printf 'propio\n' > "$XDG_CONFIG_HOME/opencode/commands/propio.md"
STATUS="$(bash "$PROJECTOR" projection-status)"; rc=$?; assert_rc "$rc" 0 'estado disabled no exige proyeccion ni release ajena'; assert_projection_status "$STATUS" disabled '"1.2.3"' null 'estado disabled es JSON versionado y estable'
bash "$PROJECTOR" project >/dev/null; assert_rc "$?" 0 'proyecta la release activa en XDG_CONFIG_HOME'
[ -L "$XDG_CONFIG_HOME/opencode/commands/mefisto:tooling.md" ] && [ -L "$XDG_CONFIG_HOME/opencode/agents/mefisto-writer.md" ] && [ -L "$XDG_CONFIG_HOME/opencode/plugins/mefisto-mcp.js" ] && [ -L "$XDG_CONFIG_HOME/opencode/skills/mefisto-projections/SKILL.md" ] && [ -L "$XDG_CONFIG_HOME/opencode/skills/mefisto-comment-cleanup/SKILL.md" ] && grep -q '^name: mefisto-projections$' "$XDG_CONFIG_HOME/opencode/skills/mefisto-projections/SKILL.md" && grep -q '^name: mefisto-comment-cleanup$' "$XDG_CONFIG_HOME/opencode/skills/mefisto-comment-cleanup/SKILL.md" && [ "$(< "$XDG_CONFIG_HOME/opencode/skills/mefisto-projections/read-apis.md")" = 'recurso 1.2.3' ] && pass 'proyecta plugins MCP, Skills nativos y recursos relativos sin checkout' || fail 'faltan enlaces globales de plugin o Skills'
[ "$(shasum -a 256 "$XDG_CONFIG_HOME/opencode/opencode.json")" = "$CONFIG_SHA" ] && [ -f "$XDG_CONFIG_HOME/opencode/commands/propio.md" ] && pass 'conserva providers, modelos, permisos, MCP y comandos propios' || fail 'altero estado ajeno'
bash "$PROJECTOR" project >/dev/null; assert_rc "$?" 0 'reproyectar la misma version es idempotente'
STATUS="$(bash "$PROJECTOR" projection-status)"; rc=$?; assert_rc "$rc" 0 'estado enabled es exitoso'; assert_projection_status "$STATUS" enabled '"1.2.3"' '"1.2.3"' 'estado enabled verifica enlaces y ledger'
STATUS_REPEAT="$(bash "$PROJECTOR" projection-status)"; [ "$STATUS" = "$STATUS_REPEAT" ] && pass 'estado JSON es idempotente byte a byte' || fail 'estado JSON no es idempotente'
activate_fixture 2.0.0; STATUS="$(bash "$PROJECTOR" projection-status)"; rc=$?; assert_rc "$rc" 0 'cambiar active deja proyeccion stale sin repararla'; assert_projection_status "$STATUS" stale '"2.0.0"' '"1.2.3"' 'estado stale distingue deriva de desactivacion'
OUTPUT="$(bash "$PROJECTOR" project)"; assert_rc "$?" 0 'cambiar active reproyecta'
grep -q '2.0.0' "$XDG_CONFIG_HOME/opencode/commands/mefisto:tooling.md" && pass 'enlace estable sigue la nueva release activa sin residuos' || fail 'no siguio la nueva release'
[ ! -e "$XDG_CONFIG_HOME/opencode/plugins/mefisto.js" ] && [ ! -e "$XDG_CONFIG_HOME/opencode/plugins/mefisto-mcp.js" ] && [ ! -e "$XDG_CONFIG_HOME/opencode/skills/mefisto-projections/SKILL.md" ] && [ ! -e "$XDG_CONFIG_HOME/opencode/skills/mefisto-comment-cleanup/SKILL.md" ] && pass 'retira plugins MCP y capacidades ausentes en la nueva release' || fail 'dejo residuos de la release anterior'
printf '%s\n' "$OUTPUT" | grep -q 'DEGRADACION VISIBLE:.*Skills' && printf '%s\n' "$OUTPUT" | grep -q 'DEGRADACION VISIBLE:.*plugins/hooks' && printf '%s\n' "$OUTPUT" | grep -q 'DEGRADACION VISIBLE:.*plugin MCP bundleado' && pass 'reporta todas las capacidades ausentes o no representables' || fail 'oculto una degradacion'
printf 'colision\n' > "$XDG_CONFIG_HOME/opencode/agents/mefisto-ajeno.md"; printf 'ajeno\n' > "$XDG_DATA_HOME/mefisto/releases/2.0.0/agents/mefisto-ajeno.md"
bash "$PROJECTOR" project >/dev/null 2>&1; assert_rc "$?" 1 'conflicto de nombre aborta sin sobrescribir'
grep -q colision "$XDG_CONFIG_HOME/opencode/agents/mefisto-ajeno.md" && pass 'conflicto preserva archivo propio' || fail 'conflicto sobrescribio archivo propio'
rm "$XDG_DATA_HOME/mefisto/releases/2.0.0/agents/mefisto-ajeno.md"; bash "$PROJECTOR" deactivate >/dev/null; assert_rc "$?" 0 'desactivacion retira la proyeccion'
[ ! -e "$XDG_CONFIG_HOME/opencode/commands/mefisto:tooling.md" ] && [ -f "$XDG_CONFIG_HOME/opencode/commands/propio.md" ] && [ -f "$XDG_CONFIG_HOME/opencode/opencode.json" ] && [ -d "$XDG_CONFIG_HOME/opencode/plugins" ] && pass 'desactivacion restaura archivos y directorios previos' || fail 'desactivacion no restauro el estado previo'
OPENCODE_CONFIG_DIR="$WORK/override" XDG_CONFIG_HOME="$WORK/no-usar" bash "$PROJECTOR" project >/dev/null; assert_rc "$?" 0 'OPENCODE_CONFIG_DIR prevalece sobre XDG_CONFIG_HOME'
[ -L "$WORK/override/commands/mefisto:tooling.md" ] && [ ! -e "$WORK/no-usar/opencode/commands/mefisto:tooling.md" ] && pass 'usa exclusivamente el override de configuracion' || fail 'resolucion de config incorrecta'
OPENCODE_CONFIG_DIR="$WORK/override" bash "$PROJECTOR" deactivate >/dev/null
[ ! -e "$WORK/override" ] && pass 'retira la raiz que Mefisto creo y sus directorios anidados' || fail 'dejo directorios creados por Mefisto'
unset XDG_CONFIG_HOME OPENCODE_CONFIG_DIR
bash "$PROJECTOR" project >/dev/null; assert_rc "$?" 0 'HOME usa .config/opencode tambien en macOS'
[ -L "$HOME/.config/opencode/commands/mefisto:tooling.md" ] && pass 'fallback HOME correcto' || fail 'fallback HOME incorrecto'
bash "$PROJECTOR" deactivate >/dev/null
OPENCODE_CONFIG_DIR='' bash "$PROJECTOR" project >/dev/null 2>&1; assert_rc "$?" 1 'override definido pero vacio aborta'

mkdir -p "$WORK/ledger-hostil"; ln -s "$WORK/afuera" "$WORK/ledger-hostil/.mefisto-projection.json"
OPENCODE_CONFIG_DIR="$WORK/ledger-hostil" bash "$PROJECTOR" project >/dev/null 2>&1; assert_rc "$?" 1 'ledger simbolico ajeno aborta'

STATUS="$(OPENCODE_CONFIG_DIR="$WORK/ledger-hostil" bash "$PROJECTOR" projection-status)"; rc=$?; assert_rc "$rc" 1 'ledger simbolico informa conflicto sin repararlo'; jq -e --arg config "$WORK/ledger-hostil" '.schemaVersion == 1 and .status == "conflict" and .configRoot == $config and .ledgerRelease == null' <<< "$STATUS" >/dev/null && pass 'conflicto conserva JSON parseable y no sensible' || fail 'conflicto no conserva JSON parseable'
OPENCODE_CONFIG_DIR="$WORK/enlaces-conflictivos" bash "$PROJECTOR" project >/dev/null
rm "$WORK/enlaces-conflictivos/commands/mefisto:tooling.md"
STATUS="$(OPENCODE_CONFIG_DIR="$WORK/enlaces-conflictivos" bash "$PROJECTOR" projection-status)"; rc=$?; assert_rc "$rc" 1 'enlace administrado ausente informa conflicto'; jq -e '.status == "conflict"' <<< "$STATUS" >/dev/null && pass 'enlace ausente conserva salida JSON' || fail 'enlace ausente no conserva salida JSON'
ln -s "$XDG_DATA_HOME/mefisto/active/commands/mefisto:tooling.md" "$WORK/enlaces-conflictivos/commands/mefisto:tooling.md"; rm "$WORK/enlaces-conflictivos/commands/mefisto:tooling.md"; ln -s "$WORK/ajeno" "$WORK/enlaces-conflictivos/commands/mefisto:tooling.md"
STATUS="$(OPENCODE_CONFIG_DIR="$WORK/enlaces-conflictivos" bash "$PROJECTOR" projection-status)"; rc=$?; assert_rc "$rc" 1 'enlace administrado retargeteado informa conflicto'; jq -e '.status == "conflict"' <<< "$STATUS" >/dev/null && pass 'enlace retargeteado conserva salida JSON' || fail 'enlace retargeteado no conserva salida JSON'
PROJECTION_STATUS_SOURCE="$(awk '/^projection_status\(\)/,/^case /' "$PROJECTOR")"
printf '%s\n' "$PROJECTION_STATUS_SOURCE" | grep -Eq 'opencode\.json|auth|provider|model|token' && fail 'estado no debe leer opencode.json ni stores de auth' || pass 'estado no inspecciona opencode.json ni stores de auth'

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
