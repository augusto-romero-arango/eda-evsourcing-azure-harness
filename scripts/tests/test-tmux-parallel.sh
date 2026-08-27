#!/usr/bin/env bash
# test-tmux-parallel.sh -- Tests del gate de projections en --parallel de
# scripts/tmux-pipeline.sh (issue #706: el help prometia serializacion que el
# modo tmux nunca implemento -- dos tipo:projection SI corrian a la vez).
#
# Estilo subproceso real con stubs (igual que test-tmux-preparse.sh y
# test-herdr-parallel.sh): un "consumidor" falso (mktemp -d + git init, sin
# .claude-plugin/plugin.json) y stubs de `tmux`, `gh` y `sleep` en PATH que
# registran cada invocacion y devuelven respuestas deterministas -- nunca
# tocan un servidor tmux real, la red, ni duermen de verdad (el stagger real
# de 30s entre panes haria la suite lenta sin aportar nada al gate).
#
# Cubre:
#   [A] (CA-1) lote con >=2 tipo:projection aborta ANTES de crear la sesion
#       tmux (sin new-session ni split-window), con mensaje explicito que
#       nombra tipo:projection y /sequential.
#   [B] (CA-1) una sola projection en el lote (sola, o junto a un tooling) SI
#       pasa el gate y despacha sus panes.
#   [C] (CA-2) sin ninguna projection en el lote, el comportamiento no cambia:
#       la sesion se crea y se abre un pane por issue.
#
# Uso: scripts/tests/test-tmux-parallel.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

# Ver nota identica en test-tmux-preparse.sh: fuerza el camino tmux aunque el
# test corra dentro de un pane herdr.
export MEFISTO_UI=tmux

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMUX_SCRIPT="$REPO_ROOT/scripts/tmux-pipeline.sh"

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

# --- Consumidor falso + stubs de tmux, gh y sleep ---
FAKE_CONSUMER="$(mktemp -d)"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
trap 'rm -rf "$FAKE_CONSUMER" "$TMP_DIR"' EXIT

(cd "$FAKE_CONSUMER" && git init -q)

# Stub de tmux: idem test-tmux-preparse.sh (nunca toca un servidor real).
cat > "$FAKE_BIN/tmux" <<'STUB'
#!/usr/bin/env bash
set -u
echo "tmux $*" >> "$TMUX_STUB_LOG"
case "${1:-}" in
    has-session)
        exit "${TMUX_STUB_HAS_SESSION:-1}"
        ;;
    list-panes)
        for a in "$@"; do
            if [ "$a" = "#{pane_dead}" ]; then
                echo "${TMUX_STUB_PANE_DEAD:-0}"
                exit 0
            fi
        done
        echo "%0"
        ;;
    split-window)
        echo "%1"
        ;;
    *)
        exit 0
        ;;
esac
STUB
chmod +x "$FAKE_BIN/tmux"

# Stub de gh: responde a `gh issue view N --json state,labels -q <template>`
# con la linea "STATE|labels" que resolve_issue_facts espera (mismo stub que
# test-herdr-parallel.sh). El estado y los labels se derivan del numero:
#   42/43 -> OPEN, tipo:tooling
#   50/51 -> OPEN, tipo:projection
cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -u
issue="${3:-}"
case "$issue" in
    42|43) printf 'OPEN|tipo:tooling\n' ;;
    50|51) printf 'OPEN|tipo:projection\ndom:x\n' ;;
    *)     exit 1 ;;
esac
STUB
chmod +x "$FAKE_BIN/gh"

# Stub de sleep: no-op. cmd_parallel duerme 30s de verdad entre panes
# (stagger real, no delegado a un sub-proceso como en herdr) -- sin este stub
# cualquier lote con >=2 issues validos volveria la suite lenta sin aportar
# nada a la cobertura del gate.
cat > "$FAKE_BIN/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FAKE_BIN/sleep"

export TMUX_STUB_LOG="$TMP_DIR/tmux.log"

# run_parallel_capture <args...> -- corre tmux-pipeline.sh como subproceso
# real (cwd = FAKE_CONSUMER, PATH con los stubs primero, sin TTY) y deja
# RC/OUT en variables globales para poder hacer varias aserciones sobre la
# misma corrida.
run_parallel_capture() {
    : > "$TMUX_STUB_LOG"
    local out="$TMP_DIR/stdout" err="$TMP_DIR/stderr"
    (
        cd "$FAKE_CONSUMER" || exit 99
        PATH="$FAKE_BIN:$PATH" "$TMUX_SCRIPT" "$@"
    ) </dev/null >"$out" 2>"$err"
    RUN_RC=$?
    RUN_OUT="$(cat "$out" "$err")"
}

# --- [A] Gate de projections: >=2 aborta antes de tocar tmux ---
echo "[A] Lote con >=2 tipo:projection aborta antes de crear la sesion tmux (CA-1)"

run_parallel_capture --parallel 50 51
STUB_CALLS=$(cat "$TMUX_STUB_LOG")

assert_eq "exit code 1" "1" "$RUN_RC"
assert_contains "el mensaje nombra tipo:projection" "$RUN_OUT" "tipo:projection"
assert_contains "el mensaje apunta a /sequential" "$RUN_OUT" "/sequential"
assert_contains "el mensaje cita MEF-ADR-0034" "$RUN_OUT" "MEF-ADR-0034"
assert_not_contains "no crea la sesion tmux" "$STUB_CALLS" "new-session"
assert_not_contains "no abre ningun pane" "$STUB_CALLS" "split-window"

# --- [B] Una sola projection en el lote SI pasa ---
echo "[B] Una sola projection (sola, o con un tooling) pasa el gate (CA-1)"

run_parallel_capture --parallel 50
STUB_CALLS=$(cat "$TMUX_STUB_LOG")
assert_eq "una sola projection sola: exit 0" "0" "$RUN_RC"
assert_contains "crea la sesion tmux" "$STUB_CALLS" "new-session"
assert_eq "abre exactamente 1 pane" "1" "$(grep -c "^tmux split-window" <<< "$STUB_CALLS")"

run_parallel_capture --parallel 50 42
assert_eq "una projection + un tooling: exit 0" "0" "$RUN_RC"

# --- [C] Sin projections: comportamiento sin cambios (CA-2) ---
echo "[C] Sin tipo:projection en el lote, comportamiento actual sin cambios (CA-2)"

run_parallel_capture --parallel 42 43
STUB_CALLS=$(cat "$TMUX_STUB_LOG")
assert_eq "lote de 2 tooling: exit 0" "0" "$RUN_RC"
assert_contains "crea la sesion tmux" "$STUB_CALLS" "new-session"
assert_eq "abre exactamente 2 panes (uno por issue)" "2" "$(grep -c "^tmux split-window" <<< "$STUB_CALLS")"
assert_contains "mensaje de exito con ambos issues" "$RUN_OUT" "Pipeline paralelo iniciado: issues 42 43"

# --- Resumen ---
echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
