#!/usr/bin/env bash
# Contrato del comando next-order neutral y sus proyecciones publicadas.
# La linea de lanzamiento es el literal /mefisto:sequential: el validador no
# admite una directiva anidada en los argumentos de `run`, y ambos adaptadores
# materializan {{mefisto:command}} como /mefisto:<id>, asi que el literal es igual.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/next-order.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/next-order.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:next-order.md"
MIRROR="$REPO_ROOT/commands/next-order.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[fuente] contrato neutral'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "next-order" and .profile == "fast" and (keys | sort) == ["description", "id", "kind", "profile"]' >/dev/null; then pass 'metadata sin arguments, agent ni capabilities'; else fail 'metadata neutral invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:run next-order.sh --launch-command "/mefisto:sequential"}}' 'invocacion neutral del script'
contains "$body" 'modo `oleadas` del agente `planner`' 'remite al planner por id'
contains "$body" 'ADVERTENCIA' 'conserva la advertencia de universo truncado'
contains "$body" '$ARGUMENTS' 'avisa que ignora argumentos'
contains "$body" 'solo lectura' 'regla de solo lectura'
for forbidden in '.claude/' '.plugin-root' 'plugins/cache' 'claude --agent'; do absent "$body" "$forbidden" "fuente sin token prohibido: $forbidden"; done

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"
contains "$claude_body" '"${MEFISTO_PACKAGE_ROOT}/scripts/next-order.sh" --launch-command "/mefisto:sequential"' 'Claude invoca next-order.sh'
contains "$opencode_body" '"${MEFISTO_PACKAGE_ROOT}/scripts/next-order.sh" --launch-command "/mefisto:sequential"' 'OpenCode invoca next-order.sh'
for f in "$claude_body" "$opencode_body"; do
    absent "$f" 'claude --agent' 'sin claude --agent'
    absent "$f" '{{mefisto:' 'sin directivas sin resolver'
    absent "$f" 'plugins/cache' 'sin plugins/cache'
done
contains "$claude_body" 'model: "haiku"' 'Claude materializa el perfil fast'
absent "$opencode_body" 'model:' 'OpenCode no emite model'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
contains "$(< "$MIRROR")" 'GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/next-order.md' 'mirror conserva marcador generado'

echo '[assets] next-order.sh empaquetado'
for runtime in claude opencode; do
    dist="$REPO_ROOT/dist/$runtime/scripts/next-order.sh"
    if [ -x "$dist" ]; then pass "next-order.sh ejecutable en dist/$runtime"; else fail "falta next-order.sh ejecutable en dist/$runtime"; fi
    if cmp -s "$REPO_ROOT/scripts/next-order.sh" "$dist"; then pass "dist/$runtime identico a la fuente"; else fail "dist/$runtime diverge de la fuente"; fi
    if jq -e '.assets[] | select(.destination == "scripts/next-order.sh")' "$REPO_ROOT/dist/$runtime/.mefisto-generated-assets.json" >/dev/null 2>&1; then pass "inventario de dist/$runtime lo incluye"; else fail "inventario de dist/$runtime no lo incluye"; fi
done
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
