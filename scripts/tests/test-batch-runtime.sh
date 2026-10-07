#!/usr/bin/env bash
# test-batch-runtime.sh -- Tests de la resolucion del runtime activo en
# batch-pipeline.sh (issue #1591, MEF-ADR-0049/0050): el batch ya no exige el
# CLI 'claude' a secas -- resuelve el runtime activo con mefisto_resolve_runtime
# antes del primer eslabon, verifica su CLI y lo exporta para que cada eslabon
# y pr-sync.sh corran en el mismo runtime.
#
# Cubre (CA-5), con PATH controlado y stubs de gh/dotnet, del pipeline hijo
# (tooling-pipeline.sh) y de pr-sync.sh; git es el real del sistema contra un
# origin bare local, y batch-pipeline.sh es el real bajo prueba:
#   (a) Sin 'claude' en PATH, con MEFISTO_RUNTIME=opencode y un stub
#       'opencode': el batch pasa el chequeo de dependencias y el pipeline
#       hijo recibe MEFISTO_RUNTIME=opencode (CA-4).
#   (b) Con stubs 'claude' y 'opencode' y sin MEFISTO_RUNTIME: aborta con
#       "No se pudo resolver el runtime activo" y no invoca ningun eslabon
#       (CA-2).
#   (c) Con MEFISTO_RUNTIME=opencode y sin stub 'opencode': aborta con
#       "Dependencias faltantes" (CA-3).
#   (d) La cabecera muestra "Runtime: opencode" (CA-4).
#
# Uso: scripts/tests/test-batch-runtime.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BATCH_SCRIPT="$REPO_ROOT/scripts/batch-pipeline.sh"
COMMON_LIB="$REPO_ROOT/scripts/_pipeline-common.sh"
RUNTIME_DIR_SRC="$REPO_ROOT/src/runtime"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# -------- Bloque pre: batch-pipeline.sh existe, es ejecutable y compila --------

echo "[pre] batch-pipeline.sh existe, es ejecutable y tiene sintaxis valida"
if [ -x "$BATCH_SCRIPT" ]; then
    pass "batch-pipeline.sh: existe y es ejecutable"
else
    fail "batch-pipeline.sh: no existe o no es ejecutable"
fi
if bash -n "$BATCH_SCRIPT" 2>/dev/null; then
    pass "batch-pipeline.sh: sintaxis valida (bash -n)"
else
    fail "batch-pipeline.sh: bash -n reporto un error de sintaxis"
fi

if grep -qE '^\s*for dep in claude ' "$BATCH_SCRIPT" || grep -qE '^\s*for dep in .*\bclaude\b' "$BATCH_SCRIPT"; then
    fail "CA-1: el chequeo de dependencias todavia exige 'claude' a secas"
else
    pass "CA-1: el chequeo de dependencias ya no exige 'claude' a secas"
fi
if grep -qF 'for dep in gh git dotnet; do' "$BATCH_SCRIPT"; then
    pass "CA-1: el chequeo de dependencias sigue exigiendo gh, git y dotnet"
else
    fail "CA-1: el chequeo de dependencias no coincide con 'gh git dotnet'"
fi
if grep -qF 'no se encontro mefisto-runtime.sh en la clausura publicada' "$BATCH_SCRIPT"; then
    pass "CA-1: aborta si falta mefisto-runtime.sh con el mensaje esperado"
else
    fail "CA-1: no se encontro el mensaje de abort de mefisto-runtime.sh ausente"
fi

# -------- Fixtures: repo consumidor + origin real (mismo patron que --------
# -------- test-batch-stop-signal.sh) --------------------------------------

# setup_work_repo <dir> -- scaffold minimo de un CONSUMIDOR (sin
# .claude-plugin/plugin.json) con los canonicos reales bajo prueba + el
# arbol real de src/runtime (batch-pipeline.sh lo resuelve relativo a si
# mismo, no puede faltar en el fixture).
setup_work_repo() {
    local dir="$1"
    mkdir -p "$dir/scripts" "$dir/src"
    cp "$COMMON_LIB" "$dir/scripts/_pipeline-common.sh"
    cp "$BATCH_SCRIPT" "$dir/scripts/batch-pipeline.sh"
    chmod +x "$dir/scripts/batch-pipeline.sh"
    cp -R "$RUNTIME_DIR_SRC" "$dir/src/runtime"
}

