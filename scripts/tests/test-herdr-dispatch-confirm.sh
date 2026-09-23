#!/usr/bin/env bash
# test-herdr-dispatch-confirm.sh -- Confirmacion de arranque de dispatch_to_pane
# y cmd_parallel en scripts/herdr-pipeline.sh (issue #1563).
#
# Mismo estilo de subproceso real con stubs que test-herdr-parallel.sh: un
# "consumidor" falso (mktemp -d + git init, sin .claude-plugin/plugin.json) y
# stubs de `herdr` y `gh` en PATH que registran cada invocacion y devuelven
# respuestas deterministas -- nunca tocan un servidor herdr ni la red.
#
# El stub de `pane run` simula que el shell del pane ejecuto la linea tecleada
# tocando el archivo de --started-marker que trae la cmdline, EXCEPTO para los
# panes listados en HERDR_STUB_NEVER_CONFIRM (simula el pane con el shell en
# un estado invalido de la certificacion v0.38.2: el texto se tecleo pero
# --_pane-runner jamas arranco). HERDR_DISPATCH_CONFIRM_TIMEOUT se fija corto
# (1s) para que el camino de fallo no alargue la corrida de tests.
#
# Cubre (CA-6):
#   [A] Arranque confirmado al primer intento: un solo pane run, exito, sin
#       aviso de reintento.
#   [B] Fallo + reintento exitoso en pane nuevo: el pane sospechoso nunca se
#       vuelve a escribir, el reintento crea un pane nuevo y confirma ahi.
#   [C] Fallo doble: ni el pane original ni el de reintento confirman -- exit
#       distinto de 0, mensaje nombra ambos paneles y sugiere cerrarlos.
#
# Uso: scripts/tests/test-herdr-dispatch-confirm.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HERDR_SCRIPT="$REPO_ROOT/scripts/herdr-pipeline.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass "$desc"
    else
        fail "$desc -- no se encontro: '$needle'"
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        fail "$desc -- se encontro indebidamente: '$needle'"
    else
        pass "$desc"
    fi
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc -- se esperaba '$expected', fue '$actual'"
    fi
}

FAKE_CONSUMER="$(mktemp -d)"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
trap 'rm -rf "$FAKE_CONSUMER" "$TMP_DIR"' EXIT

(cd "$FAKE_CONSUMER" && git init -q)

export HERDR_STUB_LOG="$TMP_DIR/herdr-invocations.log"
export HERDR_STUB_COUNTER="$TMP_DIR/herdr-pane-counter"

# Stub de herdr: registra cada invocacion y responde JSON determinista.
#   pane split -> pane_id incremental w1:pN (contador en archivo)
#   pane process-info -> pane siempre libre (foreground == shell)
#   pane run -> ok; toca el --started-marker de la cmdline salvo que el pane
#               destino este listado en HERDR_STUB_NEVER_CONFIRM (simula el
#               shell atascado que nunca ejecuto --_pane-runner)
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
        echo '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":100}}}'
        ;;
    "pane run")
        pane_id="${3:-}"
        cmdline="${4:-}"
        confirm=1
        for bad in ${HERDR_STUB_NEVER_CONFIRM:-}; do
            [ "$bad" = "$pane_id" ] && confirm=0
        done
        if [ "$confirm" -eq 1 ]; then
            marker=$(printf '%s\n' "$cmdline" | grep -oE -- '--started-marker [^[:space:]]+' | awk '{print $2}')
            if [ -n "$marker" ]; then
                mkdir -p "$(dirname "$marker")" 2>/dev/null
                : > "$marker"
            fi
        fi
        echo '{"result":{"type":"ok"}}'
        ;;
    *)
        echo '{"result":{"type":"ok"}}'
        ;;
esac
STUB
chmod +x "$FAKE_BIN/herdr"

# Stub de gh: issue 42 siempre OPEN/tipo:tooling (unico issue usado aqui).
cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -u
issue="${3:-}"
case "$issue" in
    42) printf 'OPEN|tipo:tooling\n' ;;
    *)  exit 1 ;;
esac
STUB
chmod +x "$FAKE_BIN/gh"

echo 0 > "$HERDR_STUB_COUNTER"

# El contador de pane split NO se reinicia entre corridas (pane ids unicos en
# todo el archivo); el pool de panes registrados SI se limpia antes de cada
# corrida para que acquire_report_pane nunca reutilice un pane de un escenario
# anterior -- cada bloque [A]/[B]/[C] arranca sin ningun pane "libre" previo.
run_dispatch() {
    : > "$HERDR_STUB_LOG"
    rm -rf "$FAKE_CONSUMER/.mefisto" "$FAKE_CONSUMER/.claude/pipeline"
    (
        cd "$FAKE_CONSUMER" || exit 99
        env -u MEFISTO_UI -u MEFISTO_STATE_DIR -u MEFISTO_LEGACY_STATE_DIR \
            PATH="$FAKE_BIN:$PATH" \
            MEFISTO_RUNTIME=claude HERDR_ENV=1 HERDR_PANE_ID="w1:p0" HERDR_WORKSPACE_ID="w1" \
            HERDR_DISPATCH_CONFIRM_TIMEOUT="${HERDR_TEST_TIMEOUT:-1}" \
            HERDR_STUB_LOG="$HERDR_STUB_LOG" HERDR_STUB_COUNTER="$HERDR_STUB_COUNTER" \
            HERDR_STUB_NEVER_CONFIRM="${HERDR_STUB_NEVER_CONFIRM:-}" \
            "$HERDR_SCRIPT" "$@" 2>&1
    )
}

