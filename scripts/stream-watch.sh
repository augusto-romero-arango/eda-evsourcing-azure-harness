#!/usr/bin/env bash
# stream-watch.sh -- Visor de solo lectura de ejecuciones de agente.
#
# Sigue run-events.v1 (*.events.jsonl) desde el estado publicado y conserva un
# parser separado para los *.stream.jsonl Claude historicos de TDD/IaC. El
# camino neutral nunca consulta el wire format de un runtime ni muestra payloads.

set -uo pipefail

STREAM_WATCH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STREAM_WATCH_SCRIPT_DIR/_pipeline-common.sh"

RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
POLL_INTERVAL=1

ISSUES_CSV=""
NEWER_THAN=""
LAST_LINE=0
PREV_EMS=""
CURRENT_STREAM=""
CURRENT_FORMAT=""
JQ_FILTER_PATH=""
TMP_STATE=""
RUN_RUNTIME=""
RUN_AGENT=""
RUN_MODEL=""
TERMINAL_COUNT=0

# Materializa uno de dos parsers deliberadamente separados. El neutral solo
# nombra campos de run-events.v1 que son seguros para el pane.
write_jq_filter() {
    local dest="$1" format="$2"
    case "$format" in
        neutral)
            cat > "$dest" <<'JQ'
def epoch_ms:
  try (
    .ts
    | capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.(?<frac>[0-9]+))?Z$") as $c
    | (($c.base + "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) * 1000
      + (if $c.frac then (($c.frac + "000") | .[0:3] | tonumber) else 0 end)
  ) catch null;
def cell: if . == null or . == "" then "-" else tostring end;
def row: map(cell) | @tsv;
if type != "object" then empty
elif .type == "run.started" then ["started", epoch_ms, .runtime, .agent, .model] | row
elif .type == "message" then ["message", epoch_ms, (.kind // "text")] | row
elif .type == "tool.started" then ["tool-started", epoch_ms, .tool] | row
elif .type == "tool.completed" then ["tool-completed", epoch_ms, .tool, .ok, .duration_ms] | row
elif .type == "run.completed" or .type == "run.failed" then
  ["terminal", epoch_ms, .type, .status, .runtime, .model, .duration_ms, (.error.kind // null)] | row
else empty
end
JQ
            ;;
        legacy-claude)
            # Fallback localizable y eliminable cuando TDD/IaC emitan eventos.
            cat > "$dest" <<'JQ'
def epoch_ms:
  try (.timestamp | fromdateiso8601 * 1000) catch null;
def cell: if . == null or . == "" then "-" else tostring end;
def row: map(cell) | @tsv;
if type != "object" then empty
elif .type == "assistant" then
  . as $event
  | (.message.content // [])[]?
  | if .type == "tool_use" then ["legacy-tool", ($event | epoch_ms), .name] | row
    elif .type == "text" then ["legacy-message", ($event | epoch_ms), "texto"] | row
    elif .type == "thinking" then ["legacy-message", ($event | epoch_ms), "pensamiento"] | row
    else empty end
elif .type == "result" then ["legacy-terminal", epoch_ms, .is_error, .duration_ms, .num_turns] | row
else empty
end
JQ
            ;;
        *)
            echo "ERROR: formato de stream no soportado: $format" >&2
            return 1
            ;;
    esac
}

stream_matches_issues() {
    local base="$1" csv="$2" issue
    [ -n "$csv" ] || return 0
    for issue in ${csv//,/ }; do
        [ -n "$issue" ] || continue
        case "$base" in
            *"-issue-${issue}.events.jsonl"|*"-issue-${issue}-"*".events.jsonl"|*"-issue-${issue}.stream.jsonl"|*"-issue-${issue}-"*".stream.jsonl") return 0 ;;
        esac
    done
    return 1
}

stream_is_newer_than() {
    local path="$1" epoch="$2" mtime
    [ -n "$epoch" ] || return 0
    mtime=$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null) || return 0
    [ "$mtime" -ge "$epoch" ]
}

newest_matching() {
    local dir="$1" pattern="$2" candidate
    [ -d "$dir" ] || return 0
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        stream_matches_issues "$(basename "$candidate")" "$ISSUES_CSV" || continue
        stream_is_newer_than "$candidate" "$NEWER_THAN" || continue
        printf '%s\n' "$candidate"
        return 0
    done < <(ls -t "$dir"/$pattern 2>/dev/null)
}

# El helper fija la precedencia de roots. Dentro de cada root, run-events gana
# sobre el fallback; un stream Claude emparejado nunca puede ser seleccionado.
discover_stream() {
    local dir candidate stem
    while IFS= read -r dir; do
        candidate=$(newest_matching "$dir" '*.events.jsonl')
        if [ -n "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        candidate=$(newest_matching "$dir" '*.stream.jsonl')
        [ -n "$candidate" ] || continue
        stem="${candidate%.stream.jsonl}"
        # La comprobacion se repite aunque newest_matching neutral no hubiera
        # devuelto el par por filtros o carreras: el fallback nunca gana si el
        # artefacto neutral correspondiente existe.
        [ -f "$stem.events.jsonl" ] && continue
        printf '%s\n' "$candidate"
        return 0
    done < <(mefisto_state_read_paths logs)
}

stream_format() {
    case "$1" in
        *.events.jsonl) printf '%s\n' neutral ;;
        *.stream.jsonl) printf '%s\n' legacy-claude ;;
        *) return 1 ;;
    esac
}

