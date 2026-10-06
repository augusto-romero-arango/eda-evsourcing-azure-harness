#!/usr/bin/env bash
# Contrato del comando bug neutral y sus proyecciones publicadas.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/bug.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/bug.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:bug.md"
MIRROR="$REPO_ROOT/commands/bug.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[fuente] contrato neutral'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "bug" and .profile == "fast" and .arguments == "[--tooling|--deployed] <descripcion del sintoma>" and (keys | sort) == ["arguments", "description", "id", "kind", "profile"]' >/dev/null; then pass 'metadata sin agent ni capabilities'; else fail 'metadata neutral invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:launch-agent tooling-investigator ' 'delegacion puntual a tooling-investigator'
contains "$body" '{{mefisto:launch-agent bug-investigator ' 'delegacion puntual a bug-investigator'
contains "$body" '{{mefisto:run azure-account-info.sh 2>&1}}' 'valida sesion con azure-account-info.sh'
contains "$body" '.mefisto/appinsights.env' 'valida appinsights.env'
contains "$body" 'Uso: {{mefisto:command bug}}' 'uso vacio con command bug'
contains "$body" '`.claude/`, `.mefisto/`' 'indicadores de tooling conservan .claude/ y suman .mefisto/'
contains "$body" '--tooling' 'flag --tooling'
contains "$body" '--deployed' 'flag --deployed'
contains "$body" 'No investigues nada tu mismo' 'regla no investigar'
contains "$body" 'No modifiques codigo' 'regla no modificar codigo'
absent "$body" 'claude --agent' 'fuente sin claude --agent'
absent "$body" 'az ' 'fuente sin az directo'
for forbidden in '.plugin-root' 'plugins/cache' 'PLUGIN_SCRIPTS' 'CLAUDE_'; do absent "$body" "$forbidden" "fuente sin token prohibido: $forbidden"; done

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"
for pair in "claude:$claude_body" "opencode:$opencode_body"; do
    rt="${pair%%:*}"; f="${pair#*:}"
    contains "$f" "MEFISTO_RUNTIME=$rt \"\${MEFISTO_PACKAGE_ROOT}/scripts/azure-account-info.sh\" 2>&1" "$rt invoca azure-account-info.sh"
    absent "$f" '{{mefisto:' "$rt sin directivas sin resolver"
    absent "$f" 'claude --agent' "$rt sin claude --agent"
    absent "$f" 'az ' "$rt sin az directo"
    absent "$f" 'PLUGIN_SCRIPTS' "$rt sin PLUGIN_SCRIPTS"
    absent "$f" 'plugins/cache' "$rt sin plugins/cache"
    contains "$f" 'tooling-investigator' "$rt delega en tooling-investigator"
    contains "$f" 'bug-investigator' "$rt delega en bug-investigator"
    # (d) la validacion Azure precede a la delegacion en bug-investigator.
    after_header="${f#*Si entorno desplegado}"
    before_deleg="${after_header%%Si ambas validaciones pasan*}"
    contains "$before_deleg" 'azure-account-info.sh' "$rt valida Azure antes de delegar a bug-investigator"
    tooling_section="${f#*Si tooling}"
    tooling_section="${tooling_section%%Si entorno desplegado*}"
    absent "$tooling_section" 'azure-account-info.sh' "$rt: la ruta tooling no exige Azure"
done
contains "$opencode_body" 'agent: "command-entry-bug"' 'OpenCode liga el command-entry de bug'
contains "$opencode_body" 'subtask: false' 'OpenCode no convierte bug en subtask'
absent "$opencode_body" 'CLAUDE_' 'OpenCode sin CLAUDE_'
absent "$opencode_body" 'model:' 'OpenCode no emite model'
contains "$claude_body" 'model: "haiku"' 'Claude materializa el perfil fast'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
contains "$(< "$MIRROR")" 'GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/bug.md' 'mirror conserva marcador generado'
for runtime in claude opencode; do
    if jq -e '.. | strings | select(. == "commands/bug.md" or . == "commands/mefisto:bug.md")' "$REPO_ROOT/dist/$runtime/.mefisto-generated-assets.json" >/dev/null 2>&1; then pass "inventario de dist/$runtime lo incluye"; else fail "inventario de dist/$runtime no lo incluye"; fi
done
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
