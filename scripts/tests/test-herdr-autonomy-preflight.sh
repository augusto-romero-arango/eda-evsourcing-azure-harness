#!/usr/bin/env bash
# test-herdr-autonomy-preflight.sh -- Gate de preflight de autonomia en
# scripts/herdr-pipeline.sh (issue #1873, MEF-ADR-0055). Evaluador #1870, herdr, gh y
# pipelines son stubs deterministas (sin LLM, red ni servidor herdr real). Nunca se
# matan procesos.
#
# Cubre: CA-1 (bloqueo => cero pane run/split/close en todos los modos; el bloqueo del
# ultimo issue de --parallel no deja ningun pane; rutas con espacios), CA-2 (refresh,
# collapse y help sin preflight; legacy conserva el flujo), CA-3 (fallos no degradan a
# legacy; el reintento tras marker ausente no reevalua), CA-4 (plan del routing; contexto
# transportado solo como source:command con ruta).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

DIST="$TMP/dist con espacios"
CONS="$TMP/consumer"
FAKE_BIN="$TMP/bin"
mkdir -p "$DIST/scripts" "$DIST/src" "$FAKE_BIN" "$CONS"
cp "$REPO_ROOT/scripts/herdr-pipeline.sh" "$REPO_ROOT/scripts/_pipeline-common.sh" "$DIST/scripts/"
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

cat > "$FAKE_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
echo "herdr $*" >> "$HERDR_STUB_LOG"
case "${1:-} ${2:-}" in
    "pane split")
        n=$(cat "$HERDR_STUB_COUNTER" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$HERDR_STUB_COUNTER"
        echo "{\"result\":{\"pane\":{\"pane_id\":\"w1:p$n\"}}}" ;;
    "pane get") echo '{"result":{"pane":{"pane_id":"stub"}}}' ;;
    "pane process-info") echo '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":100}}}' ;;
    "pane run")
        marker=$(printf '%s\n' "${4:-}" | grep -oE -- '--started-marker [^[:space:]]+' | awk '{print $2}')
        if [ -n "$marker" ] && [ -z "${HERDR_NO_MARKER:-}" ]; then mkdir -p "$(dirname "$marker")"; : > "$marker"; fi
        echo '{"result":{"type":"ok"}}' ;;
    *) echo '{"result":{"type":"ok"}}' ;;
esac
STUB
cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "${3:-}" in
    42|43|44|501|502|503) printf 'OPEN|tipo:tooling\n' ;;
    60) printf 'CLOSED|tipo:tooling\n' ;;
    *) exit 1 ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/sleep"
