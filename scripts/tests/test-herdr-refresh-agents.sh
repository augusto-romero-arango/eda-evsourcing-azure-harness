#!/usr/bin/env bash
# test-herdr-refresh-agents.sh -- Tests del modo --refresh-agents (#1333).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HERDR_SCRIPT="$REPO_ROOT/scripts/herdr-pipeline.sh"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 -- se esperaba '$2', fue '$3'"; fi
}
assert_contains() {
    if printf '%s' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1 -- falta '$3'"; fi
}
assert_not_contains() {
    if printf '%s' "$2" | grep -qF -- "$3"; then fail "$1 -- aparece '$3'"; else pass "$1"; fi
}
extract_fn() {
    awk -v fn="$1" '$0 ~ "^" fn "\\(\\) \\{" { p=1 } p { print } p && /^}/ { p=0 }' "$2"
}

FAKE_CONSUMER="$(mktemp -d)"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/bin"
FAKE_RUNTIME="$TMP_DIR/runtime"
mkdir -p "$FAKE_BIN" "$FAKE_RUNTIME"
trap 'rm -rf "$FAKE_CONSUMER" "$TMP_DIR"' EXIT
(cd "$FAKE_CONSUMER" && git init -q)
export HERDR_STUB_LOG="$TMP_DIR/herdr.log"

cat > "$FAKE_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf 'herdr %s\n' "$*" >> "$HERDR_STUB_LOG"
case "${1:-} ${2:-}" in
  "agent list")
    printf '%s' '{"result":{"agents":[' \
      '{"agent":"prompted","agent_status":"idle","cwd":"'"$(git rev-parse --show-toplevel)"'","pane_id":"w9:self","workspace_id":"w9"},' \
      '{"agent":"prompted","agent_status":"working","cwd":"'"$(git rev-parse --show-toplevel)"'","pane_id":"w9:work","workspace_id":"w9"},' \
      '{"agent":"prompted","agent_status":"blocked","cwd":"'"$(git rev-parse --show-toplevel)"'","pane_id":"w9:block","workspace_id":"w9"},' \
      '{"agent":"missing","agent_status":"idle","cwd":"'"$(git rev-parse --show-toplevel)"'","pane_id":"w9:missing","workspace_id":"w9"},' \
      '{"agent":"without","agent_status":"idle","cwd":"'"$(git rev-parse --show-toplevel)"'","pane_id":"w9:without","workspace_id":"w9"},' \
      '{"agent":"broken","agent_status":"idle","cwd":"'"$(git rev-parse --show-toplevel)"'","pane_id":"w9:broken","workspace_id":"w9"},' \
      '{"agent":"prompted","agent_status":"idle","cwd":"'"$(git rev-parse --show-toplevel)"'","pane_id":"w9:ok","workspace_id":"w9"},' \
      '{"agent":"prompted","agent_status":"idle","cwd":"'"$(git rev-parse --show-toplevel)"'","pane_id":"w9:fail","workspace_id":"w9"},' \
      '{"agent":"restarting","agent_status":"idle","cwd":"'"$(git rev-parse --show-toplevel)"'","pane_id":"w9:restart","workspace_id":"w9"},' \
      '{"agent":"prompted","agent_status":"idle","cwd":"/otro","pane_id":"w9:other-cwd","workspace_id":"w9"},' \
      '{"agent":"prompted","agent_status":"idle","cwd":"'"$(git rev-parse --show-toplevel)"'","pane_id":"w8:other-workspace","workspace_id":"w8"}' \
      ']}}'
    printf '\n'
    ;;
  "agent prompt")
    [ "${3:-}" = "w9:fail" ] && exit 1
    exit 0
    ;;
esac
STUB
chmod +x "$FAKE_BIN/herdr"

