#!/usr/bin/env bash
# test-batch-autonomy-preflight.sh -- Gate de preflight de autonomia en
# batch-pipeline.sh (issue #1826, MEF-ADR-0055). Evaluador #1870, gh, tooling y
# pr-sync son stubs deterministas (sin red ni LLM); git y batch-pipeline.sh son reales.
#
# Cubre: CA-1 (aborta antes del primer eslabon; cerrados no entran al plan),
# CA-2 (legacy intacto; blocked/incomplete/75/salida invalida/script ausente no lanzan),
# CA-3 (ready-to-dispatch conserva los deferred y deja el plan cerrado sequential),
# CA-4 (reevaluacion antes del eslabon siguiente: no iniciado por preflight, exit != 0),
# CA-5 (batch-stop previo no consulta el evaluador).
#
# Uso: scripts/tests/test-batch-autonomy-preflight.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BATCH_SCRIPT="$REPO_ROOT/scripts/batch-pipeline.sh"
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
    case " ${GH_CLOSED:-} " in *" $3 "*) printf 'CLOSED|tipo:tooling\n' ;; *) printf 'OPEN|tipo:tooling\n' ;; esac
    exit 0
fi
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/dotnet"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/opencode"
chmod +x "$FAKE_BIN"/*

# Evaluador falso: registra el plan recibido y responde segun $PF_DIR/mode.<n-esima llamada>
# ("<exit> <json>"); sin archivo de modo responde legacy.
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

# new_case <nombre> : crea repo consumidor y deja WORK, PF_DIR, CALLS en variables.
new_case() {
    local name="$1"
    WORK="$TMP/work-$name"; PF_DIR="$TMP/pf-$name"; CALLS="$TMP/calls-$name"
    mkdir -p "$PF_DIR"; : > "$CALLS"
    git init -q --bare "$TMP/origin-$name.git"
    git -C "$TMP/origin-$name.git" symbolic-ref HEAD refs/heads/main
    git clone -q "$TMP/origin-$name.git" "$WORK" 2>/dev/null
    git -C "$WORK" config user.email t@mefisto.local; git -C "$WORK" config user.name T
    git -C "$WORK" commit -q --allow-empty -m base; git -C "$WORK" push -q origin main
    mkdir -p "$WORK/scripts" "$WORK/src"
    cp "$COMMON_LIB" "$WORK/scripts/_pipeline-common.sh"
    cp "$BATCH_SCRIPT" "$WORK/scripts/batch-pipeline.sh"
    cp -R "$REPO_ROOT/src/runtime" "$WORK/src/runtime"
    cat > "$WORK/scripts/tooling-pipeline.sh" <<TP
#!/usr/bin/env bash
echo "\$1" >> "$CALLS"
echo "PR creado: https://github.com/acme/x/pull/\$((\$1 + 1000))"
TP
    printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/scripts/pr-sync.sh"
    chmod +x "$WORK"/scripts/*.sh
    write_preflight_stub "$WORK"
}

# run_case <closed> <args...> : corre el batch; deja RC y OUT.
run_case() {
    local closed="$1"; shift
    OUT=$(cd "$WORK" && env PATH="$FAKE_BIN:$SAFE_SYSTEM_PATH" MEFISTO_RUNTIME=opencode GH_CLOSED="$closed" PF_DIR="$PF_DIR" \
        ./scripts/batch-pipeline.sh "$@" </dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
    RC=$?
}
pf_count() { cat "$PF_DIR/count" 2>/dev/null || echo 0; }

echo "[1] CA-1: bloqueo antes del primer eslabon -> ningun pipeline, estado explicito, exit != 0"
new_case one; echo "1 $BLOCKED" > "$PF_DIR/mode.1"
run_case "" 501 502
[ "$RC" -ne 0 ] && pass "exit != 0 ($RC)" || fail "se esperaba exit != 0"
[ ! -s "$CALLS" ] && pass "ningun pipeline lanzado" || fail "se lanzo un pipeline: $(cat "$CALLS")"
[ "$(pf_count)" = 1 ] && pass "un solo preflight inicial" || fail "preflights: $(pf_count)"
echo "$OUT" | grep -qF "no iniciado por preflight" && pass "estado 'no iniciado por preflight'" || fail "sin estado explicito"
echo "$OUT" | grep -qF "CONSENT_REVOKED" && pass "diagnostico con codigos" || fail "sin codigos de diagnostico"
echo "$OUT" | grep -q "aplazado" && fail "uso 'aplazado' fuera de batch-stop" || pass "no usa 'aplazado'"
grep -qF '"launchKind":"sequential"' "$PF_DIR/plans" && grep -qF '"number":501' "$PF_DIR/plans" && grep -qF '"number":502' "$PF_DIR/plans" \
    && pass "plan cerrado sequential con ambos issues" || fail "plan inesperado: $(cat "$PF_DIR/plans")"
grep -qF -- '--context' "$PF_DIR/plans" && fail "source:direct no lleva --context" || pass "source:direct sin --context"

echo "[2] CA-1: cerrado fuera del plan, legacy conserva el flujo"
new_case two
run_case "501" 501 502
[ "$RC" -eq 0 ] && pass "exit 0" || fail "exit $RC: $OUT"
grep -qx 502 "$CALLS" && ! grep -qx 501 "$CALLS" && pass "solo se lanza el abierto" || fail "calls: $(cat "$CALLS")"
grep -qF '"number":501' "$PF_DIR/plans" && fail "el cerrado entro al plan" || pass "el cerrado no entra al plan"
echo "$OUT" | grep -qF "Issue #501 esta CLOSED --- saltando." && pass "mensaje previo del cerrado" || fail "falta mensaje del cerrado"

echo "[3] CA-1: sin issues ruteables no se consulta el evaluador"
new_case three
run_case "501 502" 501 502
[ "$(pf_count)" = 0 ] && pass "evaluador no consultado" || fail "consultas: $(pf_count)"

echo "[4] CA-2: incomplete / 75 / salida invalida / rc 2 / script ausente no lanzan"
for variant in "1 {\"status\":\"incomplete\",\"diagnostics\":[\"X:Y\"],\"checks\":[]}" "75 -" "0 not-json" "0 {\"status\":\"otro\"}" "2 -"; do
    VN=$((${VN:-0}+1)); new_case "four$VN"; echo "$variant" > "$PF_DIR/mode.1"
    run_case "" 501
    [ "$RC" -ne 0 ] && [ ! -s "$CALLS" ] && pass "sin lanzamiento ante '${variant%% *}'" || fail "lanzo o exit 0 ante '$variant' (rc=$RC)"
done
new_case five; rm -f "$WORK/scripts/autonomy-preflight.sh"
run_case "" 501
[ "$RC" -ne 0 ] && [ ! -s "$CALLS" ] && echo "$OUT" | grep -qF PREFLIGHT_UNAVAILABLE && pass "evaluador ausente falla cerrado (no legacy)" || fail "evaluador ausente (rc=$RC)"

echo "[5] CA-3: ready-to-dispatch despacha y conserva los deferred con owner"
new_case six; echo "0 $READY" > "$PF_DIR/mode.1"
run_case "" 501
[ "$RC" -eq 0 ] && grep -qx 501 "$CALLS" && pass "despacha" || fail "no despacho (rc=$RC)"
echo "$OUT" | grep -qF "STAGE_ACTOR_GUARD@run-published-agent.sh/#1858" && pass "deferred con propietario" || fail "deferred perdido"
echo "$OUT" | grep -qF "no es permiso efectivo futuro" && pass "no declara permiso futuro" || fail "falta aviso"

echo "[6] CA-4: reevaluacion antes del eslabon siguiente"
new_case seven; echo "0 $READY" > "$PF_DIR/mode.1"; echo "1 $BLOCKED" > "$PF_DIR/mode.2"
run_case "" 501 502 503
[ "$RC" -ne 0 ] && pass "exit != 0" || fail "exit 0 pese al bloqueo"
[ "$(cat "$CALLS")" = "501" ] && pass "solo el primer eslabon corrio" || fail "calls: $(cat "$CALLS")"
[ "$(pf_count)" = 2 ] && pass "dos consultas (inicial + antes del 2o)" || fail "consultas: $(pf_count)"
echo "$OUT" | grep -qE '^#501 .*completado' && pass "#501 queda completado" || fail "#501 no completado"
[ "$(echo "$OUT" | grep -cE '^#50[23] .*no iniciado por preflight')" = 2 ] && pass "restantes: no iniciado por preflight" || fail "estado de restantes"
sed -n 5p "$PF_DIR/plans" | grep -qF '"number":501' && fail "plan restante incluye el eslabon ya concluido" || pass "plan restante sin el eslabon concluido"

echo "[7] CA-5: batch-stop previo conserva el aplazado y no consulta el evaluador"
new_case eight; mkdir -p "$WORK/pipeline-state"; : > "$WORK/pipeline-state/batch-stop"
echo "1 $BLOCKED" > "$PF_DIR/mode.1"
run_case "" 501 502
[ "$RC" -eq 0 ] && [ "$(pf_count)" = 0 ] && [ ! -s "$CALLS" ] && echo "$OUT" | grep -qF "aplazado" && pass "aplazado sin preflight" || fail "batch-stop (rc=$RC, consultas=$(pf_count))"

echo "[8] CA-5: --stop-on-error y fallo con continuacion consultan antes del siguiente"
new_case nine
cat > "$WORK/scripts/tooling-pipeline.sh" <<TP
#!/usr/bin/env bash
echo "\$1" >> "$CALLS"
[ "\$1" = 501 ] && exit 3
echo "PR creado: https://github.com/acme/x/pull/\$((\$1 + 1000))"
TP
echo "0 $READY" > "$PF_DIR/mode.1"; echo "1 $BLOCKED" > "$PF_DIR/mode.2"
run_case "" 501 502
[ "$(cat "$CALLS")" = "501" ] && [ "$RC" -ne 0 ] && pass "tras fallo, el bloqueo nuevo detiene el lanzamiento" || fail "calls: $(cat "$CALLS") rc=$RC"
echo "$OUT" | grep -qE '^#501 .*ERROR' && pass "el fallo previo no se reinterpreta" || fail "estado de #501"

echo ""
echo "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
