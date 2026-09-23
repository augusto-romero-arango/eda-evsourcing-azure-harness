#!/usr/bin/env bash
# Contrato del comando infra neutral y sus dos proyecciones publicadas.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/infra.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/infra.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:infra.md"
MIRROR="$REPO_ROOT/commands/infra.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[fuente] contrato neutral'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "infra" and .profile == "fast" and .arguments == "<issue>" and (keys | sort) == ["arguments", "description", "id", "kind", "profile"]' >/dev/null; then pass 'metadata sin agent ni capabilities'; else fail 'metadata neutral invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
guard_line="$(grep -nF '{{mefisto:assert-consumer-repo}}' "$SOURCE" | cut -d: -f1)"
operation_line="$(awk '/gh issue view/ { print NR; exit }' "$SOURCE")"
[ -n "$guard_line" ] && [ -n "$operation_line" ] && [ "$guard_line" -lt "$operation_line" ] && pass 'guard precede cualquier operacion' || fail 'guard no precede las operaciones'
contains "$body" '{{mefisto:run tmux-pipeline.sh --infra $ARGUMENTS}}' 'despacho neutral exacto'
[ "$(grep -cF '{{mefisto:run tmux-pipeline.sh --infra $ARGUMENTS}}' "$SOURCE")" -eq 1 ] && pass 'existe un unico despacho' || fail 'el despacho no es unico'
contains "$body" 'gh issue view' 'valida issues antes de lanzar'
contains "$body" 'esta cerrado (`CLOSED`), informa y detente' 'rechaza issue inexistente o cerrado'
contains "$body" 'tipo:infra' 'valida el label tipo:infra'
contains "$body" 'Continuar de todos modos? (s/n)' 'advierte sin tipo:infra con confirmacion'
contains "$body" 'Si no se confirma, detente' 'se detiene sin confirmacion'
contains "$body" 'Depende de #N' 'reconoce lineas canonicas Depende de #N'
contains "$body" 'Bloqueado por #N' 'reconoce lineas canonicas Bloqueado por #N'
contains "$body" 'gh pr view' 'consulta PR antes que issue'
contains "$body" 'Nunca supongas que un fallo significa cierre' 'falla cerrado ante consulta no resoluble'
contains "$body" 'HERDR_ENV=1' 'documenta deteccion de Herdr'
contains "$body" 'tmux -CC attach -t infra-<numero>' 'documenta el attach tmux fuera de Herdr'
contains "$body" '{{mefisto:command work-status}}' 'referencia work-status via directiva command'
contains "$body" '{{mefisto:command implement}}' 'referencia implement via directiva command'
contains "$body" '{{mefisto:command tooling}}' 'referencia tooling via directiva command'
contains "$body" 'MEF-ADR-0021' 'documenta el ADR de cero permisos de Azure'
contains "$body" 'MEF-ADR-0022' 'documenta el ADR de cierre del issue en CI'
contains "$body" 'terraform plan' 'documenta que no se ejecuta terraform plan'
contains "$body" 'No esperes a que termine' 'regla: no esperar'
contains "$body" 'No implementes nada tu mismo' 'regla: no implementar'
contains "$body" 'Si tmux no esta instalado' 'documenta deteccion de tmux ausente'
for forbidden in 'Claude' 'OpenCode' '.claude/' '.opencode/' 'cache' 'model:' 'tools:' 'allowed-tools:' 'permission:' '.plugin-root' 'CLAUDE_' 'plugins/cache'; do absent "$body" "$forbidden" "fuente no publica token prohibido: $forbidden"; done

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"
contains "$claude_body" 'MEFISTO_RUNTIME=claude "${MEFISTO_PACKAGE_ROOT}/scripts/tmux-pipeline.sh" --infra $ARGUMENTS' 'Claude invoca tmux-pipeline.sh --infra y fija su runtime'
absent "$claude_body" 'MEFISTO_RUNTIME=opencode' 'Claude no fija el runtime OpenCode'
contains "$opencode_body" 'MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/tmux-pipeline.sh" --infra $ARGUMENTS' 'OpenCode invoca tmux-pipeline.sh --infra y fija su runtime'
absent "$opencode_body" 'MEFISTO_RUNTIME=claude' 'OpenCode no fija el runtime Claude'
contains "$claude_body" 'model: "haiku"' 'Claude materializa el perfil fast'
absent "$opencode_body" 'model:' 'OpenCode no emite model'
contains "$claude_body" '/mefisto:work-status' 'Claude resuelve la directiva command a /mefisto:work-status'
contains "$opencode_body" '/mefisto:work-status' 'OpenCode resuelve la directiva command a /mefisto:work-status'
contains "$claude_body" '/mefisto:implement' 'Claude resuelve la directiva command a /mefisto:implement'
contains "$opencode_body" '/mefisto:implement' 'OpenCode resuelve la directiva command a /mefisto:implement'
contains "$claude_body" '/mefisto:tooling' 'Claude resuelve la directiva command a /mefisto:tooling'
contains "$opencode_body" '/mefisto:tooling' 'OpenCode resuelve la directiva command a /mefisto:tooling'
claude_invocation="$(printf '%s\n' "$claude_body" | grep -F 'scripts/tmux-pipeline.sh" --infra')"
opencode_invocation="$(printf '%s\n' "$opencode_body" | grep -F 'scripts/tmux-pipeline.sh" --infra')"
for forbidden_path in '.claude/pipeline/.plugin-root' 'plugins/cache'; do
    absent "$claude_invocation" "$forbidden_path" "invocacion Claude no reimplementa el lookup legacy ($forbidden_path)"
    absent "$opencode_invocation" "$forbidden_path" "invocacion OpenCode no reimplementa el lookup legacy ($forbidden_path)"
