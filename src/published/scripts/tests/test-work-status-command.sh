#!/usr/bin/env bash
# Contrato del comando work-status neutral y sus dos proyecciones publicadas.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/work-status.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/work-status.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:work-status.md"
MIRROR="$REPO_ROOT/commands/work-status.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[fuente] contrato neutral'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "work-status" and .profile == "fast" and .arguments == "[<issue>[/<variante>] | pregunta]" and (keys | sort) == ["arguments", "description", "id", "kind", "profile"]' >/dev/null; then pass 'metadata sin agent ni capabilities'; else fail 'metadata neutral invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor antes del proceso'
guard_line="$(grep -nF '{{mefisto:assert-consumer-repo}}' "$SOURCE" | cut -d: -f1)"
collect_line="$(grep -nF 'work-status-collect.sh' "$SOURCE" | head -1 | cut -d: -f1)"
[ -n "$guard_line" ] && [ -n "$collect_line" ] && [ "$guard_line" -lt "$collect_line" ] && pass 'guard precede la invocacion del colector' || fail 'guard no precede la invocacion del colector'
contains "$body" '{{mefisto:run work-status-collect.sh --json}}' 'invoca el colector con --json'
[ "$(grep -cF '{{mefisto:run work-status-collect.sh --json}}' "$SOURCE")" -eq 1 ] && pass 'existe una unica invocacion del colector' || fail 'la invocacion del colector no es unica'
contains "$body" 'lee el final del archivo `log`' 'describe la lectura del log en terminos neutrales'
contains "$body" 'lee en su lugar el archivo hermano' 'describe el drill-down del events.jsonl en terminos neutrales'
contains "$body" 'EN ESPERA' 'presenta hold como EN ESPERA'
contains "$body" 'SIN NOVEDADES' 'presenta stale como SIN NOVEDADES'
contains "$body" '(sin pipelines registrados)' 'mensaje sin pipelines registrados'
contains "$body" '(sin pipelines completados aun)' 'mensaje sin pipelines completados'
for forbidden in 'Claude' 'OpenCode' 'claude' 'opencode' '.claude' '.opencode' 'cache' 'model:' 'tools:' 'allowed-tools:' 'permission:' 'Glob' 'Read' 'Bash(' '/mefisto-work-status' '.mefisto/pipeline' '.claude/pipeline'; do absent "$body" "$forbidden" "fuente no publica token prohibido: $forbidden"; done

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
contains "$(< "$CLAUDE")" 'MEFISTO_RUNTIME=claude "${MEFISTO_PACKAGE_ROOT}/scripts/work-status-collect.sh" --json' 'Claude invoca el colector bajo el package root'
contains "$(< "$CLAUDE")" 'model: "haiku"' 'Claude materializa el perfil fast'
absent "$(< "$CLAUDE")" 'MEFISTO_RUNTIME=opencode' 'Claude no fija el runtime OpenCode'
contains "$(< "$OPENCODE")" 'MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/work-status-collect.sh" --json' 'OpenCode invoca el colector bajo el package root'
absent "$(< "$OPENCODE")" $'\nmodel:' 'OpenCode no emite model'
absent "$(< "$OPENCODE")" 'MEFISTO_RUNTIME=claude' 'OpenCode no fija el runtime Claude'
# CA-6 (b): ninguna salida lee el estado legacy ni nombra tools de un runtime.
# El preambulo compartido de resolucion de MEFISTO_PACKAGE_ROOT de Claude cita
# el marcador .plugin-root como fallback de lectura y queda fuera del chequeo.
claude_no_preamble="$(grep -vF '.plugin-root' "$CLAUDE")"
absent "$claude_no_preamble" '.claude/pipeline' 'Claude no lee .claude/pipeline fuera del preambulo'
absent "$(< "$OPENCODE")" '.claude/pipeline' 'OpenCode no lee .claude/pipeline'
for file in "$CLAUDE" "$OPENCODE"; do
    content="$(< "$file")"
    absent "$content" 'Glob' "${file#"$REPO_ROOT/"} no nombra Glob"
    absent "$content" 'Read ' "${file#"$REPO_ROOT/"} no nombra Read como tool"
done
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
contains "$(< "$MIRROR")" '<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/work-status.md. No editar a mano. -->' 'mirror conserva marcador generado'
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
