#!/usr/bin/env bash
# test-install-apim-instructions-path.sh -- Contrato de instrucciones efectivas
# para la resolucion de RootNamespace en /install-apim (#1516, MEF-ADR-0053).

set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
COMMAND="$REPO_ROOT/commands/install-apim.md"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

extract_bash_after_heading() {
    local heading="$1"
    awk -v heading="$heading" '
        $0 == heading { found=1; next }
        found && /^```bash$/ { inside=1; next }
        found && /^```$/ && inside { exit }
        inside { print }
    ' "$COMMAND"
}

MCP_BLOCK="$(extract_bash_after_heading '### 2b. Detectar los servidores MCP del BC (CA-3 del issue #820)')"
ROOT_BLOCK="$(extract_bash_after_heading '#### 9.1 Resolver `<RootNamespace>`')"

resolve_mcp() {
    local root="$1"
    (cd "$root" && bash -c "$MCP_BLOCK"$'\n''printf "ROOT=%s SERVIDORES=%s\\n" "$ROOT_NAMESPACE" "$SERVIDORES_MCP"')
}

resolve_root() {
    local root="$1"
    (cd "$root" && bash -c "$ROOT_BLOCK"$'\n''printf "ROOT=%s PATH=%s\\n" "$ROOT_NAMESPACE" "$MEFISTO_INSTRUCTIONS_PATH"')
}

reuse_root() {
    local root="$1"
    (cd "$root" && ROOT_NAMESPACE='Previamente.Resuelto' bash -c "$ROOT_BLOCK"$'\n''printf "ROOT=%s\\n" "$ROOT_NAMESPACE"')
}

echo '[1] Canonico: AGENTS.md determina RootNamespace, descubre MCP y permite tenancy'
CANON="$WORK/canonico"; mkdir -p "$CANON/src/Bitakora.ControlAsistencia.Mcp.Reportes"
printf 'RootNamespace: Bitakora.ControlAsistencia\n' > "$CANON/AGENTS.md"
printf '@AGENTS.md\n' > "$CANON/CLAUDE.md"
out="$(resolve_mcp "$CANON" 2>"$WORK/canonico-mcp.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'ROOT=Bitakora.ControlAsistencia SERVIDORES=Reportes' ] \
    && grep -Fq 'AVISO: se usara AGENTS.md' "$WORK/canonico-mcp.err"; then
    pass '2b usa AGENTS.md, detecta el servidor MCP y avisa la coexistencia'
else
    fail "2b canonico no resolvio o detecto correctamente (rc=$rc, out='$out', err='$(cat "$WORK/canonico-mcp.err")')"
fi
out="$(resolve_root "$CANON" 2>"$WORK/canonico-root.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'ROOT=Bitakora.ControlAsistencia PATH=AGENTS.md' ]; then
    pass '9.1 relee AGENTS.md en un shell nuevo y continua'
else
    fail "9.1 canonico no continuo (rc=$rc, out='$out', err='$(cat "$WORK/canonico-root.err")')"
fi
REUSE="$WORK/reuso"; mkdir -p "$REUSE"
out="$(reuse_root "$REUSE" 2>"$WORK/reuso.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'ROOT=Previamente.Resuelto' ] && [ ! -s "$WORK/reuso.err" ]; then
    pass '9.1 reutiliza RootNamespace sin exigir ni releer el archivo'
else
    fail "9.1 no reutilizo RootNamespace (rc=$rc, out='$out', err='$(cat "$WORK/reuso.err")')"
fi

echo '[2] Solo legacy conserva el fallback de lectura'
LEGACY="$WORK/legacy"; mkdir -p "$LEGACY/src/Legado.Producto.Mcp.Consulta"
printf 'RootNamespace: Legado.Producto\n' > "$LEGACY/CLAUDE.md"
out="$(resolve_mcp "$LEGACY" 2>"$WORK/legacy-mcp.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'ROOT=Legado.Producto SERVIDORES=Consulta' ] && [ ! -s "$WORK/legacy-mcp.err" ]; then
    pass '2b conserva el fallback legacy'
