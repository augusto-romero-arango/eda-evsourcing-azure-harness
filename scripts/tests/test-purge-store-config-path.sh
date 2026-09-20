#!/usr/bin/env bash
# test-purge-store-config-path.sh -- Contrato de config de /purge-store (#1502).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMAND="$REPO_ROOT/commands/purge-store.md"
SCRIPT="$REPO_ROOT/scripts/purge-store.sh"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

SKILL_BLOCK=$(awk '
    /^```bash$/ { block = block + 1; next }
    block == 2 && /^```$/ { exit }
    block == 2 { print }
' "$COMMAND")

if [ -n "$SKILL_BLOCK" ]; then
    pass "se encontro el bloque de resolucion del skill"
else
    fail "no se encontro el bloque de resolucion del skill"
fi

write_config() {
    local path="$1" labels="$2"
    mkdir -p "$(dirname "$path")"
    printf '{"domainLabels":%s}\n' "$labels" > "$path"
}

run_skill_block() {
    local root="$1" domain="$2" output rc
    output=$(DOMINIO="$domain" bash -c "cd \"$root\" && $SKILL_BLOCK" 2>&1)
    rc=$?
    printf '%s\n%s\n' "$rc" "$output"
}

assert_resolves() {
    local label="$1" root="$2" domain="$3" expected="$4" result rc output
    result=$(run_skill_block "$root" "$domain")
    rc=${result%%$'\n'*}
    output=${result#*$'\n'}
    if [ "$rc" -eq 0 ] && grep -Fq "Dominio canonico: $expected" <<< "$output"; then
        pass "$label resuelve '$expected'"
    else
        fail "$label esperaba '$expected': $output"
    fi
}

echo "[1] Consumidor canonico"
CANONICAL_ROOT="$TMP_DIR/canonical"
mkdir -p "$CANONICAL_ROOT"
git -C "$CANONICAL_ROOT" init -q
write_config "$CANONICAL_ROOT/.mefisto/harness.config.json" '["calculo-horas"]'
assert_resolves "canonico" "$CANONICAL_ROOT" CalculoHoras calculo-horas

echo "[2] Ambos configs divergentes"
BOTH_ROOT="$TMP_DIR/both"
mkdir -p "$BOTH_ROOT"
git -C "$BOTH_ROOT" init -q
BOTH_ROOT_PHYSICAL=$(cd "$BOTH_ROOT" && pwd -P)
write_config "$BOTH_ROOT/.mefisto/harness.config.json" '["calculo-horas"]'
write_config "$BOTH_ROOT/.claude/harness.config.json" '["legacy"]'
BOTH_RESULT=$(run_skill_block "$BOTH_ROOT" CalculoHoras)
if grep -Fq 'Dominio canonico: calculo-horas' <<< "$BOTH_RESULT" \
    && grep -Fq "AVISO: se usara el config canonico $BOTH_ROOT_PHYSICAL/.mefisto/harness.config.json; se ignora el legacy $BOTH_ROOT_PHYSICAL/.claude/harness.config.json. Migra o elimina conscientemente el archivo legacy para evitar divergencias." <<< "$BOTH_RESULT"; then
    pass "ambos usa exclusivamente el canonico y emite AVISO"
else
    fail "ambos no conserva precedencia o AVISO: $BOTH_RESULT"
fi

echo "[3] Consumidor legacy"
LEGACY_ROOT="$TMP_DIR/legacy"
mkdir -p "$LEGACY_ROOT"
git -C "$LEGACY_ROOT" init -q
write_config "$LEGACY_ROOT/.claude/harness.config.json" '["calculo-horas"]'
assert_resolves "legacy" "$LEGACY_ROOT" calculo-horas calculo-horas

echo "[4] Ausencia de ambos configs"
MISSING_ROOT="$TMP_DIR/missing"
mkdir -p "$MISSING_ROOT"
git -C "$MISSING_ROOT" init -q
MISSING_RESULT=$(run_skill_block "$MISSING_ROOT" calculo-horas)
if [ "${MISSING_RESULT%%$'\n'*}" -ne 0 ] \
    && grep -Fq 'ERROR: no se encontro el config canonico requerido' <<< "$MISSING_RESULT" \
    && grep -Fq 'Se acepta solo para lectura el fallback legacy' <<< "$MISSING_RESULT"; then
    pass "ausencia aborta y explica canonico y fallback"
else
    fail "ausencia no aborto con el diagnostico esperado: $MISSING_RESULT"
fi

echo "[5] Anti-regresion de lecturas y mensajes legacy"
CANONICAL_COUNT=$(grep -Fc 'CONFIG="$REPO_ROOT/.mefisto/harness.config.json"' "$COMMAND" || true)
LEGACY_COUNT=$(grep -Fc 'CONFIG="$REPO_ROOT/.claude/harness.config.json"' "$COMMAND" || true)
if [ "$CANONICAL_COUNT" -eq 1 ] && [ "$LEGACY_COUNT" -eq 1 ]; then
    pass "el skill contiene exactamente un par canonico/legacy"
else
    fail "pares de resolver inesperados: canonico/legacy=$CANONICAL_COUNT/$LEGACY_COUNT"
fi
if grep -Eq '(^|[;&|[:space:]])jq[[:space:]].*\.claude/harness\.config\.json|(^|[;&|[:space:]])(cat|sed|awk|grep)[[:space:]].*\.claude/harness\.config\.json|<[[:space:]]*[^[:space:]]*\.claude/harness\.config\.json' "$COMMAND" "$SCRIPT"; then
    fail "reaparecio una lectura directa del config legacy"
else
    pass "no hay lecturas directas del config legacy"
fi
if grep -Eq 'jq[[:space:]].*\.(mefisto|claude)/harness\.config\.json' "$COMMAND" "$SCRIPT"; then
    fail "alguna lectura jq evita la ruta efectiva CONFIG"
else
    pass "las lecturas jq del skill usan CONFIG"
fi
if grep -Fq 'de .claude/harness.config.json' "$SCRIPT"; then
    fail "el error de dominio del script no usa HARNESS_CONFIG_PATH"
else
    pass "el error de dominio del script usa la ruta efectiva"
fi
if ! grep -Fq 'fallback' "$SCRIPT" \
    || ! grep -Fq 'legacy solo de lectura en .claude/harness.config.json' "$SCRIPT" \
    || ! grep -Fq 'fallback de lectura si no existe el canonico' "$COMMAND"; then
    fail "la prosa no califica la ruta legacy como fallback de lectura"
else
    pass "la prosa califica la ruta legacy como fallback de lectura"
fi

echo "[6] Sintaxis del script"
if bash -n "$SCRIPT"; then
    pass "purge-store.sh pasa bash -n"
else
    fail "purge-store.sh no pasa bash -n"
fi

echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
