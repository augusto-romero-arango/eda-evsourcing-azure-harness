#!/usr/bin/env bash
# Contrato del comando implement neutral y sus dos proyecciones publicadas.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/implement.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/implement.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:implement.md"
MIRROR="$REPO_ROOT/commands/implement.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[fuente] contrato neutral'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "implement" and .profile == "fast" and .arguments == "<issue> [--models '\''agente=modelo[,agente=modelo...]'\''] [--variant <label>]" and (keys | sort) == ["arguments", "description", "id", "kind", "profile"]' >/dev/null; then pass 'metadata sin capacidades ni runtime'; else fail 'metadata neutral invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor antes del proceso'
guard_line="$(grep -nF '{{mefisto:assert-consumer-repo}}' "$SOURCE" | cut -d: -f1)"
operation_line="$(awk '/gh issue view/ { print NR; exit }' "$SOURCE")"
[ -n "$guard_line" ] && [ -n "$operation_line" ] && [ "$guard_line" -lt "$operation_line" ] && pass 'guard precede cualquier operacion' || fail 'guard no precede las operaciones'
contains "$body" 'exactamente un tipo TDD' 'exige tipo TDD unico'
contains "$body" 'tipo:feature' 'admite feature'
contains "$body" 'tipo:refactor' 'admite refactor'
contains "$body" 'tipo:projection' 'admite projection'
contains "$body" '{{mefisto:command tooling}}' 'tooling se remite al comando especializado'
contains "$body" '{{mefisto:package-root}}/docs/adr/mef-adr-0011-definition-of-ready.md' 'DoR se lee desde package root'
contains "$body" 'todos los criterios vigentes' 'DoR no memoriza cantidad fija'
contains "$body" 'Depende de #N' 'dependencias declaradas se filtran'
contains "$body" 'Bloqueado por #N' 'dependencias bloqueadas se filtran'
contains "$body" 'intenta primero `gh pr view`' 'consulta PR antes que issue'
contains "$body" 'Ignora cualquier otro `#N`' 'ignora referencias ajenas a dependencias'
contains "$body" 'Con `--variant`, nunca mutas labels' 'variante no muta labels'
contains "$body" '{{mefisto:config-path}}' 'configuracion usa directiva neutral'
contains "$body" '## Impacto' 'deteccion limitada a impacto'
contains "$body" 'tres opciones' 'ofrece las tres opciones de scaffold'
contains "$body" 'solo se admite un scaffold por invocacion' 'limita scaffold por invocacion'
contains "$body" '{{mefisto:run tmux-pipeline.sh $ARGUMENTS}}' 'despacho sin scaffold'
contains "$body" '{{mefisto:run tmux-pipeline.sh $ARGUMENTS --scaffold-domain <dominio-kebab-confirmado>}}' 'despacho con scaffold confirmado'
[ "$(grep -cF '{{mefisto:run tmux-pipeline.sh' "$SOURCE")" -eq 2 ] && pass 'existen dos rutas de lanzamiento' || fail 'las rutas de lanzamiento no son dos'
for forbidden in 'Claude' 'OpenCode' '.claude/' '.opencode/' 'cache' 'model:' 'tools:' 'allowed-tools:' 'permission:' 'SCAFFOLD_FLAG' '/work-status'; do absent "$body" "$forbidden" "fuente no publica token prohibido: $forbidden"; done

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
contains "$(< "$CLAUDE")" 'model: "haiku"' 'Claude materializa el perfil fast'
contains "$(< "$CLAUDE")" 'MEFISTO_PACKAGE_ROOT' 'Claude resuelve package root una vez'
[ "$(grep -c '^MEFISTO_PACKAGE_ROOT=' "$CLAUDE")" -eq 1 ] && pass 'Claude tiene un preambulo de package root' || fail 'Claude duplica package root'
contains "$(< "$OPENCODE")" 'description:' 'OpenCode materializa el comando'
contains "$(< "$OPENCODE")" 'mefisto-opencode' 'OpenCode resuelve la release activa'
[ "$(grep -c 'MEFISTO_PACKAGE_ROOT=.*package-root' "$OPENCODE")" -eq 1 ] && pass 'OpenCode tiene un preambulo de package root' || fail 'OpenCode duplica package root'
contains "$(< "$CLAUDE")" '"${MEFISTO_PACKAGE_ROOT}/scripts/tmux-pipeline.sh" $ARGUMENTS' 'Claude conserva package root con espacios'
contains "$(< "$OPENCODE")" '"${MEFISTO_PACKAGE_ROOT}/scripts/tmux-pipeline.sh" $ARGUMENTS' 'OpenCode conserva package root con espacios'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
