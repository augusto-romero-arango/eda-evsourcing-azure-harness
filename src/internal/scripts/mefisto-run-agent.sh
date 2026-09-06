#!/usr/bin/env bash
# mefisto-run-agent.sh -- Runner neutral a runtime de una invocacion de agente
# (MEF-ADR-0049 CA-1/CA-2, issue #858). Reemplaza, para quien lo adopte
# (#869), la invocacion directa de `claude -p ...` de
# .claude/scripts/mefisto-tooling-pipeline.sh:463 por un contrato que ningun
# pipeline necesita conocer en detalle: recibe argumentos opacos, escribe
# JSONL neutral (vocabulario cerrado en src/internal/contract/run-events.
# schema.json) y devuelve un exit code que resume el desenlace sin que el
# caller tenga que interpretar el stream crudo de ningun CLI.
#
# Uso:
#   mefisto-run-agent.sh --agent <id> --cwd <dir> --prompt-file <f>
#                         --event-log <jsonl>
#                         [--runtime <id>] [--model <opaco>]
#                         [--system-file <f>] [--timeout <s>]
#                         [--raw-log <f>] [--stderr-log <f>]
#
#   --runtime <id>       Fuerza el runtime (precedencia sobre MEFISTO_RUNTIME
#                         y la autodeteccion, ver mefisto_resolve_runtime en
#                         lib/mefisto-runtime.sh). Opcional: sin el, se
#                         resuelve por entorno/autodeteccion (CA-2).
#   --agent <id>          Id del agente que se invoca (viaja tal cual a
#                         run.started.agent). Obligatorio.
#   --cwd <dir>           Directorio de trabajo del agente (debe existir).
#                         Obligatorio.
#   --prompt-file <f>     Archivo con el prompt (debe existir). Obligatorio.
#   --event-log <jsonl>   Ruta de salida del JSONL neutral. Obligatorio; su
#                         directorio padre se crea si falta.
#   --model <opaco>       Modelo a pasar al adaptador, opaco para este runner
#                         (un alias de Claude Code, un "provider/model" de
#                         OpenCode, lo que sea). Vacio o ausente = heredar
#                         (CA-1): NO llega al adaptador -- build_cmd nunca ve
#                         el flag de modelo en ese caso.
#   --system-file <f>     Sustituto neutral de --append-system-prompt (debe
#                         existir si se pasa). Cada adaptador decide como
#                         inyectarlo.
#   --timeout <s>         Timeout duro en segundos del watchdog (entero > 0).
#                         Default: 1800 (mismo default que
#                         mefisto-tooling-pipeline.sh hoy).
#   --raw-log <f>         Donde conservar la traza cruda del adaptador (issue
#                         #861: ningun gate la parsea, es solo diagnostico).
#                         Sin el, se usa un archivo temporal descartable.
#   --stderr-log <f>      Donde conservar el stderr crudo del proceso. Mismo
#                         default que --raw-log si se omite.
#
# Exit code (CA-5): 0 solo con un evento terminal run.completed{status:
# "success"}; 124 si el watchdog mato el proceso por timeout; 65 si el
# protocolo resulto invalido (el adaptador emitio cero o mas de un evento
# terminal -- el runner lo normaliza SIEMPRE a exactamente uno en
# --event-log, descartando los que sobren); en cualquier otro caso, el exit
# code del adaptador (distinto de cero). Validacion de argumentos: exit 64
# (uso). Resolucion de runtime fallida: exit 69.
#
# Interfaz de adaptador (dos funciones por runtime, `source`adas desde
# lib/runtime-<id>.sh; este issue solo entrega runtime-fake.sh -- Claude Code
# y OpenCode son #859/#860):
#   runtime_<id>_build_cmd <agent> <cwd> <prompt_file> <model> <system_file>
#     Rellena el array global MEFISTO_RUNTIME_CMD con el argv completo a
#     invocar via run_agent_with_watchdog, SIN `eval`.
#   runtime_<id>_translate <raw_file> <runtime_id> <model>
#     Imprime por stdout el JSONL neutral (message/tool.*/terminal) derivado
#     de <raw_file>. Nunca emite run.started -- eso lo hace este runner,
#     directo, porque no depende de ningun dato especifico del adaptador.
#
# Ver src/internal/contract/README.md ("Protocolo de ejecucion y eventos")
# para el detalle completo del contrato y su justificacion.
#
# Bash 3.2 + jq 1.7 (MEF-ADR-0049 CA-6): sin arrays asociativos.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
COMMON_LIB="$REPO_ROOT/.claude/scripts/_mefisto-common.sh"

