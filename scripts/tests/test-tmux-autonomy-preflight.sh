#!/usr/bin/env bash
# test-tmux-autonomy-preflight.sh -- Gate de preflight de autonomia en
# scripts/tmux-pipeline.sh (issue #1872, MEF-ADR-0055). Evaluador #1870, tmux, gh y
# pipelines son stubs deterministas (sin LLM, red ni servidor tmux real); git y
# tmux-pipeline.sh son reales. Nunca se matan procesos.
#
# Cubre: CA-1 (bloqueo => cero new-session/split/send-keys en todos los modos; en
# --parallel el bloqueo del ultimo issue no deja ningun pane; rutas con espacios),
# CA-2 (reuse/attach/help sin preflight; replace bloqueado conserva la sesion vieja),
# CA-3 (legacy sin contexto conserva el flujo; contexto/JSON invalido/busy/ausente no
# degradan a legacy), CA-4 (el plan sale del routing; contexto transportado solo como
# source:command con ruta, sin contenido en send-keys).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMUX_SCRIPT_SRC="$REPO_ROOT/scripts/tmux-pipeline.sh"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

DIST="$TMP/dist con espacios"
CONS="$TMP/consumer"
FAKE_BIN="$TMP/bin"
mkdir -p "$DIST/scripts" "$DIST/src" "$FAKE_BIN" "$CONS"
cp "$TMUX_SCRIPT_SRC" "$REPO_ROOT/scripts/_pipeline-common.sh" "$DIST/scripts/"
cp -R "$REPO_ROOT/src/runtime" "$DIST/src/runtime"
for p in tooling tdd iac scaffold batch parallel; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$DIST/scripts/$p-pipeline.sh"
done
chmod +x "$DIST"/scripts/*.sh
(cd "$CONS" && git init -q)

cat > "$DIST/scripts/autonomy-preflight.sh" <<'PF'
#!/usr/bin/env bash
n=$(( $(cat "$PF_DIR/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$PF_DIR/count"
{ echo "ARGS: $*"; cat; echo; } >> "$PF_DIR/plans"
if [ -f "$PF_DIR/mode.$n" ]; then
    read -r rc json < "$PF_DIR/mode.$n"
    [ "$json" = "-" ] || echo "$json"
    exit "$rc"
fi
echo '{"schemaVersion":1,"status":"legacy","diagnostics":[],"checks":[]}'
PF

cat > "$FAKE_BIN/tmux" <<'STUB'
#!/usr/bin/env bash
echo "tmux $*" >> "$TMUX_STUB_LOG"
case "${1:-}" in
    has-session) [ -n "${TMUX_EXISTING:-}" ] && [ "$3" = "$TMUX_EXISTING" ] && exit 0; exit 1 ;;
    list-panes)
        case "$*" in *pane_dead*) echo 0 ;; *) echo "%0" ;; esac ;;
    split-window) echo "%1" ;;
    *) exit 0 ;;
esac
STUB
cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
case " ${GH_PROJ:-} " in *" $3 "*) printf 'OPEN|tipo:projection\n' ;; *) printf 'OPEN|tipo:tooling\n' ;; esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/sleep"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/opencode"
chmod +x "$FAKE_BIN"/*

BLOCKED='{"status":"blocked","diagnostics":["PROFILE_CONSENT:CONSENT_REVOKED"],"checks":[]}'
READY='{"status":"ready-to-dispatch","diagnostics":["STAGE_ACTOR_GUARD:X"],"checks":[{"code":"STAGE_ACTOR_GUARD","state":"deferred","owner":"run-published-agent.sh/#1858","actionCode":"X"}]}'

export TMUX_STUB_LOG="$TMP/tmux.log" PF_DIR="$TMP/pf"
OUT=""; RC=0
new_case() { rm -rf "$PF_DIR"; mkdir -p "$PF_DIR"; : > "$TMUX_STUB_LOG"; }
pf_count() { cat "$PF_DIR/count" 2>/dev/null || echo 0; }
# run <env VAR=val...> -- <args...>
run() {
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    OUT=$(cd "$CONS" && env PATH="$FAKE_BIN:$PATH" MEFISTO_UI=tmux MEFISTO_RUNTIME=opencode ${envs[@]+"${envs[@]}"} \
        "$DIST/scripts/tmux-pipeline.sh" "$@" </dev/null 2>&1)
    RC=$?
    OUT=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g')
}
tmux_has() { grep -qE -- "$1" "$TMUX_STUB_LOG"; }
no_tmux_mutation() { ! tmux_has '^tmux (new-session|split-window|send-keys|kill-session)'; }

echo "[1] CA-1: bloqueo => ninguna sesion/pane/pipeline en cada modo"
for mode in "--pipeline tooling 42" "--tooling 42" "--infra 42" "--scaffold 42 --domain demo" "--batch --pipeline tooling 42 43" "--parallel 42 43"; do
    new_case; echo "1 $BLOCKED" > "$PF_DIR/mode.1"
    # shellcheck disable=SC2086
    run -- $mode
    if [ "$RC" -ne 0 ] && no_tmux_mutation && echo "$OUT" | grep -qF CONSENT_REVOKED; then
        pass "[$mode] bloqueado sin tocar tmux"
    else
        fail "[$mode] rc=$RC log=$(cat "$TMUX_STUB_LOG")"
    fi
done
[ "$(pf_count)" = 1 ] && pass "un solo preflight por corrida" || fail "preflights=$(pf_count)"

echo "[2] CA-1: plan cerrado del routing; --parallel comprueba todos antes del primer split"
new_case; echo "1 $BLOCKED" > "$PF_DIR/mode.1"
run -- --parallel 501 502 503
[ "$RC" -ne 0 ] && no_tmux_mutation && pass "--parallel bloqueado: cero panes" || fail "parallel rc=$RC"
grep -qF '"launchKind":"pane"' "$PF_DIR/plans" && grep -qF '"number":501' "$PF_DIR/plans" \
    && grep -qF '"number":502' "$PF_DIR/plans" && grep -qF '"number":503' "$PF_DIR/plans" \
    && pass "plan pane con todos los issues" || fail "plan: $(cat "$PF_DIR/plans")"
grep -qF -- '--context' "$PF_DIR/plans" && fail "direct con --context" || pass "source:direct sin --context"
new_case; run -- --batch --pipeline tooling 42 43
grep -qF '"launchKind":"sequential"' "$PF_DIR/plans" && pass "batch: plan sequential" || fail "batch plan: $(cat "$PF_DIR/plans")"

echo "[3] CA-2: reuse/attach/help sin preflight; replace bloqueado conserva la sesion"
new_case; run TMUX_EXISTING=tooling-42 -- --tooling 42 --if-exists reuse
[ "$(pf_count)" = 0 ] && no_tmux_mutation && pass "reuse: sin preflight ni mutacion" || fail "reuse consultas=$(pf_count)"
new_case; run -- --attach; [ "$(pf_count)" = 0 ] && pass "attach sin preflight" || fail "attach consulto"
new_case; run -- --help; [ "$(pf_count)" = 0 ] && [ "$RC" -eq 0 ] && pass "help sin preflight" || fail "help consulto"
new_case; echo "1 $BLOCKED" > "$PF_DIR/mode.1"
run TMUX_EXISTING=tooling-42 -- --tooling 42 --if-exists replace
[ "$RC" -ne 0 ] && no_tmux_mutation && pass "replace bloqueado: sin kill-session" || fail "replace rc=$RC log=$(cat "$TMUX_STUB_LOG")"
new_case
run TMUX_EXISTING=tooling-42 -- --tooling 42 --if-exists replace
if [ "$RC" -eq 0 ] && tmux_has '^tmux kill-session' && tmux_has '^tmux new-session'; then pass "replace con preflight ok: mata y recrea"; else fail "replace ok rc=$RC"; fi

echo "[4] CA-3: legacy conserva el flujo; fallos no degradan a legacy"
new_case; run -- --tooling 42
if [ "$RC" -eq 0 ] && tmux_has '^tmux new-session' && tmux_has "MEFISTO_RUNTIME=opencode"; then pass "legacy lanza como antes"; else fail "legacy rc=$RC"; fi
new_case; echo "0 $READY" > "$PF_DIR/mode.1"; run -- --tooling 42
[ "$RC" -eq 0 ] && echo "$OUT" | grep -qF "STAGE_ACTOR_GUARD@run-published-agent.sh/#1858" && pass "ready: deferred con owner, sin pass adelantado" || fail "ready rc=$RC"
for variant in '1 {"status":"incomplete","diagnostics":["X:Y"],"checks":[]}' "75 -" "0 not-json" '0 {"status":"otro"}' "2 -"; do
    new_case; echo "$variant" > "$PF_DIR/mode.1"; run -- --tooling 42
    [ "$RC" -ne 0 ] && no_tmux_mutation && pass "sin lanzamiento ante '${variant%% *}'" || fail "lanzo ante '$variant'"
done
NO_OWNER='{"status":"ready-to-dispatch","diagnostics":[],"checks":[{"code":"X","state":"deferred","owner":"","actionCode":"X"}]}'
new_case; echo "0 $NO_OWNER" > "$PF_DIR/mode.1"; run -- --tooling 42
[ "$RC" -ne 0 ] && no_tmux_mutation && echo "$OUT" | grep -qF PREFLIGHT_CHECKS_INCONSISTENT && pass "ready inconsistente falla cerrado" || fail "inconsistente rc=$RC"
new_case; rm "$DIST/scripts/autonomy-preflight.sh.bak" 2>/dev/null; mv "$DIST/scripts/autonomy-preflight.sh" "$TMP/pf.sh"
run -- --tooling 42
[ "$RC" -ne 0 ] && no_tmux_mutation && echo "$OUT" | grep -qF PREFLIGHT_UNAVAILABLE && pass "evaluador ausente falla cerrado" || fail "ausente rc=$RC"
mv "$TMP/pf.sh" "$DIST/scripts/autonomy-preflight.sh"

echo "[5] CA-3/CA-4: contexto transportado => source:command con ruta; legacy no lo degrada"
new_case; run MEFISTO_EXECUTION_CONTEXT="$TMP/ctx.json" MEFISTO_EXECUTION_DIGEST=abc -- --tooling 42
[ "$RC" -ne 0 ] && no_tmux_mutation && echo "$OUT" | grep -qF PREFLIGHT_LEGACY_WITH_CONTEXT && pass "legacy con contexto falla cerrado" || fail "ctx legacy rc=$RC"
grep -qF '"source":"command"' "$PF_DIR/plans" && grep -qF -- "--context $TMP/ctx.json" "$PF_DIR/plans" && pass "plan source:command con --context" || fail "plan: $(cat "$PF_DIR/plans")"

echo ""
echo "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
