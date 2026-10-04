#!/usr/bin/env bash
# Contrato del comando seed-secret neutral y sus dos proyecciones publicadas.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/seed-secret.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/seed-secret.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:seed-secret.md"
MIRROR="$REPO_ROOT/commands/seed-secret.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[fuente] contrato neutral'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "seed-secret" and .profile == "balanced" and .arguments == "<nombre> --domain <Dominio> (--from-output <output> | --from-github-secret <NOMBRE>) [--env <env>]" and (keys | sort) == ["arguments", "description", "id", "kind", "profile"]' >/dev/null; then pass 'metadata sin agent ni capabilities'; else fail 'metadata neutral invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:run seed-secret.sh <nombre> --domain <Dominio> --env <env> <flag-de-fuente> <valor>}}' 'invocacion neutral del script'
contains "$body" 'Registro: <ruta>' 'extrae la linea Registro'
contains "$body" '{{mefisto:command scaffold}}' 'remite a scaffold via directiva command'
contains "$body" '{{mefisto:package-root}}/agents/domain-scaffolder.md' 'molde del HCL via package-root'
contains "$body" '¿Continuar? (s/n)' 'pide confirmacion explicita'
contains "$body" 'git switch -c seed-secret/' 'crea rama si se esta en main'
contains "$body" 'detente sin editar ningun otro archivo' 'se detiene si el script falla'
contains "$body" 'init -backend=false' 'solo init -backend=false'
for command in '(cd "infra/environments/<env>" && terraform fmt -recursive ../..)' '(cd "infra/environments/<env>" && terraform init -backend=false)' '(cd "infra/environments/<env>" && terraform validate)'; do
    contains "$body" "$command" "validacion local usa subshell para $command"
done
absent "$body" 'terraform -chdir=' 'validacion local no usa -chdir'
contains "$body" 'command -v terraform' 'consulta canonica de disponibilidad'
contains "$body" 'Key Vault Secrets User' 'verifica Secrets User'
contains "$body" 'Nunca toques' 'regla: nunca Secrets Officer'
contains "$body" 'Nunca ejecutes' 'regla: nunca plan/apply'
contains "$body" 'azurerm_key_vault_secret' 'regla: nunca azurerm_key_vault_secret'
contains "$body" 'Nunca crees el dominio' 'regla: nunca crear dominio'
for forbidden in '.claude/' 'CLAUDE_' '.plugin-root' 'plugins/cache' 'PLUGIN_SCRIPTS' 'PLUGIN_ROOT'; do absent "$body" "$forbidden" "fuente no publica token prohibido: $forbidden"; done
guard_line="$(grep -nF '{{mefisto:assert-consumer-repo}}' "$SOURCE" | cut -d: -f1)"
confirm_line="$(grep -nF '¿Continuar? (s/n)' "$SOURCE" | cut -d: -f1)"
run_line="$(grep -nF '{{mefisto:run seed-secret.sh' "$SOURCE" | cut -d: -f1)"
edit_line="$(grep -nF 'git add' "$SOURCE" | cut -d: -f1)"
[ -n "$guard_line" ] && [ -n "$confirm_line" ] && [ "$guard_line" -lt "$confirm_line" ] && pass 'guard precede la confirmacion' || fail 'guard no precede la confirmacion'
[ -n "$confirm_line" ] && [ -n "$run_line" ] && [ "$confirm_line" -lt "$run_line" ] && [ "$run_line" -lt "$edit_line" ] && pass 'confirmacion precede a cualquier escritura' || fail 'confirmacion no precede las escrituras'

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"
contains "$claude_body" 'MEFISTO_RUNTIME=claude "${MEFISTO_PACKAGE_ROOT}/scripts/seed-secret.sh"' 'Claude invoca seed-secret.sh con su runtime'
contains "$opencode_body" 'MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/seed-secret.sh"' 'OpenCode invoca seed-secret.sh con su runtime'
absent "$claude_body" 'MEFISTO_RUNTIME=opencode' 'Claude no fija el runtime OpenCode'
absent "$opencode_body" 'MEFISTO_RUNTIME=claude' 'OpenCode no fija el runtime Claude'
contains "$claude_body" 'model: "sonnet"' 'Claude materializa el perfil balanced'
absent "$opencode_body" 'model:' 'OpenCode no emite model'
absent "$claude_body" 'plugins/cache' 'Claude sin plugins/cache'
absent "$opencode_body" 'plugins/cache' 'OpenCode sin plugins/cache'
absent "$opencode_body" '.plugin-root' 'OpenCode sin .plugin-root'
claude_invocation="$(printf '%s\n' "$claude_body" | grep -F 'scripts/seed-secret.sh"')"
absent "$claude_invocation" '.plugin-root' 'invocacion Claude sin lookup legacy .plugin-root'
absent "$claude_invocation" 'PLUGIN_SCRIPTS' 'invocacion Claude sin PLUGIN_SCRIPTS'
contains "$claude_body" '/mefisto:scaffold' 'Claude resuelve command scaffold'
contains "$opencode_body" '/mefisto:scaffold' 'OpenCode resuelve command scaffold'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
contains "$(< "$MIRROR")" '<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/seed-secret.md. No editar a mano. -->' 'mirror conserva marcador generado'
for f in "$CLAUDE" "$OPENCODE"; do
    guard_l="$(grep -nF 'aborta si existe `src/internal/scripts/generate-internal-adapters.sh`' "$f" | head -1 | cut -d: -f1)"
    run_l="$(grep -nF 'scripts/seed-secret.sh' "$f" | head -1 | cut -d: -f1)"
    conf_l="$(grep -nF '¿Continuar? (s/n)' "$f" | head -1 | cut -d: -f1)"
    [ -n "$guard_l" ] && [ -n "$conf_l" ] && [ "$guard_l" -lt "$conf_l" ] && pass "guard antes de la confirmacion en ${f#"$REPO_ROOT/"}" || fail "guard no precede la confirmacion en ${f#"$REPO_ROOT/"}"
    [ -n "$conf_l" ] && [ -n "$run_l" ] && [ "$conf_l" -lt "$run_l" ] && pass "confirmacion antes del script en ${f#"$REPO_ROOT/"}" || fail "confirmacion no precede al script en ${f#"$REPO_ROOT/"}"
