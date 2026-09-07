#!/usr/bin/env bash
# runtime-fake.sh -- Adaptador de runtime FALSO (issue #858). Unico adaptador
# que este issue entrega (Claude Code y OpenCode son #859/#860): existe para
# que mefisto-run-agent.sh y su contrato de eventos se puedan probar sin
# invocar un CLI real, guionando escenarios (exito, fallo, cuelgue, protocolo
# invalido) por variable de entorno.
#
# Implementa la interfaz de dos funciones que todo adaptador de runtime debe
# exponer (ver src/internal/contract/README.md, "Protocolo de ejecucion y
# eventos"):
#   runtime_fake_build_cmd <agent> <cwd> <prompt_file> <model> <system_file>
#     Rellena el array global MEFISTO_RUNTIME_CMD con el argv a invocar via
#     run_agent_with_watchdog (sin `eval`). <model> puede llegar vacio
#     (heredar, CA-1): en ese caso NO se agrega ningun flag de modelo al argv
#     -- el CLI fake nunca lo ve, igual que un adaptador real nunca deberia
#     pasar un --model vacio al CLI que envuelve.
#   runtime_fake_translate <raw_file> <runtime_id> <model>
#     Imprime por stdout el JSONL neutral derivado de <raw_file> (una linea
#     por evento, sin emitir "run.started": eso lo hace el runner). El campo
#     `duration_ms` de un evento terminal se emite en null a proposito -- el
#     runner es quien sobreescribe ese campo con el tiempo real medido
#     alrededor de la invocacion completa (ver mefisto-run-agent.sh), nunca un
#     adaptador: ninguno tiene, desde el interior del proceso, el reloj de
#     pared que envuelve al proceso entero.
#
# Este mismo archivo es tambien el "CLI fake" que build_cmd invoca: al
# ejecutarse DIRECTAMENTE (no al ser `source`ado) reproduce el guion que
# indique MEFISTO_FAKE_SCRIPT y termina con el exit code de ese guion. La
# deteccion "sourceado vs. ejecutado" es el idiom estandar de bash
# (BASH_SOURCE[0] == $0 solo cuando el archivo corre como proceso propio).
#
# Guiones soportados via MEFISTO_FAKE_SCRIPT (CA-6):
#   success        Emite message + tool.started/tool.completed + terminal
#                   status=success. Exit 0.
#   slow-success   Emite las MISMAS lineas que "success", byte a byte, pero
#                   con un `sleep ${MEFISTO_FAKE_STEP_DELAY_S:-2}` entre cada
#                   una (issue #924): existe para poder observar en un test el
#                   anexo EN VIVO de mefisto-run-agent.sh a mitad de una
#                   corrida real, algo que "success" no permite por terminar
#                   antes de que transcurra el primer intervalo. La identidad
#                   linea a linea con "success" no es cosmetica: es lo que
#                   deja comparar el --event-log de ambos y afirmar que el
#                   anexo en vivo produce la misma secuencia que el volcado
#                   al cierre (CA-2). Si se cambia un guion hay que cambiar
#                   el otro.
#   fail            Emite terminal status=failed (error.kind=nonzero_exit).
#                   Exit $MEFISTO_FAKE_EXIT_CODE (default 3, debe ser != 0).
#   hang            No termina solo: se queda dormido muy por encima de
#                   cualquier --timeout de prueba, para que el watchdog de
#                   run_agent_with_watchdog lo mate (mismo stand-in de CLI que
#                   test-watchdog-trabajo-util.sh: un `sleep` largo).
#   no-terminal     Emite un mensaje pero NUNCA un evento terminal. Exit 0.
#   two-terminals   Emite DOS eventos terminales validos. Exit 0.
#   malformed       Emite una linea valida y luego una linea JSON truncada a
#                   media escritura (nunca llega a un terminal valido). Exit 1.
#   touch-tty       Repro determinista del aislamiento de tty (issue #943):
#                   emite un message, intenta `read -r x </dev/tty`, despues
#                   `stty -echo` (tcsetattr sobre stdin) y despues `read -r y`
#                   de stdin -- los tres disparadores de SIGTTIN/SIGTTOU que
#                   detuvieron un writer real en STAT=T. Ignora los fallos de
#                   las tres (este archivo no usa `set -e`): con terminal de
#                   control, cualquiera de ellas detiene al grupo; sin ella
#                   (sesion nueva + stdin en /dev/null), fallan rapido y sin
#                   senal (ENXIO / "not a terminal" / EOF). Termina con
#                   terminal status=success. Exit 0.
# Default sin MEFISTO_FAKE_SCRIPT: "success".
#
# Bash 3.2 + jq 1.7: sin arrays asociativos, sin dependencias de red.

# --- runtime_fake_build_cmd ---------------------------------------------

runtime_fake_build_cmd() {
    local agent="$1" cwd="$2" prompt_file="$3" model="$4" system_file="$5"
    # Resuelto contra el propio BASH_SOURCE (no MEFISTO_RUNTIME_LIB_DIR): esta
    # funcion debe encontrar su propio "CLI fake" aunque quien la invoque haya
    # sourceado este archivo desde un directorio de prueba distinto al
    # canonico -- mismo criterio defensivo que el resto de rutas resueltas por
    # BASH_SOURCE en este repo (ver mefisto-state.sh).
    local self
    self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runtime-fake.sh"

    MEFISTO_RUNTIME_CMD=(bash "$self" __mefisto-fake-emit "$agent" "$prompt_file" "$system_file")
    if [ -n "$model" ]; then
        MEFISTO_RUNTIME_CMD+=(--fake-model "$model")
    fi
}

