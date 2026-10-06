#!/usr/bin/env bash
# Contrato del comando bitacora neutral y sus proyecciones publicadas.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/bitacora.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/bitacora.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:bitacora.md"
MIRROR="$REPO_ROOT/commands/bitacora.md"
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
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "bitacora" and .profile == "fast" and .arguments == "[YYYY-MM-DD]" and (keys | sort) == ["arguments", "description", "id", "kind", "profile"]' >/dev/null; then pass 'metadata sin agent ni capabilities'; else fail 'metadata neutral invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:launch-agent historiador ' 'delegacion puntual a historiador'
contains "$body" 'unicamente las field notes del dia <fecha>' 'mensaje con filtro de fecha'
contains "$body" '{{mefisto:command-doc merge}}' 'lee command-doc merge'
contains "$body" 'gh pr view <num> --json number,state,headRefName,files' 'verifica el PR con gh pr view'
contains "$body" 'docs/bitacora/' 'exige archivos bajo docs/bitacora/'
contains "$body" 'mensaje final' 'PR tomado del mensaje final'
contains "$body" 'No pidas ninguna confirmacion adicional' 'sin confirmacion antes de mergear'
contains "$body" 'gh pr merge' 'regla de no merges manuales'
contains "$body" 'No diagnostiques errores de `pr-sync.sh`' 'regla de no diagnosticar pr-sync'
for forbidden in 'claude --agent' '.plugin-root' 'plugins/cache' 'commands/merge.md' 'CLAUDE_' '.claude/' 'PLUGIN_ROOT'; do absent "$body" "$forbidden" "fuente sin token prohibido: $forbidden"; done
order_ok=1; prev=0
for marker in '{{mefisto:assert-consumer-repo}}' '{{mefisto:launch-agent historiador ' 'gh pr view <num>' '{{mefisto:command-doc merge}}'; do
    n="$(line_of "$SOURCE" "$marker")"
    if [ -z "$n" ] || [ "$n" -le "$prev" ]; then order_ok=0; printf '    orden: %s -> %s\n' "$marker" "${n:-ausente}"; fi
    prev="${n:-$prev}"
done
[ "$order_ok" -eq 1 ] && pass 'orden: guard -> historiador -> verificacion del PR -> merge' || fail 'orden de pasos invalido'

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"
contains "$claude_body" 'model: "haiku"' 'Claude materializa el perfil fast'
absent "$opencode_body" 'model:' 'OpenCode no emite model'
contains "$opencode_body" 'agent: "command-entry-bitacora"' 'OpenCode liga el command-entry de bitacora'
contains "$opencode_body" 'subtask: false' 'OpenCode no convierte bitacora en subtask'
contains "$claude_body" 'mefisto:historiador' 'Claude delega en mefisto:historiador'
contains "$opencode_body" 'historiador' 'OpenCode delega en historiador'
contains "$claude_body" '"${MEFISTO_PACKAGE_ROOT}/commands/merge.md"' 'Claude lee merge'
contains "$opencode_body" '"${MEFISTO_PACKAGE_ROOT}/commands/mefisto:merge.md"' 'OpenCode lee merge'
[ -f "$REPO_ROOT/dist/claude/commands/merge.md" ] && pass 'existe dist/claude/commands/merge.md' || fail 'falta dist/claude/commands/merge.md'
[ -f "$REPO_ROOT/dist/opencode/commands/mefisto:merge.md" ] && pass 'existe dist/opencode/commands/mefisto:merge.md' || fail 'falta dist/opencode/commands/mefisto:merge.md'
for rt in claude opencode; do
    out="$claude_body"; [ "$rt" = opencode ] && out="$opencode_body"
    forbidden_set=('plugins/cache' 'claude --agent')
    [ "$rt" = opencode ] && forbidden_set+=('CLAUDE_' '.claude/' '.plugin-root')
    for forbidden in "${forbidden_set[@]}"; do absent "$out" "$forbidden" "$rt sin token de runtime: $forbidden"; done
done
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
for runtime in claude opencode; do
    dest="commands/bitacora.md"; [ "$runtime" = opencode ] && dest="commands/mefisto:bitacora.md"
    if grep -qF "$dest" "$REPO_ROOT/dist/$runtime/.mefisto-generated-assets.json"; then pass "inventario de dist/$runtime lo incluye"; else fail "inventario de dist/$runtime no lo incluye"; fi
done
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