neutral_run_metadata() {
    jq -r -s '
      [ .[] | select(type == "object" and .type == "run.started") ] | first
      | if . == null then "-\t-\t-" else [ .runtime, .agent, .model ] | map(if . == null or . == "" then "-" else tostring end) | @tsv end
    ' "$1" 2>/dev/null || printf '%s\n' $'-\t-\t-'
}

parse_stream_header() {
    local path="$1" format="$2" runtime="${3:--}" agent="${4:--}" model="${5:--}"
    local base stage issue state details=""
    base=$(basename "$path")
    stage=$(printf '%s' "$base" | sed -n 's/.*stage-\([0-9][0-9]*\).*/\1/p')
    issue=$(printf '%s' "$base" | sed -n 's/.*-issue-\([0-9][0-9]*\).*/\1/p')
    state=manual
    case "$path" in
        "$MEFISTO_STATE_DIR/"*) state=canonico ;;
        "$MEFISTO_LEGACY_STATE_DIR/"*) state=legacy ;;
    esac
    [ -n "$issue" ] && details="issue #$issue"
    [ -n "$stage" ] && details="${details}${details:+ | }stage $stage"
    ! is_missing "$runtime" && details="${details}${details:+ | }runtime $runtime"
    ! is_missing "$agent" && details="${details}${details:+ | }agente $agent"
    ! is_missing "$model" && details="${details}${details:+ | }modelo $model"
    printf '%b\n' "${CYAN}${BOLD}=== ${format}${details:+ | $details} ===${NC}"
    printf '%b\n' "${CYAN}estado: ${state} | ruta: ${path}${NC}"
}

is_missing() {
    case "$1" in ""|"-"|null) return 0 ;; *) return 1 ;; esac
}

fmt_time_hhmmss() {
    local secs
    if is_missing "$1"; then printf '%s\n' '--:--:--'; return 0; fi
    secs=$(( $1 / 1000 ))
    date -r "$secs" +%H:%M:%S 2>/dev/null || date -d "@$secs" +%H:%M:%S 2>/dev/null || printf '%s\n' '--:--:--'
}

fmt_delta_s() {
    if is_missing "$1" || is_missing "$2"; then printf '%7s' '-'; return 0; fi
    awk -v a="$1" -v b="$2" 'BEGIN { printf "+%5.1fs", (b-a)/1000 }'
}

ms_to_s() {
    if is_missing "$1"; then printf '%s\n' '?'; return 0; fi
    awk -v v="$1" 'BEGIN { printf "%.1f", v/1000 }'
}

