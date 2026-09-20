#!/usr/bin/env bash
# test-mcp-scaffolder-instructions-path.sh -- Contrato de instrucciones efectivo
# de mcp-scaffolder (#1507, MEF-ADR-0053 decision 4).

set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
AGENT="$REPO_ROOT/agents/mcp-scaffolder.md"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

extract_instructions_block() {
    awk '
        /^```bash$/ { inside=1; block=""; next }
        /^```$/ {
            if (inside && block ~ /MEFISTO_INSTRUCTIONS_PATH/) { print block; exit }
            inside=0; next
        }
        inside { block = block $0 "\n" }
    ' "$AGENT"
}

SCRIPT="$(extract_instructions_block)"
if [ -n "$SCRIPT" ]; then pass "extrae el bloque de resolucion de instrucciones"; else fail "no encontro el bloque de instrucciones"; fi

resolve() {
    local root="$1"
    (cd "$root" && bash -c "$SCRIPT")
}

tokens() {
    local path="$1"
    grep -E '^(RootNamespace|SolutionFile|ProjectDisplayName|BoundedContext):' "$path" | tr '\n' '|'
}

write_tokens() {
    local path="$1" prefix="$2"
    cat > "$path" <<EOF
RootNamespace: $prefix.Namespace
SolutionFile: $prefix.slnx
ProjectDisplayName: $prefix Display
BoundedContext: $prefix Context
EOF
}

echo "[1] Consumidor canonico"
CANON="$WORK/canonico"; mkdir -p "$CANON"
write_tokens "$CANON/AGENTS.md" Canonico
out="$(resolve "$CANON" 2>"$WORK/canonico.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'AGENTS.md' ] && [ "$(tokens "$CANON/$out")" = 'RootNamespace: Canonico.Namespace|SolutionFile: Canonico.slnx|ProjectDisplayName: Canonico Display|BoundedContext: Canonico Context|' ] && [ ! -s "$WORK/canonico.err" ]; then
    pass "resuelve los cuatro tokens desde AGENTS.md sin detenerse"
else
    fail "el consumidor canonico no resolvio AGENTS.md (out='$out', err='$(cat "$WORK/canonico.err")')"
fi

echo "[2] Consumidor canonico con puente minimo"
BRIDGE="$WORK/puente"; mkdir -p "$BRIDGE"
write_tokens "$BRIDGE/AGENTS.md" Puente
printf '@AGENTS.md\n' > "$BRIDGE/CLAUDE.md"
out="$(resolve "$BRIDGE" 2>"$WORK/puente.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'AGENTS.md' ] && [ "$(tokens "$BRIDGE/$out")" = 'RootNamespace: Puente.Namespace|SolutionFile: Puente.slnx|ProjectDisplayName: Puente Display|BoundedContext: Puente Context|' ] && grep -Fqx 'AVISO: se usara AGENTS.md; se ignora el legacy CLAUDE.md. Migra o elimina conscientemente el archivo legacy para evitar divergencias.' "$WORK/puente.err"; then
    pass "el puente minimo no impide resolver los cuatro tokens canonicos"
else
    fail "el consumidor con puente minimo no resolvio AGENTS.md (out='$out', err='$(cat "$WORK/puente.err")')"
fi

echo "[3] Consumidor solo legacy"
LEGACY="$WORK/legacy"; mkdir -p "$LEGACY"
write_tokens "$LEGACY/CLAUDE.md" Legacy
out="$(resolve "$LEGACY" 2>"$WORK/legacy.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'CLAUDE.md' ] && [ "$(tokens "$LEGACY/$out")" = 'RootNamespace: Legacy.Namespace|SolutionFile: Legacy.slnx|ProjectDisplayName: Legacy Display|BoundedContext: Legacy Context|' ] && [ ! -s "$WORK/legacy.err" ]; then
    pass "el fallback legacy conserva los cuatro tokens"
