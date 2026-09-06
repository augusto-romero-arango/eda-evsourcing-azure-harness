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
#   [18-21] Flags que se consumen o se reenvian (CA-3): --verbose e --if-exists
#         no viajan nunca al sub-pipeline (uno es no-op en herdr, el otro es de
#         las sesiones tmux, y avisa); --from-stage y --variant si viajan con su
#         valor, y --from-stage no numerico aborta antes de despachar.
#   [22]  Guard de contexto herdr (CA-5): sin HERDR_ENV=1 aborta remitiendo a
#         mefisto-tmux-pipeline.sh, sin despachar ningun pane.
#   [23]  Guard estatico del canonico REAL (CA-4), contraparte del bloque [B]
#         de test-batch-runtime.sh: cero menciones de "claude -p", estado
#         resuelto con mefisto_state_path (logs y registro de panes), cero
#         ".claude/pipeline" en codigo, y las unicas referencias
#         ".claude/scripts" en codigo son la invocacion del visor -- que sigue
#         viviendo ahi porque #878 neutralizo su fuente de datos, no su
#         ubicacion (mismo caso que mefisto-tmux-pipeline.sh tras #871).
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

# --- [18-20] Flags que se consumen o se reenvian tal cual (CA-3) --------------
#
# --verbose e --if-exists no llegan nunca al sub-pipeline (uno es no-op en
# herdr, el otro es de las sesiones tmux); --from-stage y --variant si, y su
# valor tiene que aparecer en la linea que se teclea en el pane. Sin estos
# casos, un flag mal ruteado se descartaria en silencio -- exactamente el
# defecto que #709/#711 corrigieron para --models/--variant.

echo ""
echo "[18] --verbose se consume sin efecto: despacha igual y no viaja al sub-pipeline"
run_herdr --tooling 872 --verbose
if [ "$LAST_RC" -eq 0 ]; then pass "corre sin abortar (rc=$LAST_RC)"; else fail "no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
if grep -qF "mefisto-tooling-pipeline.sh 872" "$HERDR_STUB_LOG"; then
    pass "despacha el issue igual que sin --verbose"
else
    fail "no despacho el issue -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qF -- "--verbose" "$HERDR_STUB_LOG"; then
    fail "--verbose no deberia viajar al sub-pipeline -- log: $(cat "$HERDR_STUB_LOG")"
else
    pass "--verbose no viaja al sub-pipeline"
fi

echo ""
echo "[19] --if-exists avisa por stderr y se ignora (es de las sesiones tmux)"
run_herdr --tooling 872 --if-exists fail
if [ "$LAST_RC" -eq 0 ]; then pass "corre sin abortar (rc=$LAST_RC)"; else fail "no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "no aplica en herdr"; then pass "avisa que no aplica en herdr"; else fail "sin aviso en stderr: $LAST_STDERR"; fi
if grep -qF -- "--if-exists" "$HERDR_STUB_LOG"; then
    fail "--if-exists no deberia viajar al sub-pipeline -- log: $(cat "$HERDR_STUB_LOG")"
else
    pass "--if-exists no viaja al sub-pipeline"
fi

echo ""
echo "[20] --from-stage y --variant se reenvian con su valor al sub-pipeline canonico"
run_herdr --tooling 872 --from-stage 2 --variant experimento-a
if [ "$LAST_RC" -eq 0 ]; then pass "corre sin abortar (rc=$LAST_RC)"; else fail "no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
if grep -qF -- "mefisto-tooling-pipeline.sh 872 --from-stage 2" "$HERDR_STUB_LOG"; then
    pass "--from-stage 2 llega al sub-pipeline en la posicion esperada"
else
    fail "--from-stage no llego al sub-pipeline -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qF -- "--variant experimento-a" "$HERDR_STUB_LOG"; then
    pass "--variant llega al sub-pipeline con su label"
else
    fail "--variant no llego al sub-pipeline -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qF "experimento-a" "$HERDR_STUB_LOG" && grep -qF -- "--title" "$HERDR_STUB_LOG"; then
    pass "el titulo del pane distingue la variante"
else
    fail "el titulo del pane no distingue la variante -- log: $(cat "$HERDR_STUB_LOG")"
fi

echo ""
echo "[21] --from-stage con valor no numerico aborta antes de despachar"
run_herdr --tooling 872 --from-stage dos
if [ "$LAST_RC" -eq 1 ]; then pass "aborta (rc=$LAST_RC)"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "numero entero"; then pass "mensaje: debe ser un numero entero"; else fail "mensaje inesperado: $LAST_STDERR"; fi
if grep -q "pane run" "$HERDR_STUB_LOG"; then fail "no deberia despachar ningun pane"; else pass "ningun pane despachado"; fi

echo ""
echo "----------------------------------------"
echo "  Flags consumidos y reenviados: $PASS pass, $FAIL fail (hasta aqui)"
echo "----------------------------------------"

# --- [22] Guard de contexto herdr (CA-5) -------------------------------------

