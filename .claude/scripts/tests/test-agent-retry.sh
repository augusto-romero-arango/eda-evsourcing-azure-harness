#!/usr/bin/env bash
# test-agent-retry.sh -- Tests del reintento con backoff ante fallo transitorio
# del servidor (issue #534).
#
# Contexto (medido el 2026-08-05): 6 de 10 intentos de stage murieron con
# 522/529 de api.anthropic.com. El pipeline no reintentaba nunca, asi que cada
# uno tiraba el trabajo del stage entero pese a que el payload del 522 declara
# `"retryable": true, "retry_after": 120`.
#
# Casos cubiertos:
#   [pre] las funciones nuevas existen en _mefisto-common.sh
#   [A]   classify_agent_failure: paridad con la clasificacion inline anterior
#   [B]   agent_failure_is_retryable: solo API_ERROR_SERVER reintenta
#   [C]   el bucle de run_agent: reintenta 5xx, respeta el tope, no reintenta
#         los demas tipos, y restaura el worktree solo si entraba limpio
#
# Uso: .claude/scripts/tests/test-agent-retry.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# shellcheck source=/dev/null
source "$REPO_ROOT/.claude/scripts/_mefisto-common.sh" 2>/dev/null

INTERNAL_PIPELINE="$REPO_ROOT/.claude/scripts/mefisto-tooling-pipeline.sh"

# extract_fn <function_name> <file> -- mismo patron que test-abort-log-tail.sh
extract_fn() {
    local name="$1" file="$2"
    awk -v fn="$name" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p{print} p && /^}/{p=0}' "$file"
}

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# -------- Bloque pre --------

echo "[pre] Las funciones nuevas estan definidas en _mefisto-common.sh"
for fn in classify_agent_failure agent_failure_is_retryable; do
    if declare -F "$fn" >/dev/null; then
        pass "$fn definida"
    else
        fail "$fn NO definida"
    fi
done

# -------- Bloque A: classify_agent_failure --------

echo ""
echo "[A] classify_agent_failure conserva las etiquetas de la clasificacion inline"

LOG_5XX="$TMP/log-5xx.txt";  printf 'blah\nAPI Error: 529 Overloaded\n' > "$LOG_5XX"
LOG_4XX="$TMP/log-4xx.txt";  printf 'blah\nAPI Error: 400 Bad Request\n' > "$LOG_4XX"
LOG_CUT="$TMP/log-cut.txt";  printf 'blah\nConnection closed mid-response\n' > "$LOG_CUT"
LOG_PLAIN="$TMP/log-plain.txt"; printf 'todo tranquilo\n' > "$LOG_PLAIN"

STREAM_OK="$TMP/stream-ok.jsonl"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false}' > "$STREAM_OK"
STREAM_BAD="$TMP/stream-bad.jsonl"
printf '%s\n' '{"type":"assistant"}' > "$STREAM_BAD"

check_label() {
    local desc="$1" expected="$2"; shift 2
    local got
    got=$(classify_agent_failure "$@")
    if [ "$got" = "$expected" ]; then
        pass "$desc -> $expected"
    else
        fail "$desc: se esperaba '$expected', se obtuvo '$got'"
    fi
}

check_label "A-1: watchdog disparo" \
    "TIMEOUT (99s, exit 1)"                 "true"  "1"   "99" "$LOG_PLAIN" "$STREAM_BAD"
check_label "A-2: senal con result de exito" \
    "SIGNAL_POST_SUCCESS (exit 137, 12s)"   "false" "137" "12" "$LOG_PLAIN" "$STREAM_OK"
check_label "A-3: senal sin result" \
    "SIGNAL_MID_FLIGHT (exit 137, 12s)"     "false" "137" "12" "$LOG_PLAIN" "$STREAM_BAD"
check_label "A-4: 5xx del servidor" \
    "API_ERROR_SERVER (exit 1)"             "false" "1"   "12" "$LOG_5XX"   "$STREAM_BAD"
check_label "A-5: 4xx del cliente" \
    "API_ERROR_CLIENT (exit 1)"             "false" "1"   "12" "$LOG_4XX"   "$STREAM_BAD"
check_label "A-6: corte de stream" \
    "STREAM_CUT (exit 1)"                   "false" "1"   "12" "$LOG_CUT"   "$STREAM_BAD"
check_label "A-7: sin sintoma reconocible" \
    "CLI_ERROR (exit 3)"                    "false" "3"   "12" "$LOG_PLAIN" "$STREAM_BAD"
# El orden importa: un TIMEOUT del watchdog gana aunque el log traiga un 5xx.
check_label "A-8: TIMEOUT precede al 5xx" \
    "TIMEOUT (99s, exit 1)"                 "true"  "1"   "99" "$LOG_5XX"   "$STREAM_BAD"

