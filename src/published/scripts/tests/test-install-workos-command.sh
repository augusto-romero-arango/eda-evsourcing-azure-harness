#!/usr/bin/env bash
# Contrato del comando install-workos neutral y sus proyecciones publicadas.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/install-workos.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/install-workos.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:install-workos.md"
MIRROR="$REPO_ROOT/commands/install-workos.md"
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
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "install-workos" and .profile == "balanced" and .arguments == "--domain <Dominio> [--env <env>]" and (keys | sort) == ["arguments", "description", "id", "kind", "profile"]' >/dev/null; then pass 'metadata sin agent ni capabilities'; else fail 'metadata neutral invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:launch-agent workos-identity-scaffolder ' 'delegacion puntual al agente de identidad'
contains "$body" 'WORKOS_API_KEY (fijo' 'el mensaje fija el app setting WORKOS_API_KEY'
contains "$body" '{{mefisto:command-doc seed-secret}}' 'lee el documento de seed-secret via command-doc'
contains "$body" '{{mefisto:run seed-secret.sh workos-api-key --domain <Dominio> --env <env> --from-github-secret WORKOS_API_KEY}}' 'invocacion neutral de seed-secret.sh'
contains "$body" '{{mefisto:command seed-secret}}' 'remite a seed-secret via command'
contains "$body" '{{mefisto:command install-apim}}' 'remite a install-apim via command'
contains "$body" '{{mefisto:command scaffold}}' 'remite a scaffold via command'
contains "$body" '¿Continuar? (s/n)' 'pide confirmacion explicita'
contains "$body" 'git switch -c install-workos/' 'rama unica compartida'
contains "$body" 'gh variable set WORKOS_CLIENT_ID' 'registra WORKOS_CLIENT_ID como variable'
contains "$body" 'gh secret list' 'verifica existencia de WORKOS_API_KEY'
contains "$body" 'NO VERIFICADO' 'degrada a NO VERIFICADO'
contains "$body" 'git push -u origin install-workos/' 'push de rama unica'
contains "$body" 'Nunca pidas, imprimas ni manejes el valor de `WORKOS_API_KEY`' 'regla: nunca manejar la API key'
contains "$body" 'Nunca ejecutes `terraform plan`' 'regla: nunca plan/apply'
for forbidden in 'claude --agent' '.claude/' 'CLAUDE_' '.plugin-root' 'plugins/cache' 'PLUGIN_SCRIPTS' 'PLUGIN_ROOT' 'commands/seed-secret.md'; do absent "$body" "$forbidden" "fuente sin token prohibido: $forbidden"; done
order_ok=1; prev=0
for marker in '{{mefisto:assert-consumer-repo}}' '¿Continuar? (s/n)' 'git switch -c install-workos/' '{{mefisto:launch-agent' '{{mefisto:run seed-secret.sh' 'gh pr create'; do
    n="$(line_of "$SOURCE" "$marker")"
    if [ -z "$n" ] || [ "$n" -le "$prev" ]; then order_ok=0; fi
    prev="${n:-$prev}"
done
[ "$order_ok" -eq 1 ] && pass 'orden: guard -> confirmacion -> rama -> agente -> seed-secret -> PR' || fail 'orden de pasos invalido'

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"
contains "$claude_body" 'model: "sonnet"' 'Claude materializa el perfil balanced'
absent "$opencode_body" 'model:' 'OpenCode no emite model'
absent "$opencode_body" 'subtask' 'OpenCode no emite subtask'
absent "$opencode_body" 'agent:' 'OpenCode no emite agent'
contains "$claude_body" 'agente `mefisto:workos-identity-scaffolder`' 'Claude delega puntualmente en mefisto:workos-identity-scaffolder'
contains "$opencode_body" 'agente `workos-identity-scaffolder`' 'OpenCode delega puntualmente en workos-identity-scaffolder'
contains "$claude_body" 'MEFISTO_RUNTIME=claude "${MEFISTO_PACKAGE_ROOT}/scripts/seed-secret.sh" workos-api-key' 'Claude invoca seed-secret.sh con su runtime'
contains "$opencode_body" 'MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/seed-secret.sh" workos-api-key' 'OpenCode invoca seed-secret.sh con su runtime'
contains "$claude_body" '"${MEFISTO_PACKAGE_ROOT}/commands/seed-secret.md"' 'Claude lee commands/seed-secret.md'
contains "$opencode_body" '"${MEFISTO_PACKAGE_ROOT}/commands/mefisto:seed-secret.md"' 'OpenCode lee commands/mefisto:seed-secret.md'
[ -f "$REPO_ROOT/dist/claude/commands/seed-secret.md" ] && pass 'existe la ruta leida por Claude' || fail 'falta la ruta leida por Claude'
[ -f "$REPO_ROOT/dist/opencode/commands/mefisto:seed-secret.md" ] && pass 'existe la ruta leida por OpenCode' || fail 'falta la ruta leida por OpenCode'
for rt in claude opencode; do
    out="$claude_body"; [ "$rt" = opencode ] && out="$opencode_body"
    forbidden_set=('claude --agent' 'plugins/cache' 'PLUGIN_SCRIPTS')
    [ "$rt" = opencode ] && forbidden_set+=('CLAUDE_' '.plugin-root')
    for forbidden in "${forbidden_set[@]}"; do absent "$out" "$forbidden" "$rt sin token de runtime: $forbidden"; done
done
contains "$claude_body" '/mefisto:install-apim' 'Claude resuelve command install-apim'
contains "$opencode_body" '/mefisto:install-apim' 'OpenCode resuelve command install-apim'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
for runtime in claude opencode; do
    dest="commands/install-workos.md"; [ "$runtime" = opencode ] && dest="commands/mefisto:install-workos.md"
    if jq -e --arg d "$dest" '.. | objects | select(.destination? == $d or .path? == $d)' "$REPO_ROOT/dist/$runtime/.mefisto-generated-assets.json" >/dev/null 2>&1 || grep -qF "$dest" "$REPO_ROOT/dist/$runtime/.mefisto-generated-assets.json"; then pass "inventario de dist/$runtime lo incluye"; else fail "inventario de dist/$runtime no lo incluye"; fi
done
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
