#!/usr/bin/env bash
# Contrato del comando eraser-diagram neutral y sus proyecciones publicadas.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/eraser-diagram.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/eraser-diagram.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:eraser-diagram.md"
MIRROR="$REPO_ROOT/commands/eraser-diagram.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[fuente] contrato neutral'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "eraser-diagram" and .profile == "balanced" and .arguments == "<descripcion del diagrama>" and (keys | sort) == ["arguments", "description", "id", "kind", "profile"]' >/dev/null; then pass 'metadata sin agent ni capabilities'; else fail 'metadata neutral invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
for s in '## Paso 1 ' '## Paso 2 ' '## Paso 3 ' '## Paso 4 '; do contains "$body" "$s" "conserva $s"; done
contains "$body" 'https://app.eraser.io/api/render/elements' 'endpoint de render presente'
contains "$body" 'Authorization: Bearer ${ERASER_API_TOKEN}' 'Bearer con ERASER_API_TOKEN'
contains "$body" 'Si falla por falta de `ERASER_API_TOKEN`, muestra el DSL' 'degradacion visible sin token'
absent "$body" 'echo "$ERASER_API_TOKEN' 'el token no se imprime'
absent "$body" '${ERASER_API_TOKEN}" >' 'el token no se escribe a archivo'
for t in sequence-diagram cloud-architecture-diagram flowchart-diagram entity-relationship-diagram bpmn-diagram; do contains "$body" "$t" "sintaxis de $t"; done
for forbidden in '.claude' '.plugin-root' 'plugins/cache' 'PLUGIN_SCRIPTS' 'CLAUDE_'; do absent "$body" "$forbidden" "fuente sin token prohibido: $forbidden"; done

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"
for pair in "claude:$claude_body" "opencode:$opencode_body"; do
    rt="${pair%%:*}"; f="${pair#*:}"
    contains "$f" 'https://app.eraser.io/api/render/elements' "$rt llama al endpoint"
    contains "$f" 'Authorization: Bearer ${ERASER_API_TOKEN}' "$rt usa Bearer del entorno"
    contains "$f" 'Si falla por falta de `ERASER_API_TOKEN`, muestra el DSL y explica que se puede pegar en https://app.eraser.io para renderizar.' "$rt degrada sin token"
    absent "$f" '{{mefisto:' "$rt sin directivas sin resolver"
    absent "$f" 'PLUGIN_SCRIPTS' "$rt sin PLUGIN_SCRIPTS"
    absent "$f" 'plugins/cache' "$rt sin plugins/cache"
    absent "$f" '.claude-plugin/plugin.json"' "$rt sin guard inline"
    # El guard precede a la llamada.
    before="${f%%api/render/elements*}"
    contains "$before" 'Paso 1' "$rt: pasos previos a la llamada"
    contains "$before" 'aborta si existe `src/internal/scripts/generate-internal-adapters.sh`' "$rt: guard precede a la llamada"
done
guard_pos="${body%%api/render/elements*}"
contains "$guard_pos" '{{mefisto:assert-consumer-repo}}' 'fuente: guard precede a la llamada'
for forbidden in '.claude/' '.plugin-root' 'CLAUDE_'; do absent "$opencode_body" "$forbidden" "OpenCode sin token Claude: $forbidden"; done
contains "$claude_body" 'model: "sonnet"' 'Claude materializa el perfil balanced'
absent "$opencode_body" 'model:' 'OpenCode no emite model'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
contains "$(< "$MIRROR")" 'GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/eraser-diagram.md' 'mirror conserva marcador generado'
for runtime in claude opencode; do
    if jq -e '.. | strings | select(. == "commands/eraser-diagram.md" or . == "commands/mefisto:eraser-diagram.md")' "$REPO_ROOT/dist/$runtime/.mefisto-generated-assets.json" >/dev/null 2>&1; then pass "inventario de dist/$runtime lo incluye"; else fail "inventario de dist/$runtime no lo incluye"; fi
done
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
