#!/usr/bin/env bash
# Contrato del comando install-auth neutral y sus proyecciones publicadas.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/install-auth.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/install-auth.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:install-auth.md"
MIRROR="$REPO_ROOT/commands/install-auth.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }
line_of() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }

echo '[fuente] contrato neutral'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "install-auth" and .profile == "balanced" and .arguments == "--identity-domain <Dominio> --domain <Dominio> [--domain <Dominio2> ...] [--env <env>] [--cors-origin <origin> ...]" and (keys | sort) == ["arguments", "description", "id", "kind", "profile"]' >/dev/null; then pass 'metadata sin agent ni capabilities'; else fail 'metadata neutral invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:command-doc install-workos}}' 'lee command-doc install-workos'
contains "$body" '{{mefisto:command-doc install-apim}}' 'lee command-doc install-apim'
for cmd in install-workos install-apim infra-base scaffold; do contains "$body" "{{mefisto:command $cmd}}" "remite a $cmd via command"; done
contains "$body" '{{mefisto:package-root}}/agents/domain-scaffolder.md' 'domain-scaffolder por package-root'
for forbidden in '.plugin-root' 'plugins/cache' 'commands/install-workos.md' 'commands/install-apim.md' '.claude/' 'CLAUDE_' 'PLUGIN_ROOT'; do absent "$body" "$forbidden" "fuente sin token prohibido: $forbidden"; done
order_ok=1; prev=0
for marker in '{{mefisto:assert-consumer-repo}}' 'FALTA la infraestructura base' 'FALTA: es la primera instalacion del gateway APIM' '¿Continuar? (s/n)' 'git switch -c "install-auth/' '### 5. Etapa 1' 'gh variable list' '### 7. Etapa 2' 'gh pr create'; do
    n="$(line_of "$SOURCE" "$marker")"
    if [ -z "$n" ] || [ "$n" -le "$prev" ]; then order_ok=0; printf '    orden: %s -> %s\n' "$marker" "${n:-ausente}"; fi
    prev="${n:-$prev}"
done
[ "$order_ok" -eq 1 ] && pass 'orden: guard -> prerequisitos -> CORS -> confirmacion -> rama -> etapa 1 -> gate -> etapa 2 -> PR' || fail 'orden de pasos invalido'
for marker in 'verbo QUERY' 'App Insights' 'codigo de exito documentado' 'headers de identidad'; do absent "$body" "$marker" "sin copia del checklist post-deploy: $marker"; done

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"
contains "$claude_body" 'model: "sonnet"' 'Claude materializa el perfil balanced'
absent "$opencode_body" 'model:' 'OpenCode no emite model'
contains "$opencode_body" 'agent: "command-entry-install-auth"' 'OpenCode liga el command-entry de install-auth'
contains "$opencode_body" 'subtask: false' 'OpenCode no convierte install-auth en subtask'
contains "$claude_body" '"${MEFISTO_PACKAGE_ROOT}/commands/install-workos.md"' 'Claude lee install-workos'
contains "$claude_body" '"${MEFISTO_PACKAGE_ROOT}/commands/install-apim.md"' 'Claude lee install-apim'
contains "$opencode_body" '"${MEFISTO_PACKAGE_ROOT}/commands/mefisto:install-workos.md"' 'OpenCode lee install-workos'
contains "$opencode_body" '"${MEFISTO_PACKAGE_ROOT}/commands/mefisto:install-apim.md"' 'OpenCode lee install-apim'
for id in install-workos install-apim; do
    [ -f "$REPO_ROOT/dist/claude/commands/$id.md" ] && pass "existe dist/claude/commands/$id.md" || fail "falta dist/claude/commands/$id.md"
    [ -f "$REPO_ROOT/dist/opencode/commands/mefisto:$id.md" ] && pass "existe dist/opencode/commands/mefisto:$id.md" || fail "falta dist/opencode/commands/mefisto:$id.md"
done
for rt in claude opencode; do
    out="$claude_body"; [ "$rt" = opencode ] && out="$opencode_body"
    forbidden_set=('plugins/cache')
    [ "$rt" = opencode ] && forbidden_set+=('CLAUDE_' '.claude/' '.plugin-root')
    for forbidden in "${forbidden_set[@]}"; do absent "$out" "$forbidden" "$rt sin token de runtime: $forbidden"; done
done
contains "$claude_body" '/mefisto:install-workos' 'Claude resuelve command install-workos'
contains "$opencode_body" '/mefisto:install-apim' 'OpenCode resuelve command install-apim'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
for runtime in claude opencode; do
    dest="commands/install-auth.md"; [ "$runtime" = opencode ] && dest="commands/mefisto:install-auth.md"
    if grep -qF "$dest" "$REPO_ROOT/dist/$runtime/.mefisto-generated-assets.json"; then pass "inventario de dist/$runtime lo incluye"; else fail "inventario de dist/$runtime no lo incluye"; fi
done
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
