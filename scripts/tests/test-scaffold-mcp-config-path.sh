#!/usr/bin/env bash
# test-scaffold-mcp-config-path.sh -- Contrato de resolución de config de /scaffold-mcp (#1501).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMAND="$REPO_ROOT/commands/scaffold-mcp.md"
AGENT="$REPO_ROOT/agents/mcp-scaffolder.md"
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
    local path="$1" namespace="$2" solution="$3" domain="$4" tenancy="$5"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<JSON
{"namespacePrefix":"$namespace","solutionFile":"$solution","boundedContext":{"domains":["$domain"]},"tenancy":{"strategy":"$tenancy"}}
JSON
}

tokens() {
    jq -r '[.namespacePrefix, .solutionFile, .boundedContext.domains[0], .tenancy.strategy] | join("|")' "$1"
}

assert_config() {
    local label="$1" root="$2" expected_path="$3" expected_tokens="$4" actual_path actual_tokens
    actual_path=$(resolve_config "$root" 2>"$TMP_DIR/$label.stderr") || { fail "$label no resolvio config"; return; }
    actual_tokens=$(tokens "$actual_path")
    if [ "$actual_path" = "$expected_path" ] && [ "$actual_tokens" = "$expected_tokens" ]; then
        pass "$label resuelve los cuatro tokens esperados"
    else
        fail "$label esperaba $expected_path ($expected_tokens) y obtuvo $actual_path ($actual_tokens)"
    fi
}

echo "[1] Consumidor canonico"
CANONICAL_ROOT="$TMP_DIR/canonical"
write_config "$CANONICAL_ROOT/.mefisto/harness.config.json" Canonical Canonical.slnx canonical-domain multi-tenant-header
assert_config "canonico" "$CANONICAL_ROOT" "$CANONICAL_ROOT/.mefisto/harness.config.json" "Canonical|Canonical.slnx|canonical-domain|multi-tenant-header"

echo "[2] Ambos configs divergentes"
BOTH_ROOT="$TMP_DIR/both"
write_config "$BOTH_ROOT/.mefisto/harness.config.json" Canonical Canonical.slnx canonical-domain multi-tenant-header
write_config "$BOTH_ROOT/.claude/harness.config.json" Legacy Legacy.slnx legacy-domain mono-tenant-transitorio
assert_config "ambos" "$BOTH_ROOT" "$BOTH_ROOT/.mefisto/harness.config.json" "Canonical|Canonical.slnx|canonical-domain|multi-tenant-header"
if grep -Fq "AVISO: se usara el config canonico $BOTH_ROOT/.mefisto/harness.config.json; se ignora el legacy $BOTH_ROOT/.claude/harness.config.json. Migra o elimina conscientemente el archivo legacy para evitar divergencias." "$TMP_DIR/ambos.stderr"; then
    pass "ambos emite el AVISO canonico"
else
    fail "ambos no emite el AVISO canonico"
fi

echo "[3] Consumidor legacy"
LEGACY_ROOT="$TMP_DIR/legacy"
write_config "$LEGACY_ROOT/.claude/harness.config.json" Legacy Legacy.slnx legacy-domain mono-tenant-transitorio
assert_config "legacy" "$LEGACY_ROOT" "$LEGACY_ROOT/.claude/harness.config.json" "Legacy|Legacy.slnx|legacy-domain|mono-tenant-transitorio"

echo "[4] Ausencia de ambos configs"
MISSING_ROOT="$TMP_DIR/missing"
mkdir -p "$MISSING_ROOT"
if resolve_config "$MISSING_ROOT" >"$TMP_DIR/missing.stdout" 2>"$TMP_DIR/missing.stderr"; then
    fail "ausencia debe abortar"
elif grep -Fq "config canonico requerido $MISSING_ROOT/.mefisto/harness.config.json" "$TMP_DIR/missing.stderr" \
    && grep -Fq "fallback legacy $MISSING_ROOT/.claude/harness.config.json" "$TMP_DIR/missing.stderr"; then
    pass "ausencia aborta y explica el contrato canonico y el fallback"
else
    fail "ausencia no explica el contrato canonico y el fallback"
fi

echo "[5] Skill (preludio renderizado de config-path) y agente usan la ruta efectiva (#1662, #1661)"
for path in "$COMMAND" "$AGENT"; do
    name=$(basename "$path")
    if grep -Fq 'MEFISTO_CONFIG_PATH=".mefisto/harness.config.json"' "$path" \
        && grep -Fq 'MEFISTO_CONFIG_PATH=".claude/harness.config.json"' "$path" \
        && grep -Fq "AVISO: se usara el config canonico .mefisto/harness.config.json; se ignora el legacy .claude/harness.config.json." "$path"; then
        pass "$name resuelve canonico, fallback y AVISO mediante el preludio renderizado"
    else
        fail "$name no contiene el resolver requerido"
    fi
done
if grep -Fq 'jq -r '\''.namespacePrefix // ""'\'' "${MEFISTO_CONFIG_PATH}"' "$COMMAND" \
    && grep -Fq 'jq -r '\''.solutionFile // ""'\'' "${MEFISTO_CONFIG_PATH}"' "$COMMAND" \
    && grep -Fq 'jq -r '\''.boundedContext.domains[0] // ""'\'' "$CONFIG"' "$AGENT" \
    && grep -Fq 'jq -r '\''.tenancy.strategy // "mono-tenant-transitorio"'\'' "$CONFIG"' "$AGENT" \
    && grep -Fq 'jq -r '\''.boundedContext.domains[]'\'' "$CONFIG"' "$AGENT"; then
    pass "los tokens se leen desde la ruta efectiva del config"
else
    fail "alguno de los tokens no usa la ruta efectiva"
fi
if grep -Fq 'Nunca copies, migres ni escribas el archivo de config' "$AGENT"; then
    pass "el agente prohibe escribir el config"
else
    fail "el agente no documenta la prohibicion de escritura"
fi

echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