usage() {
    cat <<'EOF' >&2
Uso: mefisto-run-agent.sh --agent <id> --cwd <dir> --prompt-file <f> --event-log <jsonl>
                           [--runtime <id>] [--model <opaco>] [--system-file <f>]
                           [--timeout <s>] [--raw-log <f>] [--stderr-log <f>]
EOF
}

abort_usage() {
    echo "ERROR: $1" >&2
    usage
    exit 64
}

if [ ! -f "$COMMON_LIB" ]; then
    echo "ERROR: no se encontro '$COMMON_LIB' (run_agent_with_watchdog, issue #424; el traslado de esta lib a src/internal/scripts es alcance de #869)" >&2
    exit 69
fi
if [ ! -f "$LIB_DIR/mefisto-runtime.sh" ]; then
    echo "ERROR: no existe '$LIB_DIR/mefisto-runtime.sh'" >&2
    exit 69
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq no esta instalado (MEF-ADR-0049 CA-6: bash + jq, sin dependencia externa)" >&2
    exit 69
fi

# shellcheck source=/dev/null
source "$COMMON_LIB"
# shellcheck source=/dev/null
source "$LIB_DIR/mefisto-runtime.sh"

# --- Parseo de argumentos ----------------------------------------------------

OPT_RUNTIME=""
OPT_AGENT=""
OPT_CWD=""
OPT_PROMPT_FILE=""
OPT_EVENT_LOG=""
OPT_MODEL=""
OPT_SYSTEM_FILE=""
OPT_TIMEOUT=""
OPT_RAW_LOG=""
OPT_STDERR_LOG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --runtime)     [ $# -ge 2 ] || abort_usage "--runtime requiere un valor"; OPT_RUNTIME="$2"; shift 2 ;;
        --agent)       [ $# -ge 2 ] || abort_usage "--agent requiere un valor"; OPT_AGENT="$2"; shift 2 ;;
        --cwd)         [ $# -ge 2 ] || abort_usage "--cwd requiere un valor"; OPT_CWD="$2"; shift 2 ;;
        --prompt-file) [ $# -ge 2 ] || abort_usage "--prompt-file requiere un valor"; OPT_PROMPT_FILE="$2"; shift 2 ;;
        --event-log)   [ $# -ge 2 ] || abort_usage "--event-log requiere un valor"; OPT_EVENT_LOG="$2"; shift 2 ;;
        --model)       [ $# -ge 2 ] || abort_usage "--model requiere un valor"; OPT_MODEL="$2"; shift 2 ;;
        --system-file) [ $# -ge 2 ] || abort_usage "--system-file requiere un valor"; OPT_SYSTEM_FILE="$2"; shift 2 ;;
        --timeout)     [ $# -ge 2 ] || abort_usage "--timeout requiere un valor"; OPT_TIMEOUT="$2"; shift 2 ;;
        --raw-log)     [ $# -ge 2 ] || abort_usage "--raw-log requiere un valor"; OPT_RAW_LOG="$2"; shift 2 ;;
        --stderr-log)  [ $# -ge 2 ] || abort_usage "--stderr-log requiere un valor"; OPT_STDERR_LOG="$2"; shift 2 ;;
        *) abort_usage "argumento desconocido: '$1'" ;;
    esac
done

[ -n "$OPT_AGENT" ]       || abort_usage "--agent es obligatorio"
[ -n "$OPT_CWD" ]         || abort_usage "--cwd es obligatorio"
[ -n "$OPT_PROMPT_FILE" ] || abort_usage "--prompt-file es obligatorio"
[ -n "$OPT_EVENT_LOG" ]   || abort_usage "--event-log es obligatorio"

[ -d "$OPT_CWD" ]         || abort_usage "--cwd '$OPT_CWD' no es un directorio existente"
[ -f "$OPT_PROMPT_FILE" ] || abort_usage "--prompt-file '$OPT_PROMPT_FILE' no existe"
if [ -n "$OPT_SYSTEM_FILE" ]; then
    [ -f "$OPT_SYSTEM_FILE" ] || abort_usage "--system-file '$OPT_SYSTEM_FILE' no existe"
fi
if [ -n "$OPT_TIMEOUT" ]; then
    case "$OPT_TIMEOUT" in
        ''|*[!0-9]*) abort_usage "--timeout '$OPT_TIMEOUT' no es un entero" ;;
    esac
    [ "$OPT_TIMEOUT" -gt 0 ] || abort_usage "--timeout debe ser mayor que 0"
fi
TIMEOUT_S="${OPT_TIMEOUT:-1800}"

# --- Resolucion de runtime (CA-2) -------------------------------------------