# El contador de pane split es compartido y NUNCA se reinicia entre bloques
# (arriba): se lee su valor ANTES de cada corrida para predecir los pane ids
# que asignara el stub (w1:p<contador+1> para el pane de ejecucion, y
# w1:p<contador+2> para el reintento si hace falta uno).
next_pane_id() {
    printf 'w1:p%s\n' "$(( $(cat "$HERDR_STUB_COUNTER") + $1 ))"
}

# --- [A] Arranque confirmado al primer intento ---
echo "[A] Arranque confirmado al primer intento"

unset HERDR_STUB_NEVER_CONFIRM
PANE_A=$(next_pane_id 1)
OUT=$(run_dispatch --tooling 42)
RC=$?
STUB_CALLS=$(cat "$HERDR_STUB_LOG")

assert_eq "exit code 0" "0" "$RC"
assert_eq "un solo pane split (el pane de ejecucion)" "1" "$(grep -c "^herdr pane split" <<< "$STUB_CALLS")"
assert_eq "un solo pane run (sin reintento)" "1" "$(grep -c "^herdr pane run" <<< "$STUB_CALLS")"
assert_contains "mensaje de exito nombra el pane" "$OUT" "corriendo en el pane $PANE_A"
assert_not_contains "no hay aviso de reintento" "$OUT" "Reintentando"

# --- [B] Fallo + reintento exitoso en pane nuevo ---
echo "[B] Fallo del primer arranque, reintento exitoso en un pane nuevo"

SUSPECT_B=$(next_pane_id 1)
RETRY_B=$(next_pane_id 2)
export HERDR_STUB_NEVER_CONFIRM="$SUSPECT_B"
OUT=$(run_dispatch --tooling 42)
RC=$?
STUB_CALLS=$(cat "$HERDR_STUB_LOG")
unset HERDR_STUB_NEVER_CONFIRM

assert_eq "exit code 0 (el reintento confirma)" "0" "$RC"
assert_eq "dos pane split: pane sospechoso + reintento nuevo" "2" "$(grep -c "^herdr pane split" <<< "$STUB_CALLS")"
assert_eq "dos pane run: original + reintento" "2" "$(grep -c "^herdr pane run" <<< "$STUB_CALLS")"
assert_contains "el reintento nunca vuelve a escribir en el pane sospechoso" "$STUB_CALLS" "pane run $RETRY_B"
assert_eq "el pane sospechoso solo recibe un pane run" "1" "$(grep -c "pane run $SUSPECT_B" <<< "$STUB_CALLS")"
assert_contains "el aviso nombra el pane sospechoso" "$OUT" "El pane $SUSPECT_B no confirmo el arranque"
assert_contains "el exito final nombra el pane de reintento" "$OUT" "corriendo en el pane $RETRY_B"
assert_contains "el exito final documenta el reintento" "$OUT" "reintento tras un arranque no confirmado en $SUSPECT_B"

# --- [C] Fallo doble: ni el original ni el reintento confirman ---
echo "[C] Fallo doble: ni el pane original ni el de reintento confirman"

SUSPECT_C=$(next_pane_id 1)
RETRY_C=$(next_pane_id 2)
export HERDR_STUB_NEVER_CONFIRM="$SUSPECT_C $RETRY_C"
OUT=$(run_dispatch --tooling 42)
RC=$?
STUB_CALLS=$(cat "$HERDR_STUB_LOG")
unset HERDR_STUB_NEVER_CONFIRM

assert_eq "exit code distinto de 0" "1" "$RC"
assert_eq "dos pane split (sin un tercer intento)" "2" "$(grep -c "^herdr pane split" <<< "$STUB_CALLS")"
assert_eq "dos pane run (sin un tercer intento)" "2" "$(grep -c "^herdr pane run" <<< "$STUB_CALLS")"
assert_contains "el mensaje final nombra el pane original" "$OUT" "$SUSPECT_C"
assert_contains "el mensaje final nombra el pane de reintento" "$OUT" "$RETRY_C"
assert_contains "el mensaje sugiere cerrar los paneles" "$OUT" "Cierra ambos paneles"
assert_not_contains "no imprime el mensaje de exito" "$OUT" "corriendo en el pane"

# --- Resumen ---
echo ""
echo "Resultado: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
