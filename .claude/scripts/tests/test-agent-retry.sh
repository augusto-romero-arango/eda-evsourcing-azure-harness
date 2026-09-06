#!/usr/bin/env bash
# test-agent-retry.sh -- Tests del reintento con backoff ante fallo transitorio
# del servidor (issue #534, actualizada sobre el JSONL neutral en el issue
# #906).
#
# Contexto (medido el 2026-08-05): 6 de 10 intentos de stage murieron con
# 522/529 de api.anthropic.com. El pipeline no reintentaba nunca, asi que cada
# uno tiraba el trabajo del stage entero pese a que el payload del 522 declara
# `"retryable": true, "retry_after": 120`.
#
# Desde el issue #906, classify_agent_failure lee `error.kind`/`error.detail`
# del `<log_base>.events.jsonl` que run_agent escribe traduciendo cada intento
# con runtime_claude_translate (#859) -- no un log de texto ni la traza cruda
# de Claude. El bloque [A] usa fixtures de JSONL neutral escritas a mano
# (conforme a run-events.schema.json); el bloque [C] ejercita run_agent
# extraido de verdad, con un stub de run_agent_with_watchdog que escribe
# trazas REALES de Claude Code (`fixtures/runtime-claude/*.jsonl`) para que el
# traductor real produzca el JSONL neutral que consume la clasificacion --
# mismo espiritu que el bloque [O] de test-stream-watch.sh.
#
# Casos cubiertos:
#   [pre] las funciones nuevas existen en _mefisto-common.sh
#   [A]   classify_agent_failure: paridad con la clasificacion anterior, ahora
#         leyendo el JSONL neutral en vez de grepear un log de texto
#   [B]   agent_failure_is_retryable: solo API_ERROR_SERVER reintenta (sin
#         cambios -- no lee el JSONL neutral)
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
# shellcheck source=/dev/null
source "$REPO_ROOT/src/internal/scripts/lib/runtime-claude.sh" 2>/dev/null

INTERNAL_PIPELINE="$REPO_ROOT/src/internal/scripts/mefisto-tooling-pipeline.sh"
FIXDIR="$SCRIPT_DIR/fixtures/runtime-claude"

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
for fn in classify_agent_failure agent_failure_is_retryable agent_events_error_kind; do
    if declare -F "$fn" >/dev/null; then
        pass "$fn definida"
    else
        fail "$fn NO definida"
    fi
done

# -------- Bloque A: classify_agent_failure --------

echo ""
echo "[A] classify_agent_failure conserva las etiquetas, ahora desde el JSONL neutral"

# Fixtures inline conforme a run-events.schema.json (issue #906): un terminal
# run.completed/run.failed con `error{kind, detail}` estructurado.
EVENTS_5XX="$TMP/events-5xx.jsonl"
printf '%s\n' '{"v":1,"type":"run.failed","ts":"2026-08-05T10:00:00Z","status":"failed","runtime":"claude","model":null,"session_id":null,"duration_ms":100,"tokens":{"input":null,"output":null},"cost_usd":null,"turns":null,"denials":null,"ttft_ms":null,"api_duration_ms":null,"error":{"kind":"api_error","detail":"API Error: 529 Overloaded"}}' > "$EVENTS_5XX"
EVENTS_4XX="$TMP/events-4xx.jsonl"
printf '%s\n' '{"v":1,"type":"run.failed","ts":"2026-08-05T10:00:00Z","status":"failed","runtime":"claude","model":null,"session_id":null,"duration_ms":100,"tokens":{"input":null,"output":null},"cost_usd":null,"turns":null,"denials":null,"ttft_ms":null,"api_duration_ms":null,"error":{"kind":"api_error","detail":"API Error: 400 Bad Request"}}' > "$EVENTS_4XX"
EVENTS_CUT="$TMP/events-cut.jsonl"
printf '%s\n' '{"v":1,"type":"run.failed","ts":"2026-08-05T10:00:00Z","status":"failed","runtime":"claude","model":null,"session_id":null,"duration_ms":100,"tokens":{"input":null,"output":null},"cost_usd":null,"turns":null,"denials":null,"ttft_ms":null,"api_duration_ms":null,"error":{"kind":"stream_cut","detail":"Connection closed mid-response"}}' > "$EVENTS_CUT"
EVENTS_PLAIN="$TMP/events-plain.jsonl"
printf '%s\n' '{"v":1,"type":"run.failed","ts":"2026-08-05T10:00:00Z","status":"failed","runtime":"claude","model":null,"session_id":null,"duration_ms":100,"tokens":{"input":null,"output":null},"cost_usd":null,"turns":null,"denials":null,"ttft_ms":null,"api_duration_ms":null,"error":{"kind":"nonzero_exit","detail":"stop_reason=? subtype=?"}}' > "$EVENTS_PLAIN"
EVENTS_OK="$TMP/events-ok.jsonl"
printf '%s\n' '{"v":1,"type":"run.completed","ts":"2026-08-05T10:00:00Z","status":"success","runtime":"claude","model":"claude-sonnet-5","session_id":null,"duration_ms":100,"tokens":{"input":null,"output":null},"cost_usd":null,"turns":null,"denials":null,"ttft_ms":null,"api_duration_ms":null,"error":null}' > "$EVENTS_OK"
EVENTS_BAD="$TMP/events-bad.jsonl"
printf '%s\n' '{"v":1,"type":"message","ts":"2026-08-05T10:00:00Z","role":"assistant","text":"trabajando"}' > "$EVENTS_BAD"

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
    "TIMEOUT (99s, exit 1)"                 "true"  "1"   "99" "$EVENTS_BAD"
