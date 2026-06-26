#!/usr/bin/env bash
# test-storage-naming.sh -- Tests de los helpers de naming de Storage Account
# (scripts/_pipeline-common.sh) que usa scripts/bootstrap-backend.sh (issue #92).
#
# El nombre de una Storage Account es un endpoint DNS publico y por tanto unico en
# todo Azure; bootstrap-backend.sh anexa un sufijo de unicidad global al nombre
# base del config. Estos tests cubren las tres funciones PURAS (sin 'az') que
# componen esa resolucion:
#   truncate_storage_base            - respeta el limite de 24 chars (CA-4).
#   gen_storage_suffix               - sufijo aleatorio [a-z0-9] del largo pedido.
#   read_backend_storage_account_name - reusa el nombre ya escrito en backend.tf,
#                                       ancla de idempotencia (CA-3).
#
# Uso: scripts/tests/test-storage-naming.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Las funciones viven en _pipeline-common.sh; sourcearlo solo las define (es una
# libreria, no ejecuta nada), asi que es seguro incluso dentro del repo de Mefisto.
set +u
source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null
set -u

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# -------- truncate_storage_base (CA-4: limite de 24 chars) --------

echo "[1] truncate_storage_base respeta el limite de 24 chars (base + 6 de sufijo)"

# Nombre base corto (15 chars): pasa intacto.
R=$(truncate_storage_base "stmcptfstatedev" 24 6)
if [ "$R" = "stmcptfstatedev" ]; then pass "15 chars pasa intacto"; else fail "15 chars deberia pasar intacto (obtenido '$R')"; fi

# Nombre base de 24 chars: se trunca a 18 para dejar 6 al sufijo.
R=$(truncate_storage_base "abcdefghij0123456789abcd" 24 6)
if [ "${#R}" -eq 18 ]; then pass "24 chars -> truncado a 18 (deja 6 al sufijo)"; else fail "24 chars deberia truncarse a 18 (obtenido ${#R}: '$R')"; fi

# El nombre final (base truncada + 6) nunca supera 24.
if [ "$((${#R} + 6))" -le 24 ]; then pass "base truncada + sufijo <= 24"; else fail "base truncada + sufijo supera 24"; fi

# Limite exacto: 18 chars de base caben justo (18 + 6 = 24), no se trunca.
R=$(truncate_storage_base "abcdefghijklmnopqr" 24 6)  # 18 chars
if [ "$R" = "abcdefghijklmnopqr" ]; then pass "18 chars (limite) pasa intacto"; else fail "18 chars deberia pasar intacto (obtenido '$R')"; fi

# Un caracter mas (19) ya se trunca a 18.
R=$(truncate_storage_base "abcdefghijklmnopqrs" 24 6)  # 19 chars
if [ "${#R}" -eq 18 ]; then pass "19 chars -> truncado a 18"; else fail "19 chars deberia truncarse a 18 (obtenido ${#R})"; fi

# Defaults (max_total=24, suffix_len=6) si se omiten los argumentos opcionales.
R=$(truncate_storage_base "abcdefghij0123456789abcd")
if [ "${#R}" -eq 18 ]; then pass "defaults (24/6) truncan a 18"; else fail "defaults deberian truncar a 18 (obtenido ${#R})"; fi

# -------- gen_storage_suffix (sufijo aleatorio valido) --------

echo ""
echo "[2] gen_storage_suffix genera sufijo aleatorio [a-z0-9] del largo pedido"

S=$(gen_storage_suffix 6)
if [ "${#S}" -eq 6 ]; then pass "largo por defecto del issue: 6 chars"; else fail "deberia generar 6 chars (obtenido ${#S}: '$S')"; fi

if printf '%s' "$S" | grep -Eq '^[a-z0-9]{6}$'; then pass "formato valido [a-z0-9]{6}"; else fail "formato invalido: '$S'"; fi

S4=$(gen_storage_suffix 4)
if [ "${#S4}" -eq 4 ]; then pass "respeta el largo pedido (4)"; else fail "deberia generar 4 chars (obtenido ${#S4})"; fi

