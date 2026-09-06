#!/usr/bin/env bash
# test-mefisto-herdr-pipeline.sh -- Tests dedicados del porte de
# mefisto-herdr-pipeline.sh al layout canonico src/internal/scripts/
# (MEF-ADR-0049, issue #872). Contraparte interna de test-caffeinate-prefix.sh
# / test-herdr-*.sh (lado publicado): mismo contrato de UX, verificado sobre
# la copia interna -- MEF-ADR-0019 prohibe compartir codigo entre los dos
# lados, asi que este archivo no importa nada del publicado ni de los otros
# tests internos que ya tocan mefisto-herdr-pipeline.sh (test-mefisto-tooling-variant.sh,
# test-mefisto-stage-models.sh, test-tooling-state-paths.sh).
#
# Cubre (CA-6):
#   [1-4] --tooling/--batch heredan MEFISTO_RUNTIME=claude|opencode (y
#         MEFISTO_MODELS_FILE) en el pane run, antepuestos como asignacion de
#         entorno a la invocacion del runner (CA-2).
#   [5]   Sin MEFISTO_RUNTIME/MEFISTO_MODELS_FILE fijados, el pane run no
#         lleva ninguna asignacion de entorno (ENV_PREFIX vacio no cambia el
#         comportamiento de autodeteccion respecto de no fijarlo).
#   [6-7] Argumentos con caracteres especiales (corchetes, comas, comillas
#         simples de un id de modelo) llegan intactos al pane run -- printf %q
#         los escapa como dato, nunca se re-emiten crudos.
#   [8-12] Argumentos faltantes: --tooling sin issue, --batch sin issues,
#         --models/--variant/--from-stage sin valor abortan con mensaje claro.
#   [13-15] Combinaciones invalidas: --batch rechaza --models, --variant y
#         --from-stage (serian ambiguos sobre varios issues) sin despachar
#         ningun pane.
#   [16]  Reutilizacion de un pane libre ya registrado: no crea un pane nuevo
#         (sin "pane split" en el log).
#   [17]  Un pane registrado pero ocupado se descarta: crea uno nuevo via
#         "pane split" en vez de reusarlo.
#
# Uso: .claude/scripts/tests/test-mefisto-herdr-pipeline.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# --- Fixture: repo de mentira con el canonico + su shim ---------------------
#
# Mismo arnes que test-mefisto-tooling-variant.sh: .claude-plugin/plugin.json
# (assert_in_mefisto lo exige), copias reales de los scripts y un stub de
# herdr en PATH que solo registra la invocacion sin tocar un servidor real.

TMP_DIR="$(mktemp -d)"
FAKE_MEFISTO="$TMP_DIR/fake-mefisto"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_MEFISTO/.claude-plugin" "$FAKE_MEFISTO/.claude/scripts" "$FAKE_MEFISTO/src/internal/scripts/lib" "$FAKE_BIN"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$FAKE_MEFISTO/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "mefisto",
  "version": "0.0.0"
}
EOF
cp "$REPO_ROOT/src/internal/scripts/lib/_mefisto-common.sh" "$FAKE_MEFISTO/src/internal/scripts/lib/_mefisto-common.sh"
cp "$REPO_ROOT/src/internal/scripts/lib/mefisto-state.sh" "$FAKE_MEFISTO/src/internal/scripts/lib/mefisto-state.sh"
cp "$REPO_ROOT/src/internal/scripts/mefisto-herdr-pipeline.sh" "$FAKE_MEFISTO/src/internal/scripts/mefisto-herdr-pipeline.sh"
cp "$REPO_ROOT/.claude/scripts/mefisto-herdr-pipeline.sh" "$FAKE_MEFISTO/.claude/scripts/mefisto-herdr-pipeline.sh"
(cd "$FAKE_MEFISTO" && git init -q && git -c user.email="test@example.com" -c user.name="Test" commit --allow-empty -q -m "commit inicial")

cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$FAKE_BIN/gh"

