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
# Cubre la validacion del registro serviceBus (issue #163, ADR-0024):
#   SB-1: serviceBus ausente NO aborta (opcional) y deja los HARNESS_SB_* vacios.
#   SB-2: serviceBus.internal.secretName vacio o ausente aborta con mensaje accionable.
#   SB-3: serviceBus valido con internal + external pasa y exporta HARNESS_SB_* (listas
#         paralelas separadas por espacios, mismo orden posicional).
#   SB-4: serviceBus con solo internal (sin external) pasa y deja los HARNESS_SB_EXTERNAL_*
#         vacios.
#   SB-5..SB-7: una entrada de external con alias/alcance/secretName invalido aborta.
#   SB-8: alias reservado INTERNO reutilizado en external aborta (case-insensitive).
#   SB-9: aliases duplicados en external abortan (case-insensitive).
#
# Cubre la validacion del registro secrets[] y el helper upsert_harness_secret
# (issue #256, siembra data-driven de infra-cd.yml):
#   SEC-1: secrets ausente NO aborta (opcional) y deja los HARNESS_SECRETS_* vacios.
#   SEC-2: secrets valido (output/github-secret/composite) pasa y exporta listas paralelas.
#   SEC-3: entrada con 'name' vacio aborta.
#   SEC-4: entrada con 'source.type' invalido aborta.
#   SEC-5: entrada con 'source.value' vacio aborta.
#   SEC-6: 'name' duplicado aborta.
#   SEC-7: 'secrets' que no es un array aborta.
#   UPSERT-1: upsert_harness_secret crea el array 'secrets' si el config no lo declara.
#   UPSERT-2: upsert_harness_secret agrega una entrada nueva sin tocar las existentes.
#   UPSERT-3: upsert_harness_secret actualiza (no duplica) una entrada existente por 'name'.
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

# write_sb_config <archivo> <fragmento_serviceBus|__OMIT__>
# Genera un config con required + domainLabels + boundedContext valido, y el
# bloque serviceBus indicado tal cual (debe ser JSON valido). __OMIT__ omite
# por completo el campo serviceBus (caso consumidor que aun no lo declara).
write_sb_config() {
    local file="$1"
    local sb="$2"
    if [ "$sb" = "__OMIT__" ]; then
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
  "domainLabels": ["dominio1", "dominio2"],
  "boundedContext": { "name": "Principal", "domains": ["dominio1"] },
  "serviceBus": $sb
}
JSON
    fi
}