# -------- Bloque B: agent_failure_is_retryable --------

echo ""
echo "[B] agent_failure_is_retryable: solo el 5xx transitorio se reintenta"

if agent_failure_is_retryable "API_ERROR_SERVER (exit 1)"; then
    pass "B-1: API_ERROR_SERVER es reintentable"
else
    fail "B-1: API_ERROR_SERVER deberia ser reintentable"
fi

for label in "TIMEOUT (1800s, exit 137)" "API_ERROR_CLIENT (exit 1)" \
             "STREAM_CUT (exit 1)" "CLI_ERROR (exit 3)" \
             "SIGNAL_MID_FLIGHT (exit 137, 12s)" "SIGNAL_POST_SUCCESS (exit 137, 12s)" ""; do
    if agent_failure_is_retryable "$label"; then
        fail "B-2: '$label' NO deberia ser reintentable"
    else
        pass "B-2: '${label:-<vacio>}' no se reintenta"
    fi
done

# -------- Bloque C: el bucle de run_agent --------

echo ""
echo "[C] run_agent reintenta el 5xx, respeta el tope y no toca los demas tipos"

# Entorno minimo para ejecutar run_agent extraido, sin invocar el CLI real.
setup_run_agent_env() {
    local wt="$1"

    LOG_DIR_ABS="$TMP/logs"; PIPELINE_DIR_ABS="$TMP/pipeline"
    mkdir -p "$LOG_DIR_ABS" "$PIPELINE_DIR_ABS/metrics"
    EVENTS_LOG_ABS="$TMP/events.log"; : > "$EVENTS_LOG_ABS"
    TIMESTAMP="testts"; ISSUE_NUM="999"
    WORKTREE_PATH="$wt"; SNAPSHOT_COMMIT="HEAD"
    RED=""; NC=""
    AGENT_WR_RES=""; AGENT_RV_RES=""; AGENT_WR_DUR=0; AGENT_RV_DUR=0
    AGENT_WR_METRICS_JSON=""; AGENT_RV_METRICS_JSON=""
    LAST_AGENT_DURATION=0; LAST_AGENT_METRICS_JSON=""

    # Reintentos rapidos: el bucle real espera 120s.
    export MEFISTO_AGENT_MAX_ATTEMPTS=3
    export MEFISTO_AGENT_RETRY_BACKOFF_SECONDS=0

    log()  { :; }
    warn() { :; }
    update_status() { :; }
    abort() { echo "ABORTED: $*" >> "$TMP/aborted.txt"; return 1; }
    derive_stage_log_from_stream() { :; }
    compute_stage_metrics() { echo "null"; }
    agent_work_is_trustworthy() { return 1; }
}

# Stub del invocador: falla con el sintoma indicado durante los primeros
# $STUB_FAILURES intentos y luego devuelve exito. Lleva la cuenta en disco.
make_watchdog_stub() {
    local symptom="$1"
    STUB_SYMPTOM="$symptom"
    : > "$TMP/attempts.txt"
    run_agent_with_watchdog() {
        local stdout_file="$3" log_file_unused
        echo "x" >> "$TMP/attempts.txt"
        local n
        n=$(wc -l < "$TMP/attempts.txt" | tr -d ' ')
        : > "$stdout_file"
        if [ "$n" -le "$STUB_FAILURES" ]; then
            printf '%s\n' "$STUB_SYMPTOM" > "$LOG_STAGE_PATH"
            echo "1"
        else
            printf 'todo bien\n' > "$LOG_STAGE_PATH"
            echo "0"
        fi
    }
}

attempts_made() { wc -l < "$TMP/attempts.txt" | tr -d ' '; }

# El log del stage lo escribe el stub (derive_stage_log_from_stream esta
# neutralizado), asi que necesita la misma ruta que calcula run_agent.
LOG_STAGE_PATH=""

run_case() {
    local desc="$1" symptom="$2" failures="$3" expected_attempts="$4" expect_ok="$5"

    local wt="$TMP/wt-$RANDOM"
    mkdir -p "$wt"
    git -C "$wt" init -q
    git -C "$wt" config user.email t@t.t
    git -C "$wt" config user.name t
    echo "base" > "$wt/base.txt"
    git -C "$wt" add -A && git -C "$wt" commit -qm base

    setup_run_agent_env "$wt"
    LOG_STAGE_PATH="$LOG_DIR_ABS/mefisto-tooling-stage-1-writer-${TIMESTAMP}-issue-${ISSUE_NUM}.log"
    STUB_FAILURES="$failures"
    make_watchdog_stub "$symptom"

    eval "$(extract_fn run_agent "$INTERNAL_PIPELINE")"

    local rc=0
    run_agent "1" "writer" "prompt de prueba" >/dev/null 2>&1 || rc=$?

    local got
    got=$(attempts_made)
    if [ "$got" = "$expected_attempts" ]; then
        pass "$desc: $got intento(s)"
    else
        fail "$desc: se esperaban $expected_attempts intento(s), hubo $got"
    fi

    if [ "$expect_ok" = "ok" ] && [ "$rc" -ne 0 ]; then
        fail "$desc: se esperaba que el stage saliera bien (rc=$rc)"
    fi
}