# HERDR_STUB_FREE controla la respuesta de "pane process-info" (bloques
# 16/17): "true" (default) simula un pane en su prompt interactivo; "false"
# simula un pane con un comando en foreground (ocupado).
cat > "$FAKE_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
set -u
echo "herdr $*" >> "$HERDR_STUB_LOG"
case "${1:-} ${2:-}" in
    "pane split")
        n=$(cat "$HERDR_STUB_COUNTER" 2>/dev/null || echo 0)
        n=$((n + 1))
        echo "$n" > "$HERDR_STUB_COUNTER"
        echo "{\"result\":{\"pane\":{\"pane_id\":\"w1:p$n\"}}}"
        ;;
    "pane get")
        echo '{"result":{"pane":{"pane_id":"stub"}}}'
        ;;
    "pane process-info")
        if [ "${HERDR_STUB_FREE:-true}" = "true" ]; then
            echo '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":100}}}'
        else
            echo '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200}}}'
        fi
        ;;
    *)
        echo '{"result":{"type":"ok"}}'
        ;;
esac
STUB
chmod +x "$FAKE_BIN/herdr"

export HERDR_STUB_LOG="$TMP_DIR/herdr-invocations.log"
export HERDR_STUB_COUNTER="$TMP_DIR/herdr-pane-counter"
HERDR_SCRIPT="$FAKE_MEFISTO/.claude/scripts/mefisto-herdr-pipeline.sh"

LAST_STDOUT=""
LAST_STDERR=""
LAST_RC=0

# run_herdr [args...]
#
# Corre el shim (que reenvia al canonico via exec) dentro de un pane herdr
# simulado. Hereda MEFISTO_RUNTIME/MEFISTO_MODELS_FILE si el caller los tiene
# exportados en su propio entorno -- asi los bloques 1-5 solo necesitan
# export/unset alrededor de la llamada, igual que en una corrida real donde el
# comando generado los antepone al invocar el launcher.
#
# Las -u de MEFISTO_STATE_DIR/MEFISTO_LEGACY_STATE_DIR/MEFISTO_REPO_ROOT/
# MEFISTO_PROJECT_NAME/MEFISTO_REPO_SLUG son necesarias: si este test corre
# DENTRO de una corrida real de mefisto-tooling-pipeline.sh (como la que lo
# escribio), esas variables ya llegan exportadas al proceso apuntando al repo
# REAL -- sin desarmarlas aqui, mefisto-state.sh (`: "${VAR:=default}"`) las
# respeta tal cual y el fixture deja de escribir en su propio
# FAKE_MEFISTO/.mefisto/pipeline/ para escribir en el .mefisto/pipeline/ del
# repo que orquesta esta misma sesion (visto en vivo: un primer intento sin
# estas -u filtro el registro de panes del checkout real).
run_herdr() {
    : > "$HERDR_STUB_LOG"
    echo 0 > "$HERDR_STUB_COUNTER"
    local out="$TMP_DIR/stdout" err="$TMP_DIR/stderr"
    (
        cd "$FAKE_MEFISTO" || exit 99
        env -u MEFISTO_UI \
            -u MEFISTO_STATE_DIR -u MEFISTO_LEGACY_STATE_DIR \
            -u MEFISTO_REPO_ROOT -u MEFISTO_PROJECT_NAME -u MEFISTO_REPO_SLUG \
            PATH="$FAKE_BIN:$PATH" \
            HERDR_ENV=1 HERDR_PANE_ID="w1:p0" HERDR_WORKSPACE_ID="w1" \
            HERDR_STUB_LOG="$HERDR_STUB_LOG" HERDR_STUB_COUNTER="$HERDR_STUB_COUNTER" \
            HERDR_STUB_FREE="${HERDR_STUB_FREE:-true}" \
            "$HERDR_SCRIPT" "$@"
    ) </dev/null >"$out" 2>"$err"
    LAST_RC=$?
    LAST_STDOUT=$(cat "$out")
    LAST_STDERR=$(cat "$err")
}

# --- [1-4] MEFISTO_RUNTIME/MEFISTO_MODELS_FILE heredados en el pane (CA-2) --