# Aleatoriedad: dos invocaciones consecutivas casi siempre difieren. Con 36^6
# combinaciones la colision es despreciable; este chequeo detecta un generador
# constante (bug), no garantiza unicidad criptografica.
S_A=$(gen_storage_suffix 6)
S_B=$(gen_storage_suffix 6)
if [ "$S_A" != "$S_B" ]; then pass "dos sufijos consecutivos difieren ('$S_A' != '$S_B')"; else fail "dos sufijos consecutivos son iguales ('$S_A'): generador no aleatorio"; fi

# El nombre completo (base de 18 + sufijo de 6) cumple las reglas de Azure.
FULL="abcdefghijklmnopqr${S}"
if printf '%s' "$FULL" | grep -Eq '^[a-z0-9]{3,24}$'; then pass "nombre completo base+sufijo cumple ^[a-z0-9]{3,24}$"; else fail "nombre completo invalido: '$FULL' (${#FULL} chars)"; fi

# -------- read_backend_storage_account_name (idempotencia via backend.tf) --------

echo ""
echo "[3] read_backend_storage_account_name reusa el nombre escrito en backend.tf"

# backend.tf valido -> devuelve el storage_account_name.
mkdir -p "$TMP_DIR/conbackend"
cat > "$TMP_DIR/conbackend/backend.tf" <<'EOF'
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-foo-tfstate"
    storage_account_name = "stmcptfstatedevab12cd"
    container_name       = "tfstate"
    key                  = "dev.tfstate"
  }
}
EOF
R=$(read_backend_storage_account_name "$TMP_DIR/conbackend")
if [ "$R" = "stmcptfstatedevab12cd" ]; then pass "backend.tf valido -> 'stmcptfstatedevab12cd'"; else fail "deberia leer el nombre del backend.tf (obtenido '$R')"; fi

# Directorio sin .tf -> vacio.
mkdir -p "$TMP_DIR/vacio"
R=$(read_backend_storage_account_name "$TMP_DIR/vacio")
if [ -z "$R" ]; then pass "directorio sin .tf -> vacio"; else fail "directorio sin .tf deberia dar vacio (obtenido '$R')"; fi

# Directorio inexistente -> vacio (no aborta).
R=$(read_backend_storage_account_name "$TMP_DIR/no-existe")
if [ -z "$R" ]; then pass "directorio inexistente -> vacio"; else fail "directorio inexistente deberia dar vacio (obtenido '$R')"; fi

# .tf sin bloque backend "azurerm" -> vacio.
mkdir -p "$TMP_DIR/sinbackend"
echo 'resource "azurerm_storage_account" "x" { name = "stno" }' > "$TMP_DIR/sinbackend/main.tf"
R=$(read_backend_storage_account_name "$TMP_DIR/sinbackend")
if [ -z "$R" ]; then pass ".tf sin backend azurerm -> vacio"; else fail ".tf sin backend deberia dar vacio (obtenido '$R')"; fi

# storage_account_name no literal (referencia a variable) -> vacio (no es un
# nombre valido y no debe reusarse como si lo fuera).
mkdir -p "$TMP_DIR/novar"
cat > "$TMP_DIR/novar/backend.tf" <<'EOF'
terraform {
  backend "azurerm" {
    storage_account_name = var.tfstate_storage
  }
}
EOF
R=$(read_backend_storage_account_name "$TMP_DIR/novar")
if [ -z "$R" ]; then pass "storage_account_name no literal -> vacio"; else fail "valor no literal deberia dar vacio (obtenido '$R')"; fi

# El bloque backend puede vivir en otro .tf (no necesariamente backend.tf).
mkdir -p "$TMP_DIR/otrotf"
cat > "$TMP_DIR/otrotf/providers.tf" <<'EOF'
terraform {
  backend "azurerm" {
    storage_account_name = "stotrotfstatedevxyz789"
  }
}
EOF
R=$(read_backend_storage_account_name "$TMP_DIR/otrotf")
if [ "$R" = "stotrotfstatedevxyz789" ]; then pass "backend en otro .tf (providers.tf) -> lo encuentra"; else fail "deberia encontrar el backend en providers.tf (obtenido '$R')"; fi

# -------- Resumen --------

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