done
absent "$opencode_body" '.claude/pipeline/.plugin-root' 'salida OpenCode completa sin marcador Claude'
absent "$opencode_body" 'plugins/cache' 'salida OpenCode completa sin cache de plugins'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
contains "$(< "$MIRROR")" '<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/infra.md. No editar a mano. -->' 'mirror conserva marcador generado'

echo '[assets] iac-pipeline.sh empaquetado'
if [ -x "$REPO_ROOT/dist/claude/scripts/iac-pipeline.sh" ]; then pass 'iac-pipeline.sh empaquetado en dist/claude/scripts'; else fail 'falta dist/claude/scripts/iac-pipeline.sh'; fi
if [ -x "$REPO_ROOT/dist/opencode/scripts/iac-pipeline.sh" ]; then pass 'iac-pipeline.sh empaquetado en dist/opencode/scripts'; else fail 'falta dist/opencode/scripts/iac-pipeline.sh'; fi
if cmp -s "$REPO_ROOT/scripts/iac-pipeline.sh" "$REPO_ROOT/dist/opencode/scripts/iac-pipeline.sh"; then pass 'dist/opencode/scripts/iac-pipeline.sh identico a la fuente'; else fail 'dist/opencode/scripts/iac-pipeline.sh diverge de la fuente'; fi
if cmp -s "$REPO_ROOT/scripts/iac-pipeline.sh" "$REPO_ROOT/dist/claude/scripts/iac-pipeline.sh"; then pass 'dist/claude/scripts/iac-pipeline.sh identico a la fuente'; else fail 'dist/claude/scripts/iac-pipeline.sh diverge de la fuente'; fi
for runtime in claude opencode; do
    inventory="$REPO_ROOT/dist/$runtime/.mefisto-generated-assets.json"
    if jq -e '.assets[] | select(.destination == "scripts/iac-pipeline.sh")' "$inventory" >/dev/null 2>&1; then pass "scripts/iac-pipeline.sh en el inventario de dist/$runtime"; else fail "scripts/iac-pipeline.sh ausente del inventario de dist/$runtime"; fi
done
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
