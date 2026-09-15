#!/usr/bin/env bash
# Contrato del comando runtimes neutral y sus adaptaciones publicadas.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/runtimes.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/runtimes.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:runtimes.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[fuente] contrato neutral'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "runtimes" and .arguments == "[status | enable opencode | disable opencode]" and (keys | sort) == ["arguments", "description", "id", "kind"]' >/dev/null; then pass 'metadata neutral sin perfil ni runtime'; else fail 'metadata neutral invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:lifecycle-launcher}}' 'delegacion de launcher adaptable presente'
contains "$body" 'Uso: /mefisto:runtimes [status | enable opencode | disable opencode]' 'uso unico para entrada invalida'
contains "$body" 'selector' 'sin argumentos ofrece selector confirmado'
contains "$body" 'unavailable' 'declara unavailable'
contains "$body" 'installed-disabled' 'declara installed-disabled'
contains "$body" 'Normaliza el estado estructurado `disabled` como `installed-disabled`' 'normaliza disabled del launcher'
contains "$body" 'enabled' 'declara enabled'
contains "$body" 'stale' 'declara stale'
contains "$body" 'conflict' 'declara conflict'
contains "$body" 'configRoot' 'muestra raiz efectiva'
contains "$body" 'activeVersion' 'muestra release activa'
contains "$body" 'ledgerRelease' 'muestra release del ledger'
contains "$body" 'administrado externamente' 'declara lifecycle externo del plugin'
contains "$body" '"$MEFISTO_LIFECYCLE_LAUNCHER" project' 'enable usa solo proyeccion'
contains "$body" '"$MEFISTO_LIFECYCLE_LAUNCHER" deactivate' 'disable usa solo retirada de proyeccion'
contains "$body" 'No consulta red' 'enable no usa red'
contains "$body" '/mefisto:upgrade' 'remite upgrade si falta release activa'
contains "$body" 'dejara de estar disponible' 'advierte auto-desactivacion'
contains "$body" 'sin inspeccionar archivos de configuracion' 'estado no inspecciona configuracion ajena'
contains "$body" 'stores de autenticacion' 'estado no inspecciona stores de autenticacion'

echo '[salidas] adaptadores'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
for file in "$CLAUDE" "$OPENCODE"; do
    rendered="$(< "$file")"
    contains "$rendered" 'MEFISTO_LIFECYCLE_LAUNCHER' "${file#"$REPO_ROOT/"} materializa launcher"
    contains "$rendered" 'projection-status' "${file#"$REPO_ROOT/"} materializa status"
    contains "$rendered" 'mefisto-opencode' "${file#"$REPO_ROOT/"} resuelve launcher estable"
done
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi
printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