if ! RUNTIME_ID="$(mefisto_resolve_runtime "$OPT_RUNTIME")"; then
    echo "ERROR: $MEFISTO_RUNTIME_ERROR" >&2
    exit 69
fi

RUNTIME_LIB="$MEFISTO_RUNTIME_LIB_DIR/runtime-${RUNTIME_ID}.sh"
# shellcheck source=/dev/null
source "$RUNTIME_LIB"

BUILD_FN="runtime_${RUNTIME_ID}_build_cmd"
TRANSLATE_FN="runtime_${RUNTIME_ID}_translate"
if ! declare -F "$BUILD_FN" >/dev/null 2>&1; then
    echo "ERROR: $RUNTIME_LIB no define $BUILD_FN" >&2
    exit 69
fi
if ! declare -F "$TRANSLATE_FN" >/dev/null 2>&1; then
    echo "ERROR: $RUNTIME_LIB no define $TRANSLATE_FN" >&2
    exit 69
fi

MEFISTO_RUNTIME_CMD=()
"$BUILD_FN" "$OPT_AGENT" "$OPT_CWD" "$OPT_PROMPT_FILE" "$OPT_MODEL" "$OPT_SYSTEM_FILE"
if [ "${#MEFISTO_RUNTIME_CMD[@]}" -eq 0 ]; then
    echo "ERROR: $BUILD_FN no genero ningun comando (MEFISTO_RUNTIME_CMD vacio)" >&2
    exit 69
fi

# --- Archivos de trabajo ------------------------------------------------

mkdir -p "$(dirname "$OPT_EVENT_LOG")" 2>/dev/null || true

CLEANUP_FILES=()

if [ -n "$OPT_RAW_LOG" ]; then
    RAW_LOG="$OPT_RAW_LOG"
    mkdir -p "$(dirname "$RAW_LOG")" 2>/dev/null || true
else
    RAW_LOG="$(mktemp -t mefisto-run-agent-raw)"
    CLEANUP_FILES+=("$RAW_LOG")
fi

if [ -n "$OPT_STDERR_LOG" ]; then
    STDERR_LOG="$OPT_STDERR_LOG"
    mkdir -p "$(dirname "$STDERR_LOG")" 2>/dev/null || true
else
    STDERR_LOG="$(mktemp -t mefisto-run-agent-stderr)"
    CLEANUP_FILES+=("$STDERR_LOG")
fi

# events_log de run_agent_with_watchdog: solo recibe SU linea de texto plano
# de diagnostico ("[HH:MM:SS] TIMEOUT: ..."), nunca el JSONL neutral -- mezclar
# ambos formatos en --event-log corromperia el contrato (CA-3/CA-4).
WATCHDOG_EVENTS_LOG="$(mktemp -t mefisto-run-agent-watchdog-events)"
SIGNAL_FILE="$(mktemp -u -t mefisto-run-agent-signal)"
CLEANUP_FILES+=("$WATCHDOG_EVENTS_LOG")

cleanup() {
    rm -f "${CLEANUP_FILES[@]+"${CLEANUP_FILES[@]}"}" "$SIGNAL_FILE" 2>/dev/null || true
}
trap cleanup EXIT

# --- Helpers -----------------------------------------------------------

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

model_json_or_null() {
    if [ -n "$1" ]; then
        printf '%s' "$1" | jq -Rr '@json'
    else
        printf 'null'
    fi
}

# --- run.started (CA-3): lo emite el runner, no el adaptador ----------------

RUN_STARTED_MODEL_JSON="$(model_json_or_null "$OPT_MODEL")"
jq -n -c \
    --arg ts "$(now_ts)" \
    --arg runtime "$RUNTIME_ID" \
    --arg agent "$OPT_AGENT" \
    --argjson model "$RUN_STARTED_MODEL_JSON" \
    --arg cwd "$OPT_CWD" \
    '{v: 1, type: "run.started", ts: $ts, runtime: $runtime, agent: $agent, model: $model, cwd: $cwd}' \
    > "$OPT_EVENT_LOG"

# --- Invocacion bajo watchdog (CA-5) -----------------------------------

START_EPOCH=$(date +%s)
ADAPTER_EXIT=$(run_agent_with_watchdog "$OPT_CWD" "$TIMEOUT_S" "$RAW_LOG" "$STDERR_LOG" "$WATCHDOG_EVENTS_LOG" "$OPT_AGENT" "$SIGNAL_FILE" "${MEFISTO_RUNTIME_CMD[@]}")
END_EPOCH=$(date +%s)
ELAPSED_MS=$(( (END_EPOCH - START_EPOCH) * 1000 ))