# fake_tooling_pipeline <dir> <call_log> <env_log>
#
# Stub que registra el issue invocado en <call_log> y el valor de
# MEFISTO_RUNTIME visto en <env_log> (CA-4: el eslabon hereda el runtime ya
# resuelto, no lo vuelve a resolver por su cuenta).
fake_tooling_pipeline() {
    local dir="$1" call_log="$2" env_log="$3"
    cat > "$dir/scripts/tooling-pipeline.sh" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$call_log"
echo "\${MEFISTO_RUNTIME:-<vacio>}" >> "$env_log"
echo "PR creado: https://github.com/acme/fake-consumer/pull/\$((\$1 + 1000))"
exit 0
EOF
    chmod +x "$dir/scripts/tooling-pipeline.sh"
}

fake_pr_sync() {
    local dir="$1"
    cat > "$dir/scripts/pr-sync.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$dir/scripts/pr-sync.sh"
}

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    printf 'OPEN|tipo:tooling\n'
    exit 0
fi
exit 0
STUB
chmod +x "$FAKE_BIN/gh"
cat > "$FAKE_BIN/dotnet" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FAKE_BIN/dotnet"

# Mismo criterio que test-batch-stop-signal.sh: solo el tramo de sistema
# (git/coreutils) queda fuera de FAKE_BIN.
SAFE_SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

new_origin() {
    local bare="$1" work="$2"
    git init -q --bare "$bare"
    git -C "$bare" symbolic-ref HEAD refs/heads/main
    git clone -q "$bare" "$work" 2>/dev/null
    git -C "$work" config user.email "test@mefisto.local"
    git -C "$work" config user.name "Mefisto Test"
    git -C "$work" commit -q --allow-empty -m "base"
    git -C "$work" push -q origin main
}

# -------- Escenario (a): sin 'claude', MEFISTO_RUNTIME=opencode + stub --------

echo ""
echo "[a] Sin 'claude' en PATH, MEFISTO_RUNTIME=opencode + stub 'opencode': pasa el chequeo y el eslabon hereda el runtime (CA-3/CA-4)"

WORK_A="$TMP/work-a"
new_origin "$TMP/origin-a.git" "$WORK_A"
setup_work_repo "$WORK_A"
CALL_LOG_A="$TMP/call-log-a"; : > "$CALL_LOG_A"
ENV_LOG_A="$TMP/env-log-a"; : > "$ENV_LOG_A"
fake_tooling_pipeline "$WORK_A" "$CALL_LOG_A" "$ENV_LOG_A"
fake_pr_sync "$WORK_A"

FAKE_BIN_A="$TMP/bin-a"
mkdir -p "$FAKE_BIN_A"
cp "$FAKE_BIN/gh" "$FAKE_BIN/dotnet" "$FAKE_BIN_A/"
cat > "$FAKE_BIN_A/opencode" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FAKE_BIN_A/opencode"

(
    cd "$WORK_A" || exit 99
    env PATH="$FAKE_BIN_A:$SAFE_SYSTEM_PATH" MEFISTO_RUNTIME=opencode ./scripts/batch-pipeline.sh 501
) </dev/null >"$TMP/stdout-a" 2>"$TMP/stderr-a"
RC_A=$?
OUT_A=$(cat "$TMP/stdout-a")

if [ "$RC_A" -eq 0 ]; then
    pass "a: exit 0 (el batch completo el issue con el runtime opencode)"
else
    fail "a: se esperaba exit 0, se obtuvo $RC_A. stdout: $OUT_A / stderr: $(cat "$TMP/stderr-a")"
fi

if grep -qF "501" "$CALL_LOG_A"; then
    pass "a: el eslabon se invoco (el chequeo de dependencias no bloqueo la corrida)"
else
    fail "a: el eslabon nunca se invoco: $(cat "$CALL_LOG_A")"
fi

if grep -qF "opencode" "$ENV_LOG_A"; then
    pass "a: el eslabon recibio MEFISTO_RUNTIME=opencode (CA-4)"
else
    fail "a: el eslabon no recibio MEFISTO_RUNTIME=opencode. env visto: $(cat "$ENV_LOG_A")"
fi

# -------- Escenario (b): stubs claude+opencode, sin MEFISTO_RUNTIME --------

echo ""
echo "[b] Con stubs 'claude' y 'opencode' y sin MEFISTO_RUNTIME: aborta sin invocar ningun eslabon (CA-2)"

WORK_B="$TMP/work-b"
new_origin "$TMP/origin-b.git" "$WORK_B"
setup_work_repo "$WORK_B"
CALL_LOG_B="$TMP/call-log-b"; : > "$CALL_LOG_B"
ENV_LOG_B="$TMP/env-log-b"; : > "$ENV_LOG_B"
fake_tooling_pipeline "$WORK_B" "$CALL_LOG_B" "$ENV_LOG_B"
fake_pr_sync "$WORK_B"