else
    fail "el fallback legacy no resolvio como se esperaba (out='$out', err='$(cat "$WORK/legacy.err")')"
fi

echo "[4] Coexistencia divergente"
BOTH="$WORK/ambos"; mkdir -p "$BOTH"
write_tokens "$BOTH/AGENTS.md" Canonico
write_tokens "$BOTH/CLAUDE.md" Legacy
out="$(resolve "$BOTH" 2>"$WORK/ambos.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'AGENTS.md' ] && [ "$(tokens "$BOTH/$out")" = 'RootNamespace: Canonico.Namespace|SolutionFile: Canonico.slnx|ProjectDisplayName: Canonico Display|BoundedContext: Canonico Context|' ] && grep -Fqx 'AVISO: se usara AGENTS.md; se ignora el legacy CLAUDE.md. Migra o elimina conscientemente el archivo legacy para evitar divergencias.' "$WORK/ambos.err"; then
    pass "AGENTS.md prevalece y emite el AVISO literal"
else
    fail "la coexistencia no uso exclusivamente AGENTS.md (out='$out', err='$(cat "$WORK/ambos.err")')"
fi

echo "[5] Ausencia"
MISSING="$WORK/ausente"; mkdir -p "$MISSING"
out="$(resolve "$MISSING" 2>"$WORK/ausente.err")"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ] && grep -Fqx 'ERROR: no se encontro AGENTS.md, la fuente canonica de directivas del consumidor.' "$WORK/ausente.err" && grep -Fqx '  Ejecuta /mefisto:onboard para diagnosticar y completar el contrato del consumidor.' "$WORK/ausente.err"; then
    pass "la ausencia aborta con el diagnostico de onboarding"
else
    fail "la ausencia no aborto con el diagnostico esperado (rc=$rc, out='$out', err='$(cat "$WORK/ausente.err")')"
fi

echo "[6] Prosa y lecturas"
if grep -Fq 'Tokens de `CLAUDE.md`' "$AGENT" || grep -Fq '`CLAUDE.md` raiz' "$AGENT"; then
    fail "reaparecio una referencia legacy directa a los tokens"
else
    pass "la prosa no remite los tokens a CLAUDE.md"
fi
if python3 - "$AGENT" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
blocks = re.findall(r"```bash\n(.*?)\n```", text, re.S)
resolver = next((block for block in blocks if "MEFISTO_INSTRUCTIONS_PATH" in block), None)
if resolver is None:
    raise SystemExit(1)
prose = text.replace(f"```bash\n{resolver}\n```", "", 1)
direct_read = re.compile(
    r"(?:lee|leela|leer|Read)[^\n]*CLAUDE\.md|"
    r"CLAUDE\.md[^\n]*(?:tokens?[^\n]*(?:viene|sale|resuelve)|(?:lee|leela|leer|Read)[^\n]*tokens?)",
    re.IGNORECASE,
)
if direct_read.search(prose):
    raise SystemExit(1)
PY
then
    pass "no hay lectura directa de tokens desde CLAUDE.md fuera del fallback"
else
    fail "reaparecio una instruccion de leer tokens desde CLAUDE.md fuera del fallback"
fi
if grep -Fq '`${MEFISTO_INSTRUCTIONS_PATH}`' "$AGENT" \
    && grep -Fq 'Si el archivo efectivo no declara alguno de los cuatro' "$AGENT" \
    && grep -Fq 'los declare en `AGENTS.md`, seccion "Tokens del harness"' "$AGENT" \
    && grep -Fq 'No crees, copies, migres ni escribas `AGENTS.md` ni el fallback legacy `CLAUDE.md`.' "$AGENT"; then
    pass "la prosa usa el archivo efectivo, remite la declaracion a AGENTS.md y prohibe mutar instrucciones"
else
    fail "la prosa no conserva el contrato del archivo efectivo"
fi

echo
echo "Resumen: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