chmod +x "$FAKE_BIN"/*

BLOCKED='{"status":"blocked","diagnostics":["PROFILE_CONSENT:CONSENT_REVOKED"],"checks":[]}'
READY='{"status":"ready-to-dispatch","diagnostics":[],"checks":[{"code":"STAGE_ACTOR_GUARD","state":"deferred","owner":"run-published-agent.sh/#1858","actionCode":"X"}]}'

export HERDR_STUB_LOG="$TMP/herdr.log" HERDR_STUB_COUNTER="$TMP/counter" PF_DIR="$TMP/pf"
OUT=""; RC=0
new_case() { rm -rf "$PF_DIR" "$CONS/.mefisto"; mkdir -p "$PF_DIR"; : > "$HERDR_STUB_LOG"; echo 0 > "$HERDR_STUB_COUNTER"; }
pf_count() { cat "$PF_DIR/count" 2>/dev/null || echo 0; }
run() {
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    OUT=$(cd "$CONS" && env -u MEFISTO_UI -u MEFISTO_EXECUTION_CONTEXT -u MEFISTO_EXECUTION_DIGEST \
        PATH="$FAKE_BIN:$PATH" MEFISTO_RUNTIME=opencode HERDR_ENV=1 HERDR_PANE_ID=w1:p0 HERDR_WORKSPACE_ID=w1 \
        HERDR_DISPATCH_CONFIRM_TIMEOUT=1 ${envs[@]+"${envs[@]}"} \
        "$DIST/scripts/herdr-pipeline.sh" "$@" </dev/null 2>&1)
    RC=$?
    OUT=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g')
}
h_has() { grep -qE -- "$1" "$HERDR_STUB_LOG"; }
no_herdr_mutation() { ! h_has '^herdr pane (run|split|close)'; }

echo "[1] CA-1: bloqueo => ningun pane/pipeline en cada modo"
for mode in "--pipeline tooling 42" "--tooling 42" "--infra 42" "--scaffold 42 --domain demo" "--batch --pipeline tooling 42 43" "--parallel 42 43"; do
    new_case; echo "1 $BLOCKED" > "$PF_DIR/mode.1"
    # shellcheck disable=SC2086
    run -- $mode
    if [ "$RC" -ne 0 ] && no_herdr_mutation && echo "$OUT" | grep -qF CONSENT_REVOKED && [ ! -d "$CONS/.mefisto/pipeline/dispatch" ] \
        && [ "$(pf_count)" = 1 ]; then
        pass "[$mode] bloqueado sin tocar herdr (un solo preflight)"
    else
        fail "[$mode] rc=$RC preflights=$(pf_count) log=$(cat "$HERDR_STUB_LOG")"
    fi
done

echo "[2] CA-1: plan cerrado del routing; --parallel comprueba todos antes del primer split"
new_case; echo "1 $BLOCKED" > "$PF_DIR/mode.1"
run -- --parallel 501 502 503
[ "$RC" -ne 0 ] && no_herdr_mutation && pass "--parallel bloqueado: cero panes" || fail "parallel rc=$RC"
grep -qF '"launchKind":"pane"' "$PF_DIR/plans" && grep -qF '"number":501' "$PF_DIR/plans" \
    && grep -qF '"number":502' "$PF_DIR/plans" && grep -qF '"number":503' "$PF_DIR/plans" \
    && pass "plan pane con todos los issues" || fail "plan: $(cat "$PF_DIR/plans")"
grep -qF -- '--context' "$PF_DIR/plans" && fail "direct con --context" || pass "source:direct sin --context"
new_case; run -- --batch --pipeline tooling 42 43
grep -qF '"launchKind":"sequential"' "$PF_DIR/plans" && pass "batch: plan sequential" || fail "batch plan: $(cat "$PF_DIR/plans")"
new_case; echo "1 $BLOCKED" > "$PF_DIR/mode.1"; run -- --parallel 42 60
grep -qF '"number":60' "$PF_DIR/plans" && fail "issue cerrado en el plan" || pass "closed conserva su semantica (fuera del plan)"

echo "[3] CA-2: refresh/collapse/help sin preflight"
for m in --refresh-agents --collapse-panes --help; do
    new_case; run -- "$m"
    [ "$(pf_count)" = 0 ] && pass "$m sin preflight" || fail "$m consulto"
done

echo "[4] CA-2/CA-3: legacy conserva el flujo; fallos no degradan a legacy"
new_case; run -- --tooling 42
if [ "$RC" -eq 0 ] && h_has '^herdr pane (run|split)' && h_has "MEFISTO_RUNTIME=opencode"; then pass "legacy lanza como antes"; else fail "legacy rc=$RC out=$OUT"; fi
new_case; echo "0 $READY" > "$PF_DIR/mode.1"; run -- --tooling 42
[ "$(pf_count)" = 1 ] && echo "$OUT" | grep -qF "STAGE_ACTOR_GUARD@run-published-agent.sh/#1858" && pass "ready: deferred con owner" || fail "ready rc=$RC out=$OUT"
for variant in '1 {"status":"incomplete","diagnostics":["X:Y"],"checks":[]}' "75 -" "0 not-json" '0 {"status":"otro"}' "2 -"; do
    new_case; echo "$variant" > "$PF_DIR/mode.1"; run -- --tooling 42
    [ "$RC" -ne 0 ] && no_herdr_mutation && pass "sin lanzamiento ante '${variant%% *}'" || fail "lanzo ante '$variant'"
done
new_case; mv "$DIST/scripts/autonomy-preflight.sh" "$TMP/pf.sh"; run -- --tooling 42
[ "$RC" -ne 0 ] && no_herdr_mutation && echo "$OUT" | grep -qF PREFLIGHT_UNAVAILABLE && pass "evaluador ausente falla cerrado" || fail "ausente rc=$RC"
mv "$TMP/pf.sh" "$DIST/scripts/autonomy-preflight.sh"

echo "[5] CA-3: reintento tras marker ausente conserva la decision (no reevalua)"
new_case; run HERDR_NO_MARKER=1 -- --tooling 42
[ "$(pf_count)" = 1 ] && pass "un solo preflight pese al reintento" || fail "preflights=$(pf_count) rc=$RC"
[ "$(grep -c '^herdr pane run' "$HERDR_STUB_LOG")" = 2 ] && pass "reintento en pane nuevo" || fail "runs=$(grep -c '^herdr pane run' "$HERDR_STUB_LOG")"

echo "[6] CA-4: contexto transportado => source:command con ruta; legacy no lo degrada"
new_case; run MEFISTO_EXECUTION_CONTEXT="$TMP/ctx.json" MEFISTO_EXECUTION_DIGEST=abc -- --tooling 42
[ "$RC" -ne 0 ] && no_herdr_mutation && echo "$OUT" | grep -qF PREFLIGHT_LEGACY_WITH_CONTEXT && pass "legacy con contexto falla cerrado" || fail "ctx legacy rc=$RC out=$OUT"
grep -qF '"source":"command"' "$PF_DIR/plans" && grep -qF -- "--context $TMP/ctx.json" "$PF_DIR/plans" && pass "plan source:command con --context" || fail "plan: $(cat "$PF_DIR/plans")"

echo ""
echo "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
