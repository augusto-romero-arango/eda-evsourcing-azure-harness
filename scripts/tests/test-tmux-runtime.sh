#!/usr/bin/env bash
# test-tmux-runtime.sh -- Tests de la propagacion del runtime resuelto a los
# panes que lanza scripts/tmux-pipeline.sh (issue #1593).
#
# Contexto: un servidor tmux ya vivo NO propaga MEFISTO_RUNTIME a una sesion
# nueva creada por un cliente distinto (verificado en vivo, ver el issue). Sin
# fijarlo explicito en el send-keys, el sub-pipeline dentro del pane
# autodetecta por su cuenta: aborta si hay varios CLIs instalados, o corre en
# un runtime distinto del que lanzo el comando si hay uno solo.
#
# Estilo subproceso real con stubs (igual que test-tmux-preparse.sh y
# test-tmux-parallel.sh): un "consumidor" falso (mktemp -d + git init, sin
# .claude-plugin/plugin.json) y stubs de `tmux`/`gh`/`herdr` en PATH que
# registran cada invocacion y devuelven respuestas deterministas -- nunca
# tocan un servidor tmux real, la red, ni un workspace herdr real.
#
# Cubre (CA-4):
#   (a) con MEFISTO_RUNTIME=opencode, los cuatro modos que lanzan
#       sub-pipelines (single/tdd, batch, parallel, tooling) envian el
#       comando con el prefijo MEFISTO_RUNTIME=opencode.
#   (b) con stubs de `claude` y `opencode` en PATH y sin MEFISTO_RUNTIME,
#       aborta con el mensaje de CA-2 y no invoca `tmux new-session`.
#   (c) con HERDR_ENV=1 (contexto herdr), delega a herdr-pipeline.sh sin
#       resolver el runtime en tmux-pipeline.sh.
#
# Uso: scripts/tests/test-tmux-runtime.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

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

# --- Consumidor falso: repo git sin .claude-plugin/plugin.json ---
FAKE_CONSUMER="$(mktemp -d)"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
trap 'rm -rf "$FAKE_CONSUMER" "$TMP_DIR"' EXIT

(cd "$FAKE_CONSUMER" && git init -q)

# --- Stub de tmux: nunca toca un servidor real (idem test-tmux-preparse.sh) ---
cat > "$FAKE_BIN/tmux" <<'STUB'
#!/usr/bin/env bash
set -u
echo "tmux $*" >> "$TMUX_STUB_LOG"
case "${1:-}" in
    has-session)
        exit 1
        ;;
    list-panes)
        for a in "$@"; do
            if [ "$a" = "#{pane_dead}" ]; then
                echo "0"
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

# --- Stub de gh: cualquier issue resuelve OPEN + tipo:tooling ---
# (con --pipeline explicito, resolve_pipeline nunca llama a gh; solo
# cmd_parallel lo necesita, via resolve_issue_facts, incluso con override).
cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'OPEN|tipo:tooling\n'
STUB
chmod +x "$FAKE_BIN/gh"

# --- Stub de sleep: no-op (cmd_parallel duerme 30s reales entre panes) ---
cat > "$FAKE_BIN/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FAKE_BIN/sleep"

export TMUX_STUB_LOG="$TMP_DIR/tmux.log"

LAST_STDOUT=""
LAST_STDERR=""
LAST_RC=0

# run_wrapper <args...>
#
# Corre tmux-pipeline.sh como subproceso real (cwd = FAKE_CONSUMER, PATH con
# los stubs primero, sin TTY). MEFISTO_UI=tmux fuerza el camino tmux (evita
# que should_delegate_to_herdr desvie a herdr-pipeline.sh, incluso si el test
# corre dentro de un pane herdr de verdad).
run_wrapper() {
    : > "$TMUX_STUB_LOG"
    local out="$TMP_DIR/stdout" err="$TMP_DIR/stderr"
    (
        cd "$FAKE_CONSUMER" || exit 99
        PATH="$FAKE_BIN:$PATH" MEFISTO_UI=tmux "$TMUX_SCRIPT" "$@"
    ) </dev/null >"$out" 2>"$err"
    LAST_RC=$?
    LAST_STDOUT=$(cat "$out")
    LAST_STDERR=$(cat "$err")
}

echo "[a] MEFISTO_RUNTIME=opencode: los cuatro modos propagan el prefijo (CA-3/CA-4a)"

export MEFISTO_RUNTIME=opencode

