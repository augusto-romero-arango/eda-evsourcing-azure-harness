#!/usr/bin/env bash
# stream-watch.sh -- Visor de solo lectura de ejecuciones de agente.
#
# Consume primero run-events.v1 (*.events.jsonl) desde el estado canonico
# .mefisto/pipeline y conserva *.stream.jsonl como compatibilidad rotulada para
# stages Claude historicos. No interpreta wire formats en el camino neutral.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git" >&2; exit 1; }
if [ -f "$_REPO_TOP/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/stream-watch.sh es del plugin publicado y solo aplica al consumidor." >&2
    exit 1
fi
# MEF-ADR-0053: el helper resuelve .mefisto primero y .claude solo para lectura.
source "$SCRIPT_DIR/_pipeline-common.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
POLL_INTERVAL=1
ISSUES_CSV=""; NEWER_THAN=""; LAST_LINE=0; PREV_EMS=""; CURRENT_STREAM=""; CURRENT_FORMAT=""; JQ_FILTER_PATH=""; TMP_STATE=""; RUN_RUNTIME=""; RUN_AGENT=""; RUN_MODEL=""

# write_jq_filter <dest> <neutral|legacy-claude>
# El filtro neutral solo consulta campos de run-events.v1 permitidos para el pane;
# en particular nunca serializa text, input_summary, error.detail ni tokens.
write_jq_filter() {
    local dest="$1" format="$2"
    if [ "$format" = "neutral" ]; then
        cat > "$dest" <<'JQ'
def epoch_ms: try (.ts | fromdateiso8601 * 1000) catch null;
def cell: if . == null or . == "" then "-" else tostring end;
def row: map(cell) | @tsv;
if type != "object" then empty else
  (epoch_ms) as $ts |
  if .type == "run.started" then ["started", $ts, .runtime, .agent, .model] | row
  elif .type == "message" then ["message", $ts, .role, .kind] | row
  elif .type == "tool.started" then ["tool-started", $ts, .tool] | row
  elif .type == "tool.completed" then ["tool-completed", $ts, .tool, .ok, .duration_ms] | row
  elif .type == "run.completed" or .type == "run.failed" then ["terminal", $ts, .type, .status, .runtime, .agent, .model, .duration_ms, (.error.kind // null)] | row
  else empty end
end
JQ
    else
        # Compatibilidad aislada: este es el unico parser que conoce Claude.
        cat > "$dest" <<'JQ'
def epoch_ms: try (.timestamp | fromdateiso8601 * 1000) catch null;
def cell: if . == null or . == "" then "-" else tostring end;
def row: map(cell) | @tsv;
if type != "object" then empty else
  (epoch_ms) as $ts |
  if .type == "assistant" then
    (.message.content // [])[]? | if .type == "tool_use" then ["legacy-tool", $ts, .name] | row elif .type == "text" then ["legacy-message", $ts, "texto"] | row elif .type == "thinking" then ["legacy-message", $ts, "pensamiento"] | row else empty end
  elif .type == "result" then ["legacy-terminal", $ts, .is_error, .duration_ms, .num_turns] | row
  else empty end
end
JQ
    fi
}

stream_matches_issues() {
    local base="$1" csv="$2" issue
    [ -n "$csv" ] || return 0
    for issue in ${csv//,/ }; do case "$base" in *"-issue-${issue}.events.jsonl"|*"-issue-${issue}-"*".events.jsonl"|*"-issue-${issue}.stream.jsonl"|*"-issue-${issue}-"*".stream.jsonl") return 0;; esac; done
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
        stream_matches_issues "$(basename "$candidate")" "$ISSUES_CSV" || continue
        stream_is_newer_than "$candidate" "$NEWER_THAN" || continue
        printf '%s\n' "$candidate"; return 0
    done < <(ls -t "$dir"/$pattern 2>/dev/null)
}

# discover_stream: consulta cada root de lectura en orden canonico/legacy. En
# cada root el evento neutral gana; el stream Claude solo es fallback si no hay
# un .events.jsonl con el mismo stem.
discover_stream() {
    local dir candidate stem
    while IFS= read -r dir; do
        candidate=$(newest_matching "$dir" '*.events.jsonl')
        [ -n "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done < <(mefisto_state_read_paths logs)
    while IFS= read -r dir; do
        candidate=$(newest_matching "$dir" '*.stream.jsonl')
        [ -z "$candidate" ] && continue
        stem="${candidate%.stream.jsonl}"
        [ -f "$stem.events.jsonl" ] && continue
        printf '%s\n' "$candidate"; return 0
    done < <(mefisto_state_read_paths logs)
}

stream_format() { case "$1" in *.events.jsonl) echo neutral;; *.stream.jsonl) echo legacy-claude;; *) echo unknown;; esac; }

parse_stream_header() {
    local path="$1" format="$2" base stage issue state
    base=$(basename "$path"); stage=$(printf '%s' "$base" | sed -n 's/.*stage-\([0-9][0-9]*\).*/\1/p'); issue=$(printf '%s' "$base" | sed -n 's/.*-issue-\([0-9][0-9]*\).*/\1/p')
    state=manual
    case "$path" in "$_REPO_TOP/.mefisto/"*) state=canonico;; "$_REPO_TOP/.claude/"*) state=legacy;; esac
    printf '%b\n' "${CYAN}${BOLD}=== visor ${format} ===${NC}"
    printf '%b\n' "${CYAN}estado: ${state} | ruta: ${path}${NC}"
    [ -n "$issue" ] && printf 'issue #%s  ' "$issue"; [ -n "$stage" ] && printf 'stage %s' "$stage"; [ -n "$issue$stage" ] && echo ""
}

is_missing() { case "$1" in ""|"-"|null) return 0;; *) return 1;; esac; }
fmt_time_hhmmss() { is_missing "$1" && { echo '--:--:--'; return; }; date -r "$(( $1 / 1000 ))" +%H:%M:%S 2>/dev/null || date -d "@$(( $1 / 1000 ))" +%H:%M:%S 2>/dev/null || echo '--:--:--'; }
fmt_delta_s() { is_missing "$1" || is_missing "$2" && { printf '%7s' '-'; return; }; awk -v a="$1" -v b="$2" 'BEGIN { printf "+%5.1fs", (b-a)/1000 }'; }
ms_to_s() { is_missing "$1" && { echo '?'; return; }; awk -v v="$1" 'BEGIN { printf "%.1f", v/1000 }'; }

