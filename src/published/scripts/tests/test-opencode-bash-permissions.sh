#!/usr/bin/env bash
# Contrato cerrado de candidatos Bash de OpenCode 1.18.29. No interpreta Bash:
# el corpus versionado caracteriza los rangos de command de tree-sitter-bash.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
CORPUS="$HERE/fixtures/bash-candidates/opencode-1.18.29.json"
EVALUATOR_DIR="$REPO_ROOT/src/published/scripts/adapters/lib"
ARTIFACT_ROOT="${1:-$REPO_ROOT/dist/opencode}"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$CORPUS" ] && [ -d "$ARTIFACT_ROOT" ] || { printf '%s\n' 'ERROR: falta corpus o artefactos OpenCode'; exit 1; }
runtime="$(jq -r '.runtime | [.opencode,.treeSitterBash,.webTreeSitter] | join("/")' "$CORPUS")"
[ "$runtime" = '1.18.29/0.25.0/0.25.10' ] && pass 'corpus pinneado a OpenCode/tree-sitter/web-tree-sitter verificados' || fail 'versiones del corpus inesperadas'

permission="$(awk '/^permission: / { sub(/^permission: /, ""); print; exit }' "$ARTIFACT_ROOT/agents/test-writer.md")"
[ -n "$permission" ] || { printf '%s\n' 'ERROR: falta permission.bash en test-writer'; exit 1; }
evaluate() {
    jq -L "$EVALUATOR_DIR" -cnr --argjson permission "$permission" --arg candidate "$1" \
      'include "opencode-entry-permissions"; {action:"evaluate",policy:{rules:($permission.bash | to_entries | map({permission:"bash",pattern:.key,value:.value}))},candidates:[{permission:"bash",candidate:$candidate}]} | entry_permissions | .decisions[0].decision'
}

printf '%s\n' '[corpus] snippets generados y reglas evaluadas por la biblioteca #1838'
while IFS=$'\t' read -r artifact candidate source; do
    target="$ARTIFACT_ROOT/$artifact"
    case "$artifact" in commands/*) target="$ARTIFACT_ROOT/commands/mefisto:${artifact#commands/}" ;; esac
    if [ -f "$target" ] && grep -Fq "$candidate" "$target"; then
        pass "$source conserva bytes canonicos en $artifact"
    else
        fail "$source no coincide exactamente con el artefacto generado $artifact"
    fi
done < <(jq -r '.scriptCalls[] | [.artifact,.candidate,.source] | join("\u001f")' "$CORPUS" | tr '\037' '\t')

while IFS=$'\t' read -r candidate expected source; do
    actual="$(evaluate "$candidate")"
    [ "$actual" = "$expected" ] && pass "$source: $expected" || fail "$source: se esperaba $expected y fue $actual"
done < <(jq -r '.candidates[] | [.candidate,.expected,.source] | join("\u001f")' "$CORPUS" | tr '\037' '\t')

printf '%s\n' '[controles] semantica AST caracterizada, sin normalizacion heuristica'
for source in 'assignment without command' 'declaration with substitution' 'bracket test' 'cwd and pipe' 'single quoted literal' 'function static traversal'; do
    jq -e --arg source "$source" '.nonCandidates[] | select(.source == $source) | (.node | length > 0)' "$CORPUS" >/dev/null && pass "$source caracterizado" || fail "$source ausente"
done
for forbidden in 'bash -c x' 'sh -c x' 'env x' 'eval x' 'curl x' 'sudo x' 'ssh x' 'scp x' 'terraform plan' 'terraform apply' 'terraform destroy'; do
    [ "$(evaluate "$forbidden")" = 'deny' ] && pass "$forbidden sigue denegado" || fail "$forbidden dejo de estar denegado"
done
jq -e '(.bash | has("${MEFISTO_PACKAGE_ROOT}/scripts/*") | not) and (.bash | has("export MEFISTO_PACKAGE_ROOT") | not) and (.bash | has("[ *") | not)' <<< "$permission" >/dev/null && pass 'sin regla incompatible ni falsos candidatos de export/test' || fail 'persisten reglas incompatibles o inertes'

printf '\n%s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
