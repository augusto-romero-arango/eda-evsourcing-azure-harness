#!/usr/bin/env bash
# test-workos-identity-scaffolder-instructions-path.sh -- Verifica que el
# scaffolder WorkOS resuelve RootNamespace desde el contrato efectivo (#1515).

set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
AGENT="$REPO_ROOT/agents/workos-identity-scaffolder.md"
REFERENCE_AGENT="$REPO_ROOT/agents/implementer.md"
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
REFERENCE_SCRIPT="$(extract_bash_block "$REFERENCE_AGENT" 1)"
if [ -n "$SCRIPT" ] && [ "$SCRIPT" = "$REFERENCE_SCRIPT" ]; then
    pass "el segundo bloque bash reutiliza literalmente el resolver publicado"
else
    fail "el bloque de resolucion no coincide con el contrato publicado"
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
if grep -Fq 'No crees, copies, migres ni escribas `AGENTS.md` ni el fallback legacy `CLAUDE.md`.' "$AGENT"; then
    pass "el agente prohibe mutar ambos archivos de instrucciones"
else
    fail "falta la prohibicion de crear, copiar, migrar o escribir los archivos de instrucciones"
fi
if awk '
    /Lee `\$\{MEFISTO_INSTRUCTIONS_PATH\}` para resolver `<RootNamespace>`/ { resolved=1 }
    resolved && /^### 0\.2 - El dominio ya existe$/ { found=1 }
    END { exit !found }
' "$AGENT"; then
    pass "el flujo continua al Paso 0.2 despues de resolver RootNamespace"
else
    fail "el Paso 0.2 no sigue a la resolucion de RootNamespace"
fi

resolve() {
    local root="$1"
    (cd "$root" && bash -c "$SCRIPT"$'\n''value="$(awk -F '\''[:][[:space:]]*'\'' '\''$1 == "RootNamespace" { print $2; exit }'\'' "$MEFISTO_INSTRUCTIONS_PATH")"; [ -n "$value" ] || exit 2; printf "%s|%s\n" "$MEFISTO_INSTRUCTIONS_PATH" "$value"')
}

echo "[2] La resolucion conserva precedencia, fallback y diagnosticos"
CANON="$WORK/canonico"; mkdir -p "$CANON"
printf 'RootNamespace: Bitakora.ControlAsistencia\n' > "$CANON/AGENTS.md"
printf '@AGENTS.md\n' > "$CANON/CLAUDE.md"
out="$(resolve "$CANON" 2>"$WORK/canonico.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'AGENTS.md|Bitakora.ControlAsistencia' ] && grep -Fq 'AVISO: se usara AGENTS.md; se ignora el legacy CLAUDE.md.' "$WORK/canonico.err"; then
    pass "canonico completo resuelve RootNamespace, prevalece sobre el puente legacy y avisa"
else
    fail "canonico no resolvio como se esperaba (rc=$rc, out='$out', err='$(cat "$WORK/canonico.err")')"
fi

LEGACY="$WORK/legacy"; mkdir -p "$LEGACY"
printf 'RootNamespace: Bitakora.ControlAsistencia\n' > "$LEGACY/CLAUDE.md"
out="$(resolve "$LEGACY" 2>"$WORK/legacy.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'CLAUDE.md|Bitakora.ControlAsistencia' ] && [ ! -s "$WORK/legacy.err" ]; then
    pass "solo legacy resuelve RootNamespace como fallback de lectura"
else
    fail "legacy no resolvio como fallback (rc=$rc, out='$out', err='$(cat "$WORK/legacy.err")')"
fi

BOTH="$WORK/ambos"; mkdir -p "$BOTH"
printf 'RootNamespace: Bitakora.ControlAsistencia\n' > "$BOTH/AGENTS.md"
printf 'RootNamespace: Legacy.Divergente\n' > "$BOTH/CLAUDE.md"
out="$(resolve "$BOTH" 2>"$WORK/ambos.err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = 'AGENTS.md|Bitakora.ControlAsistencia' ] && grep -Fq 'AVISO: se usara AGENTS.md; se ignora el legacy CLAUDE.md.' "$WORK/ambos.err"; then
    pass "coexistencia usa solo el RootNamespace de AGENTS.md y deja el AVISO literal"
else
    fail "coexistencia no eligio AGENTS.md (rc=$rc, out='$out', err='$(cat "$WORK/ambos.err")')"
fi

MISSING="$WORK/ausente"; mkdir -p "$MISSING"
out="$(resolve "$MISSING" 2>"$WORK/ausente.err")"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ] && grep -Fq 'ERROR: no se encontro AGENTS.md, la fuente canonica de directivas del consumidor.' "$WORK/ausente.err" && grep -Fq '/mefisto:onboard' "$WORK/ausente.err"; then
    pass "ausencia de ambos aborta con ERROR y diagnostico de onboarding"
else
    fail "ausencia no aborto como se esperaba (rc=$rc, out='$out', err='$(cat "$WORK/ausente.err")')"
fi

echo
echo "Resumen: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