# sb_exports <config_path> -> imprime "INTERNAL|ALIASES|ALCANCES|SECRETS"
# tras cargar el config (independiente del exit code).
sb_exports() {
    local cfg="$1"
    (
        set +u
        source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null
        load_harness_config "$cfg" >/dev/null 2>&1 || true
        echo "${HARNESS_SB_INTERNAL_SECRET:-}|${HARNESS_SB_EXTERNAL_ALIASES:-}|${HARNESS_SB_EXTERNAL_ALCANCES:-}|${HARNESS_SB_EXTERNAL_SECRETS:-}"
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

# write_secrets_config <archivo> <fragmento_secrets|__OMIT__>
# Genera un config con required + domainLabels + boundedContext valido, y el campo
# 'secrets' indicado tal cual (debe ser JSON valido). __OMIT__ omite el campo por completo.
write_secrets_config() {
    local file="$1"
    local sec="$2"
    if [ "$sec" = "__OMIT__" ]; then
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
  "domainLabels": ["dominio1", "dominio2"],
  "boundedContext": { "name": "Principal", "domains": ["dominio1"] },
  "secrets": $sec
}
JSON
    fi
}

# secrets_exports <config_path> -> imprime "NAMES|TYPES|VALUES" tras cargar el config
# (independiente del exit code).
secrets_exports() {
    local cfg="$1"
    (
        set +u
        source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null
        load_harness_config "$cfg" >/dev/null 2>&1 || true
        echo "${HARNESS_SECRETS_NAMES:-}|${HARNESS_SECRETS_TYPES:-}|${HARNESS_SECRETS_VALUES:-}"
    )
}

# run_upsert <config_path> <name> <type> <value> -> corre upsert_harness_secret sobre
# <config_path>. El subshell no impide que el archivo quede escrito: 'mv' es una
# escritura real a disco, no una variable exportada que se perderia al salir del subshell.
run_upsert() {
    local cfg="$1" name="$2" type="$3" value="$4"
    (
        set +u
        source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null
        upsert_harness_secret "$name" "$type" "$value" "$cfg"
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
echo "[SB-1] serviceBus ausente NO aborta (opcional) y deja HARNESS_SB_* vacios"

CFG="$TMP_DIR/sb-omit.json"
write_sb_config "$CFG" "__OMIT__"
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then pass "serviceBus ausente -> return 0"; else fail "serviceBus ausente NO deberia abortar (rc=$RC)"; fi
if [ "$(sb_exports "$CFG")" = "|||" ]; then pass "HARNESS_SB_* quedan vacios"; else fail "exports deberian quedar vacios: $(sb_exports "$CFG")"; fi

echo ""
echo "[SB-2] serviceBus.internal.secretName vacio o ausente aborta"

CFG="$TMP_DIR/sb-internal-empty.json"
write_sb_config "$CFG" '{ "internal": { "secretName": "" } }'
ERR="$(run_load "$CFG" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ]; then pass "internal.secretName vacio -> return 1"; else fail "internal.secretName vacio deberia abortar (rc=$RC)"; fi
if echo "$ERR" | grep -q "internal.secretName"; then pass "el mensaje menciona 'internal.secretName'"; else fail "el mensaje no menciona 'internal.secretName'"; fi

CFG="$TMP_DIR/sb-internal-missing.json"
write_sb_config "$CFG" '{ }'
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ]; then pass "internal ausente -> return 1"; else fail "internal ausente deberia abortar (rc=$RC)"; fi

echo ""
echo "[SB-3] serviceBus valido con internal + external pasa y exporta listas paralelas"

CFG="$TMP_DIR/sb-valid.json"
write_sb_config "$CFG" '{ "internal": { "secretName": "sb-connection-interno" }, "external": [ { "alias": "COSMOS", "alcance": "compartido", "secretName": "sb-connection-cosmos" }, { "alias": "FACTURACION", "alcance": "externo", "secretName": "sb-connection-facturacion" } ] }'
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then pass "serviceBus valido -> return 0"; else fail "serviceBus valido NO deberia abortar (rc=$RC)"; fi
EXPECTED="sb-connection-interno|COSMOS FACTURACION|compartido externo|sb-connection-cosmos sb-connection-facturacion"
if [ "$(sb_exports "$CFG")" = "$EXPECTED" ]; then pass "exporta HARNESS_SB_* con listas paralelas en el mismo orden"; else fail "exports incorrectos: $(sb_exports "$CFG")"; fi

echo ""
echo "[SB-4] serviceBus con solo internal (sin external) pasa y deja HARNESS_SB_EXTERNAL_* vacios"

CFG="$TMP_DIR/sb-only-internal.json"
write_sb_config "$CFG" '{ "internal": { "secretName": "sb-connection-interno" } }'
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then pass "sin external -> return 0"; else fail "serviceBus sin external NO deberia abortar (rc=$RC)"; fi
if [ "$(sb_exports "$CFG")" = "sb-connection-interno|||" ]; then pass "HARNESS_SB_EXTERNAL_* quedan vacios"; else fail "exports incorrectos: $(sb_exports "$CFG")"; fi

echo ""
echo "[SB-5] entrada external con alias vacio aborta"

CFG="$TMP_DIR/sb-ext-alias-empty.json"
write_sb_config "$CFG" '{ "internal": { "secretName": "sb-connection-interno" }, "external": [ { "alias": "", "alcance": "compartido", "secretName": "sb-x" } ] }'
ERR="$(run_load "$CFG" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ]; then pass "alias vacio -> return 1"; else fail "alias vacio deberia abortar (rc=$RC)"; fi
if echo "$ERR" | grep -q "'alias' vacio"; then pass "el mensaje menciona 'alias' vacio"; else fail "el mensaje no menciona 'alias' vacio"; fi

echo ""
echo "[SB-6] entrada external con alcance invalido aborta"

CFG="$TMP_DIR/sb-ext-alcance-invalido.json"
write_sb_config "$CFG" '{ "internal": { "secretName": "sb-connection-interno" }, "external": [ { "alias": "COSMOS", "alcance": "publico", "secretName": "sb-x" } ] }'
ERR="$(run_load "$CFG" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ]; then pass "alcance='publico' -> return 1"; else fail "alcance invalido deberia abortar (rc=$RC)"; fi
if echo "$ERR" | grep -q "alcance 'publico' invalido"; then pass "el mensaje nombra el alcance invalido"; else fail "el mensaje no nombra el alcance invalido"; fi

echo ""
echo "[SB-7] entrada external con secretName vacio aborta"

CFG="$TMP_DIR/sb-ext-secret-empty.json"
write_sb_config "$CFG" '{ "internal": { "secretName": "sb-connection-interno" }, "external": [ { "alias": "COSMOS", "alcance": "compartido", "secretName": "" } ] }'
ERR="$(run_load "$CFG" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ]; then pass "secretName vacio -> return 1"; else fail "secretName vacio deberia abortar (rc=$RC)"; fi
if echo "$ERR" | grep -q "'secretName' vacio"; then pass "el mensaje menciona 'secretName' vacio"; else fail "el mensaje no menciona 'secretName' vacio"; fi

echo ""
echo "[SB-8] alias reservado INTERNO reutilizado en external aborta (case-insensitive)"

CFG="$TMP_DIR/sb-ext-alias-interno.json"
write_sb_config "$CFG" '{ "internal": { "secretName": "sb-connection-interno" }, "external": [ { "alias": "Interno", "alcance": "compartido", "secretName": "sb-x" } ] }'
ERR="$(run_load "$CFG" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ]; then pass "alias 'Interno' -> return 1"; else fail "alias reservado deberia abortar (rc=$RC)"; fi
if echo "$ERR" | grep -qi "reservado"; then pass "el mensaje indica que INTERNO esta reservado"; else fail "el mensaje no indica que INTERNO esta reservado"; fi

echo ""
echo "[SB-9] aliases duplicados en external abortan (case-insensitive)"

CFG="$TMP_DIR/sb-ext-alias-dup.json"
write_sb_config "$CFG" '{ "internal": { "secretName": "sb-connection-interno" }, "external": [ { "alias": "COSMOS", "alcance": "compartido", "secretName": "sb-a" }, { "alias": "cosmos", "alcance": "externo", "secretName": "sb-b" } ] }'
ERR="$(run_load "$CFG" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ]; then pass "alias duplicado (distinto case) -> return 1"; else fail "alias duplicado deberia abortar (rc=$RC)"; fi
if echo "$ERR" | grep -q "duplicado"; then pass "el mensaje indica alias duplicado"; else fail "el mensaje no indica alias duplicado"; fi

echo ""
echo "[SEC-1] secrets ausente NO aborta y deja HARNESS_SECRETS_* vacios"

CFG="$TMP_DIR/sec-omit.json"
write_secrets_config "$CFG" "__OMIT__"
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then pass "secrets ausente -> return 0"; else fail "secrets ausente NO deberia abortar (rc=$RC)"; fi
if [ "$(secrets_exports "$CFG")" = "||" ]; then pass "HARNESS_SECRETS_* quedan vacios"; else fail "exports deberian quedar vacios: $(secrets_exports "$CFG")"; fi

echo ""
echo "[SEC-2] secrets valido (output/github-secret/composite) pasa y exporta listas paralelas"

CFG="$TMP_DIR/sec-valid.json"
write_secrets_config "$CFG" '[
  { "name": "sb-connection-interno", "source": { "type": "output", "value": "service_bus_interno_connection_string" } },
  { "name": "sb-connection-cosmos", "source": { "type": "github-secret", "value": "SB_EXTERNAL_COSMOS_CONNECTION_STRING" } },
  { "name": "marten-connection", "source": { "type": "composite", "value": "marten-connection" } }
]'
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then pass "secrets valido -> return 0"; else fail "secrets valido NO deberia abortar (rc=$RC)"; fi
EXPECTED="sb-connection-interno sb-connection-cosmos marten-connection|output github-secret composite|service_bus_interno_connection_string SB_EXTERNAL_COSMOS_CONNECTION_STRING marten-connection"
if [ "$(secrets_exports "$CFG")" = "$EXPECTED" ]; then pass "exporta HARNESS_SECRETS_* con listas paralelas en el mismo orden"; else fail "exports incorrectos: $(secrets_exports "$CFG")"; fi

echo ""
echo "[SEC-3] entrada con 'name' vacio aborta"

CFG="$TMP_DIR/sec-name-empty.json"
write_secrets_config "$CFG" '[ { "name": "", "source": { "type": "output", "value": "x" } } ]'
ERR="$(run_load "$CFG" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ]; then pass "name vacio -> return 1"; else fail "name vacio deberia abortar (rc=$RC)"; fi
if echo "$ERR" | grep -q "'name' vacio"; then pass "el mensaje menciona 'name' vacio"; else fail "el mensaje no menciona 'name' vacio"; fi

echo ""
echo "[SEC-4] entrada con 'source.type' invalido aborta"

CFG="$TMP_DIR/sec-type-invalid.json"
write_secrets_config "$CFG" '[ { "name": "x", "source": { "type": "literal", "value": "y" } } ]'
ERR="$(run_load "$CFG" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ]; then pass "source.type='literal' -> return 1"; else fail "source.type invalido deberia abortar (rc=$RC)"; fi
if echo "$ERR" | grep -q "source.type 'literal' invalido"; then pass "el mensaje nombra el source.type invalido"; else fail "el mensaje no nombra el source.type invalido"; fi

echo ""
echo "[SEC-5] entrada con 'source.value' vacio aborta"

CFG="$TMP_DIR/sec-value-empty.json"
write_secrets_config "$CFG" '[ { "name": "x", "source": { "type": "output", "value": "" } } ]'
ERR="$(run_load "$CFG" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ]; then pass "source.value vacio -> return 1"; else fail "source.value vacio deberia abortar (rc=$RC)"; fi
if echo "$ERR" | grep -q "'source.value' vacio"; then pass "el mensaje menciona 'source.value' vacio"; else fail "el mensaje no menciona 'source.value' vacio"; fi

echo ""
echo "[SEC-6] 'name' duplicado aborta"

CFG="$TMP_DIR/sec-name-dup.json"
write_secrets_config "$CFG" '[
  { "name": "x", "source": { "type": "output", "value": "a" } },
  { "name": "x", "source": { "type": "github-secret", "value": "B" } }
]'
ERR="$(run_load "$CFG" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ]; then pass "name duplicado -> return 1"; else fail "name duplicado deberia abortar (rc=$RC)"; fi
if echo "$ERR" | grep -q "duplicado"; then pass "el mensaje indica name duplicado"; else fail "el mensaje no indica name duplicado"; fi

