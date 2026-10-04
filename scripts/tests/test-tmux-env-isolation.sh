#!/usr/bin/env bash
# test-tmux-env-isolation.sh -- Frontera de entorno de scripts/tmux-pipeline.sh
# (issue #1740): los hijos de tmux usan SIEMPRE la biblioteca, el validador de
# modelos y el estado de su propia distribucion/consumidor, nunca los heredados
# de un servidor tmux nacido en otra distribucion.
#
# Fixture hermetico: dos distribuciones (copias minimas del paquete) y dos
# consumidores Git falsos, tmux/gh/sleep stubs. No toca tmux real, red ni CLIs.
# Un "servidor" A se simula con el entorno heredado; el comando capturado por el
# stub de send-keys se ejecuta en un shell con ese entorno. No certifica un
# tmux real (eso es #1827).
#
# Uso: scripts/tests/test-tmux-env-isolation.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 -- esperado '$2', fue '$3'"; fi; }
assert_contains() { if printf '%s' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1 -- no se encontro: '$3'"; fi; }
assert_not_contains() { if printf '%s' "$2" | grep -qF -- "$3"; then fail "$1 -- se encontro indebidamente: '$3'"; else pass "$1"; fi; }

TMP_DIR="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/tmux" <<'STUB'
#!/usr/bin/env bash
set -u
echo "tmux $*" >> "$TMUX_STUB_LOG"
case "${1:-}" in
    has-session) exit 1 ;;
    list-panes) echo "%0" ;;
    split-window) echo "%1" ;;
    *) exit 0 ;;
esac
STUB
cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf 'OPEN|tipo:tooling\n'
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/sleep"
chmod +x "$FAKE_BIN/tmux" "$FAKE_BIN/gh" "$FAKE_BIN/sleep"
export TMUX_STUB_LOG="$TMP_DIR/tmux.log"

# make_dist <dir>: copia minima del paquete publicado con pipelines stub que
# registran el entorno que ven.
make_dist() {
    local d="$1" p
    mkdir -p "$d/scripts" "$d/src/runtime"
    cp "$REPO_ROOT/scripts/tmux-pipeline.sh" "$REPO_ROOT/scripts/_pipeline-common.sh" "$d/scripts/"
    cp -R "$REPO_ROOT/src/runtime/lib" "$REPO_ROOT/src/runtime/contract" "$d/src/runtime/"
    for p in tooling tdd iac scaffold batch parallel; do
        cat > "$d/scripts/$p-pipeline.sh" <<'STUB'
#!/usr/bin/env bash
mkdir -p "$MEFISTO_STATE_DIR"
printf '%s|%s|%s|%s|%s|%s|%s\n' "${MEFISTO_RUNTIME:-}" "${MEFISTO_RUNTIME_LIB_DIR:-}" "${MEFISTO_MODELS_VALIDATOR:-}" \
    "${MEFISTO_STATE_DIR:-}" "${MEFISTO_LEGACY_STATE_DIR:-}" "${MEFISTO_RUN_AGENT_BIN-unset}" "$*" > "$MEFISTO_STATE_DIR/child.env"
STUB
        chmod +x "$d/scripts/$p-pipeline.sh"
    done
}

make_consumer() { mkdir -p "$1" && (cd "$1" && git init -q); }

DIST_A="$TMP_DIR/dist a & co"; DIST_B="$TMP_DIR/dist b \$x"
CONS_A="$TMP_DIR/cons a"; CONS_B="$TMP_DIR/cons b ;x"
make_dist "$DIST_A"; make_dist "$DIST_B"; make_consumer "$CONS_A"; make_consumer "$CONS_B"
CONS_A="$(cd "$CONS_A" && pwd -P)"; CONS_B="$(cd "$CONS_B" && pwd -P)"
DIST_A="$(cd "$DIST_A" && pwd -P)"; DIST_B="$(cd "$DIST_B" && pwd -P)"