echo "[1] --tooling hereda MEFISTO_RUNTIME=claude en el pane run"
export MEFISTO_RUNTIME=claude
run_herdr --tooling 872
unset MEFISTO_RUNTIME
if [ "$LAST_RC" -eq 0 ]; then pass "--tooling corre sin abortar (rc=$LAST_RC)"; else fail "no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
if grep -qF "MEFISTO_RUNTIME=claude" "$HERDR_STUB_LOG" && grep -q "pane run" "$HERDR_STUB_LOG"; then
    pass "el pane run lleva MEFISTO_RUNTIME=claude"
else
    fail "el pane run no lleva MEFISTO_RUNTIME=claude -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qF "mefisto-tooling-pipeline.sh 872" "$HERDR_STUB_LOG"; then
    pass "el runner reenvia a mefisto-tooling-pipeline.sh con el issue"
else
    fail "no se reenvio a mefisto-tooling-pipeline.sh -- log: $(cat "$HERDR_STUB_LOG")"
fi

echo ""
echo "[2] --tooling hereda MEFISTO_RUNTIME=opencode y MEFISTO_MODELS_FILE en el pane run"
export MEFISTO_RUNTIME=opencode
export MEFISTO_MODELS_FILE=/tmp/modelos-de-mentira.json
run_herdr --tooling 872
unset MEFISTO_RUNTIME MEFISTO_MODELS_FILE
if [ "$LAST_RC" -eq 0 ]; then pass "--tooling corre sin abortar (rc=$LAST_RC)"; else fail "no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
if grep -qF "MEFISTO_RUNTIME=opencode" "$HERDR_STUB_LOG"; then
    pass "el pane run lleva MEFISTO_RUNTIME=opencode"
else
    fail "el pane run no lleva MEFISTO_RUNTIME=opencode -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qF "MEFISTO_MODELS_FILE=/tmp/modelos-de-mentira.json" "$HERDR_STUB_LOG"; then
    pass "el pane run lleva MEFISTO_MODELS_FILE"
else
    fail "el pane run no lleva MEFISTO_MODELS_FILE -- log: $(cat "$HERDR_STUB_LOG")"
fi

echo ""
echo "[3] --batch hereda MEFISTO_RUNTIME=claude en el pane run"
export MEFISTO_RUNTIME=claude
run_herdr --batch 872 873
unset MEFISTO_RUNTIME
if [ "$LAST_RC" -eq 0 ]; then pass "--batch corre sin abortar (rc=$LAST_RC)"; else fail "no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
if grep -qF "MEFISTO_RUNTIME=claude" "$HERDR_STUB_LOG" && grep -qF "mefisto-batch-pipeline.sh 872 873" "$HERDR_STUB_LOG"; then
    pass "el pane run lleva MEFISTO_RUNTIME=claude y reenvia a mefisto-batch-pipeline.sh con ambos issues"
else
    fail "despacho de batch incompleto -- log: $(cat "$HERDR_STUB_LOG")"
fi

echo ""
echo "[4] --batch hereda MEFISTO_RUNTIME=opencode en el pane run"
export MEFISTO_RUNTIME=opencode
run_herdr --batch 872 873
unset MEFISTO_RUNTIME
if [ "$LAST_RC" -eq 0 ]; then pass "--batch corre sin abortar (rc=$LAST_RC)"; else fail "no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
if grep -qF "MEFISTO_RUNTIME=opencode" "$HERDR_STUB_LOG"; then
    pass "el pane run lleva MEFISTO_RUNTIME=opencode"
else
    fail "el pane run no lleva MEFISTO_RUNTIME=opencode -- log: $(cat "$HERDR_STUB_LOG")"
fi

echo ""
echo "[5] sin MEFISTO_RUNTIME/MEFISTO_MODELS_FILE fijados, el pane run no lleva ninguna asignacion de entorno"
run_herdr --tooling 872
if [ "$LAST_RC" -eq 0 ]; then pass "--tooling corre sin abortar (rc=$LAST_RC)"; else fail "no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
if grep -q "MEFISTO_RUNTIME=" "$HERDR_STUB_LOG"; then
    fail "el pane run no deberia mencionar MEFISTO_RUNTIME sin fijarlo -- log: $(cat "$HERDR_STUB_LOG")"