check_label "A-2: senal con terminal de exito" \
    "SIGNAL_POST_SUCCESS (exit 137, 12s)"   "false" "137" "12" "$EVENTS_OK"
check_label "A-3: senal sin terminal" \
    "SIGNAL_MID_FLIGHT (exit 137, 12s)"     "false" "137" "12" "$EVENTS_BAD"
check_label "A-4: 5xx del servidor" \
    "API_ERROR_SERVER (exit 1)"             "false" "1"   "12" "$EVENTS_5XX"
check_label "A-5: 4xx del cliente" \
    "API_ERROR_CLIENT (exit 1)"             "false" "1"   "12" "$EVENTS_4XX"
check_label "A-6: corte de stream" \
    "STREAM_CUT (exit 1)"                   "false" "1"   "12" "$EVENTS_CUT"
check_label "A-7: sin sintoma reconocible" \
    "CLI_ERROR (exit 3)"                    "false" "3"   "12" "$EVENTS_PLAIN"
# El orden importa: un TIMEOUT del watchdog gana aunque el terminal traiga un 5xx.
check_label "A-8: TIMEOUT precede al 5xx" \
    "TIMEOUT (99s, exit 1)"                 "true"  "1"   "99" "$EVENTS_5XX"

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

# Trazas REALES de Claude Code (no inventadas): el mismo traductor que corre
# en produccion (runtime_claude_translate) las convierte al JSONL neutral que
# consume classify_agent_failure -- mismo patron que el bloque [O] de
# test-stream-watch.sh.
RAW_5XX="$(cat "$FIXDIR/api-error-529.jsonl")"
RAW_4XX="$(cat "$FIXDIR/api-error-404.jsonl")"
RAW_GENERIC="$(cat "$FIXDIR/result-max-turns.jsonl")"
RAW_SUCCESS="$(cat "$FIXDIR/success.jsonl")"

