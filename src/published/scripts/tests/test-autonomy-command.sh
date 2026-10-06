#!/usr/bin/env bash
# Contrato del comando autonomy neutral y sus proyecciones publicadas (issue #1991).
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/autonomy.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/autonomy.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:autonomy.md"
MIRROR="$REPO_ROOT/commands/autonomy.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[fuente] contrato neutral'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "autonomy" and .profile == "fast"' >/dev/null; then pass 'metadata autonomy con perfil fast'; else fail 'metadata invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor'
for op in inspect propose-max preview approve revoke; do contains "$body" "autonomy-profile.sh $op" "usa la operacion $op (CA-1..4)"; done
contains "$body" '--expected-digest <profileDigest-de-propose-max>' 'approve encadena el digest de propose-max (CA-2)'
contains "$body" 'incrementa `revision`' 'reducir incrementa revision (CA-3)'
contains "$body" 'versionado' 'recuerda que el config es versionado (CA-5)'
contains "$body" 'Pull Request' 'recuerda entrega por PR (CA-5)'
contains "$body" '.mefisto/pipeline/autonomy/consent.json' 'recuerda consentimiento local (CA-5)'
contains "$body" 'Nunca ejecutes `approve` ni `revoke` sin' 'no aprueba sin confirmacion (CA-6)'
contains "$body" 'produccion' 'prohibe grants de produccion (CA-6)'
contains "$body" 'headless' 'solo interactivo (CA-6)'
for forbidden in 'Claude' 'OpenCode' '.claude/' '.opencode/' 'model:' 'tools:' 'allowed-tools:' '.claude-plugin' 'CLAUDE_'; do absent "$body" "$forbidden" "fuente no publica token prohibido: $forbidden"; done

echo '[catalogo] fila de entrada'
if jq -e '.commands[] | select(.id == "autonomy") | .writeScope == "project" and (.capabilities | index("edit"))' "$REPO_ROOT/src/published/contract/command-entry.json" >/dev/null; then pass 'fila autonomy registrada en command-entry.json'; else fail 'falta fila autonomy'; fi

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE" "$MIRROR"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
contains "$(< "$CLAUDE")" 'model: "haiku"' 'Claude materializa el perfil fast'
absent "$(< "$OPENCODE")" 'model:' 'OpenCode no emite model'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf '\nPASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