# --- runtime_fake_translate ----------------------------------------------

runtime_fake_translate() {
    local raw_file="$1" runtime_id="$2"
    [ -f "$raw_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    jq -R -c --arg runtime "$runtime_id" '
        (try fromjson catch empty)
        | select(type == "object")
        | if .fake == "message" then
              {v: 1, type: "message", ts: (now | todate), role: "assistant", text: (.text // "")}
          elif .fake == "tool_start" then
              {v: 1, type: "tool.started", ts: (now | todate), tool: (.tool // "?"), input_summary: null}
          elif .fake == "tool_end" then
              {v: 1, type: "tool.completed", ts: (now | todate), tool: (.tool // "?"),
               ok: (.ok // false), duration_ms: (.duration_ms // null)}
          elif .fake == "terminal" and .status == "success" then
              {v: 1, type: "run.completed", ts: (now | todate), status: "success", runtime: $runtime,
               model: (.model // null), session_id: null, duration_ms: null,
               tokens: {input: null, output: null}, cost_usd: null, turns: null,
               denials: null, ttft_ms: null, api_duration_ms: null, error: null}
          elif .fake == "terminal" and .status == "failed" then
              {v: 1, type: "run.failed", ts: (now | todate), status: "failed", runtime: $runtime,
               model: (.model // null), session_id: null, duration_ms: null,
               tokens: {input: null, output: null}, cost_usd: null, turns: null,
               denials: null, ttft_ms: null, api_duration_ms: null,
               error: {kind: (.error_kind // "nonzero_exit"), detail: (.error_detail // "fallo del guion fake")}}
          else empty end
    ' "$raw_file" 2>/dev/null
    return 0
}

# --- Modo "CLI fake": logica que corre cuando este archivo se EJECUTA -------

_runtime_fake_emit_main() {
    # Args: __mefisto-fake-emit <agent> <prompt_file> <system_file> [--fake-model <valor>]
    shift # descarta el token __mefisto-fake-emit
    shift || true # agent (sin uso: el guion no depende del agente invocado)
    shift || true # prompt_file
    shift || true # system_file

    local fake_model=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --fake-model) fake_model="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    local model_json="null"
    [ -n "$fake_model" ] && model_json="$(printf '%s' "$fake_model" | jq -Rr '@json' 2>/dev/null)"

    case "${MEFISTO_FAKE_SCRIPT:-success}" in
        success)
            echo '{"fake":"message","text":"hola desde el guion fake"}'
            echo '{"fake":"tool_start","tool":"demo"}'
            echo '{"fake":"tool_end","tool":"demo","ok":true,"duration_ms":5}'
            printf '{"fake":"terminal","status":"success","model":%s}\n' "$model_json"
            exit 0
            ;;
        slow-success)
            local step_delay="${MEFISTO_FAKE_STEP_DELAY_S:-2}"
            echo '{"fake":"message","text":"hola desde el guion fake"}'
            sleep "$step_delay"
            echo '{"fake":"tool_start","tool":"demo"}'
            sleep "$step_delay"
            echo '{"fake":"tool_end","tool":"demo","ok":true,"duration_ms":5}'
            sleep "$step_delay"
            printf '{"fake":"terminal","status":"success","model":%s}\n' "$model_json"
            exit 0
            ;;
        fail)
            printf '{"fake":"terminal","status":"failed","model":%s,"error_kind":"nonzero_exit","error_detail":"guion fail"}\n' "$model_json"
            exit "${MEFISTO_FAKE_EXIT_CODE:-3}"
            ;;
        hang)
            echo '{"fake":"message","text":"colgando hasta que el watchdog mate el proceso"}'
            sleep 3600
            ;;
        no-terminal)
            echo '{"fake":"message","text":"nunca emite un evento terminal"}'
            exit 0
            ;;
        two-terminals)
            printf '{"fake":"terminal","status":"success","model":%s}\n' "$model_json"
            printf '{"fake":"terminal","status":"failed","model":%s,"error_kind":"nonzero_exit","error_detail":"segundo terminal"}\n' "$model_json"
            exit 0
            ;;
        malformed)
            echo '{"fake":"message","text":"antes del corte"}'
            printf '{"fake":"terminal","status":"suc'
            exit 1
            ;;
        touch-tty)
            echo '{"fake":"message","text":"tocando la tty antes de terminar"}'
            read -r _touch_tty_x </dev/tty
            stty -echo
            read -r _touch_tty_y
            printf '{"fake":"terminal","status":"success","model":%s}\n' "$model_json"
            exit 0
            ;;
        *)
            echo "runtime-fake.sh: MEFISTO_FAKE_SCRIPT desconocido: '${MEFISTO_FAKE_SCRIPT:-}'" >&2
            exit 2
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    _runtime_fake_emit_main "$@"
fi
