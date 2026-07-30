#!/usr/bin/env bash
# test-tmux-preparse.sh -- Tests del pre-parseo de scripts/tmux-pipeline.sh
# (issue #449: retomar una corrida caida desde el wrapper tmux).
#
# tmux-pipeline.sh termina con `main "$@"` a nivel superior y arranca con un
# guard defensivo que aborta si se ejecuta dentro del repo de Mefisto -- no se
# puede sourcear para testear el pre-parseo sin ejecutarlo (ver Notas tecnicas
# del issue). Este test lo corre como SUBPROCESO real, sin tocar ese guard ni
# el entrypoint:
#   - Un "consumidor" falso (mktemp -d + git init, sin .claude-plugin/plugin.json)
#     hace que el guard defensivo pase, igual que FAKE_CONSUMER en
#     test-pipeline-resolver.sh.
#   - Un stub de `tmux` en PATH (ver tmux_stub()) registra cada invocacion y
#     devuelve resultados deterministas -- nunca toca un servidor tmux real.
#   - --pipeline tooling evita que resolve_pipeline llame a `gh` (no hay red
#     en el test).
#
# Cubre:
#   T-1 (CA-1, regresion explicita del AC): "253 --from-stage 4" despacha a
#       cmd_single (sesion de un unico issue), NO a cmd_parallel via el
#       fallback "Multiples issues sin modo especificado".
#   T-2 (CA-2): el send-keys compone "<issue> --from-stage N", solo y
#       combinado con --scaffold-domain.
#   T-3 (CA-2): --from-stage sin valor, o con valor no numerico, aborta con
#       mensaje claro (mismo patron que --scaffold-domain/--pipeline).
#   T-4 (Notas tecnicas): --from-stage con --batch, --parallel, o multiples
#       issues sin modo, aborta (ambiguo sobre un lote).
#   T-5 (CA-3/CA-4): ante una sesion existente, sin --if-exists y sin TTY, el
#       default depende de si esta viva (reusar, no se toca) o muerta
#       (reemplazar: kill-session + recrear). --if-exists abort aborta sin
#       tocar la sesion.
#   T-6 (CA-2, ningun modo se traga el flag en silencio): --tooling e --infra
#       tambien lo propagan (sus sub-scripts aceptan --from-stage), y los modos
#       que no pueden usarlo (--scaffold, --attach) lo rechazan con mensaje.
#       Un flag aceptado y descartado sin aviso arrancaria de Stage 1 sobre un
#       worktree con commits -- el dano exacto que este issue evita.
#   T-7: invocar solo flags, sin argumento posicional, sale con el mensaje de
#       uso y no con el "unbound variable" de bash 3.2 al expandir un array
#       filtered_args vacio bajo `set -u`.
#
# Uso: scripts/tests/test-tmux-preparse.sh
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

assert_rc() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc (rc=$actual)"
    else
        fail "$desc -- se esperaba rc=$expected, fue rc=$actual"
    fi
}

# --- Consumidor falso: repo git sin .claude-plugin/plugin.json ---
FAKE_CONSUMER="$(mktemp -d)"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
trap 'rm -rf "$FAKE_CONSUMER" "$TMP_DIR"' EXIT

(cd "$FAKE_CONSUMER" && git init -q)

# --- Stub de tmux: nunca toca un servidor real ---
# Controlado por env vars leidas en cada invocacion:
#   TMUX_STUB_HAS_SESSION=0  -> has-session "existe" (default: no existe, exit 1)
#   TMUX_STUB_PANE_DEAD=1    -> list-panes de #{pane_dead} reporta muerta (default: 0, viva)
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

export TMUX_STUB_LOG="$TMP_DIR/tmux.log"

LAST_STDOUT=""
LAST_STDERR=""
LAST_RC=0

# run_wrapper <args...>
#
# Corre tmux-pipeline.sh como subproceso real (cwd = FAKE_CONSUMER, PATH con
# el stub de tmux primero, stdin/stdout/stderr sin TTY -- asi handle_session_conflict
# toma siempre la rama "sin TTY" de forma deterministica). Resetea el log del
# stub antes de cada corrida.
run_wrapper() {
    : > "$TMUX_STUB_LOG"
    local out="$TMP_DIR/stdout" err="$TMP_DIR/stderr"
    (
        cd "$FAKE_CONSUMER" || exit 99
        PATH="$FAKE_BIN:$PATH" "$TMUX_SCRIPT" "$@"
    ) </dev/null >"$out" 2>"$err"
    LAST_RC=$?
    LAST_STDOUT=$(cat "$out")
    LAST_STDERR=$(cat "$err")
}

echo "[T-1] --from-stage con un unico issue despacha a cmd_single, no a cmd_parallel (CA-1)"
unset TMUX_STUB_HAS_SESSION TMUX_STUB_PANE_DEAD
run_wrapper 253 --from-stage 4 --pipeline tooling
assert_rc "cmd_single corre sin abortar" 0 "$LAST_RC"
assert_not_contains "sin warning de 'Multiples issues'" "$LAST_STDOUT" "Multiples issues"
assert_contains "sesion de un unico issue (tooling-pipeline-253)" "$(cat "$TMUX_STUB_LOG")" "new-session -d -s tooling-pipeline-253"
assert_not_contains "no crea sesion 'parallel-*'" "$(cat "$TMUX_STUB_LOG")" "-s parallel-"

echo ""
echo "[T-2] el send-keys compone <issue> --from-stage N (CA-2)"
assert_contains "send-keys incluye '253 --from-stage 4'" "$(cat "$TMUX_STUB_LOG")" "253 --from-stage 4"

