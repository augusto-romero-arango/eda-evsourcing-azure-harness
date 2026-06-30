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
# Cubre la validacion de boundedContext (issue #131, ADR-0023):
#   BC-1: boundedContext ausente aborta (return 1) con mensaje accionable de migracion.
#   BC-2: un boundedContext valido (name + domains subconjunto de domainLabels) pasa
#         (return 0) y exporta HARNESS_BC_NAME / HARNESS_BC_DOMAINS.
#   BC-3: name vacio o con caracteres invalidos (>63 chars, espacios, puntos) aborta.
#   BC-4: domains vacio, o con un dominio fuera de domainLabels, aborta.
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
# Genera un harness.config.json valido en los campos obligatorios (incluido un
# boundedContext valido, obligatorio desde issue #131). Si el segundo argumento
# es __OMIT__, omite por completo terraformStateStorage del JSON.
write_config() {
    local file="$1"
    local tfstate="$2"
    if [ "$tfstate" = "__OMIT__" ]; then
        cat > "$file" <<'JSON'
{
  "projectName": "MiControlPlane",
  "namespacePrefix": "MiControlPlane.Dominio",
  "solutionFile": "MiControlPlane.slnx",
  "domainLabels": ["dominio1", "dominio2"],
  "boundedContext": { "name": "Principal", "domains": ["dominio1"] }
}
JSON
    else
        cat > "$file" <<JSON
{
  "projectName": "MiControlPlane",
  "namespacePrefix": "MiControlPlane.Dominio",
  "solutionFile": "MiControlPlane.slnx",
  "terraformStateStorage": "$tfstate",
  "domainLabels": ["dominio1", "dominio2"],
  "boundedContext": { "name": "Principal", "domains": ["dominio1"] }
}
JSON
    fi
}

# write_bc_config <archivo> <fragmento_boundedContext|__OMIT__>
# Genera un config con required + domainLabels=[dominio1,dominio2] y el bloque
# boundedContext indicado tal cual (debe ser JSON valido). __OMIT__ omite por
# completo el campo boundedContext (caso consumidor legacy).
write_bc_config() {
    local file="$1"
    local bc="$2"
    if [ "$bc" = "__OMIT__" ]; then
        cat > "$file" <<'JSON'
{
  "projectName": "MiControlPlane",
  "namespacePrefix": "MiControlPlane.Dominio",
  "solutionFile": "MiControlPlane.slnx",
  "domainLabels": ["dominio1", "dominio2"]
}
JSON
    else
        cat > "$file" <<JSON
{
  "projectName": "MiControlPlane",
  "namespacePrefix": "MiControlPlane.Dominio",
  "solutionFile": "MiControlPlane.slnx",
  "domainLabels": ["dominio1", "dominio2"],
  "boundedContext": $bc
}
JSON
    fi
}

# bc_exports <config_path> -> imprime "HARNESS_BC_NAME|HARNESS_BC_DOMAINS"
# tras cargar el config (independiente del exit code).
bc_exports() {
    local cfg="$1"
    (
        set +u
        source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null
        load_harness_config "$cfg" >/dev/null 2>&1 || true
        echo "${HARNESS_BC_NAME:-}|${HARNESS_BC_DOMAINS:-}"
    )
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
echo "[BC-1] boundedContext ausente aborta con mensaje accionable de migracion"

CFG="$TMP_DIR/bc-omit.json"
write_bc_config "$CFG" "__OMIT__"
ERR="$(run_load "$CFG" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ]; then pass "boundedContext ausente -> return 1"; else fail "boundedContext ausente deberia abortar (rc=$RC)"; fi
if echo "$ERR" | grep -q "boundedContext"; then pass "el mensaje menciona 'boundedContext'"; else fail "el mensaje no menciona 'boundedContext'"; fi
if echo "$ERR" | grep -q '"domains"'; then pass "el mensaje muestra el shape (domains) con los domainLabels"; else fail "el mensaje no muestra el shape a anadir"; fi

echo ""
echo "[BC-2] boundedContext valido pasa y exporta HARNESS_BC_*"

CFG="$TMP_DIR/bc-valid.json"
write_bc_config "$CFG" '{ "name": "Principal", "domains": ["dominio1"] }'
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then pass "subconjunto de domainLabels -> return 0"; else fail "boundedContext valido NO deberia abortar (rc=$RC)"; fi
if [ "$(bc_exports "$CFG")" = "Principal|dominio1" ]; then pass "exporta HARNESS_BC_NAME='Principal' HARNESS_BC_DOMAINS='dominio1'"; else fail "exports incorrectos: $(bc_exports "$CFG")"; fi

CFG="$TMP_DIR/bc-all.json"
write_bc_config "$CFG" '{ "name": "Principal", "domains": ["dominio1", "dominio2"] }'
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then pass "todos los domainLabels -> return 0"; else fail "boundedContext con todos los dominios deberia pasar (rc=$RC)"; fi
if [ "$(bc_exports "$CFG")" = "Principal|dominio1 dominio2" ]; then pass "HARNESS_BC_DOMAINS separa por espacios"; else fail "HARNESS_BC_DOMAINS incorrecto: $(bc_exports "$CFG")"; fi

echo ""
echo "[BC-3] boundedContext.name invalido aborta"

CFG="$TMP_DIR/bc-name-empty.json"
write_bc_config "$CFG" '{ "name": "", "domains": ["dominio1"] }'
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ]; then pass "name vacio -> return 1"; else fail "name vacio deberia abortar (rc=$RC)"; fi

CFG="$TMP_DIR/bc-name-space.json"
write_bc_config "$CFG" '{ "name": "mi bc", "domains": ["dominio1"] }'
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ]; then pass "name con espacio -> return 1"; else fail "name con espacio deberia abortar (rc=$RC)"; fi

CFG="$TMP_DIR/bc-name-dot.json"
write_bc_config "$CFG" '{ "name": "Mi.BC", "domains": ["dominio1"] }'
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ]; then pass "name con punto -> return 1"; else fail "name con punto deberia abortar (rc=$RC)"; fi

LONG_NAME="$(printf 'a%.0s' {1..64})"  # 64 chars (> 63)
CFG="$TMP_DIR/bc-name-long.json"
write_bc_config "$CFG" "{ \"name\": \"$LONG_NAME\", \"domains\": [\"dominio1\"] }"
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ]; then pass "name de 64 chars -> return 1"; else fail "name de 64 chars deberia abortar (rc=$RC)"; fi

echo ""
echo "[BC-4] boundedContext.domains invalido aborta"

CFG="$TMP_DIR/bc-domains-empty.json"
write_bc_config "$CFG" '{ "name": "Principal", "domains": [] }'
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ]; then pass "domains vacio -> return 1"; else fail "domains vacio deberia abortar (rc=$RC)"; fi

CFG="$TMP_DIR/bc-domains-out.json"
write_bc_config "$CFG" '{ "name": "Principal", "domains": ["ventas"] }'
ERR="$(run_load "$CFG" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ]; then pass "dominio fuera de domainLabels -> return 1"; else fail "dominio fuera de domainLabels deberia abortar (rc=$RC)"; fi
if echo "$ERR" | grep -q "ventas"; then pass "el mensaje nombra el dominio invalido ('ventas')"; else fail "el mensaje no nombra el dominio invalido"; fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