run_wrapper 253 --pipeline tooling
assert_eq "single/tdd: no aborta" "0" "$LAST_RC"
assert_contains "single/tdd: send-keys con MEFISTO_RUNTIME=opencode" "$(cat "$TMUX_STUB_LOG")" "MEFISTO_RUNTIME=opencode"

run_wrapper --batch 253 254 --pipeline tooling
assert_eq "batch: no aborta" "0" "$LAST_RC"
assert_contains "batch: send-keys con MEFISTO_RUNTIME=opencode" "$(cat "$TMUX_STUB_LOG")" "MEFISTO_RUNTIME=opencode"

run_wrapper --parallel 42 43 --pipeline tooling
assert_eq "parallel: no aborta" "0" "$LAST_RC"
assert_contains "parallel: send-keys con MEFISTO_RUNTIME=opencode" "$(cat "$TMUX_STUB_LOG")" "MEFISTO_RUNTIME=opencode"

run_wrapper --tooling 253
assert_eq "tooling: no aborta" "0" "$LAST_RC"
assert_contains "tooling: send-keys con MEFISTO_RUNTIME=opencode" "$(cat "$TMUX_STUB_LOG")" "MEFISTO_RUNTIME=opencode"

unset MEFISTO_RUNTIME

echo ""
echo "[b] Sin MEFISTO_RUNTIME y con varios CLIs disponibles: aborta antes de tmux (CA-2/CA-4b)"

cat > "$FAKE_BIN/claude" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FAKE_BIN/claude"
cat > "$FAKE_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FAKE_BIN/opencode"

run_wrapper 253 --pipeline tooling
assert_eq "aborta (rc=1)" "1" "$LAST_RC"
assert_contains "mensaje: no se pudo resolver el runtime activo" "$LAST_STDERR" "No se pudo resolver el runtime activo"
assert_not_contains "no crea sesion tmux" "$(cat "$TMUX_STUB_LOG")" "new-session"

rm -f "$FAKE_BIN/claude" "$FAKE_BIN/opencode"

echo ""
echo "[c] Dentro de un pane herdr: delega a herdr-pipeline.sh sin resolver el runtime en tmux-pipeline (CA-1/CA-4c)"

export HERDR_STUB_LOG="$TMP_DIR/herdr.log"

cat > "$FAKE_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
set -u
echo "herdr $*" >> "$HERDR_STUB_LOG"
case "${1:-} ${2:-}" in
    "pane split")
        echo '{"result":{"pane":{"pane_id":"w1:p1"}}}'
        ;;
    "pane get")
        echo '{"result":{"pane":{"pane_id":"stub"}}}'
        ;;
    "pane process-info")
        echo '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":100}}}'
        ;;
    "pane run")
        cmdline="${4:-}"
        marker=$(printf '%s\n' "$cmdline" | grep -oE -- '--started-marker [^[:space:]]+' | awk '{print $2}')
        if [ -n "$marker" ]; then
            mkdir -p "$(dirname "$marker")" 2>/dev/null
            : > "$marker"
        fi
        echo '{"result":{"type":"ok"}}'
        ;;
    *)
        echo '{"result":{"type":"ok"}}'
        ;;
esac
STUB
chmod +x "$FAKE_BIN/herdr"

: > "$TMUX_STUB_LOG"
: > "$HERDR_STUB_LOG"
DELEGATE_OUT="$TMP_DIR/delegate-out"
(
    cd "$FAKE_CONSUMER" || exit 99
    env -u MEFISTO_UI \
        PATH="$FAKE_BIN:$PATH" \
        MEFISTO_RUNTIME=claude HERDR_ENV=1 HERDR_PANE_ID="w1:p0" HERDR_WORKSPACE_ID="w1" \
        "$TMUX_SCRIPT" --tooling 253
) </dev/null >"$DELEGATE_OUT" 2>&1
DELEGATE_RC=$?
DELEGATE_TEXT="$(cat "$DELEGATE_OUT")"

assert_not_contains "no invoca ningun comando tmux (delega antes)" "$(cat "$TMUX_STUB_LOG")" "tmux"
assert_contains "herdr-pipeline.sh SI corre (invoca herdr)" "$(cat "$HERDR_STUB_LOG")" "pane"
assert_not_contains "tmux-pipeline no emite su propio abort de runtime" "$DELEGATE_TEXT" "motivo desconocido"
assert_eq "delega sin abortar (runtime resuelto dentro de herdr-pipeline.sh)" "0" "$DELEGATE_RC"

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
