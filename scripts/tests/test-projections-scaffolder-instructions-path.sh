#!/usr/bin/env bash
# test-projections-scaffolder-instructions-path.sh -- Contrato de lectura de
# instrucciones de projections-scaffolder (#1514, MEF-ADR-0053 decision 4).

set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
AGENT="$REPO_ROOT/agents/projections-scaffolder.md"
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

SCRIPT="$(extract_bash_block "$AGENT" 3)"
if [ -n "$SCRIPT" ] && grep -Fq 'MEFISTO_INSTRUCTIONS_PATH' <<<"$SCRIPT"; then
    pass "el Paso 0 contiene el bloque de resolucion de instrucciones"
else
    fail "no se encontro el bloque de resolucion en el Paso 0"
fi

resolve_tokens() {
    local root="$1"
    (
        cd "$root" || exit 99
        bash -c "$SCRIPT"$'\n''grep -F "RootNamespace:" "$MEFISTO_INSTRUCTIONS_PATH" >/dev/null && grep -F "SolutionFile:" "$MEFISTO_INSTRUCTIONS_PATH" >/dev/null && printf "%s\\n" "$MEFISTO_INSTRUCTIONS_PATH"'
    )
}

echo "[1] El archivo efectivo resuelve ambos tokens (canonico/fallback/coexistencia/ausencia)"
CANON="$WORK/canonico"; mkdir -p "$CANON"
printf 'RootNamespace: Certificacion.Proyecciones\nSolutionFile: Certificacion.slnx\n' > "$CANON/AGENTS.md"
printf '@AGENTS.md\n' > "$CANON/CLAUDE.md"
out="$(resolve_tokens "$CANON" 2>"$WORK/canonico.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'AGENTS.md' ] && grep -Fq 'se ignora el legacy CLAUDE.md' "$WORK/canonico.err"; then
    pass "el canonico completo resuelve ambos tokens y prevalece sobre el puente legacy"
else
    fail "el canonico no resolvio los tokens esperados (rc=$rc, out='$out', err='$(<"$WORK/canonico.err")')"
fi

LEGACY="$WORK/legacy"; mkdir -p "$LEGACY"
printf 'RootNamespace: Certificacion.Legacy\nSolutionFile: Legacy.slnx\n' > "$LEGACY/CLAUDE.md"
out="$(resolve_tokens "$LEGACY" 2>"$WORK/legacy.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'CLAUDE.md' ] && [ ! -s "$WORK/legacy.err" ]; then
    pass "el consumidor solo legacy resuelve ambos tokens como fallback de lectura"
else
    fail "el fallback legacy no resolvio los tokens (rc=$rc, out='$out', err='$(<"$WORK/legacy.err")')"
fi

BOTH="$WORK/ambos"; mkdir -p "$BOTH"
printf 'RootNamespace: Certificacion.Canonica\nSolutionFile: Canonica.slnx\n' > "$BOTH/AGENTS.md"
printf 'RootNamespace: Legacy.Divergente\nSolutionFile: Legacy.slnx\n' > "$BOTH/CLAUDE.md"
out="$(resolve_tokens "$BOTH" 2>"$WORK/ambos.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'AGENTS.md' ] && grep -Fq 'AVISO: se usara AGENTS.md; se ignora el legacy CLAUDE.md.' "$WORK/ambos.err"; then
    pass "la coexistencia usa el canonico y deja el aviso literal"
else
    fail "la coexistencia no aplico la precedencia esperada (rc=$rc, out='$out', err='$(<"$WORK/ambos.err")')"
fi

MISSING="$WORK/ausente"; mkdir -p "$MISSING"
out="$(resolve_tokens "$MISSING" 2>"$WORK/ausente.err")"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ] && grep -Fq 'ERROR: no se encontro AGENTS.md, la fuente canonica de directivas del consumidor.' "$WORK/ausente.err" && grep -Fq '/mefisto:onboard' "$WORK/ausente.err"; then
    pass "la ausencia aborta con el diagnostico de onboarding"
else
    fail "la ausencia no aborto con el diagnostico esperado (rc=$rc, out='$out', err='$(<"$WORK/ausente.err")')"
fi

echo "[2] La prosa no vuelve a usar el archivo legacy como fuente de tokens"
WITHOUT_RESOLVER="$WORK/agente-sin-fallback.md"
awk '
    /^```bash$/ { n++; if (n == 3) { skip=1; next } }
    /^```$/ { if (skip) { skip=0; next } }
    !skip { print }
' "$AGENT" > "$WITHOUT_RESOLVER"
if grep -Fq 'Lee `CLAUDE.md`' "$WITHOUT_RESOLVER" || grep -Fq '`CLAUDE.md` raiz' "$WITHOUT_RESOLVER"; then
    fail "la prosa todavia nombra el archivo legacy como fuente de tokens"
else
    pass "la prosa usa exclusivamente MEFISTO_INSTRUCTIONS_PATH como fuente de tokens"
fi
if grep -Fq 'Lee `${MEFISTO_INSTRUCTIONS_PATH}`' "$AGENT" && grep -Fq 'Si `AGENTS.md` no declara alguno de los dos' "$AGENT"; then
    pass "la prosa nombra AGENTS.md al diagnosticar tokens ausentes"
else
    fail "la prosa no declara la fuente y el diagnostico canonicos"
fi

echo
echo "Resumen: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