# Entorno "servidor": lo heredado de la distribucion/consumidor origen.
server_env() { # <dist> <consumer>
    printf 'MEFISTO_RUNTIME_LIB_DIR=%s\nMEFISTO_MODELS_VALIDATOR=%s\nMEFISTO_STATE_DIR=%s\nMEFISTO_LEGACY_STATE_DIR=%s\nMEFISTO_RUN_AGENT_BIN=%s\n' \
        "$1/src/runtime/lib" "$1/src/runtime/contract/models.validate.jq" "$2/.mefisto/pipeline" "$2/.claude/pipeline" "$1/foreign-runner"
}

LAST_RC=0; LAST_CMD=""
# dispatch <dist> <consumer> <server-dist> <server-consumer> <args...>
dispatch() {
    local dist="$1" cons="$2" sd="$3" sc="$4"; shift 4
    : > "$TMUX_STUB_LOG"
    local envs; envs=$(server_env "$sd" "$sc")
    (
        cd "$cons" || exit 99
        while IFS= read -r l; do [ -n "$l" ] && export "$l"; done <<< "$envs"
        PATH="$FAKE_BIN:$PATH" MEFISTO_UI=tmux MEFISTO_RUNTIME=claude "$dist/scripts/tmux-pipeline.sh" "$@"
    ) </dev/null >"$TMP_DIR/out" 2>"$TMP_DIR/err"
    LAST_RC=$?
    LAST_CMD=$(grep 'send-keys -t %1 ' "$TMUX_STUB_LOG" | tail -1 | sed 's/^tmux send-keys -t %1 //; s/ Enter$//')
}

# run_child <consumer> <server-dist> <server-consumer>: ejecuta el comando capturado con el entorno del servidor.
run_child() {
    local cons="$1" sd="$2" sc="$3" envs
    envs=$(server_env "$sd" "$sc")
    ( cd "$cons" || exit 99
      while IFS= read -r l; do [ -n "$l" ] && export "$l"; done <<< "$envs"
      PATH="$FAKE_BIN:$PATH" bash -c "$LAST_CMD" )
}

echo "[1] CA-1/CA-3: A->B y B->A, cada hijo usa su distribucion y su consumidor"
dispatch "$DIST_B" "$CONS_B" "$DIST_A" "$CONS_A" --tooling 77
assert_eq "A->B: rc 0" "0" "$LAST_RC"
run_child "$CONS_B" "$DIST_A" "$CONS_A"
got=$(cat "$CONS_B/.mefisto/pipeline/child.env" 2>/dev/null)
assert_eq "A->B: runtime lib/validador/estado de B, runner descartado" \
    "claude|$DIST_B/src/runtime/lib|$DIST_B/src/runtime/contract/models.validate.jq|$CONS_B/.mefisto/pipeline|$CONS_B/.claude/pipeline|unset|77" "$got"
[ ! -e "$CONS_A/.mefisto/pipeline/child.env" ] && pass "A->B: no escribe en consumidor A" || fail "A->B: escribio en A"
[ ! -d "$CONS_B/.claude/pipeline" ] && pass "A->B: sin escrituras legacy en B" || fail "A->B: creo legacy en B"

dispatch "$DIST_A" "$CONS_A" "$DIST_B" "$CONS_B" --tooling 78
run_child "$CONS_A" "$DIST_B" "$CONS_B"
got=$(cat "$CONS_A/.mefisto/pipeline/child.env" 2>/dev/null)
assert_eq "B->A: todo de A" \
    "claude|$DIST_A/src/runtime/lib|$DIST_A/src/runtime/contract/models.validate.jq|$CONS_A/.mefisto/pipeline|$CONS_A/.claude/pipeline|unset|78" "$got"
[ ! -d "$CONS_A/.claude/pipeline" ] && pass "B->A: sin escrituras legacy en A" || fail "B->A: creo legacy en A"
assert_eq "B->A: B no cambia" "77" "$(cut -d'|' -f7 "$CONS_B/.mefisto/pipeline/child.env")"