render_row() {
    local kind="$1" ems="$2" a="$3" b="$4" c="$5" d="$6" e="$7" f="$8"
    local now delta result
    now=$(fmt_time_hhmmss "$ems")
    delta=$(fmt_delta_s "$PREV_EMS" "$ems")
    case "$kind" in
        started)
            RUN_RUNTIME="$a"; RUN_AGENT="$b"; RUN_MODEL="$c"
            printf '%b\n' "${BLUE}[${now}]${NC} ${delta}  inicio runtime=${a} agente=${b} modelo=${c}"
            ;;
        message) printf '%b\n' "${BLUE}[${now}]${NC} ${delta}  mensaje (${a})" ;;
        tool-started) printf '%b\n' "${BLUE}[${now}]${NC} ${delta}  herramienta ${BOLD}${a}${NC} iniciada" ;;
        tool-completed)
            result=fallo; [ "$b" = true ] && result=ok
            printf '%b\n' "${BLUE}[${now}]${NC} ${delta}  herramienta ${BOLD}${a}${NC}: ${result} ($(ms_to_s "$c")s)"
            ;;
        terminal)
            TERMINAL_COUNT=$((TERMINAL_COUNT + 1))
            if [ "$TERMINAL_COUNT" -gt 1 ]; then
                printf '%b\n' "${RED}Aviso: protocolo invalido; se observo mas de un terminal. El terminal adicional se omitio.${NC}"
            else
                is_missing "$c" && c="$RUN_RUNTIME"
                is_missing "$d" && d="$RUN_MODEL"
                printf '%b\n' "${BOLD}--- desenlace ${a} | resultado=${b} | runtime=${c} | agente=${RUN_AGENT:--} | modelo=${d} | duracion=$(ms_to_s "$e")s${NC}"
                if [ "$a" != run.completed ] || [ "$b" != success ]; then
                    printf '%b\n' "${RED}La corrida no termino con exito.${NC}"
                elif ! is_missing "$f"; then
                    printf '%b\n' "${YELLOW}Incidente posterior al exito: ${f}.${NC}"
                fi
            fi
            ;;
        legacy-tool) printf '%b\n' "${YELLOW}[legacy Claude]${NC} [${now}] ${delta}  herramienta ${a}" ;;
        legacy-message) printf '%b\n' "${YELLOW}[legacy Claude]${NC} [${now}] ${delta}  ${a}" ;;
        legacy-terminal)
            result=OK; [ "$a" = true ] && result=ERROR
            printf '%b\n' "${YELLOW}[legacy Claude]${NC} cierre: ${result} duracion=$(ms_to_s "$b")s turnos=${c}"
            ;;
    esac
    PREV_EMS="$ems"
}

# Consume lineas completas. Una ultima linea invalida sin newline se retiene;
# una linea corrupta ya cerrada se omite con un aviso visible.
process_new_lines() {
    local stream="$1" line line_num rows rc complete_lines
    [ -f "$stream" ] || return 0
    complete_lines=$(wc -l < "$stream" 2>/dev/null | tr -d '[:space:]')
    [ -n "$complete_lines" ] || complete_lines=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_num=$((LAST_LINE + 1))
        if ! printf '%s' "$line" | jq empty >/dev/null 2>&1; then
            if [ "$line_num" -gt "$complete_lines" ]; then
                printf '%b\n' "${YELLOW}Aviso: linea parcial; se reintentara.${NC}"
                return 0
            fi
            printf '%b\n' "${YELLOW}Aviso: linea corrupta omitida.${NC}"
            LAST_LINE=$line_num
            continue
        fi
        rows=$(printf '%s' "$line" | jq -r -f "$JQ_FILTER_PATH" 2>/dev/null); rc=$?
        if [ "$rc" -ne 0 ]; then
            printf '%b\n' "${YELLOW}Aviso: evento no renderizable omitido.${NC}"
            LAST_LINE=$line_num
            continue
        fi
        LAST_LINE=$line_num
        while IFS=$'\t' read -r kind ems a b c d e f; do
            [ -n "$kind" ] && render_row "$kind" "$ems" "$a" "$b" "$c" "$d" "$e" "$f"
        done <<< "$rows"
    done < <(sed -n "$((LAST_LINE + 1)),\$p" "$stream" 2>/dev/null)
}