echo ""
echo "[SEC-7] 'secrets' que no es un array aborta"

CFG="$TMP_DIR/sec-not-array.json"
write_secrets_config "$CFG" '{ "name": "x" }'
RC=0; run_load "$CFG" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ]; then pass "secrets como objeto -> return 1"; else fail "secrets no-array deberia abortar (rc=$RC)"; fi

echo ""
echo "[UPSERT-1] upsert_harness_secret crea el array 'secrets' si el config no lo declara"

CFG="$TMP_DIR/upsert-create.json"
write_secrets_config "$CFG" "__OMIT__"
RC=0; run_upsert "$CFG" "app-insights-connection" "output" "app_insights_connection_string" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then pass "upsert sobre config sin 'secrets' -> return 0"; else fail "upsert deberia poder crear 'secrets' (rc=$RC)"; fi
RESULT=$(jq -c '.secrets' "$CFG" 2>/dev/null)
if [ "$RESULT" = '[{"name":"app-insights-connection","source":{"type":"output","value":"app_insights_connection_string"}}]' ]; then
    pass "el array 'secrets' queda con la entrada nueva"
else
    fail "el array 'secrets' no quedo como se esperaba: $RESULT"
fi

echo ""
echo "[UPSERT-2] upsert_harness_secret agrega una entrada nueva sin tocar las existentes"