echo ""
echo "[2] CA-2: los seis modos envian el mismo prefijo, sin set-environment global"
expected_prefix="env -u MEFISTO_RUNTIME_LIB_DIR -u MEFISTO_MODELS_VALIDATOR -u MEFISTO_STATE_DIR -u MEFISTO_LEGACY_STATE_DIR -u MEFISTO_RUN_AGENT_BIN MEFISTO_RUNTIME=claude MEFISTO_RUNTIME_LIB_DIR="
for mode in "77 --pipeline tooling" "--tooling 77 --from-stage 2 --models writer=sonnet --variant v1" "--infra 77" "--scaffold 77 --domain demo" "--batch 77 78 --pipeline tooling" "--parallel 77 78 --pipeline tooling"; do
    # shellcheck disable=SC2086
    dispatch "$DIST_B" "$CONS_B" "$DIST_A" "$CONS_A" $mode
    assert_eq "[$mode] rc 0" "0" "$LAST_RC"
    assert_contains "[$mode] prefijo env -u" "$LAST_CMD" "$expected_prefix"
    assert_contains "[$mode] roots con espacios quoteadas" "$LAST_CMD" "$(printf '%q' "$DIST_B/src/runtime/lib")"
    assert_contains "[$mode] estado del consumidor" "$LAST_CMD" "$(printf '%q' "$CONS_B/.mefisto/pipeline")"
    assert_not_contains "[$mode] sin set-environment" "$(cat "$TMUX_STUB_LOG")" "set-environment"
done
dispatch "$DIST_B" "$CONS_B" "$DIST_A" "$CONS_A" --tooling 77 --from-stage 2 --models writer=sonnet --variant v1
assert_contains "tooling conserva --from-stage" "$LAST_CMD" "--from-stage 2"
assert_contains "tooling conserva --models" "$LAST_CMD" "--models 'writer=sonnet'"
assert_contains "tooling conserva --variant" "$LAST_CMD" "--variant 'v1'"
dispatch "$DIST_B" "$CONS_B" "$DIST_A" "$CONS_A" --scaffold 77 --domain demo
assert_contains "scaffold conserva --domain" "$LAST_CMD" "--domain demo"

echo ""
echo "[3] CA-4: clausura propia incompleta aborta antes de crear panes (sin usar la heredada)"
make_dist "$TMP_DIR/dist broken"
rm "$TMP_DIR/dist broken/src/runtime/contract/models.validate.jq"
dispatch "$TMP_DIR/dist broken" "$CONS_B" "$DIST_A" "$CONS_A" --tooling 77
[ "$LAST_RC" -ne 0 ] && pass "falta validador propio: aborta" || fail "falta validador propio: no aborto"
assert_not_contains "falta validador propio: sin new-session" "$(cat "$TMUX_STUB_LOG")" "new-session"
assert_contains "falta validador propio: causa" "$(cat "$TMP_DIR/err")" "models.validate.jq"
rm -rf "$TMP_DIR/dist broken/src/runtime/lib"
dispatch "$TMP_DIR/dist broken" "$CONS_B" "$DIST_A" "$CONS_A" --tooling 77
[ "$LAST_RC" -ne 0 ] && pass "falta lib propia: aborta" || fail "falta lib propia: no aborto"
assert_not_contains "falta lib propia: sin new-session" "$(cat "$TMUX_STUB_LOG")" "new-session"

echo ""
echo "[4] CA-5: --help conserva su UX"
dispatch "$DIST_B" "$CONS_B" "$DIST_A" "$CONS_A" --help
assert_eq "--help rc 0" "0" "$LAST_RC"
assert_contains "--help imprime uso" "$(cat "$TMP_DIR/out")" "tmux-pipeline.sh"

echo ""
echo "Resultado: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