else
    pass "ENV_PREFIX vacio: nada de MEFISTO_RUNTIME en el pane run"
fi

echo ""
echo "----------------------------------------"
echo "  Herencia de entorno: $PASS pass, $FAIL fail (hasta aqui)"
echo "----------------------------------------"

# --- [6-7] Argumentos con caracteres especiales sobreviven a printf %q ------

echo ""
echo "[6] --models con corchetes y coma llega intacto al pane run"
run_herdr --tooling 872 --models "writer=claude-opus-5[1m],reviewer=sonnet"
if [ "$LAST_RC" -eq 0 ]; then pass "corre sin abortar (rc=$LAST_RC)"; else fail "no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
EXPECTED_Q=$(printf '%q' "writer=claude-opus-5[1m],reviewer=sonnet")
if grep -qF -- "--models $EXPECTED_Q" "$HERDR_STUB_LOG"; then
    pass "el valor de --models llega escapado con printf %q, sin alterar corchetes ni coma"
else
    fail "el valor de --models no llego intacto -- log: $(cat "$HERDR_STUB_LOG")"
fi

echo ""
echo "[7] un valor de --models con comilla simple embebida llega intacto (printf %q, nunca crudo)"
run_herdr --tooling 872 --models "writer=modelo-de-'prueba"
if [ "$LAST_RC" -eq 0 ]; then pass "corre sin abortar (rc=$LAST_RC)"; else fail "no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
EXPECTED_Q=$(printf '%q' "writer=modelo-de-'prueba")
if grep -qF -- "--models $EXPECTED_Q" "$HERDR_STUB_LOG"; then
    pass "la comilla simple embebida sobrevive escapada, no cruda"
else
    fail "el valor con comilla simple no llego intacto -- log: $(cat "$HERDR_STUB_LOG")"
fi

echo ""
echo "----------------------------------------"
echo "  Caracteres especiales: $PASS pass, $FAIL fail (hasta aqui)"
echo "----------------------------------------"

# --- [8-12] Argumentos faltantes ---------------------------------------------

echo ""
echo "[8] --tooling sin numero de issue aborta con mensaje claro"
run_herdr --tooling
if [ "$LAST_RC" -eq 1 ]; then pass "aborta (rc=$LAST_RC)"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "Falta el numero de issue"; then pass "mensaje: falta el numero de issue"; else fail "mensaje inesperado: $LAST_STDERR"; fi

echo ""
echo "[9] --batch sin issues aborta con mensaje claro"
run_herdr --batch
if [ "$LAST_RC" -eq 1 ]; then pass "aborta (rc=$LAST_RC)"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "al menos un issue"; then pass "mensaje: al menos un issue"; else fail "mensaje inesperado: $LAST_STDERR"; fi

echo ""
echo "[10] --models sin valor aborta con mensaje claro"
run_herdr --tooling 872 --models
if [ "$LAST_RC" -eq 1 ]; then pass "aborta (rc=$LAST_RC)"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "Falta el valor de --models"; then pass "mensaje: falta el valor de --models"; else fail "mensaje inesperado: $LAST_STDERR"; fi

echo ""
echo "[11] --variant sin valor aborta con mensaje claro"
run_herdr --tooling 872 --variant
if [ "$LAST_RC" -eq 1 ]; then pass "aborta (rc=$LAST_RC)"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "Falta el valor de --variant"; then pass "mensaje: falta el valor de --variant"; else fail "mensaje inesperado: $LAST_STDERR"; fi

echo ""
echo "[12] --from-stage sin valor aborta con mensaje claro"
run_herdr --tooling 872 --from-stage
if [ "$LAST_RC" -eq 1 ]; then pass "aborta (rc=$LAST_RC)"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "Falta el valor de --from-stage"; then pass "mensaje: falta el valor de --from-stage"; else fail "mensaje inesperado: $LAST_STDERR"; fi

echo ""
echo "----------------------------------------"
echo "  Argumentos faltantes: $PASS pass, $FAIL fail (hasta aqui)"
echo "----------------------------------------"

# --- [13-15] Combinaciones invalidas -----------------------------------------