echo ""
echo "[22] fuera de un pane herdr (HERDR_ENV != 1) aborta remitiendo al lanzador tmux"
: > "$HERDR_STUB_LOG"
echo 0 > "$HERDR_STUB_COUNTER"
(
    cd "$FAKE_MEFISTO" || exit 99
    env -u MEFISTO_UI -u HERDR_ENV \
        -u MEFISTO_STATE_DIR -u MEFISTO_LEGACY_STATE_DIR \
        -u MEFISTO_REPO_ROOT -u MEFISTO_PROJECT_NAME -u MEFISTO_REPO_SLUG \
        PATH="$FAKE_BIN:$PATH" \
        HERDR_PANE_ID="w1:p0" HERDR_WORKSPACE_ID="w1" \
        HERDR_STUB_LOG="$HERDR_STUB_LOG" HERDR_STUB_COUNTER="$HERDR_STUB_COUNTER" \
        "$HERDR_SCRIPT" --tooling 872
) </dev/null >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr"
LAST_RC=$?
LAST_STDERR=$(cat "$TMP_DIR/stderr")
if [ "$LAST_RC" -eq 1 ]; then pass "aborta (rc=$LAST_RC)"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "mefisto-tmux-pipeline.sh"; then pass "el remedio nombra mefisto-tmux-pipeline.sh"; else fail "mensaje inesperado: $LAST_STDERR"; fi
if grep -q "pane run" "$HERDR_STUB_LOG"; then fail "no deberia despachar ningun pane"; else pass "ningun pane despachado"; fi

# --- [23] Guard estatico del canonico (CA-4) ---------------------------------
#
# Contraparte del bloque [B] de test-batch-runtime.sh, sobre el archivo REAL
# (no la copia del fixture). La ruta legacy del estado ya la fija el bloque
# [I] de test-tooling-state-paths.sh; aqui se cierra la parte de CA-4 que no
# cubre nadie: que ningun comentario siga hablando de `claude -p` como si el
# runner fuera siempre Claude Code (MEF-ADR-0049), y que el estado se resuelva
# con mefisto_state_path en vez de componerse a mano.

CANON_HERDR="$REPO_ROOT/src/internal/scripts/mefisto-herdr-pipeline.sh"

echo ""
echo "[23] el canonico no menciona 'claude -p' y resuelve su estado con mefisto_state_path"
if grep -qF 'claude -p' "$CANON_HERDR"; then
    fail "todavia menciona 'claude -p' (el runner depende del runtime activo)"
    grep -nF 'claude -p' "$CANON_HERDR"
else
    pass "cero menciones de 'claude -p' (codigo y comentarios)"
fi
if grep -qF 'LOG_DIR_ABS="$(mefisto_state_path "logs")"' "$CANON_HERDR"; then
    pass "LOG_DIR_ABS resuelve con mefisto_state_path"
else
    fail "LOG_DIR_ABS ya no resuelve con mefisto_state_path"
fi
if grep -qF 'PANES_STATE="$(mefisto_state_path "herdr-report-panes.txt")"' "$CANON_HERDR"; then
    pass "el registro de panes resuelve con mefisto_state_path"
else
    fail "el registro de panes ya no resuelve con mefisto_state_path"
fi
LEGACY_CODE_REFS=$(grep -vE '^\s*#' "$CANON_HERDR" | grep -c '\.claude/pipeline' || true)
if [ "$LEGACY_CODE_REFS" -eq 0 ]; then
    pass "cero lineas de codigo con '.claude/pipeline'"
else
    fail "$LEGACY_CODE_REFS linea(s) de codigo con '.claude/pipeline'"
fi
# La unica referencia a .claude/scripts que sobrevive en CODIGO es la
# invocacion del visor, que todavia vive ahi (#878 neutralizo su fuente de
# datos, no su ubicacion) -- mismo caso que mefisto-tmux-pipeline.sh tras
# #871. Fijar el numero exacto convierte cualquier ruta legacy nueva en un
# fallo, sin pedir lo imposible mientras el visor no se mueva.
SCRIPTS_CODE_REFS=$(grep -vE '^\s*#' "$CANON_HERDR" | grep -c '\.claude/scripts' || true)
VIEWER_CODE_REFS=$(grep -vE '^\s*#' "$CANON_HERDR" | grep -c '\.claude/scripts/mefisto-stream-watch\.sh' || true)
if [ "$SCRIPTS_CODE_REFS" -eq "$VIEWER_CODE_REFS" ] && [ "$VIEWER_CODE_REFS" -gt 0 ]; then
    pass "las $VIEWER_CODE_REFS referencias a .claude/scripts en codigo son solo el visor"
else
    fail "hay referencias a .claude/scripts en codigo que no son el visor ($SCRIPTS_CODE_REFS totales, $VIEWER_CODE_REFS del visor)"
    grep -vE '^\s*#' "$CANON_HERDR" | grep -n '\.claude/scripts'
fi
if grep -qF 'dispatch_to_pane "$title" "$issue" "$SCRIPT_DIR/mefisto-tooling-pipeline.sh"' "$CANON_HERDR" \
   && grep -qF 'dispatch_to_pane "mefisto-batch ${issues_csv}" "$issues_csv" "$SCRIPT_DIR/mefisto-batch-pipeline.sh"' "$CANON_HERDR"; then
    pass "tooling y batch se despachan a los siblings canonicos via SCRIPT_DIR (CA-2)"
else
    fail "tooling/batch ya no se despachan a los siblings canonicos via SCRIPT_DIR"
fi

echo ""
echo "----------------------------------------"
echo "  Guards de contexto y del canonico: $PASS pass, $FAIL fail (hasta aqui)"
echo "----------------------------------------"

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -eq 0 ]