else
    fail "2b legacy no resolvio correctamente (rc=$rc, out='$out', err='$(cat "$WORK/legacy-mcp.err")')"
fi
out="$(resolve_root "$LEGACY" 2>"$WORK/legacy-root.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'ROOT=Legado.Producto PATH=CLAUDE.md' ]; then
    pass '9.1 conserva el fallback legacy'
else
    fail "9.1 legacy no resolvio correctamente (rc=$rc, out='$out', err='$(cat "$WORK/legacy-root.err")')"
fi

echo '[3] Coexistencia prevalece AGENTS.md y ausencia aborta con onboarding'
BOTH="$WORK/ambos"; mkdir -p "$BOTH"
printf 'RootNamespace: Canonico.Producto\n' > "$BOTH/AGENTS.md"
printf 'RootNamespace: Legacy.Divergente\n' > "$BOTH/CLAUDE.md"
out="$(resolve_root "$BOTH" 2>"$WORK/ambos.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'ROOT=Canonico.Producto PATH=AGENTS.md' ] \
    && grep -Fq 'AVISO: se usara AGENTS.md' "$WORK/ambos.err"; then
    pass 'coexistencia usa exclusivamente AGENTS.md y deja AVISO'
else
    fail "coexistencia no prevalecio el canonico (rc=$rc, out='$out', err='$(cat "$WORK/ambos.err")')"
fi
MISSING="$WORK/ausente"; mkdir -p "$MISSING"
out="$(resolve_mcp "$MISSING" 2>"$WORK/ausente.err")"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ] && grep -Fq '/mefisto:onboard' "$WORK/ausente.err"; then
    pass 'ausencia de ambos archivos aborta con el diagnostico de onboarding'
else
    fail "ausencia no aborto correctamente (rc=$rc, out='$out', err='$(cat "$WORK/ausente.err")')"
fi

echo '[4] Un archivo efectivo sin token degrada 2b y bloquea 9.1'
TOKENLESS="$WORK/sin-token"; mkdir -p "$TOKENLESS"
printf '## Tokens del harness\n' > "$TOKENLESS/AGENTS.md"
out="$(resolve_mcp "$TOKENLESS" 2>"$WORK/sin-token-mcp.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'ROOT= SERVIDORES=no determinable' ]; then
    pass '2b degrada SERVIDORES_MCP cuando falta el token en el archivo efectivo'
else
    fail "2b no degrado el token ausente (rc=$rc, out='$out', err='$(cat "$WORK/sin-token-mcp.err")')"
fi
out="$(resolve_root "$TOKENLESS" 2>"$WORK/sin-token-root.err")"; rc=$?
if [ "$rc" -ne 0 ] && grep -Fq 'falta declarar RootNamespace en AGENTS.md' <<< "$out"; then
    pass '9.1 bloquea y nombra AGENTS.md cuando falta el token'
else
    fail "9.1 no bloqueo el token ausente con el diagnostico esperado (rc=$rc, out='$out')"
fi

echo '[5] Antirregresion de fuentes legacy directas'
if grep -Fq 'CLAUDE.md raiz' "$COMMAND" || grep -Fq 'leyendo el `CLAUDE.md`' "$COMMAND"; then
    fail 'reaparecio una fuente directa CLAUDE.md fuera del fallback'
else
    pass 'el skill no describe CLAUDE.md como fuente directa del token'
fi
if grep -Fq 'MEFISTO_INSTRUCTIONS_PATH' <<< "$MCP_BLOCK" \
    && grep -Fq 'MEFISTO_INSTRUCTIONS_PATH' <<< "$ROOT_BLOCK" \
    && grep -Fq 'SERVIDORES_MCP="no determinable"' <<< "$MCP_BLOCK" \
    && grep -Fq 'falta declarar RootNamespace en AGENTS.md' <<< "$ROOT_BLOCK"; then
    pass 'cada paso conserva su semantica ante token ausente'
else
    fail 'faltan la ruta efectiva o los diagnosticos de los pasos 2b/9.1'
fi

echo "Resumen: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
