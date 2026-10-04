#!/usr/bin/env bash
# test-parallel-autonomy-preflight.sh -- Gate de preflight de autonomia en
# parallel-pipeline.sh (issue #1871, MEF-ADR-0055). Evaluador #1870, gh y pipelines
# son stubs deterministas (sin red ni LLM); git y parallel-pipeline.sh son reales.
#
# Cubre: CA-1 (bloqueo inicial: cero hijos; cerrados fuera del plan),
# CA-2 (deriva tras el primer lanzamiento: pendiente no inicia, el vuelo termina),
# CA-3 (batch-stop previo sin preflight; projections serializadas),
# CA-4 (legacy intacto, fallos no degradan a legacy, deferred con owner).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PARALLEL_SCRIPT="$REPO_ROOT/scripts/parallel-pipeline.sh"
COMMON_LIB="$REPO_ROOT/scripts/_pipeline-common.sh"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SAFE_SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

FAKE_BIN="$TMP/bin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    case " ${GH_CLOSED:-} " in *" $3 "*) printf 'CLOSED|tipo:tooling\n'; exit 0 ;; esac
    case " ${GH_PROJ:-} " in *" $3 "*) printf 'OPEN|tipo:projection\n' ;; *) printf 'OPEN|tipo:tooling\n' ;; esac
    exit 0