cat > "$FAKE_RUNTIME/runtime-prompted.sh" <<'ADAPTER'
runtime_prompted_interactive_refresh() { printf '%s\n' 'prompt /refresh'; }
ADAPTER
cat > "$FAKE_RUNTIME/runtime-restarting.sh" <<'ADAPTER'
runtime_restarting_interactive_refresh() { printf '%s\n' 'restart /exit'; }
ADAPTER
cat > "$FAKE_RUNTIME/runtime-broken.sh" <<'ADAPTER'
runtime_broken_interactive_refresh() { return 1; }
ADAPTER
cat > "$FAKE_RUNTIME/runtime-without.sh" <<'ADAPTER'
runtime_without_other() { :; }
ADAPTER
: > "$FAKE_RUNTIME/mefisto-runtime.sh"

run_refresh() {
    : > "$HERDR_STUB_LOG"
    (
        cd "$FAKE_CONSUMER" || exit 99
        env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_WORKSPACE_ID "$@" \
            PATH="$FAKE_BIN:$PATH" MEFISTO_RUNTIME_LIB_DIR="$FAKE_RUNTIME" \
            HERDR_STUB_LOG="$HERDR_STUB_LOG" \
            "$HERDR_SCRIPT" --refresh-agents \
            2>"$TMP_DIR/stderr.log"
    )
}

echo "[A] No-op seguro fuera de contexto"
OUT=$(run_refresh)
RC=$?
CALLS=$(cat "$HERDR_STUB_LOG")
assert_eq "sin contexto sale 0" "0" "$RC"
assert_eq "sin contexto no imprime panes" "" "$OUT"
assert_eq "sin contexto no invoca herdr" "" "$CALLS"

OUT=$(
    cd "$FAKE_CONSUMER" || exit 99
    env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_WORKSPACE_ID \
        PATH="/usr/bin:/bin" MEFISTO_RUNTIME_LIB_DIR="$FAKE_RUNTIME" \
        HERDR_ENV=1 HERDR_PANE_ID=w9:self HERDR_WORKSPACE_ID=w9 \
        "$HERDR_SCRIPT" --refresh-agents 2>"$TMP_DIR/stderr.log"
)
RC=$?
assert_eq "sin herdr en PATH sale 0" "0" "$RC"
assert_eq "sin herdr no imprime panes" "" "$OUT"

echo "[B] Descubrimiento, filtro y estrategias"
OUT=$(run_refresh HERDR_ENV=1 HERDR_PANE_ID=w9:self HERDR_WORKSPACE_ID=w9)
RC=$?
CALLS=$(cat "$HERDR_STUB_LOG")
assert_eq "recorrido sale 0 aunque un prompt falle" "0" "$RC"
assert_eq "stdout tiene una linea por agente considerado" "9" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_contains "omite pane propio" "$OUT" "w9:self prompted omitido:pane-propio"
assert_contains "omite working" "$OUT" "w9:work prompted omitido:working"
assert_contains "omite blocked" "$OUT" "w9:block prompted omitido:blocked"
assert_contains "omite adaptador ausente" "$OUT" "w9:missing missing omitido:sin-estrategia"
assert_contains "omite funcion ausente" "$OUT" "w9:without without omitido:sin-estrategia"
assert_contains "omite estrategia fallida" "$OUT" "w9:broken broken omitido:sin-estrategia"
assert_contains "envia prompt" "$OUT" "w9:ok prompted reload-enviado"
assert_contains "continua tras fallo de prompt" "$OUT" "w9:fail prompted omitido:prompt-fallo"
assert_contains "difiere restart" "$OUT" "w9:restart restarting omitido:restart-pendiente"
assert_not_contains "no informa otro cwd" "$OUT" "other-cwd"
assert_not_contains "no informa otro workspace" "$OUT" "other-workspace"
assert_contains "prompt usa pane_id como target" "$CALLS" "agent prompt w9:ok /refresh"
assert_not_contains "restart no invoca herdr" "$CALLS" "agent prompt w9:restart"

echo "[C] Neutralidad estatica"
REFRESH_BODY=$(extract_fn cmd_refresh_agents "$HERDR_SCRIPT")
assert_eq "bloque nuevo no nombra runtimes" "0" "$(printf '%s' "$REFRESH_BODY" | grep -Eic 'claude|opencode')"

echo ""
echo "Resultado: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
