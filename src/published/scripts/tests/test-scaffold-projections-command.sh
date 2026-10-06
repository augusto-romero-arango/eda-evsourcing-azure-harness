#!/usr/bin/env bash
# Contrato del comando scaffold-projections neutral y sus proyecciones publicadas.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/scaffold-projections.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/scaffold-projections.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:scaffold-projections.md"
MIRROR="$REPO_ROOT/commands/scaffold-projections.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[fuente] contrato neutral'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "scaffold-projections" and .profile == "fast" and (keys | sort) == ["description", "id", "kind", "profile"]' >/dev/null; then pass 'metadata sin agent, arguments ni capabilities'; else fail 'metadata neutral invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:config-path}}' 'lee projections.enabled desde config-path'
contains "$body" "jq -r '.projections.enabled'" 'gate lee projections.enabled'
absent "$(grep -F "jq -r '.projections.enabled'" "$SOURCE")" '//' 'filtro jq sin //'
contains "$body" '{{mefisto:launch-agent projections-scaffolder ' 'delegacion puntual a projections-scaffolder'
guard_line="$(grep -nF '{{mefisto:assert-consumer-repo}}' "$SOURCE" | cut -d: -f1)"
gate_line="$(grep -nF "jq -r '.projections.enabled'" "$SOURCE" | head -1 | cut -d: -f1)"
launch_line="$(grep -nF '{{mefisto:launch-agent' "$SOURCE" | head -1 | cut -d: -f1)"
[ -n "$guard_line" ] && [ -n "$gate_line" ] && [ -n "$launch_line" ] && [ "$guard_line" -lt "$gate_line" ] && [ "$gate_line" -lt "$launch_line" ] && pass 'guard y gate del token preceden la delegacion' || fail 'guard/gate no preceden la delegacion'
contains "$body" '**ausente**' 'distingue token ausente'
contains "$body" '**deshabilitado**' 'distingue token deshabilitado'
contains "$body" '"projections": { "enabled": true }' 'mensaje con el bloque JSON'
contains "$body" 'Se va a generar el worker de proyecciones' 'aviso de lo que se genera'
contains "$body" 'domain-scaffolder' 'recordatorio domain-scaffolder'
contains "$body" 'projection-test-writer/projection-implementer' 'recordatorio projection-test-writer/implementer'
contains "$body" 'deploy-projections.yml solo publica la imagen' 'recordatorio orden de deploy-projections.yml'
contains "$body" '{{mefisto:command onboard}}' 'referencia onboard'
contains "$body" '{{mefisto:command infra-base}}' 'referencia infra-base'
contains "$body" '.mefisto/harness.config.json' 'ruta canonica del config'
contains "$body" 'No generes nada tu mismo' 'regla: no generar'
contains "$body" 'nunca registra un store de dominio' 'regla: nunca registra stores'
contains "$body" 'idempotente' 'regla: idempotente'
for forbidden in 'claude --agent' 'Claude' 'OpenCode' '.claude/' '.opencode/' '.plugin-root' 'CLAUDE_' 'plugins/cache' 'model:' 'allowed-tools:'; do absent "$body" "$forbidden" "fuente sin token prohibido: $forbidden"; done

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"
contains "$claude_body" 'model: "haiku"' 'Claude materializa el perfil fast'
absent "$opencode_body" 'model:' 'OpenCode no emite model'
contains "$opencode_body" 'subtask: false' 'OpenCode no convierte scaffold-projections en subtask'
opencode_fm="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$OPENCODE")"
contains "$opencode_fm" 'agent: "command-entry-scaffold-projections"' 'OpenCode liga el command-entry de scaffold-projections en el frontmatter'
contains "$claude_body" 'agente `mefisto:projections-scaffolder`' 'Claude delega con la tool Task'
contains "$opencode_body" 'tool `task` con el agente `projections-scaffolder`' 'OpenCode delega con la tool task'
contains "$claude_body" '/mefisto:infra-base' 'Claude resuelve command infra-base'
contains "$opencode_body" '/mefisto:onboard' 'OpenCode resuelve command onboard'
absent "$claude_body" 'claude --agent' 'salida Claude sin claude --agent'
absent "$opencode_body" 'claude --agent' 'salida OpenCode sin claude --agent'
absent "$opencode_body" '.plugin-root' 'salida OpenCode sin marcador de plugin'
absent "$opencode_body" 'plugins/cache' 'salida OpenCode sin cache de plugins'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
contains "$(< "$MIRROR")" '<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/scaffold-projections.md. No editar a mano. -->' 'mirror conserva marcador generado'
for runtime in claude opencode; do
    inventory="$REPO_ROOT/dist/$runtime/.mefisto-generated-assets.json"
    if jq -e '.assets[] | select(.destination | test("commands/(mefisto:)?scaffold-projections\\.md$"))' "$inventory" >/dev/null 2>&1; then pass "inventariado en dist/$runtime"; else fail "ausente del inventario de dist/$runtime"; fi
done
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
