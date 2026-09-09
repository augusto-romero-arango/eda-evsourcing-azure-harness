#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"; TARGET="$REPO_ROOT/scripts/stream-watch.sh"
PASS=0; FAIL=0; pass(){ echo "  PASS: $1"; PASS=$((PASS+1)); }; fail(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
command -v jq >/dev/null 2>&1 || { echo 'ERROR: jq requerido' >&2; exit 1; }
extract_fn(){ awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p{print} p && /^}/{p=0}' "$TARGET"; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; NC=""; _REPO_TOP="$TMP"
for fn in write_jq_filter stream_matches_issues stream_is_newer_than newest_matching discover_stream stream_format parse_stream_header is_missing fmt_time_hhmmss fmt_delta_s ms_to_s render_row process_new_lines; do eval "$(extract_fn "$fn")"; done
MEFISTO_STATE_DIR="$TMP/.mefisto/pipeline"; MEFISTO_LEGACY_STATE_DIR="$TMP/.claude/pipeline"
mefisto_state_read_paths(){ [ -e "$MEFISTO_STATE_DIR/$1" ] && printf '%s\n' "$MEFISTO_STATE_DIR/$1"; [ -e "$MEFISTO_LEGACY_STATE_DIR/$1" ] && printf '%s\n' "$MEFISTO_LEGACY_STATE_DIR/$1"; }
ISSUES_CSV=""; NEWER_THAN=""; mkdir -p "$MEFISTO_STATE_DIR/logs" "$MEFISTO_LEGACY_STATE_DIR/logs"
cp "$SCRIPT_DIR/fixtures/stream-watch/neutral-claude.events.jsonl" "$MEFISTO_STATE_DIR/logs/tooling-stage-1-writer-20260908-100000-issue-1123.events.jsonl"
cp "$SCRIPT_DIR/fixtures/stream-watch/legacy-claude.stream.jsonl" "$MEFISTO_LEGACY_STATE_DIR/logs/tooling-stage-1-writer-20260908-100000-issue-1123.stream.jsonl"
FOUND=$(discover_stream); [ "${FOUND##*.}" = jsonl ] && [[ "$FOUND" == *.events.jsonl ]] && pass 'prefiere evento neutral canonico' || fail "no prefirio neutral: $FOUND"
JQ_FILTER_PATH="$TMP/neutral.jq"; write_jq_filter "$JQ_FILTER_PATH" neutral; LAST_LINE=0; PREV_EMS=""; process_new_lines "$FOUND" > "$TMP/neutral.out"; OUT=$(<"$TMP/neutral.out")
case "$OUT" in *'inicio runtime=claude'*herramienta*'desenlace run.completed'* ) pass 'renderiza vocabulario neutral y terminal';; *) fail "salida neutral incompleta: $OUT";; esac
case "$OUT" in *SECRETO*|input_summary|error.detail|prompt*|tokens*) fail 'filtra campos sensibles';; *) pass 'no expone texto ni campos sensibles';; esac
cp "$SCRIPT_DIR/fixtures/stream-watch/neutral-opencode-failed.events.jsonl" "$MEFISTO_STATE_DIR/logs/tooling-stage-2-reviewer-20260908-110000-issue-1124.events.jsonl"; FOUND=$(discover_stream); JQ_FILTER_PATH="$TMP/failed.jq"; write_jq_filter "$JQ_FILTER_PATH" neutral; LAST_LINE=0; PREV_EMS=""; process_new_lines "$FOUND" > "$TMP/failed.out"; grep -q 'no termino con exito' "$TMP/failed.out" && pass 'terminal fallido no se presenta como exito' || fail 'no marco fallo'
rm "$MEFISTO_STATE_DIR/logs"/*.events.jsonl; FOUND=$(discover_stream); [[ "$FOUND" == *.stream.jsonl ]] && pass 'usa fallback Claude historico sin neutral' || fail 'no uso fallback'; JQ_FILTER_PATH="$TMP/legacy.jq"; write_jq_filter "$JQ_FILTER_PATH" legacy-claude; LAST_LINE=0; PREV_EMS=""; process_new_lines "$FOUND" > "$TMP/legacy.out"; grep -q 'legacy Claude' "$TMP/legacy.out" && pass 'rotula fallback legacy' || fail 'no rotulo legacy'
printf '%s' '{"v":1,"type":"message"' > "$TMP/partial.events.jsonl"; JQ_FILTER_PATH="$TMP/neutral.jq"; LAST_LINE=0; process_new_lines "$TMP/partial.events.jsonl" > "$TMP/partial.out"; [ "$LAST_LINE" -eq 0 ] && grep -q parcial "$TMP/partial.out" && pass 'linea parcial se reintenta' || fail 'linea parcial no se retuvo'
printf '%s\n' '{corrupta}' '{"v":1,"type":"message","ts":"2026-09-08T10:00:00Z","role":"assistant","text":"SECRETO"}' > "$TMP/corrupt.events.jsonl"; LAST_LINE=0; process_new_lines "$TMP/corrupt.events.jsonl" > "$TMP/corrupt.out"; [ "$LAST_LINE" -eq 2 ] && grep -q corrupta "$TMP/corrupt.out" && pass 'linea corrupta se omite visiblemente' || fail 'linea corrupta no degrado'
ISSUES_CSV=1123; stream_matches_issues "stage-1-a-issue-1123.events.jsonl" "$ISSUES_CSV" && ! stream_matches_issues "stage-1-a-issue-11230.events.jsonl" "$ISSUES_CSV" && pass 'filtro de issue es exacto' || fail 'filtro de issue incorrecto'
ISSUES_CSV=""; NEWER_THAN=9999999999; [ -z "$(discover_stream)" ] && pass 'filtro newer-than conserva semantica' || fail 'newer-than incorrecto'
NEWER_THAN=""; HEADER=$(parse_stream_header '/tmp/ruta con espacios/stage-3-agent-issue-7.events.jsonl' neutral); case "$HEADER" in *neutral*'issue #7'*'stage 3'*) pass 'header informa formato, issue y stage';; *) fail "header: $HEADER";; esac
echo "Resumen: $PASS pass, $FAIL fail"; [ "$FAIL" -eq 0 ]