done

echo '[assets] seed-secret.sh empaquetado'
for runtime in claude opencode; do
    dist="$REPO_ROOT/dist/$runtime/scripts/seed-secret.sh"
    if [ -x "$dist" ]; then pass "seed-secret.sh ejecutable en dist/$runtime"; else fail "falta seed-secret.sh ejecutable en dist/$runtime"; fi
    if cmp -s "$REPO_ROOT/scripts/seed-secret.sh" "$dist"; then pass "dist/$runtime identico a la fuente"; else fail "dist/$runtime diverge de la fuente"; fi
    if jq -e '.assets[] | select(.destination == "scripts/seed-secret.sh")' "$REPO_ROOT/dist/$runtime/.mefisto-generated-assets.json" >/dev/null 2>&1; then pass "inventario de dist/$runtime lo incluye"; else fail "inventario de dist/$runtime no lo incluye"; fi
done
[ -f "$REPO_ROOT/dist/opencode/scripts/_pipeline-common.sh" ] && pass '_pipeline-common.sh hermano presente' || fail '_pipeline-common.sh hermano ausente'
smoke_dir="$(mktemp -d)"; git -C "$smoke_dir" init -q
smoke="$(cd "$smoke_dir" && bash "$REPO_ROOT/dist/opencode/scripts/seed-secret.sh" 2>&1)"; smoke_rc=$?
rm -rf "$smoke_dir"
case "$smoke" in
    *"No such file"*|*"command not found"*|*"unbound variable"*) fail 'seed-secret.sh distribuido no resuelve _pipeline-common.sh'; printf '%s\n' "$smoke" | head -3 ;;
    *"Uso: "*) [ "$smoke_rc" -eq 1 ] && pass 'seed-secret.sh distribuido resuelve _pipeline-common.sh y responde el uso fuera del checkout' || fail "seed-secret.sh distribuido: rc inesperado $smoke_rc" ;;
    *) fail 'seed-secret.sh distribuido no imprimio el uso esperado'; printf '%s\n' "$smoke" | head -3 ;;
esac
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