# Entorno minimo para ejecutar run_agent extraido, sin invocar el CLI real.
setup_run_agent_env() {
    local wt="$1"

    LOG_DIR_ABS="$TMP/logs"; PIPELINE_DIR_ABS="$TMP/pipeline"
    mkdir -p "$LOG_DIR_ABS" "$PIPELINE_DIR_ABS/metrics"
    EVENTS_LOG_ABS="$TMP/events.log"; : > "$EVENTS_LOG_ABS"
    TIMESTAMP="testts"; ISSUE_NUM="999"
    # ISSUE_LOG_TAG (issue #711): run_agent() ya no nombra los logs de stage
    # con ISSUE_NUM directo, sino con este tag (ISSUE_NUM, o ISSUE_NUM-<label>
    # en modo variante). Sin definirlo aqui, la asignacion de log_base dentro
    # de run_agent referencia una variable sin `set` bajo `set -u` y el
    # proceso entero termina en silencio (nounset sale del shell no
    # interactivo, no solo del comando).
    ISSUE_LOG_TAG="$ISSUE_NUM"
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

# Stub del invocador: falla con la traza cruda indicada durante los primeros
# $STUB_FAILURES intentos y luego devuelve exito. Escribe DIRECTO al
# $stdout_file/$stderr_file que run_agent le pasa (posiciones 3 y 4) -- el
# resto de run_agent (runtime_claude_translate real, derive_stage_log_from_stream
# stubeado, classify_agent_failure real) corre sin cambios. Lleva la cuenta en
# disco.
make_watchdog_stub() {
    local raw_fail="$1" raw_success="$2"
    STUB_RAW_FAIL="$raw_fail"
    STUB_RAW_SUCCESS="$raw_success"
    : > "$TMP/attempts.txt"
    run_agent_with_watchdog() {
        local stdout_file="$3" stderr_file="$4"
        echo "x" >> "$TMP/attempts.txt"
        local n
        n=$(wc -l < "$TMP/attempts.txt" | tr -d ' ')
        : > "$stderr_file"
        if [ "$n" -le "$STUB_FAILURES" ]; then
            printf '%s\n' "$STUB_RAW_FAIL" > "$stdout_file"
            echo "1"
        else
            printf '%s\n' "$STUB_RAW_SUCCESS" > "$stdout_file"
            echo "0"
        fi
    }
}

attempts_made() { wc -l < "$TMP/attempts.txt" | tr -d ' '; }

run_case() {
    local desc="$1" raw_fail="$2" failures="$3" expected_attempts="$4" expect_ok="$5"

    local wt="$TMP/wt-$RANDOM"
    mkdir -p "$wt"
    git -C "$wt" init -q
    git -C "$wt" config user.email t@t.t
    git -C "$wt" config user.name t
    echo "base" > "$wt/base.txt"
    git -C "$wt" add -A && git -C "$wt" commit -qm base

    setup_run_agent_env "$wt"
    STUB_FAILURES="$failures"
    make_watchdog_stub "$raw_fail" "$RAW_SUCCESS"

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
    "$RAW_5XX" 1 2 ok
run_case "C-2: 5xx persistente, se detiene en el tope de 3" \
    "$RAW_5XX" 9 3 fail
run_case "C-3: 4xx del cliente, no se reintenta" \
    "$RAW_4XX" 9 1 fail
run_case "C-4: error generico del CLI, no se reintenta" \
    "$RAW_GENERIC" 9 1 fail

# C-5: worktree restaurado entre reintentos cuando entraba limpio.
WT_C5="$TMP/wt-c5"
mkdir -p "$WT_C5"
git -C "$WT_C5" init -q
git -C "$WT_C5" config user.email t@t.t
git -C "$WT_C5" config user.name t
echo "base" > "$WT_C5/base.txt"
git -C "$WT_C5" add -A && git -C "$WT_C5" commit -qm base

setup_run_agent_env "$WT_C5"
STUB_FAILURES=1
: > "$TMP/attempts.txt"
run_agent_with_watchdog() {
    local stdout_file="$3" stderr_file="$4"
    echo "x" >> "$TMP/attempts.txt"
    local n
    n=$(wc -l < "$TMP/attempts.txt" | tr -d ' ')
    : > "$stderr_file"
    if [ "$n" -le "$STUB_FAILURES" ]; then
        # El intento que falla deja basura en el worktree.
        echo "a medias" > "$WT_C5/basura.txt"
        echo "modificado" >> "$WT_C5/base.txt"
        printf '%s\n' "$RAW_5XX" > "$stdout_file"
        echo "1"
    else
        printf '%s\n' "$RAW_SUCCESS" > "$stdout_file"
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
STUB_FAILURES=1
: > "$TMP/attempts.txt"
make_watchdog_stub "$RAW_5XX" "$RAW_SUCCESS"
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
