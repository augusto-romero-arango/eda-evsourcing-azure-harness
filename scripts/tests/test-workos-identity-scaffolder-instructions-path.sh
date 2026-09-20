#!/usr/bin/env bash
# test-workos-identity-scaffolder-instructions-path.sh -- Verifica que el
# scaffolder WorkOS resuelve RootNamespace desde el contrato efectivo (#1515).

set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
AGENT="$REPO_ROOT/agents/workos-identity-scaffolder.md"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

extract_bash_block() {
    local file="$1" target="$2"
    awk -v target="$target" '
        /^```bash$/ { n++; if (n == target) { inside=1; next } }
        /^```$/ { if (inside) { exit } }
        inside { print }
    ' "$file"
}

echo "[1] El agente usa el archivo efectivo y mantiene la ruta legacy solo dentro del fallback"
SCRIPT="$(extract_bash_block "$AGENT" 2)"
if [ -n "$SCRIPT" ] && grep -Fq 'MEFISTO_INSTRUCTIONS_PATH' <<<"$SCRIPT"; then
    pass "el segundo bloque bash resuelve y exporta MEFISTO_INSTRUCTIONS_PATH"
else
    fail "no se encontro el bloque de resolucion de instrucciones"
fi
if grep -Fq 'Lee `${MEFISTO_INSTRUCTIONS_PATH}` para resolver `<RootNamespace>`' "$AGENT"; then
    pass "RootNamespace se lee desde el archivo efectivo"
else
    fail "RootNamespace no se lee desde el archivo efectivo"
fi
PROSE_WITHOUT_FALLBACK="$(awk '
    /^```bash$/ { n++; if (n == 2) { skip=1; next } }
    /^```$/ { if (skip) { skip=0; next } }
    !skip { print }
' "$AGENT")"
if grep -Eq 'Lee `CLAUDE\.md`|`CLAUDE\.md` raiz' <<<"$PROSE_WITHOUT_FALLBACK"; then
    fail "la prosa vuelve a usar CLAUDE.md como fuente del token"
else
    pass "la prosa no usa CLAUDE.md como fuente del token"
fi

resolve() {
    local root="$1"
    (cd "$root" && bash -c "$SCRIPT"$'\n''printf "%s\n" "$MEFISTO_INSTRUCTIONS_PATH"')
}

echo "[2] La resolucion conserva precedencia, fallback y diagnosticos"
CANON="$WORK/canonico"; mkdir -p "$CANON"
printf 'RootNamespace: Bitakora.ControlAsistencia\n' > "$CANON/AGENTS.md"
printf '@AGENTS.md\n' > "$CANON/CLAUDE.md"
out="$(resolve "$CANON" 2>"$WORK/canonico.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'AGENTS.md' ] && grep -Fq 'AVISO:' "$WORK/canonico.err"; then
    pass "canonico completo prevalece sobre el puente legacy y avisa"
else
    fail "canonico no resolvio como se esperaba (rc=$rc, out='$out', err='$(cat "$WORK/canonico.err")')"
fi

LEGACY="$WORK/legacy"; mkdir -p "$LEGACY"
printf 'RootNamespace: Bitakora.ControlAsistencia\n' > "$LEGACY/CLAUDE.md"
out="$(resolve "$LEGACY" 2>"$WORK/legacy.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'CLAUDE.md' ] && [ ! -s "$WORK/legacy.err" ]; then
    pass "solo legacy se resuelve como fallback de lectura"
else
    fail "legacy no resolvio como fallback (rc=$rc, out='$out', err='$(cat "$WORK/legacy.err")')"
fi

BOTH="$WORK/ambos"; mkdir -p "$BOTH"
printf 'RootNamespace: Bitakora.ControlAsistencia\n' > "$BOTH/AGENTS.md"
printf 'RootNamespace: Legacy.Divergente\n' > "$BOTH/CLAUDE.md"
out="$(resolve "$BOTH" 2>"$WORK/ambos.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'AGENTS.md' ] && grep -Fq 'AVISO:' "$WORK/ambos.err"; then
    pass "coexistencia usa AGENTS.md y deja AVISO visible"
else
    fail "coexistencia no eligio AGENTS.md (rc=$rc, out='$out', err='$(cat "$WORK/ambos.err")')"
fi

MISSING="$WORK/ausente"; mkdir -p "$MISSING"
out="$(resolve "$MISSING" 2>"$WORK/ausente.err")"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ] && grep -Fq 'ERROR:' "$WORK/ausente.err" && grep -Fq '/mefisto:onboard' "$WORK/ausente.err"; then
    pass "ausencia de ambos aborta con ERROR y diagnostico de onboarding"
else
    fail "ausencia no aborto como se esperaba (rc=$rc, out='$out', err='$(cat "$WORK/ausente.err")')"
fi

echo
echo "Resumen: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