CFG="$TMP_DIR/upsert-add.json"
write_secrets_config "$CFG" '[ { "name": "marten-connection", "source": { "type": "composite", "value": "marten-connection" } } ]'
run_upsert "$CFG" "sb-connection-cosmos" "github-secret" "SB_EXTERNAL_COSMOS_CONNECTION_STRING" >/dev/null 2>&1
COUNT=$(jq '.secrets | length' "$CFG" 2>/dev/null)
if [ "$COUNT" = "2" ]; then pass "el array queda con 2 entradas (1 previa + 1 nueva)"; else fail "se esperaban 2 entradas, hay $COUNT"; fi
if [ "$(jq -r '.secrets[0].name' "$CFG")" = "marten-connection" ]; then pass "la entrada previa no se toco"; else fail "la entrada previa se modifico"; fi

echo ""
echo "[UPSERT-3] upsert_harness_secret actualiza (no duplica) una entrada existente por 'name'"

CFG="$TMP_DIR/upsert-update.json"
write_secrets_config "$CFG" '[ { "name": "sb-connection-cosmos", "source": { "type": "github-secret", "value": "OLD_NAME" } } ]'
run_upsert "$CFG" "sb-connection-cosmos" "github-secret" "SB_EXTERNAL_COSMOS_CONNECTION_STRING" >/dev/null 2>&1
COUNT=$(jq '.secrets | length' "$CFG" 2>/dev/null)
if [ "$COUNT" = "1" ]; then pass "re-ejecutar sobre el mismo 'name' no duplica la entrada"; else fail "se esperaba 1 entrada (idempotente), hay $COUNT"; fi
if [ "$(jq -r '.secrets[0].source.value' "$CFG")" = "SB_EXTERNAL_COSMOS_CONNECTION_STRING" ]; then
    pass "el 'source.value' queda actualizado al nuevo"
else
    fail "el 'source.value' no se actualizo"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