finish_current_stream() {
    [ "$CURRENT_FORMAT" = neutral ] || return 0
    if [ "$TERMINAL_COUNT" -eq 0 ]; then
        printf '%b\n' "${YELLOW}Aviso: el stream anterior quedo truncado: no declaro terminal.${NC}"
    elif [ "$TERMINAL_COUNT" -gt 1 ]; then
        printf '%b\n' "${RED}Aviso: el stream anterior es invalido: declaro ${TERMINAL_COUNT} terminales.${NC}"
    fi
}

activate_stream() {
    local stream="$1" metadata
    [ "$stream" = "$CURRENT_STREAM" ] && return 0
    [ -z "$CURRENT_STREAM" ] || finish_current_stream
    CURRENT_FORMAT=$(stream_format "$stream") || {
        echo "ERROR: la ruta manual no es *.events.jsonl ni *.stream.jsonl: $stream" >&2
        return 1
    }
    CURRENT_STREAM="$stream"
    LAST_LINE=0; PREV_EMS=""; RUN_RUNTIME=""; RUN_AGENT=""; RUN_MODEL=""; TERMINAL_COUNT=0
    JQ_FILTER_PATH="$TMP_STATE/filter.jq"
    write_jq_filter "$JQ_FILTER_PATH" "$CURRENT_FORMAT" || return 1
    if [ "$CURRENT_FORMAT" = neutral ]; then
        metadata=$(neutral_run_metadata "$stream")
        IFS=$'\t' read -r RUN_RUNTIME RUN_AGENT RUN_MODEL <<< "$metadata"
    fi
    parse_stream_header "$stream" "$CURRENT_FORMAT" "$RUN_RUNTIME" "$RUN_AGENT" "$RUN_MODEL"
}

print_usage() {
    echo "Uso: stream-watch.sh [<ruta-al-stream>] [--issues <n1,n2,...>] [--newer-than <epoch-segundos>]"
}

main() {
    local repo_top pinned_path="" stream
    repo_top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git" >&2; return 1; }
    if [ -f "$repo_top/.claude-plugin/plugin.json" ]; then
        echo "ERROR: scripts/stream-watch.sh es del plugin publicado y solo aplica al consumidor." >&2
        return 1
    fi
    while [ $# -gt 0 ]; do
        case "$1" in
            --issues)
                [ $# -ge 2 ] || { echo "ERROR: falta el valor de --issues" >&2; return 2; }
                ISSUES_CSV="$2"; shift 2
                ;;
            --newer-than)
                [ $# -ge 2 ] || { echo "ERROR: falta el valor de --newer-than" >&2; return 2; }
                case "$2" in *[!0-9]*|"") echo "ERROR: --newer-than debe ser un epoch en segundos" >&2; return 2 ;; esac
                NEWER_THAN="$2"; shift 2
                ;;
            --help|-h) print_usage; return 0 ;;
            -*) echo "ERROR: opcion desconocida: $1" >&2; return 2 ;;
            *)
                [ -z "$pinned_path" ] || { echo "ERROR: solo se admite una ruta manual" >&2; return 2; }
                pinned_path="$1"; shift
                ;;
        esac
    done
    [ -z "$pinned_path" ] || [ -f "$pinned_path" ] || { echo "ERROR: no existe el stream indicado: $pinned_path" >&2; return 1; }
    if [ -n "$pinned_path" ] && ! stream_format "$pinned_path" >/dev/null; then
        echo "ERROR: la ruta manual no es *.events.jsonl ni *.stream.jsonl: $pinned_path" >&2
        return 1
    fi
    command -v jq >/dev/null 2>&1 || { echo "ERROR: este visor requiere jq." >&2; return 1; }
    TMP_STATE=$(mktemp -d "${TMPDIR:-/tmp}/stream-watch.XXXXXX") || return 1
    trap 'rm -rf "$TMP_STATE"' EXIT
    trap 'rm -rf "$TMP_STATE"; exit 130' INT TERM
    printf '%b\n' "${CYAN}${BOLD}Mefisto -- visor run-events.v1${NC}"
    while true; do
        stream="${pinned_path:-$(discover_stream)}"
        if [ -n "$stream" ] && [ "$stream" != "$CURRENT_STREAM" ]; then
            activate_stream "$stream" || return 1
        fi
        [ -n "$CURRENT_STREAM" ] && process_new_lines "$CURRENT_STREAM"
        sleep "$POLL_INTERVAL"
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