TIMED_OUT=false
[ -f "$SIGNAL_FILE" ] && TIMED_OUT=true
rm -f "$SIGNAL_FILE"

# --- Traduccion del adaptador --------------------------------------------

TRANSLATED="$("$TRANSLATE_FN" "$RAW_LOG" "$RUNTIME_ID" "$OPT_MODEL" 2>/dev/null)"

NON_TERMINAL_JSON=""
TERMINAL_JSON=""
if [ -n "$TRANSLATED" ]; then
    NON_TERMINAL_JSON="$(printf '%s\n' "$TRANSLATED" | jq -c 'select(type == "object") | select(.type != "run.completed" and .type != "run.failed")' 2>/dev/null)"
    TERMINAL_JSON="$(printf '%s\n' "$TRANSLATED" | jq -c 'select(type == "object") | select(.type == "run.completed" or .type == "run.failed")' 2>/dev/null)"
fi

TERMINAL_COUNT=0
if [ -n "$TERMINAL_JSON" ]; then
    TERMINAL_COUNT="$(printf '%s\n' "$TERMINAL_JSON" | jq -s 'length' 2>/dev/null)"
    [ -n "$TERMINAL_COUNT" ] || TERMINAL_COUNT=0
fi

# --- Normalizacion a EXACTAMENTE un evento terminal (CA-5) ------------------

CHOSEN_TERMINAL=""
FINAL_EXIT=1

if [ "$TIMED_OUT" = "true" ]; then
    # El watchdog mato el proceso a mitad de vuelo: cualquier terminal que el
    # adaptador haya alcanzado a traducir de todos modos no es confiable (la
    # senal pudo llegar a mitad de escritura). Se descarta sin miralo.
    NON_TERMINAL_JSON=""
    CHOSEN_TERMINAL="$(jq -n -c \
        --arg ts "$(now_ts)" --arg runtime "$RUNTIME_ID" --argjson model "$RUN_STARTED_MODEL_JSON" \
        --arg detail "el watchdog mato el proceso tras superar ${TIMEOUT_S}s" \
        '{v: 1, type: "run.failed", ts: $ts, status: "timeout", runtime: $runtime, model: $model,
          session_id: null, duration_ms: null, tokens: {input: null, output: null}, cost_usd: null,
          turns: null, denials: null, ttft_ms: null, api_duration_ms: null,
          error: {kind: "timeout", detail: $detail}}')"
    FINAL_EXIT=124
elif [ "$TERMINAL_COUNT" -eq 1 ]; then
    CHOSEN_TERMINAL="$TERMINAL_JSON"
    TERMINAL_STATUS="$(printf '%s' "$CHOSEN_TERMINAL" | jq -r '.status')"
    if [ "$TERMINAL_STATUS" = "success" ]; then
        FINAL_EXIT=0
    elif [ "$ADAPTER_EXIT" -ne 0 ] 2>/dev/null; then
        FINAL_EXIT="$ADAPTER_EXIT"
    else
        FINAL_EXIT=1
    fi
else
    DETAIL="el adaptador '$RUNTIME_ID' emitio $TERMINAL_COUNT eventos terminales (se esperaba exactamente 1)"
    CHOSEN_TERMINAL="$(jq -n -c \
        --arg ts "$(now_ts)" --arg runtime "$RUNTIME_ID" --argjson model "$RUN_STARTED_MODEL_JSON" \
        --arg detail "$DETAIL" \
        '{v: 1, type: "run.failed", ts: $ts, status: "protocol_invalid", runtime: $runtime, model: $model,
          session_id: null, duration_ms: null, tokens: {input: null, output: null}, cost_usd: null,
          turns: null, denials: null, ttft_ms: null, api_duration_ms: null,
          error: {kind: "protocol_invalid", detail: $detail}}')"
    FINAL_EXIT=65
fi

# duration_ms real (CA-5): el runner es la unica parte que tiene el reloj de
# pared alrededor de la invocacion COMPLETA -- sobreescribe lo que el
# adaptador haya (o no) traducido, nunca un cero fabricado (MEF-ADR-0049 CA-1).
CHOSEN_TERMINAL="$(printf '%s' "$CHOSEN_TERMINAL" | jq -c --argjson d "$ELAPSED_MS" '.duration_ms = $d')"

[ -n "$NON_TERMINAL_JSON" ] && printf '%s\n' "$NON_TERMINAL_JSON" >> "$OPT_EVENT_LOG"
printf '%s\n' "$CHOSEN_TERMINAL" >> "$OPT_EVENT_LOG"

exit "$FINAL_EXIT"
