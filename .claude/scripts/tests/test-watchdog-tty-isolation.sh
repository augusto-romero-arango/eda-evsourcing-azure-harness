#!/usr/bin/env bash
# test-watchdog-tty-isolation.sh -- Repro determinista de la clase de bug de
# issue #943: aislar el tty en la invocacion del adaptador para que ninguna
# tool Bash del agente quede suspendida por SIGTTIN/SIGTTOU.
#
# Contexto: en el batch de #928 (2026-09-06) un writer quedo 15 minutos
# detenido (STAT=T) porque una tool Bash del agente accedio a la terminal
# (read </dev/tty, stty/tcsetattr, o lectura de stdin heredado) mientras
# corria en un grupo de procesos que NO era el grupo en primer plano de la
# pty del pane -- el kernel detiene al grupo ENTERO con SIGTTIN/SIGTTOU en
# ese caso. El arreglo (_mefisto-common.sh, run_agent_with_watchdog) lanza el
# comando en una sesion nueva (setsid o su fallback Perl) sin terminal de
# control y con stdin desde /dev/null: sin terminal de control,
# SIGTTIN/SIGTTOU son imposibles.
#
# Casos cubiertos:
#   [CA-3] Repro determinista dentro de una pty real (tmux): el guion
#       'touch-tty' de runtime-fake.sh (message + read </dev/tty + stty -echo
#       + read de stdin, terminal success) corre bajo
#       mefisto-run-agent.sh --timeout 20 y jamas deja un proceso del arbol en
#       STAT=T -- exit 0, run.completed presente, duracion < 20s.
#   [control] El MISMO guion, lanzado con el patron VIEJO (set -m + '&' sin
#       setsid, sin aislar stdin) replicado inline en este test, SI deja el
#       grupo en STAT=T -- demuestra que la pty del test ejercita el
#       mecanismo real y que [CA-3] no pasa en vacio.
#   [CA-4] Degradacion explicita: con un PATH que no expone `setsid` ni
#       `perl`, run_agent_with_watchdog cae al patron viejo (set -m +
#       /dev/null) pero deja una linea WARN en events_log, nunca en silencio.
#
# Si `tmux` no esta en PATH, el test FALLA con un mensaje explicito -- nunca
# se salta en silencio (CA-3): sin una pty real no hay forma de ejercitar
# SIGTTIN/SIGTTOU.
#
# Uso: .claude/scripts/tests/test-watchdog-tty-isolation.sh
# Exit code: 0 si todos los checks pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INTERNAL_SCRIPTS="$REPO_ROOT/src/internal/scripts"
LIB_DIR="$INTERNAL_SCRIPTS/lib"
RUNNER="$INTERNAL_SCRIPTS/mefisto-run-agent.sh"
FAKE_LIB="$LIB_DIR/runtime-fake.sh"
COMMON_LIB="$REPO_ROOT/.claude/scripts/_mefisto-common.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

if ! command -v tmux >/dev/null 2>&1; then
    echo "FAIL: tmux no esta en PATH -- este test EXIGE una pty real para ejercitar SIGTTIN/SIGTTOU (issue #943); no puede saltarse en silencio" >&2
    exit 1
fi

TMP=$(mktemp -d)
SESSION_A="mefisto-tty-a-$$"
SESSION_CTRL="mefisto-tty-ctrl-$$"
CTRL_PID=""

