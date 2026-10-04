#!/usr/bin/env bash
# test-orchestrator-execution-propagation.sh -- Propagacion de contextos de ejecucion
# por los orquestadores publicados (issue #1861, MEF-ADR-0055): batch/parallel mantienen
# una referencia viva para toda la cadena/cola y reservan un contexto hijo antes de cada
# spawn; tmux/Herdr lo transportan por proceso/pane, sin entorno global.
#
# Hermetico: dobles de tmux/herdr/gh/dotnet, del CLI de contexto (EC_EXECUTION_CONTEXT_CMD)
# y de los pipelines hijos. Sin runtimes ni red reales.
#
# Uso: scripts/tests/test-orchestrator-execution-propagation.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 -- esperado '$2', fue '$3'"; fi; }
assert_contains() { if printf '%s' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1 -- no se encontro: '$3'"; fi; }
assert_not_contains() { if printf '%s' "$2" | grep -qF -- "$3"; then fail "$1 -- se encontro indebidamente: '$3'"; else pass "$1"; fi; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
SAFE_SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export EC_LOG="$TMP/ec.log"

# Doble del CLI de contexto: registra "op<TAB>request" y responde JSON determinista.
cat > "$TMP/ec-stub.sh" <<'STUB'
#!/usr/bin/env bash
op="$1"; req="$(cat)"
printf '%s\t%s\n' "$op" "$req" >> "$EC_LOG"
A="$(printf 'a%.0s' $(seq 64))"; B="$(printf 'b%.0s' $(seq 64))"
proj="$(printf '%s' "$req" | jq -r .projectRoot)"
run="$(printf '%s' "$req" | jq -r .runId)"
case "$op" in
    prepare) printf '{"schemaVersion":1,"status":"ready","digest":"%s"}\n' "$A" ;;
    attach)  printf '{"status":"ready","path":"%s/.mefisto/pipeline/autonomy/runs/%s/contexts/p.json","digest":"%s","state":"attached"}\n' "$proj" "$run" "$A" ;;
    reserve-child)
        [ "${EC_FAIL_RESERVE:-0}" = 1 ] && exit 1
        child="$(printf '%s' "$req" | jq -r .childContextId)"
        printf '{"status":"ready","path":"%s/.mefisto/pipeline/autonomy/runs/%s/contexts/%s.json","digest":"%s","state":"prepared"}\n' "$proj" "$run" "$child" "$B" ;;
    finish) [ "${EC_FAIL_FINISH:-0}" = 1 ] && exit 1; printf '{"status":"finished","liveChildren":1}\n' ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$TMP/ec-stub.sh"
export EC_EXECUTION_CONTEXT_CMD="$TMP/ec-stub.sh"

for b in dotnet; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$b"; chmod +x "$BIN/$b"; done
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/opencode"; chmod +x "$BIN/opencode"
cp "$BIN/opencode" "$BIN/claude"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = issue ] && [ "$2" = view ] && printf 'OPEN|tipo:tooling\n'
exit 0
STUB
chmod +x "$BIN/gh"
cat > "$BIN/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN/sleep"

ec_ops() { cut -f1 "$EC_LOG" | tr '\n' ' ' | sed 's/ $//'; }

# setup_consumer <dir>: consumidor con perfil, la clausura minima y pipelines hijos dobles.
setup_consumer() {
    local d="$1" p
    mkdir -p "$d/scripts" "$d/src/published" "$d/.mefisto"
    cp "$REPO_ROOT"/scripts/{_pipeline-common.sh,_execution-context.sh,batch-pipeline.sh,parallel-pipeline.sh} "$d/scripts/"
    cp -R "$REPO_ROOT/src/runtime" "$d/src/runtime"
    cp -R "$REPO_ROOT/src/published/contract" "$d/src/published/contract"
    echo '{}' > "$d/.mefisto/harness.config.json"
    cat > "$d/scripts/tooling-pipeline.sh" <<'STUB'
#!/usr/bin/env bash
n_finish="$(grep -c '^finish' "$EC_LOG" 2>/dev/null || true)"
printf '%s ctx=%s digest=%s finish_antes=%s\n' "$1" "${MEFISTO_EXECUTION_CONTEXT:-}" "${MEFISTO_EXECUTION_DIGEST:-}" "$n_finish" >> "$CHILD_LOG"
echo "PR creado: https://github.com/acme/x/pull/$(( $1 + 1000 ))"
exit "${CHILD_RC:-0}"
STUB
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/scripts/pr-sync.sh"
    chmod +x "$d/scripts/"*.sh
    git init -q "$d"; git -C "$d" config user.email t@m.local; git -C "$d" config user.name T
    git -C "$d" add -A; git -C "$d" commit -q -m base
}