fi
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/dotnet"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/opencode"
chmod +x "$FAKE_BIN"/*

write_preflight_stub() {
    cat > "$1/scripts/autonomy-preflight.sh" <<'PF'
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
    chmod +x "$1/scripts/autonomy-preflight.sh"
}

BLOCKED='{"status":"blocked","diagnostics":["PROFILE_CONSENT:CONSENT_REVOKED"],"checks":[]}'
READY='{"status":"ready-to-dispatch","diagnostics":["STAGE_ACTOR_GUARD:ACTOR_AND_PERMISSIONS_AT_STAGE"],"checks":[{"code":"STAGE_ACTOR_GUARD","state":"deferred","owner":"run-published-agent.sh/#1858","actionCode":"X"}]}'

# new_case <nombre> [sleep-segundos del pipeline falso]
new_case() {
    local name="$1" nap="${2:-0}"
    WORK="$TMP/work-$name"; PF_DIR="$TMP/pf-$name"; CALLS="$TMP/calls-$name"
    mkdir -p "$PF_DIR"; : > "$CALLS"
    git init -q --bare "$TMP/origin-$name.git"
    git -C "$TMP/origin-$name.git" symbolic-ref HEAD refs/heads/main
    git clone -q "$TMP/origin-$name.git" "$WORK" 2>/dev/null
    git -C "$WORK" config user.email t@mefisto.local; git -C "$WORK" config user.name T
    git -C "$WORK" commit -q --allow-empty -m base; git -C "$WORK" push -q origin main
    mkdir -p "$WORK/scripts" "$WORK/src"
    cp "$COMMON_LIB" "$WORK/scripts/_pipeline-common.sh"
    cp "$PARALLEL_SCRIPT" "$WORK/scripts/parallel-pipeline.sh"
    cp -R "$REPO_ROOT/src/runtime" "$WORK/src/runtime"
    cat > "$WORK/scripts/tooling-pipeline.sh" <<TP
#!/usr/bin/env bash
echo "\$1" >> "$CALLS"
sleep $nap
echo "PR creado: https://github.com/acme/x/pull/\$((\$1 + 1000))"
TP
    cp "$WORK/scripts/tooling-pipeline.sh" "$WORK/scripts/tdd-pipeline.sh"
    chmod +x "$WORK"/scripts/*.sh
    write_preflight_stub "$WORK"
}

run_case() {
    local closed="$1"; shift
    OUT=$(cd "$WORK" && env PATH="$FAKE_BIN:$SAFE_SYSTEM_PATH" MEFISTO_RUNTIME=opencode GH_CLOSED="$closed" GH_PROJ="${GH_PROJ:-}" PF_DIR="$PF_DIR" \
        ./scripts/parallel-pipeline.sh "$@" </dev/null 2>&1)
    RC=$?
    OUT=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g')
}
pf_count() { cat "$PF_DIR/count" 2>/dev/null || echo 0; }

echo "[1] CA-1: segundo issue bloqueado -> ninguno se lanza, con o sin --max-parallel"
for mp in 0 1; do
    new_case "one$mp"; echo "1 $BLOCKED" > "$PF_DIR/mode.1"
    run_case "" 501 502 --max-parallel "$mp" --keep-status
    [ "$RC" -ne 0 ] && pass "exit != 0 (mp=$mp)" || fail "exit 0 (mp=$mp)"
    [ ! -s "$CALLS" ] && pass "cero hijos (mp=$mp)" || fail "se lanzo: $(cat "$CALLS")"
    [ "$(pf_count)" = 1 ] && pass "un solo preflight (mp=$mp)" || fail "preflights: $(pf_count)"
    echo "$OUT" | grep -qF "no iniciado por preflight" && echo "$OUT" | grep -qF CONSENT_REVOKED \
        && pass "causa en salida (mp=$mp)" || fail "sin causa (mp=$mp)"
    echo "$OUT" | grep -q "aplazado (parada" && fail "uso aplazado (mp=$mp)" || pass "no usa aplazado (mp=$mp)"
done
grep -qF '"launchKind":"parallel"' "$PF_DIR/plans" && grep -qF '"number":501' "$PF_DIR/plans" && grep -qF '"number":502' "$PF_DIR/plans" \
    && pass "plan cerrado parallel" || fail "plan: $(cat "$PF_DIR/plans")"
grep -qF -- '--context' "$PF_DIR/plans" && fail "source:direct con --context" || pass "source:direct sin --context"

echo "[2] CA-1: cerrado fuera del plan; sin validos conserva el error actual"
new_case two
run_case "501" 501 502
[ "$RC" -eq 0 ] && grep -qx 502 "$CALLS" && ! grep -qx 501 "$CALLS" && pass "solo el abierto" || fail "rc=$RC calls=$(cat "$CALLS")"
grep -qF '"number":501' "$PF_DIR/plans" && fail "cerrado en el plan" || pass "cerrado fuera del plan"
new_case three
run_case "501 502" 501 502
[ "$RC" -ne 0 ] && [ "$(pf_count)" = 0 ] && echo "$OUT" | grep -qF "No hay issues validos" && pass "error vigente sin preflight" || fail "rc=$RC consultas=$(pf_count)"

echo "[3] CA-2: deriva tras el primer lanzamiento: pendiente no inicia, el vuelo termina"
new_case four 2; echo "0 $READY" > "$PF_DIR/mode.1"; echo "1 $BLOCKED" > "$PF_DIR/mode.2"
run_case "" 501 502 --max-parallel 1
[ "$RC" -ne 0 ] && pass "exit != 0" || fail "exit 0 pese al bloqueo"
[ "$(cat "$CALLS")" = "501" ] && pass "solo el primero corrio" || fail "calls: $(cat "$CALLS")"
echo "$OUT" | grep -qE '^#501 .*completado' && pass "#501 recolectado" || fail "#501 no completado"
echo "$OUT" | grep -qE '^#502 .*no iniciado por preflight' && pass "#502 no iniciado por preflight" || fail "estado de #502"
echo "$OUT" | grep -q "aplazado (parada" && fail "uso aplazado" || pass "no usa aplazado"
echo "$OUT" | grep -qF "STAGE_ACTOR_GUARD@run-published-agent.sh/#1858" && pass "deferred con owner" || fail "deferred perdido"
[ "$(pf_count)" = 2 ] && pass "dos consultas (inicial + antes de lanzar el pendiente)" || fail "consultas: $(pf_count)"

echo "[4] CA-3: batch-stop previo no consulta el evaluador"
new_case five; mkdir -p "$WORK/pipeline-state"; : > "$WORK/pipeline-state/batch-stop"
echo "1 $BLOCKED" > "$PF_DIR/mode.1"
run_case "" 501 502
[ "$RC" -eq 0 ] && [ "$(pf_count)" = 0 ] && [ ! -s "$CALLS" ] && echo "$OUT" | grep -qF "aplazados" && pass "aplazado sin preflight" || fail "rc=$RC consultas=$(pf_count)"

echo "[5] CA-3: dos projections se serializan y se revalida antes del segundo launch"
new_case six 1
GH_PROJ="501 502" run_case "" 501 502
[ "$RC" -eq 0 ] && [ "$(tr '\n' ' ' < "$CALLS")" = "501 502 " ] && pass "ambas corren en orden" || fail "rc=$RC calls=$(cat "$CALLS")"
[ "$(pf_count)" -ge 2 ] && pass "revalidacion antes del 2o launch ($(pf_count) consultas)" || fail "consultas: $(pf_count)"

echo "[6] CA-4: legacy conserva el flujo; fallos del evaluador no degradan a legacy"
new_case seven
run_case "" 501 502
[ "$RC" -eq 0 ] && [ "$(sort "$CALLS" | tr '\n' ' ')" = "501 502 " ] && pass "legacy lanza ambos" || fail "rc=$RC calls=$(cat "$CALLS")"
for variant in '1 {"status":"incomplete","diagnostics":["X:Y"],"checks":[]}' "75 -" "0 not-json" '0 {"status":"otro"}' "2 -"; do
    VN=$((${VN:-0}+1)); new_case "eight$VN"; echo "$variant" > "$PF_DIR/mode.1"
    run_case "" 501
    [ "$RC" -ne 0 ] && [ ! -s "$CALLS" ] && pass "sin lanzamiento ante '${variant%% *}'" || fail "lanzo o exit 0 ante '$variant'"
done
new_case nine; rm -f "$WORK/scripts/autonomy-preflight.sh"
run_case "" 501
[ "$RC" -ne 0 ] && [ ! -s "$CALLS" ] && echo "$OUT" | grep -qF PREFLIGHT_UNAVAILABLE && pass "evaluador ausente falla cerrado" || fail "ausente rc=$RC"
NO_OWNER='{"status":"ready-to-dispatch","diagnostics":[],"checks":[{"code":"STAGE_ACTOR_GUARD","state":"deferred","owner":"","actionCode":"X"}]}'
new_case ten; echo "0 $NO_OWNER" > "$PF_DIR/mode.1"
run_case "" 501
[ "$RC" -ne 0 ] && [ ! -s "$CALLS" ] && echo "$OUT" | grep -qF PREFLIGHT_CHECKS_INCONSISTENT && pass "ready inconsistente falla cerrado" || fail "inconsistente rc=$RC"

echo ""
echo "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