render_row() {
    local kind="$1" ems="$2" a="$3" b="$4" c="$5" d="$6" e="$7" f="$8" g="$9" now delta
    now=$(fmt_time_hhmmss "$ems"); delta=$(fmt_delta_s "$PREV_EMS" "$ems")
    case "$kind" in
        started) RUN_RUNTIME="$a"; RUN_AGENT="$b"; RUN_MODEL="$c"; printf '%b\n' "${BLUE}[${now}]${NC} ${delta}  inicio runtime=${a} agente=${b} modelo=${c}" ;;
        message) printf '%b\n' "${BLUE}[${now}]${NC} ${delta}  mensaje (${b:-sin-clase})" ;;
        tool-started) printf '%b\n' "${BLUE}[${now}]${NC} ${delta}  herramienta ${BOLD}${a}${NC} iniciada" ;;
        tool-completed) printf '%b\n' "${BLUE}[${now}]${NC} ${delta}  herramienta ${BOLD}${a}${NC}: $( [ "$b" = true ] && echo ok || echo fallo ) ($(ms_to_s "$c")s)" ;;
        terminal) is_missing "$c" && c="$RUN_RUNTIME"; is_missing "$d" && d="$RUN_AGENT"; is_missing "$e" && e="$RUN_MODEL"; printf '%b\n' "${BOLD}--- desenlace ${a} status=${b} runtime=${c} agente=${d} modelo=${e} duracion=$(ms_to_s "$f")s${NC}"; [ "$a" = run.completed ] || printf '%b\n' "${RED}La corrida no termino con exito.${NC}" ;;
        legacy-tool) printf '%b\n' "${YELLOW}[legacy Claude]${NC} [${now}] ${delta}  herramienta ${a}" ;;
        legacy-message) printf '%b\n' "${YELLOW}[legacy Claude]${NC} [${now}] ${delta}  ${a}" ;;
        legacy-terminal) printf '%b\n' "${YELLOW}[legacy Claude]${NC} cierre: $( [ "$a" = true ] && echo ERROR || echo OK ) duracion=$(ms_to_s "$b")s turnos=${c}" ;;
    esac
    PREV_EMS="$ems"
}