FAKE_BIN_B="$TMP/bin-b"
mkdir -p "$FAKE_BIN_B"
cp "$FAKE_BIN/gh" "$FAKE_BIN/dotnet" "$FAKE_BIN_B/"
for cli in claude opencode; do
    cat > "$FAKE_BIN_B/$cli" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$FAKE_BIN_B/$cli"
done

(
    cd "$WORK_B" || exit 99
    env -u MEFISTO_RUNTIME -u MEFISTO_FAKE_AVAILABLE PATH="$FAKE_BIN_B:$SAFE_SYSTEM_PATH" ./scripts/batch-pipeline.sh 502
) </dev/null >"$TMP/stdout-b" 2>"$TMP/stderr-b"
RC_B=$?
OUT_B=$(cat "$TMP/stdout-b")
ERR_B=$(cat "$TMP/stderr-b")

if [ "$RC_B" -ne 0 ]; then
    pass "b: exit distinto de 0 (sin desambiguar, el batch no puede arrancar)"
else
    fail "b: se esperaba exit != 0, se obtuvo 0. stdout: $OUT_B"
fi

if echo "$OUT_B$ERR_B" | grep -qF "No se pudo resolver el runtime activo"; then
    pass "b: el mensaje de abort es el esperado"
else
    fail "b: no se encontro 'No se pudo resolver el runtime activo'. stdout: $OUT_B / stderr: $ERR_B"
fi

if [ ! -s "$CALL_LOG_B" ]; then
    pass "b: ningun eslabon se invoco (CA-2: el batch aborta antes de procesar issues)"
else
    fail "b: se invoco un eslabon pese a no poder resolver el runtime: $(cat "$CALL_LOG_B")"
fi

# -------- Escenario (c): MEFISTO_RUNTIME=opencode sin stub 'opencode' --------

echo ""
echo "[c] Con MEFISTO_RUNTIME=opencode y sin stub 'opencode': aborta con 'Dependencias faltantes' (CA-3)"

WORK_C="$TMP/work-c"
new_origin "$TMP/origin-c.git" "$WORK_C"
setup_work_repo "$WORK_C"
CALL_LOG_C="$TMP/call-log-c"; : > "$CALL_LOG_C"
ENV_LOG_C="$TMP/env-log-c"; : > "$ENV_LOG_C"
fake_tooling_pipeline "$WORK_C" "$CALL_LOG_C" "$ENV_LOG_C"
fake_pr_sync "$WORK_C"

(
    cd "$WORK_C" || exit 99
    env PATH="$FAKE_BIN:$SAFE_SYSTEM_PATH" MEFISTO_RUNTIME=opencode ./scripts/batch-pipeline.sh 503
) </dev/null >"$TMP/stdout-c" 2>"$TMP/stderr-c"
RC_C=$?
OUT_C=$(cat "$TMP/stdout-c")
ERR_C=$(cat "$TMP/stderr-c")

if [ "$RC_C" -ne 0 ]; then
    pass "c: exit distinto de 0 (falta el CLI del runtime resuelto)"
else
    fail "c: se esperaba exit != 0, se obtuvo 0. stdout: $OUT_C"
fi

if echo "$OUT_C$ERR_C" | grep -qF "Dependencias faltantes"; then
    pass "c: el mensaje de abort menciona 'Dependencias faltantes'"
else
    fail "c: no se encontro 'Dependencias faltantes'. stdout: $OUT_C / stderr: $ERR_C"
fi

if echo "$OUT_C$ERR_C" | grep -qF "opencode"; then
    pass "c: el mensaje nombra el runtime resuelto ('opencode')"
else
    fail "c: el mensaje no nombra 'opencode'. stdout: $OUT_C / stderr: $ERR_C"
fi

if [ ! -s "$CALL_LOG_C" ]; then
    pass "c: ningun eslabon se invoco (falla temprano, antes del primer issue)"
else
    fail "c: se invoco un eslabon pese a faltar el CLI del runtime: $(cat "$CALL_LOG_C")"
fi

# -------- Escenario (d): la cabecera muestra 'Runtime: opencode' --------

echo ""
echo "[d] La cabecera del batch muestra 'Runtime: opencode' cuando ese es el runtime resuelto (CA-4)"

if echo "$OUT_A" | grep -qF "Runtime: opencode"; then
    pass "d: la cabecera del escenario (a) muestra 'Runtime: opencode'"
else
    fail "d: no se encontro 'Runtime: opencode' en la cabecera. stdout: $OUT_A"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