run_wrapper 253 --from-stage 4 --scaffold-domain miDominio --pipeline tooling
assert_rc "combinado con --scaffold-domain corre sin abortar" 0 "$LAST_RC"
assert_contains "send-keys combina --scaffold-domain y --from-stage en orden" "$(cat "$TMUX_STUB_LOG")" "253 --scaffold-domain miDominio --from-stage 4"

echo ""
echo "[T-3] --from-stage sin valor o no numerico aborta con mensaje claro"
run_wrapper 253 --pipeline tooling --from-stage
assert_rc "--from-stage al final (sin valor) aborta" 1 "$LAST_RC"
assert_contains "mensaje: falta el valor" "$LAST_STDERR" "Falta el valor de --from-stage"

run_wrapper 253 --from-stage abc --pipeline tooling
assert_rc "--from-stage abc (no numerico) aborta" 1 "$LAST_RC"
assert_contains "mensaje: debe ser un numero entero" "$LAST_STDERR" "--from-stage debe ser un numero entero"

echo ""
echo "[T-4] --from-stage sobre un lote de issues es ambiguo: se rechaza"
run_wrapper --batch 253 254 --from-stage 4
assert_rc "--batch + --from-stage aborta" 1 "$LAST_RC"
assert_contains "mensaje: no valido con --batch" "$LAST_STDERR" "no es valido con --batch"

run_wrapper --parallel 253 254 --from-stage 4
assert_rc "--parallel + --from-stage aborta" 1 "$LAST_RC"
assert_contains "mensaje: no valido con --parallel" "$LAST_STDERR" "no es valido con --parallel"

run_wrapper 253 254 --from-stage 4
assert_rc "multiples issues sin modo + --from-stage aborta" 1 "$LAST_RC"
assert_contains "mensaje: no valido con multiples issues" "$LAST_STDERR" "no es valido con multiples issues"

echo ""
echo "[T-5] sesion existente: default seguro sin TTY, y --if-exists abort (CA-3/CA-4)"

# Sesion viva, sin flag: se reusa (no se toca, no hay new-session/kill-session).
export TMUX_STUB_HAS_SESSION=0
export TMUX_STUB_PANE_DEAD=0
run_wrapper 253 --pipeline tooling
assert_rc "sesion viva sin flag: no aborta (reuse silencioso)" 0 "$LAST_RC"
assert_not_contains "sesion viva: no se crea sesion nueva" "$(cat "$TMUX_STUB_LOG")" "new-session"
assert_not_contains "sesion viva: no se mata la sesion" "$(cat "$TMUX_STUB_LOG")" "kill-session"
assert_contains "sesion viva: imprime el hint de conexion" "$LAST_STDOUT" "Sesion tmux lista"

# Sesion muerta, sin flag: se reemplaza (kill-session + recrear).
export TMUX_STUB_PANE_DEAD=1
run_wrapper 253 --pipeline tooling
assert_rc "sesion muerta sin flag: no aborta (replace automatico)" 0 "$LAST_RC"
assert_contains "sesion muerta: se mata la sesion vieja" "$(cat "$TMUX_STUB_LOG")" "kill-session"
assert_contains "sesion muerta: se crea una nueva" "$(cat "$TMUX_STUB_LOG")" "new-session"

# --if-exists abort: aborta sin tocar la sesion, viva o muerta.
export TMUX_STUB_PANE_DEAD=0
run_wrapper 253 --pipeline tooling --if-exists abort
assert_rc "--if-exists abort aborta" 1 "$LAST_RC"
assert_not_contains "--if-exists abort: no crea sesion" "$(cat "$TMUX_STUB_LOG")" "new-session"
assert_not_contains "--if-exists abort: no mata la sesion" "$(cat "$TMUX_STUB_LOG")" "kill-session"

unset TMUX_STUB_HAS_SESSION TMUX_STUB_PANE_DEAD

echo ""
echo "[T-6] ningun modo se traga --from-stage en silencio (CA-2)"

# --tooling e --infra son modos de un unico issue y sus sub-scripts aceptan
# --from-stage (rango 1-2): deben propagarlo.
run_wrapper --tooling 253 --from-stage 2
assert_rc "--tooling + --from-stage corre sin abortar" 0 "$LAST_RC"
assert_contains "--tooling propaga el flag al send-keys" "$(cat "$TMUX_STUB_LOG")" "tooling-pipeline.sh' 253 --from-stage 2"

run_wrapper --infra 253 --from-stage 2
assert_rc "--infra + --from-stage corre sin abortar" 0 "$LAST_RC"
assert_contains "--infra propaga el flag al send-keys" "$(cat "$TMUX_STUB_LOG")" "iac-pipeline.sh' 253 --from-stage 2"

# --scaffold y --attach no tienen stages retomables: rechazan en vez de callar.
run_wrapper --scaffold 253 --domain miDominio --from-stage 2
assert_rc "--scaffold + --from-stage aborta" 1 "$LAST_RC"
assert_contains "mensaje: no valido con --scaffold" "$LAST_STDERR" "no es valido con --scaffold"

run_wrapper --attach tooling-pipeline-253 --from-stage 2
assert_rc "--attach + --from-stage aborta" 1 "$LAST_RC"
assert_contains "mensaje: no aplica a --attach" "$LAST_STDERR" "no aplica a --attach"

echo ""
echo "[T-7] solo flags, sin argumento posicional: mensaje de uso, no error de bash"
run_wrapper --from-stage 4
assert_rc "aborta" 1 "$LAST_RC"
assert_contains "mensaje: faltan argumentos posicionales" "$LAST_STDERR" "Faltan argumentos posicionales"
assert_not_contains "sin 'unbound variable' de bash 3.2" "$LAST_STDERR" "unbound variable"

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
