#!/usr/bin/env bash
# test-scaffold-projections-config-path.sh -- Contrato de ruta del token de proyecciones (#1500).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMAND="$REPO_ROOT/commands/scaffold-projections.md"
AGENT="$REPO_ROOT/agents/projections-scaffolder.md"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

resolve_config() {
    local root="$1" canonical legacy
    canonical="$root/.mefisto/harness.config.json"
    legacy="$root/.claude/harness.config.json"
    if [ -f "$canonical" ]; then
        if [ -f "$legacy" ]; then
            echo "AVISO: se usara el config canonico $canonical; se ignora el legacy $legacy. Migra o elimina conscientemente el archivo legacy para evitar divergencias." >&2
        fi
        printf '%s\n' "$canonical"
        return 0
    fi
    if [ -f "$legacy" ]; then
        printf '%s\n' "$legacy"
        return 0
    fi
    echo "ERROR: no se encontro el config canonico requerido $canonical." >&2
    echo "  Se acepta solo para lectura el fallback legacy $legacy." >&2
    return 1
}

write_config() {
    local path="$1" enabled="$2"
    mkdir -p "$(dirname "$path")"
    printf '{"projections":{"enabled":%s}}\n' "$enabled" > "$path"
}

assert_config() {
    local label="$1" root="$2" expected="$3" actual
    actual=$(resolve_config "$root" 2>"$TMP_DIR/$label.stderr")
    if [ "$?" -eq 0 ] && [ "$actual" = "$expected" ]; then
        pass "$label resuelve la ruta efectiva"
    else
        fail "$label no resolvio '$expected'"
    fi
}

echo "[1] Consumidor canonico"
CANONICAL_ROOT="$TMP_DIR/canonical"
write_config "$CANONICAL_ROOT/.mefisto/harness.config.json" true
assert_config "canonico" "$CANONICAL_ROOT" "$CANONICAL_ROOT/.mefisto/harness.config.json"
if [ "$(jq -r '.projections.enabled' "$(resolve_config "$CANONICAL_ROOT")")" = "true" ]; then
    pass "canonico habilita projections.enabled"
else
    fail "canonico no entrega projections.enabled=true"
fi

echo "[2] Ambos configs divergentes: prevalece el canonico y emite AVISO"
BOTH_ROOT="$TMP_DIR/both"
write_config "$BOTH_ROOT/.mefisto/harness.config.json" true
write_config "$BOTH_ROOT/.claude/harness.config.json" false
assert_config "ambos" "$BOTH_ROOT" "$BOTH_ROOT/.mefisto/harness.config.json"
if [ "$(jq -r '.projections.enabled' "$(resolve_config "$BOTH_ROOT" 2>"$TMP_DIR/both-read.stderr")")" = "true" ] \
    && grep -Fq "AVISO: se usara el config canonico $BOTH_ROOT/.mefisto/harness.config.json; se ignora el legacy $BOTH_ROOT/.claude/harness.config.json. Migra o elimina conscientemente el archivo legacy para evitar divergencias." "$TMP_DIR/both-read.stderr"; then
    pass "ambos usa solo el canonico y anuncia la divergencia"
else
    fail "ambos no preserva la precedencia o el AVISO"
fi

echo "[3] Consumidor legacy"
LEGACY_ROOT="$TMP_DIR/legacy"
write_config "$LEGACY_ROOT/.claude/harness.config.json" true
assert_config "legacy" "$LEGACY_ROOT" "$LEGACY_ROOT/.claude/harness.config.json"
if [ "$(jq -r '.projections.enabled' "$(resolve_config "$LEGACY_ROOT")")" = "true" ]; then
    pass "legacy habilita projections.enabled mediante fallback"
else
    fail "legacy no entrega projections.enabled=true"
fi

echo "[4] Ausencia de ambos configs"
MISSING_ROOT="$TMP_DIR/missing"
mkdir -p "$MISSING_ROOT"
if resolve_config "$MISSING_ROOT" >"$TMP_DIR/missing.stdout" 2>"$TMP_DIR/missing.stderr"; then
    fail "ausencia debe abortar"
elif grep -Fq "config canonico requerido $MISSING_ROOT/.mefisto/harness.config.json" "$TMP_DIR/missing.stderr" \
    && grep -Fq "fallback legacy $MISSING_ROOT/.claude/harness.config.json" "$TMP_DIR/missing.stderr"; then
    pass "ausencia aborta y explica contrato canonico y fallback"
else
    fail "ausencia no explica el contrato y fallback"
fi

echo "[5] Skill y agente conservan el resolver explicito"
for path in "$COMMAND" "$AGENT"; do
    name=$(basename "$path")
    if grep -Fq 'CONFIG="$REPO_ROOT/.mefisto/harness.config.json"' "$path" \
        && grep -Fq 'LEGACY_CONFIG="$REPO_ROOT/.claude/harness.config.json"' "$path" \
        && grep -Fq 'RAW=$(jq -r '\''.projections.enabled'\'' "$CONFIG" 2>/dev/null)' "$path" \
        && grep -Fq 'AVISO: se usara el config canonico $CONFIG; se ignora el legacy $LEGACY_CONFIG. Migra o elimina conscientemente el archivo legacy para evitar divergencias.' "$path"; then
        pass "$name resuelve canonico, fallback y AVISO mediante CONFIG"
    else
        fail "$name no contiene el resolver requerido"
    fi
    if grep -Eq '(^|[;&|[:space:]])(jq|cat)[[:space:]].*\.claude/harness\.config\.json|<[[:space:]]*[^[:space:]]*\.claude/harness\.config\.json' "$path"; then
        fail "$name reintroduce una lectura directa legacy"
    else
        pass "$name no lee directamente el config legacy"
    fi
    if grep -E '^[[:space:]]*echo .*\.claude/harness\.config\.json' "$path" | grep -Ev 'fallback legacy|AVISO:.*legacy' | grep -q .; then
        fail "$name nombra el legacy en un mensaje sin calificarlo"
    else
        pass "$name califica toda referencia legacy en mensajes de usuario"
    fi
done

echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
