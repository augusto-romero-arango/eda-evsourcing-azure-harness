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
if grep -Fq 'Resuelve primero el contrato canonico `.mefisto/harness.config.json`' "$COMMAND" \
    && grep -Fq 'solo como fallback de lectura' "$COMMAND" \
    && grep -Fq 'Nunca copies, migres ni escribas ninguno de esos archivos.' "$COMMAND" \
    && grep -Fq '**El dominio de ejemplo**, del contrato canonico `.mefisto/harness.config.json`' "$AGENT" \
    && grep -Fq 'Nunca copies, migres ni escribas el archivo legacy' "$AGENT" \
    && grep -Fq '**Estado de auth del BC**, del mismo contrato canonico `.mefisto/harness.config.json`' "$AGENT"; then
    pass "la prosa documenta canonico, fallback y prohibicion de escritura"
else
    fail "la prosa no documenta completamente el contrato de lectura"
fi
if python3 - "$COMMAND" "$AGENT" <<'PY'
import re
import sys
from pathlib import Path

expected = {sys.argv[1]: 1, sys.argv[2]: 3}
notice = "AVISO: se usara el config canonico $CONFIG; se ignora el legacy $REPO_ROOT/.claude/harness.config.json."
for path, count in expected.items():
    text = Path(path).read_text()
    blocks = [block for block in re.findall(r"```bash\n(.*?)\n```", text, re.S)
              if 'CONFIG="$REPO_ROOT/.mefisto/harness.config.json"' in block]
    if len(blocks) != count:
        raise SystemExit(1)
    for block in blocks:
        required = (
            'REPO_ROOT=$(git rev-parse --show-toplevel',
            'CONFIG="$REPO_ROOT/.claude/harness.config.json"',
            notice,
            'config canonico requerido $REPO_ROOT/.mefisto/harness.config.json',
            'fallback legacy $REPO_ROOT/.claude/harness.config.json',
        )
        if any(fragment not in block for fragment in required):
            raise SystemExit(1)
PY
then
    pass "cada bloque es autocontenido y conserva AVISO y aborto"
else
    fail "algun bloque no rederiva el resolver completo"
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
