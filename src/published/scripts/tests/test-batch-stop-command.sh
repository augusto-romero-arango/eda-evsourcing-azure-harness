#!/usr/bin/env bash
# Contrato del comando batch-stop neutral y sus dos proyecciones publicadas
# (issue #1596: migracion desde el formato Claude-only commands/batch-stop.md).
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/batch-stop.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/batch-stop.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:batch-stop.md"
MIRROR="$REPO_ROOT/commands/batch-stop.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }
absent_word() {
    # Verifica que <palabra> nunca aparece como token de shell independiente
    # (limites de inicio/fin de linea, espacio o separadores ; & |), a
    # diferencia de una subcadena que puede caer dentro de otra palabra
    # (p.ej. "rm" dentro de "confirmar").
    if printf '%s' "$1" | grep -Eqc "(^|[;&|[:space:]])$2([[:space:]]|\$)"; then
        fail "$3"
    else
        pass "$3"
    fi
}

echo '[fuente] contrato neutral'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "batch-stop" and .profile == "fast" and (keys | sort) == ["description", "id", "kind", "profile"]' >/dev/null; then pass 'metadata sin arguments, agent ni capabilities (CA-1)'; else fail 'metadata neutral invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor antes del proceso'
guard_line="$(grep -nF '{{mefisto:assert-consumer-repo}}' "$SOURCE" | cut -d: -f1)"
operation_line="$(awk '/pgrep -f/ { print NR; exit }' "$SOURCE")"
[ -n "$guard_line" ] && [ -n "$operation_line" ] && [ "$guard_line" -lt "$operation_line" ] && pass 'guard precede cualquier operacion' || fail 'guard no precede las operaciones'
contains "$body" '{{mefisto:command sequential}}' 'referencia neutral a sequential'
contains "$body" '{{mefisto:command parallel}}' 'referencia neutral a parallel'
contains "$body" '{{mefisto:command batch-stop}}' 'autoreferencia neutral (confirmacion ya dada)'
contains "$body" 'pgrep -f "[s]cripts/batch-pipeline\.sh"' 'patron de deteccion sin auto-coincidencia'
contains "$body" 'pipeline-state/batch-stop' 'ruta de la senal relativa a la raiz del repo'
for forbidden in 'Claude' 'OpenCode' '.claude/' '.opencode/' 'cache' 'model:' 'tools:' 'allowed-tools:' 'permission:' '.claude-plugin' 'CLAUDE_' '/mefisto-batch-stop'; do absent "$body" "$forbidden" "fuente no publica token prohibido: $forbidden"; done

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
for label in claude opencode; do
    case "$label" in claude) content="$(< "$CLAUDE")" ;; opencode) content="$(< "$OPENCODE")" ;; esac
    contains "$content" 'pgrep -f "[s]cripts/batch-pipeline\.sh"' "$label conserva el patron de deteccion (CA-5a)"
    contains "$content" 'pipeline-state/batch-stop' "$label conserva la ruta de la senal (CA-5a)"
    absent_word "$content" kill "$label no invoca kill (CA-5b)"
    absent_word "$content" pkill "$label no invoca pkill (CA-5b)"
    absent_word "$content" rm "$label no invoca rm (CA-5b)"
done
contains "$(< "$CLAUDE")" 'model: "haiku"' 'Claude materializa el perfil fast (CA-5c)'
absent "$(< "$OPENCODE")" 'model:' 'OpenCode no emite model (CA-5c)'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
contains "$(< "$MIRROR")" '<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/batch-stop.md. No editar a mano. -->' 'mirror conserva marcador generado'
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
