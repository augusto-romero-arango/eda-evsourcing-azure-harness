#!/usr/bin/env bash
# test-parallel-runtime.sh -- Regresion del runtime activo de parallel-pipeline
# (issue #1620, MEF-ADR-0049/0050).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PARALLEL_SCRIPT="$REPO_ROOT/scripts/parallel-pipeline.sh"
COMMON_LIB="$REPO_ROOT/scripts/_pipeline-common.sh"
RUNTIME_DIR_SRC="$REPO_ROOT/src/runtime"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "[pre] parallel-pipeline.sh existe y tiene sintaxis valida"
if [ -x "$PARALLEL_SCRIPT" ]; then pass "el pipeline es ejecutable"; else fail "el pipeline no es ejecutable"; fi
if bash -n "$PARALLEL_SCRIPT"; then pass "el pipeline tiene sintaxis valida"; else fail "bash -n fallo"; fi
if grep -qF 'for dep in gh git dotnet; do' "$PARALLEL_SCRIPT"; then
    pass "CA-1: las dependencias base son gh, git y dotnet"
else
    fail "CA-1: las dependencias base no coinciden"
fi
if grep -qE '^source .*mefisto-models\.sh' "$PARALLEL_SCRIPT"; then
    fail "CA-1: el scheduler no debe cargar mefisto-models.sh"
else
    pass "CA-1: el scheduler solo carga la biblioteca de runtime necesaria"
fi

setup_work_repo() {
    local dir="$1" call_log="$2" env_log="$3"
    mkdir -p "$dir/scripts" "$dir/src"
    cp "$PARALLEL_SCRIPT" "$dir/scripts/parallel-pipeline.sh"
    cp "$COMMON_LIB" "$dir/scripts/_pipeline-common.sh"
    cp -R "$RUNTIME_DIR_SRC" "$dir/src/runtime"
    chmod +x "$dir/scripts/parallel-pipeline.sh"
    cat > "$dir/scripts/tooling-pipeline.sh" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$call_log"
echo "\${MEFISTO_RUNTIME:-<vacio>}" >> "$env_log"
exit 0
EOF
    chmod +x "$dir/scripts/tooling-pipeline.sh"
    git init -q "$dir"
    git -C "$dir" config user.email test@mefisto.local
    git -C "$dir" config user.name 'Mefisto Test'
    git -C "$dir" add .
    git -C "$dir" commit -q -m base
}

make_base_bin() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = issue ] && [ "$2" = view ]; then printf 'OPEN|tipo:tooling\n'; fi
EOF
    cat > "$dir/git" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/git "$@"
EOF
    cat > "$dir/dotnet" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$dir/gh" "$dir/git" "$dir/dotnet"
}

SAFE_SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
run_parallel() {
    local work="$1" bin="$2" runtime="$3" issue="$4" out="$5" err="$6"
    (
        cd "$work" || exit 99
        if [ -n "$runtime" ]; then
            env PATH="$bin:$SAFE_SYSTEM_PATH" MEFISTO_RUNTIME="$runtime" ./scripts/parallel-pipeline.sh "$issue"
        else
            env -u MEFISTO_RUNTIME PATH="$bin:$SAFE_SYSTEM_PATH" ./scripts/parallel-pipeline.sh "$issue"
        fi
    ) </dev/null >"$out" 2>"$err"
}

echo ""
echo "[a] opencode explicito sin claude pasa y se propaga al hijo"
WORK_A="$TMP/work-a"; CALL_A="$TMP/call-a"; ENV_A="$TMP/env-a"; : > "$CALL_A"; : > "$ENV_A"
setup_work_repo "$WORK_A" "$CALL_A" "$ENV_A"
BIN_A="$TMP/bin-a"; make_base_bin "$BIN_A"
cat > "$BIN_A/opencode" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN_A/opencode"
run_parallel "$WORK_A" "$BIN_A" opencode 501 "$TMP/out-a" "$TMP/err-a"; RC_A=$?
OUT_A=$(cat "$TMP/out-a")
if [ "$RC_A" -eq 0 ]; then pass "a: exit 0 sin claude"; else fail "a: exit $RC_A: $(cat "$TMP/err-a")"; fi
if grep -qxF 501 "$CALL_A" && grep -qxF opencode "$ENV_A"; then
    pass "a: el hijo recibe MEFISTO_RUNTIME=opencode"
else
    fail "a: el hijo no recibio el runtime esperado"
fi

echo ""
echo "[b] dos CLIs sin seleccion abortan antes del primer issue"
WORK_B="$TMP/work-b"; CALL_B="$TMP/call-b"; ENV_B="$TMP/env-b"; : > "$CALL_B"; : > "$ENV_B"
setup_work_repo "$WORK_B" "$CALL_B" "$ENV_B"
BIN_B="$TMP/bin-b"; make_base_bin "$BIN_B"
for cli in claude opencode; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN_B/$cli"; chmod +x "$BIN_B/$cli"; done
run_parallel "$WORK_B" "$BIN_B" '' 502 "$TMP/out-b" "$TMP/err-b"; RC_B=$?
if [ "$RC_B" -ne 0 ] && cat "$TMP/out-b" "$TMP/err-b" | grep -qF 'No se pudo resolver el runtime activo' && [ ! -s "$CALL_B" ]; then
    pass "b: aborta sin lanzar ningun issue"
else
    fail "b: no aborto correctamente antes de lanzar el issue"
fi

echo ""
echo "[c] runtime explicito sin su CLI aborta temprano"
WORK_C="$TMP/work-c"; CALL_C="$TMP/call-c"; ENV_C="$TMP/env-c"; : > "$CALL_C"; : > "$ENV_C"
setup_work_repo "$WORK_C" "$CALL_C" "$ENV_C"
BIN_C="$TMP/bin-c"; make_base_bin "$BIN_C"
run_parallel "$WORK_C" "$BIN_C" opencode 503 "$TMP/out-c" "$TMP/err-c"; RC_C=$?
if [ "$RC_C" -ne 0 ] && cat "$TMP/out-c" "$TMP/err-c" | grep -qF "Dependencias faltantes: CLI del runtime 'opencode'" && [ ! -s "$CALL_C" ]; then
    pass "c: reporta el CLI ausente sin lanzar ningun issue"
else
    fail "c: no reporto correctamente el CLI ausente"
fi

echo ""
echo "[d] la cabecera y el log del lote informan el runtime resuelto"
if echo "$OUT_A" | grep -qF 'Runtime: opencode'; then
    pass "d: la cabecera muestra Runtime: opencode"
else
    fail "d: la cabecera no informa el runtime"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
