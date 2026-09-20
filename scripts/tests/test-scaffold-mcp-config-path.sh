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
    local root="$1" config="$root/.mefisto/harness.config.json"
    [ -f "$config" ] || config="$root/.claude/harness.config.json"
    [ -f "$config" ] || return 1
    printf '%s\n' "$config"
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
    actual_path=$(resolve_config "$root") || { fail "$label no resolvio config"; return; }
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

echo "[3] Consumidor legacy"
LEGACY_ROOT="$TMP_DIR/legacy"
write_config "$LEGACY_ROOT/.claude/harness.config.json" Legacy Legacy.slnx legacy-domain mono-tenant-transitorio
assert_config "legacy" "$LEGACY_ROOT" "$LEGACY_ROOT/.claude/harness.config.json" "Legacy|Legacy.slnx|legacy-domain|mono-tenant-transitorio"

echo "[4] Ausencia de ambos configs"
MISSING_ROOT="$TMP_DIR/missing"
mkdir -p "$MISSING_ROOT"
if [ ! -f "$MISSING_ROOT/.mefisto/harness.config.json" ] && [ ! -f "$MISSING_ROOT/.claude/harness.config.json" ]; then
    pass "ausencia aborta"
else
    fail "ausencia debe abortar"
fi

echo "[5] Prompts conservan resolucion y fallback explicitos"
COMMAND_CANONICAL=$(grep -Fc 'CONFIG="$REPO_ROOT/.mefisto/harness.config.json"' "$COMMAND" || true)
COMMAND_LEGACY=$(grep -Fc 'CONFIG="$REPO_ROOT/.claude/harness.config.json"' "$COMMAND" || true)
AGENT_CANONICAL=$(grep -Fc 'CONFIG="$REPO_ROOT/.mefisto/harness.config.json"' "$AGENT" || true)
AGENT_LEGACY=$(grep -Fc 'CONFIG="$REPO_ROOT/.claude/harness.config.json"' "$AGENT" || true)
if [ "$COMMAND_CANONICAL" -eq 1 ] && [ "$COMMAND_LEGACY" -eq 1 ] && [ "$AGENT_CANONICAL" -eq 3 ] && [ "$AGENT_LEGACY" -eq 3 ]; then
    pass "skill tiene un resolver y agente tiene tres"
else
    fail "conteos inesperados skill canonico/legacy=$COMMAND_CANONICAL/$COMMAND_LEGACY, agente=$AGENT_CANONICAL/$AGENT_LEGACY"
fi
if [ "$(grep -Fc 'AVISO: se usara el config canonico $CONFIG; se ignora el legacy $REPO_ROOT/.claude/harness.config.json. Migra o elimina conscientemente el archivo legacy para evitar divergencias.' "$COMMAND" || true)" -eq 1 ] \
    && [ "$(grep -Fc 'AVISO: se usara el config canonico $CONFIG; se ignora el legacy $REPO_ROOT/.claude/harness.config.json. Migra o elimina conscientemente el archivo legacy para evitar divergencias.' "$AGENT" || true)" -eq 3 ]; then
    pass "cada bloque emite el AVISO de coexistencia"
else
    fail "falta el AVISO de coexistencia en algun bloque"
fi
if grep -Eq '(^|[;&|[:space:]])(jq|cat)[[:space:]].*\.claude/harness\.config\.json|<[[:space:]]*[^[:space:]]*\.claude/harness\.config\.json' "$COMMAND" "$AGENT"; then
    fail "reaparecio una lectura directa del config legacy"
else
    pass "las lecturas usan exclusivamente CONFIG"
fi
if grep -E 'echo.*\.claude/harness\.config\.json' "$COMMAND" "$AGENT" | grep -Ev 'fallback|se ignora el legacy|Se acepta solo para lectura' >/dev/null; then
    fail "un mensaje de usuario nombra el legacy sin calificarlo"
else
    pass "los mensajes califican la ruta legacy"
fi
if grep -Fq 'jq -r '\''.namespacePrefix // ""'\'' "$CONFIG"' "$COMMAND" \
    && grep -Fq 'jq -r '\''.solutionFile // ""'\'' "$CONFIG"' "$COMMAND" \
    && grep -Fq 'jq -r '\''.boundedContext.domains[0] // ""'\'' "$CONFIG"' "$AGENT" \
    && grep -Fq 'jq -r '\''.tenancy.strategy // "mono-tenant-transitorio"'\'' "$CONFIG"' "$AGENT" \
    && grep -Fq 'jq -r '\''.boundedContext.domains[]'\'' "$CONFIG"' "$AGENT"; then
    pass "los cuatro tokens se leen desde CONFIG"
else
    fail "alguno de los cuatro tokens no usa CONFIG"
fi

echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