run_orch() { # <dir> <runtime> <script> args...
    local d="$1" rt="$2" s="$3"; shift 3
    : > "$EC_LOG"; : > "$CHILD_LOG"
    ( cd "$d" && env -u MEFISTO_EXECUTION_CONTEXT -u MEFISTO_EXECUTION_DIGEST PATH="$BIN:$SAFE_SYSTEM_PATH" \
        MEFISTO_STATE_DIR="$d/.mefisto/pipeline" MEFISTO_LEGACY_STATE_DIR="$d/.claude/pipeline" \
        MEFISTO_RUNTIME="$rt" "./scripts/$s" "$@" ) </dev/null >"$TMP/out" 2>"$TMP/err"
}

export CHILD_LOG="$TMP/child.log"
CONS="$TMP/con espacio"
setup_consumer "$CONS"

echo "[A] batch: referencia de cadena viva entre eslabones; el padre cierra al final"
run_orch "$CONS" opencode batch-pipeline.sh 501 502; RC=$?
assert_eq "A: exit 0" 0 "$RC"
assert_eq "A: orden de operaciones" "prepare attach reserve-child finish reserve-child finish finish" "$(ec_ops)"
assert_contains "A: eslabon 1 recibe el contexto hijo" "$(sed -n 1p "$CHILD_LOG")" "/contexts/ctx-c-"
assert_contains "A: eslabon 1 recibe el digest hijo" "$(sed -n 1p "$CHILD_LOG")" "digest=$(printf 'b%.0s' $(seq 64))"
assert_contains "A: eslabon 1 corre antes de cualquier finish" "$(sed -n 1p "$CHILD_LOG")" "finish_antes=0"
assert_contains "A: eslabon 2 corre con solo el hijo 1 cerrado (padre vivo)" "$(sed -n 2p "$CHILD_LOG")" "finish_antes=1"
LAST_FINISH="$(grep '^finish' "$EC_LOG" | tail -1 | cut -f2)"
assert_contains "A: el ultimo finish es del padre (outcome succeeded)" "$LAST_FINISH" '"outcome":"succeeded"'
assert_not_contains "A: el ultimo finish no es de un hijo" "$LAST_FINISH" 'ctx-c-'

echo "[B] batch: eslabon que falla cierra su hijo como failed y el padre sigue vivo"
CHILD_RC=3 run_orch "$CONS" opencode batch-pipeline.sh 501; RC=$?
assert_eq "B: exit != 0" 1 "$RC"
assert_contains "B: finish del hijo con failed" "$(grep '^finish' "$EC_LOG" | head -1)" '"outcome":"failed"'

echo "[C] batch: reserva fallida => el eslabon no se lanza ni se reporta ejecutado"
EC_FAIL_RESERVE=1 run_orch "$CONS" opencode batch-pipeline.sh 501; RC=$?
assert_eq "C: exit 1" 1 "$RC"
assert_eq "C: el pipeline hijo no corrio" 0 "$(wc -l < "$CHILD_LOG" | tr -d ' ')"
assert_contains "C: se reporta como no lanzado" "$(cat "$TMP/out")" "el pipeline no se lanzo"

echo "[D] batch: control sin perfil y runtime Claude conserva la ruta previa"
run_orch "$CONS" claude batch-pipeline.sh 501; RC=$?
assert_eq "D: sin llamadas al servicio de contexto" 0 "$(wc -l < "$EC_LOG" | tr -d ' ')"
assert_contains "D: el hijo no recibe contexto" "$(cat "$CHILD_LOG")" "ctx= digest="
CONS_NP="$TMP/sin-perfil"; setup_consumer "$CONS_NP"; rm -f "$CONS_NP/.mefisto/harness.config.json"
run_orch "$CONS_NP" opencode batch-pipeline.sh 501; RC=$?
assert_eq "D: sin perfil no hay servicio ni archivos nuevos" 0 "$(wc -l < "$EC_LOG" | tr -d ' ')"