echo ""
echo "[13] --batch + --models aborta (ambiguo sobre varios issues) sin despachar ningun pane"
run_herdr --batch 872 873 --models "writer=sonnet"
if [ "$LAST_RC" -eq 1 ]; then pass "aborta (rc=$LAST_RC)"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "no es valido con --batch"; then pass "mensaje: --models no valido con --batch"; else fail "mensaje inesperado: $LAST_STDERR"; fi
if grep -q "pane run" "$HERDR_STUB_LOG"; then fail "no deberia despachar ningun pane"; else pass "ningun pane despachado"; fi

echo ""
echo "[14] --batch + --variant aborta (ambiguo sobre varios issues) sin despachar ningun pane"
run_herdr --batch 872 873 --variant experimento-a
if [ "$LAST_RC" -eq 1 ]; then pass "aborta (rc=$LAST_RC)"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "no es valido con --batch"; then pass "mensaje: --variant no valido con --batch"; else fail "mensaje inesperado: $LAST_STDERR"; fi
if grep -q "pane run" "$HERDR_STUB_LOG"; then fail "no deberia despachar ningun pane"; else pass "ningun pane despachado"; fi

echo ""
echo "[15] --batch + --from-stage aborta (ambiguo sobre varios issues) sin despachar ningun pane"
run_herdr --batch 872 873 --from-stage 2
if [ "$LAST_RC" -eq 1 ]; then pass "aborta (rc=$LAST_RC)"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "no es valido con --batch"; then pass "mensaje: --from-stage no valido con --batch"; else fail "mensaje inesperado: $LAST_STDERR"; fi
if grep -q "pane run" "$HERDR_STUB_LOG"; then fail "no deberia despachar ningun pane"; else pass "ningun pane despachado"; fi

echo ""
echo "----------------------------------------"
echo "  Combinaciones invalidas: $PASS pass, $FAIL fail (hasta aqui)"
echo "----------------------------------------"

# --- [16-17] Reutilizacion de panes -------------------------------------------

echo ""
echo "[16] un pane libre ya registrado se reutiliza (sin 'pane split')"
mkdir -p "$FAKE_MEFISTO/.mefisto/pipeline"
printf 'w1:p9\n' > "$FAKE_MEFISTO/.mefisto/pipeline/herdr-report-panes.txt"
HERDR_STUB_FREE=true run_herdr --tooling 872
if [ "$LAST_RC" -eq 0 ]; then pass "corre sin abortar (rc=$LAST_RC)"; else fail "no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
if grep -q "pane split" "$HERDR_STUB_LOG"; then
    fail "no deberia crear un pane nuevo -- log: $(cat "$HERDR_STUB_LOG")"
else
    pass "no crea un pane nuevo"
fi
if grep -qF "pane run w1:p9" "$HERDR_STUB_LOG"; then
    pass "reutiliza el pane libre registrado (w1:p9)"
else
    fail "no reutilizo el pane registrado -- log: $(cat "$HERDR_STUB_LOG")"
fi

echo ""
echo "[17] un pane registrado pero ocupado se descarta: crea uno nuevo (pane split)"
mkdir -p "$FAKE_MEFISTO/.mefisto/pipeline"
printf 'w1:p9\n' > "$FAKE_MEFISTO/.mefisto/pipeline/herdr-report-panes.txt"
HERDR_STUB_FREE=false run_herdr --tooling 872
if [ "$LAST_RC" -eq 0 ]; then pass "corre sin abortar (rc=$LAST_RC)"; else fail "no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
if grep -q "pane split" "$HERDR_STUB_LOG"; then
    pass "crea un pane nuevo porque el registrado esta ocupado"
else
    fail "deberia haber creado un pane nuevo -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qF "pane run w1:p9" "$HERDR_STUB_LOG"; then
    fail "no deberia reusar el pane ocupado -- log: $(cat "$HERDR_STUB_LOG")"
else
    pass "no reutiliza el pane ocupado"
fi

echo ""
echo "----------------------------------------"
echo "  Reutilizacion de panes: $PASS pass, $FAIL fail (hasta aqui)"
echo "----------------------------------------"

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -eq 0 ]