# Una linea corrupta se consume para que un archivo historico corrupto no bloquee
# el pane; se anuncia la degradacion. Una linea parcial sin salto final se retiene.
process_new_lines() {
    local stream="$1" line line_num rows rc
    [ -f "$stream" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line_num=$((LAST_LINE + 1))
        if ! printf '%s' "$line" | jq empty >/dev/null 2>&1; then
            if [ "$(tail -c 1 "$stream" 2>/dev/null)" != "" ]; then printf '%b\n' "${YELLOW}Aviso: linea parcial; se reintentara.${NC}"; return 0; fi
            printf '%b\n' "${YELLOW}Aviso: linea corrupta omitida.${NC}"; LAST_LINE=$line_num; continue
        fi
        rows=$(printf '%s' "$line" | jq -r -f "$JQ_FILTER_PATH" 2>/dev/null); rc=$?
        [ "$rc" -eq 0 ] || { printf '%b\n' "${YELLOW}Aviso: evento no renderizable omitido.${NC}"; LAST_LINE=$line_num; continue; }
        LAST_LINE=$line_num
        while IFS=$'\t' read -r kind ems a b c d e f g; do [ -n "$kind" ] && render_row "$kind" "$ems" "$a" "$b" "$c" "$d" "$e" "$f" "$g"; done <<< "$rows"
    done < <(sed -n "$((LAST_LINE + 1)),\$p" "$stream" 2>/dev/null)
}

print_usage() { echo 'Uso: stream-watch.sh [ruta] [--issues n1,n2] [--newer-than epoch]'; }
main() {
    local pinned_path="" stream format
    while [ $# -gt 0 ]; do case "$1" in --issues) ISSUES_CSV="$2"; shift 2;; --newer-than) NEWER_THAN="$2"; shift 2;; --help|-h) print_usage; return;; *) pinned_path="$1"; shift;; esac; done
    [ -z "$pinned_path" ] || [ -f "$pinned_path" ] || { echo "ERROR: no existe el stream indicado: $pinned_path" >&2; return 1; }
    command -v jq >/dev/null 2>&1 || { echo 'ERROR: este visor requiere jq.' >&2; return 1; }
    TMP_STATE=$(mktemp -d "${TMPDIR:-/tmp}/stream-watch.XXXXXX") || return 1; trap 'rm -rf "$TMP_STATE"' EXIT INT TERM
    printf '%b\n' "${CYAN}${BOLD}Mefisto -- visor neutral run-events.v1${NC}"
    while true; do
        stream="${pinned_path:-$(discover_stream)}"
        if [ -n "$stream" ] && [ "$stream" != "$CURRENT_STREAM" ]; then
            CURRENT_STREAM="$stream"; CURRENT_FORMAT=$(stream_format "$stream"); LAST_LINE=0; PREV_EMS=""; RUN_RUNTIME=""; RUN_AGENT=""; RUN_MODEL=""; JQ_FILTER_PATH="$TMP_STATE/filter.jq"; write_jq_filter "$JQ_FILTER_PATH" "$CURRENT_FORMAT"; parse_stream_header "$stream" "$CURRENT_FORMAT"
        fi
        [ -n "$CURRENT_STREAM" ] && process_new_lines "$CURRENT_STREAM"; sleep "$POLL_INTERVAL"
    done
}
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
