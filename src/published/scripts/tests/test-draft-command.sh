#!/usr/bin/env bash
# Contrato del comando draft neutral y sus dos proyecciones publicadas
# (issue #1641: migracion desde el formato Claude-only commands/draft.md).
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/draft.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/draft.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:draft.md"
MIRROR="$REPO_ROOT/commands/draft.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[fuente] contrato neutral'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "draft" and .profile == "fast" and .arguments == "<descripcion de la idea>" and (keys | sort) == ["arguments", "description", "id", "kind", "profile"]' >/dev/null; then pass 'metadata sin agent ni capabilities (CA-1)'; else fail 'metadata neutral invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"

echo '[fuente] guard y directivas (CA-2)'
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
guard_line="$(grep -nF '{{mefisto:assert-consumer-repo}}' "$SOURCE" | cut -d: -f1)"
operation_line="$(awk '/gh issue create/ { print NR; exit }' "$SOURCE")"
[ -n "$guard_line" ] && [ -n "$operation_line" ] && [ "$guard_line" -lt "$operation_line" ] && pass 'guard precede cualquier operacion' || fail 'guard no precede las operaciones'
contains "$body" 'domainLabels` de {{mefisto:config-path}}' 'domainLabels se lee desde config-path'
contains "$body" "jq -r '.repoSlug // empty' \"{{mefisto:config-path}}\"" 'repoSlug se lee desde config-path con el molde del planner'
contains "$body" 'HARNESS_REPO_SLUG="augusto-romero-arango/eda-evsourcing-azure-harness"' 'mismo default que el planner cuando el campo falta'
contains "$body" 'gh issue create -R "$HARNESS_REPO_SLUG"' 'draft cross-repo usa -R con el slug resuelto'
absent "$body" '${HARNESS_REPO_SLUG:-' 'HARNESS_REPO_SLUG ya no se lee como override de entorno'
for forbidden in 'Claude' 'OpenCode' '.claude/' '.opencode/' 'cache' 'model:' 'tools:' 'allowed-tools:' 'permission:' '.plugin-root' 'CLAUDE_' 'plugins/cache'; do absent "$body" "$forbidden" "fuente no publica token prohibido: $forbidden"; done

echo '[fuente] comportamiento conservado (CA-3/CA-4)'
contains "$body" '[verbo infinitivo] [que cosa]' 'formato de titulo conservado'
contains "$body" 'Maximo 70 caracteres' 'limite de 70 caracteres conservado'
contains "$body" 'tipo:feature` (default)' 'default tipo:feature conservado'
contains "$body" 'agrega ademas el label `bug`' 'label bug en defectos conservado'
contains "$body" 'default `tipo:refactor` para defectos' 'default tipo:refactor para defectos conservado'
contains "$body" '## Idea' 'body con seccion Idea'
contains "$body" '## Notas' 'body con seccion Notas'
contains "$body" 'estado:borrador' 'siempre estado:borrador'
contains "$body" 'Uso: {{mefisto:command draft}} [descripcion de la idea]' 'mensaje de uso vacio via directiva command'
contains "$body" 'agente `planner` (modo `refinar`)' 'confirmacion remite al agente planner en modo refinar'
contains "$body" '/mefisto-plan' 'regla cross-repo remite a /mefisto-plan para refinar en Mefisto'
contains "$body" 'NUNCA agregues `dom:` ni `estado:listo`' 'draft cross-repo nunca ofrece estado:listo'

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"
contains "$claude_body" 'model: "haiku"' 'Claude materializa el perfil fast (CA-5)'
absent "$opencode_body" 'model:' 'OpenCode no emite model (CA-5)'
contains "$claude_body" 'argument-hint: "<descripcion de la idea>"' 'Claude emite argument-hint'
absent "$opencode_body" 'argument-hint:' 'OpenCode no emite argument-hint propio de Claude'
contains "$claude_body" '/mefisto:draft' 'Claude resuelve la directiva command a /mefisto:draft'
contains "$opencode_body" '/mefisto:draft' 'OpenCode resuelve la directiva command a /mefisto:draft'
for content_label in claude opencode; do
    case "$content_label" in claude) content="$claude_body" ;; opencode) content="$opencode_body" ;; esac
    contains "$content" 'MEFISTO_CONFIG_PATH' "$content_label resuelve MEFISTO_CONFIG_PATH (CA-2)"
    contains "$content" 'HARNESS_REPO_SLUG=$(jq -r' "$content_label conserva la lectura de repoSlug"
    absent "$content" '${HARNESS_REPO_SLUG:-' "$content_label no reintroduce el override de entorno"
    absent "$content" 'plugins/cache' "$content_label no reimplementa token prohibido: plugins/cache"
done
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte (CA-5e)'; else fail 'mirror Claude diverge'; fi
contains "$(< "$MIRROR")" '<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/draft.md. No editar a mano. -->' 'mirror conserva marcador generado'
if jq -e '.assets[] | select(.destination == "commands/draft.md")' "$REPO_ROOT/dist/claude/.mefisto-generated-assets.json" >/dev/null; then pass 'inventariado en dist/claude/.mefisto-generated-assets.json'; else fail 'falta en el inventario Claude'; fi
if jq -e '.assets[] | select(.destination == "commands/mefisto:draft.md")' "$REPO_ROOT/dist/opencode/.mefisto-generated-assets.json" >/dev/null; then pass 'inventariado en dist/opencode/.mefisto-generated-assets.json'; else fail 'falta en el inventario OpenCode'; fi
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