echo "[E] parallel: hijos reservados antes del spawn y cerrados al observar su exit; padre al final"
run_orch "$CONS" opencode parallel-pipeline.sh 501 502; RC=$?
assert_eq "E: exit 0" 0 "$RC"
assert_eq "E: dos reservas, tres cierres, padre ultimo" "prepare attach reserve-child reserve-child finish finish finish" "$(ec_ops)"
assert_eq "E: cada hijo recibio contexto" 2 "$(grep -c '/contexts/ctx-c-' "$CHILD_LOG")"
assert_not_contains "E: el ultimo finish es del padre" "$(grep '^finish' "$EC_LOG" | tail -1)" 'ctx-c-'

echo "[F] parallel: reserva fallida => no se lanza y se reporta ERROR"
EC_FAIL_RESERVE=1 run_orch "$CONS" opencode parallel-pipeline.sh 501; RC=$?
assert_eq "F: exit 1" 1 "$RC"
assert_eq "F: el hijo no corrio" 0 "$(wc -l < "$CHILD_LOG" | tr -d ' ')"
assert_contains "F: ERROR en el resumen" "$(cat "$TMP/out")" "no se pudo reservar"

echo "[G] tmux: contexto/digest por comando, ruta con espacios, sin set-environment global"
cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
echo "tmux $*" >> "$TMUX_LOG"
case "${1:-}" in
    has-session) exit 1 ;;
    list-panes) echo "%0" ;;
    split-window) echo "%1" ;;
    send-keys) [ "${TMUX_FAIL_SEND:-0}" = 1 ] && [ "${3:-}" = "%1" ] && exit 1; exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/tmux"
export TMUX_LOG="$TMP/tmux.log"
CONS_T="$TMP/consumidor tmux"; mkdir -p "$CONS_T/.mefisto"; echo '{}' > "$CONS_T/.mefisto/harness.config.json"
git init -q "$CONS_T"; git -C "$CONS_T" config user.email t@m.local; git -C "$CONS_T" config user.name T
git -C "$CONS_T" commit -q --allow-empty -m base
run_tmux() { # <runtime> args...
    local rt="$1"; shift; : > "$EC_LOG"; : > "$TMUX_LOG"
    ( cd "$CONS_T" && env -u MEFISTO_UI -u HERDR_ENV -u MEFISTO_EXECUTION_CONTEXT -u MEFISTO_EXECUTION_DIGEST \
        PATH="$BIN:$SAFE_SYSTEM_PATH" MEFISTO_RUNTIME="$rt" "$REPO_ROOT/scripts/tmux-pipeline.sh" "$@" ) </dev/null >"$TMP/out" 2>"$TMP/err"
}
run_tmux opencode --tooling 42; RC=$?
KEYS="$(grep 'send-keys -t %1' "$TMUX_LOG")"
assert_eq "G: exit 0" 0 "$RC"
assert_eq "G: prepare, attach, reserve-child, finish del wrapper" "prepare attach reserve-child finish" "$(ec_ops)"
assert_contains "G: contexto por comando" "$KEYS" "MEFISTO_EXECUTION_CONTEXT="
assert_contains "G: digest por comando" "$KEYS" "MEFISTO_EXECUTION_DIGEST=$(printf 'b%.0s' $(seq 64))"
assert_contains "G: ruta con espacios preservada" "$KEYS" 'consumidor\ tmux'
assert_not_contains "G: sin set-environment global" "$(cat "$TMUX_LOG")" "set-environment"
assert_not_contains "G: la reserva no se cierra (handoff sin confirmar)" "$(grep '^finish' "$EC_LOG")" "ctx-c-"
TMUX_FAIL_SEND=1 run_tmux opencode --tooling 42; RC=$?
assert_eq "G: send-keys fallido aborta" 1 "$RC"
assert_contains "G: solo entonces se retira la reserva (aborted)" "$(grep '^finish' "$EC_LOG" | head -1)" '"outcome":"aborted"'
run_tmux claude --tooling 42; RC=$?
assert_eq "G: Claude sin servicio de contexto" 0 "$(wc -l < "$EC_LOG" | tr -d ' ')"
assert_not_contains "G: Claude no transporta contexto" "$(grep 'send-keys -t %1' "$TMUX_LOG")" "MEFISTO_EXECUTION_CONTEXT="
run_tmux opencode --batch 42 43; RC=$?
assert_contains "G: batch por tmux reserva con la raiz sequential" "$(grep '^prepare' "$EC_LOG")" '"rootCommand":"sequential"'