cleanup() {
    tmux kill-session -t "$SESSION_A" >/dev/null 2>&1 || true
    tmux kill-session -t "$SESSION_CTRL" >/dev/null 2>&1 || true
    [ -n "$CTRL_PID" ] && kill -9 -"$CTRL_PID" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

# any_stopped <marker> -- exit 0 si algun proceso vivo cuyo argv contiene
# <marker> esta en STAT=T (detenido), 1 si ninguno lo esta. El anclaje `^[Tt]`
# no es cosmetico: el estado va SIEMPRE en el primer caracter de STAT y los
# flags que le siguen (`s`, `+`, `N`, `<`...) no incluyen ninguna T -- un
# `/T/` suelto podria dar un falso positivo sobre un flag futuro y volver el
# test flaky en la direccion peor (fallar cuando el arreglo funciona).
any_stopped() {
    local marker="$1"
    ps -axo stat=,command= 2>/dev/null | awk -v m="$marker" '
        index($0, m) > 0 && $1 ~ /^[Tt]/ { found=1 }
        END { exit(found ? 0 : 1) }
    '
}

# ============================================================================
echo "[CA-3] mefisto-run-agent.sh + guion touch-tty dentro de una pty real (tmux)"

WORKDIR_A="$TMP/wt-a"; mkdir -p "$WORKDIR_A"
PROMPT_FILE="$TMP/prompt.txt"; echo "prompt de prueba" > "$PROMPT_FILE"
SYSTEM_FILE="$TMP/system.txt"; echo "system de prueba" > "$SYSTEM_FILE"
EVENT_LOG_A="$TMP/event-log-a.jsonl"
RC_A="$TMP/rc-a"
DONE_A="$TMP/done-a"

RUN_SCRIPT_A="$TMP/run-a.sh"
cat > "$RUN_SCRIPT_A" <<EOF
#!/usr/bin/env bash
MEFISTO_FAKE_SCRIPT=touch-tty "$RUNNER" --runtime fake --agent test-agent --cwd "$WORKDIR_A" --prompt-file "$PROMPT_FILE" --event-log "$EVENT_LOG_A" --timeout 20
echo \$? > "$RC_A"
touch "$DONE_A"
EOF
chmod +x "$RUN_SCRIPT_A"

START_A=$(date +%s)
tmux new-session -d -s "$SESSION_A" "$RUN_SCRIPT_A"

SEEN_T_A=false
i=0
while [ "$i" -lt 400 ]; do
    [ -f "$DONE_A" ] && break
    if any_stopped "$TMP"; then
        SEEN_T_A=true
    fi
    sleep 0.05
    i=$((i + 1))
done
# Una ultima pasada tras ver DONE_A: el `break` no espera un tick mas, asi que
# una ventana de STAT=T justo antes del cierre podria perderse sin este check.
if any_stopped "$TMP"; then
    SEEN_T_A=true
fi
END_A=$(date +%s)
DURATION_A=$((END_A - START_A))

if [ "$SEEN_T_A" = "false" ]; then
    pass "CA-3-1: ningun proceso del arbol quedo en STAT=T durante la corrida (sesion nueva, sin terminal de control)"
else
    fail "CA-3-1: se observo STAT=T en el arbol -- la sesion nueva no aislo la tty"
fi

if [ -f "$DONE_A" ]; then
    pass "CA-3-2: la corrida termino dentro de la ventana de espera (< 20s)"
else
    fail "CA-3-2: la corrida no termino tras 20s de espera activa"
fi

RC_VAL_A="$(cat "$RC_A" 2>/dev/null || echo "?")"
if [ "$RC_VAL_A" = "0" ]; then
    pass "CA-3-3: mefisto-run-agent.sh termino con exit 0"
else
    fail "CA-3-3: exit '$RC_VAL_A' (esperaba 0)"
fi

if [ "$DURATION_A" -lt 20 ]; then
    pass "CA-3-4: duracion total ${DURATION_A}s < 20s"
else
    fail "CA-3-4: duracion total ${DURATION_A}s >= 20s"
fi

if [ -s "$EVENT_LOG_A" ] && jq -e 'select(.type=="run.completed")' "$EVENT_LOG_A" >/dev/null 2>&1; then
    pass "CA-3-5: --event-log trae un evento run.completed"
else
    fail "CA-3-5: no se encontro run.completed en --event-log: $(cat "$EVENT_LOG_A" 2>/dev/null)"
fi

tmux kill-session -t "$SESSION_A" >/dev/null 2>&1 || true

# ============================================================================
echo ""
echo "[control] el patron VIEJO (set -m + '&' sin setsid, sin aislar stdin) SI detiene el grupo"

WORKDIR_CTRL="$TMP/wt-ctrl"; mkdir -p "$WORKDIR_CTRL"
CTRL_STDOUT="$TMP/ctrl-stdout.log"
CTRL_STDERR="$TMP/ctrl-stderr.log"
CTRL_PIDFILE="$TMP/ctrl.pid"

RUN_SCRIPT_CTRL="$TMP/run-ctrl.sh"
cat > "$RUN_SCRIPT_CTRL" <<EOF
#!/usr/bin/env bash
set -m
( cd "$WORKDIR_CTRL" && MEFISTO_FAKE_SCRIPT=touch-tty bash "$FAKE_LIB" __mefisto-fake-emit test-agent "$PROMPT_FILE" "$SYSTEM_FILE" ) >"$CTRL_STDOUT" 2>"$CTRL_STDERR" &
echo \$! > "$CTRL_PIDFILE"
set +m
sleep 30
EOF
chmod +x "$RUN_SCRIPT_CTRL"

tmux new-session -d -s "$SESSION_CTRL" "$RUN_SCRIPT_CTRL"

SEEN_T_CTRL=false
i=0
while [ "$i" -lt 100 ]; do
    if any_stopped "$TMP"; then
        SEEN_T_CTRL=true
        break
    fi
    sleep 0.05
    i=$((i + 1))
done

if [ "$SEEN_T_CTRL" = "true" ]; then
    pass "control-1: el patron viejo SI deja el grupo en STAT=T (la pty del test ejercita el mecanismo, CA-3 no pasa en vacio)"
else
    fail "control-1: el patron viejo NO dejo el grupo en STAT=T -- la pty del test no esta ejercitando SIGTTIN/SIGTTOU"
fi

CTRL_PID="$(cat "$CTRL_PIDFILE" 2>/dev/null || echo "")"
[ -n "$CTRL_PID" ] && kill -9 -"$CTRL_PID" 2>/dev/null
tmux kill-session -t "$SESSION_CTRL" >/dev/null 2>&1 || true

# ============================================================================
echo ""
echo "[CA-4] degradacion explicita: sin setsid ni perl en PATH, cae a set -m + WARN"

# shellcheck source=/dev/null
source "$COMMON_LIB" 2>/dev/null

BIN_NONE="$TMP/bin-none-degraded"; mkdir -p "$BIN_NONE"
for tool in rm sleep touch date; do
    src="$(command -v "$tool" 2>/dev/null)"
    [ -n "$src" ] && ln -sf "$src" "$BIN_NONE/$tool"
done

WT_DEG="$TMP/wt-degraded"; mkdir -p "$WT_DEG"
DEG_EVENTS="$TMP/degraded-events.log"
ORIG_PATH_DEG="$PATH"
PATH="$BIN_NONE"
EXIT_DEG=$(run_agent_with_watchdog "$WT_DEG" 5 "$TMP/deg-stdout.log" "$TMP/deg-stderr.log" "$DEG_EVENTS" "writer" "$TMP/deg-signal" \
    /bin/echo hola)
PATH="$ORIG_PATH_DEG"

if [ "$EXIT_DEG" = "0" ]; then
    pass "CA-4-1: sin setsid ni perl en PATH, el comando corre igual y su exit code viaja intacto"
else
    fail "CA-4-1: se esperaba exit 0, se obtuvo '$EXIT_DEG'"
fi

if grep -q "WARN: writer corre con terminal de control (sin setsid ni perl)" "$DEG_EVENTS" 2>/dev/null; then
    pass "CA-4-2: la degradacion deja constancia explicita (WARN) en events_log, nunca en silencio"
else
    fail "CA-4-2: no se encontro la linea WARN en events_log: $(cat "$DEG_EVENTS" 2>/dev/null)"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
