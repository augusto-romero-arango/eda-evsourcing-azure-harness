#!/usr/bin/env bash
# test-warning-remnants-section.sh — Tests de render_warning_remnants_section()
# (scripts/_pipeline-common.sh), issue #2408, MEF-ADR-0056.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export HARNESS_NAMESPACE_PREFIX="Acme"
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null || true

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

wt=$(mktemp -d)
mkdir -p "$wt/.mefisto/pipeline"
f="$wt/.mefisto/pipeline/warnings-remanentes.txt"

out=$(render_warning_remnants_section "$wt")
[ -z "$out" ] && ok "sin archivo: salida vacia" || fail "sin archivo: salida no vacia"

printf 'nada\n\n  texto suelto\n' > "$f"
out=$(render_warning_remnants_section "$wt")
[ -z "$out" ] && ok "archivo sin referencias: salida vacia" || fail "archivo sin referencias: salida no vacia"

printf '#12\n15\n' > "$f"
out=$(render_warning_remnants_section "$wt")
[[ "$out" == "## Warnings remanentes"* ]] && ok "encabezado presente" || fail "encabezado ausente"
[ "$(grep -c '^- Relacionado:' <<<"$out")" -eq 2 ] && ok "#12 y 15: dos lineas" || fail "#12 y 15: conteo"
grep -qx -- '- Relacionado: #12' <<<"$out" && grep -qx -- '- Relacionado: #15' <<<"$out" \
    && ok "15 se normaliza a #15" || fail "normalizacion"
first=$(grep '^- Relacionado:' <<<"$out" | head -1)
[ "$first" = "- Relacionado: #12" ] && ok "orden de primera aparicion" || fail "orden"

printf 'owner/repo#7\n' > "$f"
out=$(render_warning_remnants_section "$wt")
grep -qx -- '- Relacionado: owner/repo#7' <<<"$out" && ok "owner/repo#7" || fail "owner/repo#7"

printf '#5\n5\n#5\nbasura\n' > "$f"
out=$(render_warning_remnants_section "$wt")
[ "$(grep -c '^- Relacionado:' <<<"$out")" -eq 1 ] && ok "duplicados: una linea" || fail "duplicados"

rm -rf "$wt"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