echo "[H] herdr: contexto/digest y raices fijadas por pane; reserva retirada solo si no se entrego"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
echo "herdr $*" >> "$HERDR_LOG"
case "${1:-} ${2:-}" in
    "pane split") n=$(cat "$HERDR_COUNTER" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$HERDR_COUNTER"; echo "{\"result\":{\"pane\":{\"pane_id\":\"w1:p$n\"}}}" ;;
    "pane process-info") echo '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":100}}}' ;;
    "pane run")
        [ "${HERDR_FAIL_RUN:-0}" = 1 ] && exit 1
        if [ "${HERDR_NEVER_CONFIRM:-0}" != 1 ]; then
            m=$(printf '%s\n' "${4:-}" | grep -oE -- '--started-marker [^[:space:]]+' | awk '{print $2}')
            [ -n "$m" ] && { mkdir -p "$(dirname "$m")"; : > "$m"; }
        fi ;;
    *) echo '{"result":{"type":"ok"}}' ;;
esac
STUB
chmod +x "$BIN/herdr"
export HERDR_LOG="$TMP/herdr.log" HERDR_COUNTER="$TMP/herdr.count"; echo 0 > "$HERDR_COUNTER"
CONS_H="$TMP/consumidor herdr"; mkdir -p "$CONS_H/.mefisto"; echo '{}' > "$CONS_H/.mefisto/harness.config.json"
git init -q "$CONS_H"; git -C "$CONS_H" config user.email t@m.local; git -C "$CONS_H" config user.name T
git -C "$CONS_H" commit -q --allow-empty -m base
run_herdr() { # <runtime> args...
    local rt="$1"; shift; : > "$EC_LOG"; : > "$HERDR_LOG"; rm -rf "$CONS_H/.mefisto/pipeline"
    ( cd "$CONS_H" && env -u MEFISTO_UI -u MEFISTO_EXECUTION_CONTEXT -u MEFISTO_EXECUTION_DIGEST \
        MEFISTO_RUNTIME_LIB_DIR="$TMP/otra/lib" PATH="$BIN:$SAFE_SYSTEM_PATH" MEFISTO_RUNTIME="$rt" \
        HERDR_ENV=1 HERDR_PANE_ID=w1:p0 HERDR_WORKSPACE_ID=w1 HERDR_DISPATCH_CONFIRM_TIMEOUT=1 \
        "$REPO_ROOT/scripts/herdr-pipeline.sh" "$@" ) </dev/null >"$TMP/out" 2>"$TMP/err"
}
mkdir -p "$TMP/otra"; cp -R "$REPO_ROOT/src/runtime/lib" "$TMP/otra/lib"
run_herdr opencode --tooling 42; RC=$?
RUNL="$(grep '^herdr pane run' "$HERDR_LOG")"
assert_eq "H: exit 0" 0 "$RC"
assert_contains "H: contexto por pane" "$RUNL" "MEFISTO_EXECUTION_CONTEXT="
assert_contains "H: ruta con espacios preservada" "$RUNL" 'consumidor\ herdr'
assert_contains "H: biblioteca fijada a la distribucion lanzadora" "$RUNL" "MEFISTO_RUNTIME_LIB_DIR=$REPO_ROOT/src/runtime/lib"
assert_not_contains "H: no hereda la biblioteca de otra distribucion" "$RUNL" "$TMP/otra"
assert_contains "H: estado del consumidor fijado" "$RUNL" 'MEFISTO_STATE_DIR='
assert_not_contains "H: marker started no cierra la reserva" "$(grep '^finish' "$EC_LOG")" "ctx-c-"
HERDR_FAIL_RUN=1 run_herdr opencode --tooling 42; RC=$?
assert_eq "H: pane run fallido aborta" 1 "$RC"
assert_contains "H: reserva no entregada retirada" "$(grep '^finish' "$EC_LOG" | head -1)" '"outcome":"aborted"'
HERDR_NEVER_CONFIRM=1 run_herdr opencode --tooling 42; RC=$?
assert_eq "H: sin confirmar tras reintento aborta" 1 "$RC"
assert_eq "H: dos reservas (original + reintento), ambas retiradas" 2 "$(grep -c '"outcome":"aborted"' "$EC_LOG")"
run_herdr claude --tooling 42; RC=$?
assert_eq "H: Claude sin servicio de contexto" 0 "$(wc -l < "$EC_LOG" | tr -d ' ')"
assert_not_contains "H: Claude no transporta contexto" "$(grep '^herdr pane run' "$HERDR_LOG")" "MEFISTO_EXECUTION_CONTEXT="

echo ""
echo "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