run_case "C-1: 5xx transitorio, exito al 2do intento" \
    "API Error: 529 Overloaded" 1 2 ok
run_case "C-2: 5xx persistente, se detiene en el tope de 3" \
    "API Error: 529 Overloaded" 9 3 fail
run_case "C-3: 4xx del cliente, no se reintenta" \
    "API Error: 400 Bad Request" 9 1 fail
run_case "C-4: error generico del CLI, no se reintenta" \
    "algo raro paso" 9 1 fail

# C-5: worktree restaurado entre reintentos cuando entraba limpio.
WT_C5="$TMP/wt-c5"
mkdir -p "$WT_C5"
git -C "$WT_C5" init -q
git -C "$WT_C5" config user.email t@t.t
git -C "$WT_C5" config user.name t
echo "base" > "$WT_C5/base.txt"
git -C "$WT_C5" add -A && git -C "$WT_C5" commit -qm base

setup_run_agent_env "$WT_C5"
LOG_STAGE_PATH="$LOG_DIR_ABS/mefisto-tooling-stage-1-writer-${TIMESTAMP}-issue-${ISSUE_NUM}.log"
STUB_FAILURES=1
: > "$TMP/attempts.txt"
STUB_SYMPTOM="API Error: 529 Overloaded"
run_agent_with_watchdog() {
    local stdout_file="$3"
    echo "x" >> "$TMP/attempts.txt"
    local n
    n=$(wc -l < "$TMP/attempts.txt" | tr -d ' ')
    : > "$stdout_file"
    if [ "$n" -le "$STUB_FAILURES" ]; then
        # El intento que falla deja basura en el worktree.
        echo "a medias" > "$WT_C5/basura.txt"
        echo "modificado" >> "$WT_C5/base.txt"
        printf '%s\n' "$STUB_SYMPTOM" > "$LOG_STAGE_PATH"
        echo "1"
    else
        printf 'todo bien\n' > "$LOG_STAGE_PATH"
        echo "0"
    fi
}
eval "$(extract_fn run_agent "$INTERNAL_PIPELINE")"
run_agent "1" "writer" "prompt" >/dev/null 2>&1 || true

if [ ! -f "$WT_C5/basura.txt" ] && [ "$(cat "$WT_C5/base.txt")" = "base" ]; then
    pass "C-5: el worktree limpio se restauro antes del reintento"
else
    fail "C-5: el worktree no se restauro (basura.txt o base.txt modificado sobreviven)"
fi

# C-6: worktree que YA entraba sucio no se resetea (el reset destruiria
# trabajo legitimo del writer sin commitear -- ver HAS_UNSTAGED en stage 1).
WT_C6="$TMP/wt-c6"
mkdir -p "$WT_C6"
git -C "$WT_C6" init -q
git -C "$WT_C6" config user.email t@t.t
git -C "$WT_C6" config user.name t
echo "base" > "$WT_C6/base.txt"
git -C "$WT_C6" add -A && git -C "$WT_C6" commit -qm base
echo "trabajo del writer sin commitear" > "$WT_C6/previo.txt"

setup_run_agent_env "$WT_C6"
LOG_STAGE_PATH="$LOG_DIR_ABS/mefisto-tooling-stage-1-writer-${TIMESTAMP}-issue-${ISSUE_NUM}.log"
STUB_FAILURES=1
: > "$TMP/attempts.txt"
make_watchdog_stub "API Error: 529 Overloaded"
eval "$(extract_fn run_agent "$INTERNAL_PIPELINE")"
run_agent "1" "writer" "prompt" >/dev/null 2>&1 || true

if [ -f "$WT_C6/previo.txt" ]; then
    pass "C-6: el trabajo previo sin commitear sobrevivio al reintento"
else
    fail "C-6: el reintento borro trabajo legitimo previo al stage"
fi

# C-7: cada reintento queda registrado en events.log.
if grep -q "REINTENTO writer: API_ERROR_SERVER" "$EVENTS_LOG_ABS"; then
    pass "C-7: el reintento quedo anotado en events.log"
else
    fail "C-7: events.log no registra el reintento"
fi

# -------- Resumen --------

echo ""
echo "Resultado: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
