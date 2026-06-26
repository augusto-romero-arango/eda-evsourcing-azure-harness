#!/usr/bin/env bash
# test-harness-config.sh -- Tests de load_harness_config (scripts/_pipeline-common.sh).
#
# Cubre la validacion de formato de terraformStateStorage (issue #78):
#   CA-1: load_harness_config aborta (return 1) cuando terraformStateStorage tiene
#         valor y NO cumple ^[a-z0-9]{3,24}$ (>24 chars, mayusculas, guiones, etc.).
#   CA-2: un terraformStateStorage vacio o ausente NO dispara el error.
#   CA-3: un nombre valido (3-24 chars, minusculas + digitos) pasa sin error.
#   CA-4: el mensaje de error indica el limite y sugiere abreviar el prefijo.
#
# Uso: scripts/tests/test-harness-config.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq no esta instalado; load_harness_config requiere jq para parsear el config." >&2
    exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# write_config <archivo> <terraformStateStorage|__OMIT__>
# Genera un harness.config.json valido en los campos obligatorios. Si el segundo
# argumento es __OMIT__, omite por completo terraformStateStorage del JSON.
write_config() {
    local file="$1"
    local tfstate="$2"
    if [ "$tfstate" = "__OMIT__" ]; then
        cat > "$file" <<'JSON'
{
  "projectName": "MiControlPlane",
  "namespacePrefix": "MiControlPlane.Dominio",
  "solutionFile": "MiControlPlane.slnx"
}
JSON
    else
        cat > "$file" <<JSON
{
  "projectName": "MiControlPlane",
  "namespacePrefix": "MiControlPlane.Dominio",
  "solutionFile": "MiControlPlane.slnx",
  "terraformStateStorage": "$tfstate"
}
JSON
    fi
}

# run_load <config_path>  -> imprime exit code en stdout, mensajes en archivo .err
run_load() {
    local cfg="$1"
    (
        set +u
        source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null
        load_harness_config "$cfg"
    )
}

echo "[CA-1] terraformStateStorage invalido aborta con return 1"

# >24 caracteres (el caso real de campo: 26 chars)
CFG="$TMP_DIR/too-long.json"
write_config "$CFG" "stmicontrolplanetfstatedev"
ERR="$(run_load "$CFG" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ]; then pass "nombre de 26 chars -> return 1"; else fail "nombre de 26 chars deberia abortar (rc=$RC)"; fi

# mayusculas
CFG="$TMP_DIR/uppercase.json"
write_config "$CFG" "stMcpTfstateDev"
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ]; then pass "mayusculas -> return 1"; else fail "mayusculas deberia abortar (rc=$RC)"; fi

# guiones / caracteres no permitidos
CFG="$TMP_DIR/dashes.json"
write_config "$CFG" "st-mcp-tfstate-dev"
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ]; then pass "guiones -> return 1"; else fail "guiones deberia abortar (rc=$RC)"; fi

# demasiado corto (<3 chars)
CFG="$TMP_DIR/too-short.json"
write_config "$CFG" "ab"
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ]; then pass "2 chars -> return 1"; else fail "2 chars deberia abortar (rc=$RC)"; fi

echo ""
echo "[CA-2] terraformStateStorage vacio o ausente NO dispara el error"

# campo vacio (consumidor sin IaC)
CFG="$TMP_DIR/empty.json"
write_config "$CFG" ""
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then pass "valor vacio -> return 0"; else fail "valor vacio NO deberia abortar (rc=$RC)"; fi

# campo ausente del JSON
CFG="$TMP_DIR/omitted.json"
write_config "$CFG" "__OMIT__"
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then pass "campo ausente -> return 0"; else fail "campo ausente NO deberia abortar (rc=$RC)"; fi

echo ""
echo "[CA-3] terraformStateStorage valido pasa sin error"

# nombre valido del propio issue (15 chars)
CFG="$TMP_DIR/valid.json"
write_config "$CFG" "stmcptfstatedev"
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then pass "stmcptfstatedev (15 chars) -> return 0"; else fail "nombre valido NO deberia abortar (rc=$RC)"; fi

# limites exactos: 3 y 24 chars
CFG="$TMP_DIR/min.json"
write_config "$CFG" "abc"
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then pass "3 chars (limite inferior) -> return 0"; else fail "3 chars deberia pasar (rc=$RC)"; fi

CFG="$TMP_DIR/max.json"
write_config "$CFG" "abcdefghij0123456789abcd"  # 24 chars
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then pass "24 chars (limite superior) -> return 0"; else fail "24 chars deberia pasar (rc=$RC)"; fi

echo ""
echo "[CA-4] el mensaje de error indica el limite y sugiere abreviar"

CFG="$TMP_DIR/msg.json"
write_config "$CFG" "stmicontrolplanetfstatedev"
ERR="$(run_load "$CFG" 2>&1)"
if echo "$ERR" | grep -q "3-24 caracteres"; then
    pass "menciona el limite '3-24 caracteres'"
else
    fail "el mensaje no menciona el limite '3-24 caracteres'"
fi
if echo "$ERR" | grep -qi "abrevia"; then
    pass "sugiere abreviar el prefijo"
else
    fail "el mensaje no sugiere abreviar el prefijo"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
