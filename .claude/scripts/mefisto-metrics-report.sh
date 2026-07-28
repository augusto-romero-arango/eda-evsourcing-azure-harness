#!/usr/bin/env bash
# mefisto-metrics-report.sh -- Reporte agregado de metricas del pipeline interno (issue #427)
#
# Uso:
#   .claude/scripts/mefisto-metrics-report.sh
#   .claude/scripts/mefisto-metrics-report.sh --desde 2026-07-01
#
# Responde "donde se van los 30 minutos" de un issue de tooling interno,
# agregando .claude/pipeline/pipeline-history.jsonl (una linea por corrida del
# pipeline mefisto-tooling, con agents.<agente>.metrics derivado de la traza
# por #426): ranking de herramientas, reparto API vs no-API del wall-clock
# (agregado, por corrida y writer vs reviewer) y deriva temporal semanal/
# mensual. Solo lectura: nunca escribe en .claude/pipeline/.
#
# El historico es MIXTO por diseno (CA-5): las corridas previas a #426 no
# traen "metrics" (solo la duracion plana de siempre) y se reportan aparte
# bajo SIN INSTRUMENTAR: toda cifra derivada de "metrics" declara n= sobre
# cuantas corridas se calculo.
#
# Solo requiere pipeline-history.jsonl: el detalle por tool call ya viaja en
# agents.<agente>.metrics (#426), asi que no hace falta bajar a los archivos
# .claude/pipeline/metrics/*.json por stage (ver notas tecnicas del issue).

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_mefisto-common.sh"
assert_in_mefisto || exit 1

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: este reporte requiere jq (no encontrado en PATH). Instalalo (p.ej. 'brew install jq') y reintenta." >&2
    exit 1
fi

# compute_metrics_report_json <history_file> <desde>
#
# Agrega pipeline-history.jsonl en un unico objeto JSON compacto: ranking de
# herramientas (CA-2), reparto del wall-clock agregado/por-corrida/writer-vs-
# reviewer (CA-3), series semanal y mensual (CA-4) y el conteo de corridas
# "sin instrumentar" (CA-5). <desde> es "" (todo el historico) o "YYYY-MM-DD".
# Tolera archivo ausente/vacio (contenido "") y lineas corruptas (se ignoran,
# igual que compute_stage_metrics). Nunca aborta: ante cualquier fallo de jq
# devuelve vacio y el caller decide.
compute_metrics_report_json() {
    local history_file="$1" desde="$2"
    local raw_content=""
    [ -f "$history_file" ] && raw_content="$(cat "$history_file" 2>/dev/null || true)"

    printf '%s' "$raw_content" | jq -R -s -c --arg desde "$desde" '
def median:
  sort as $s
  | ($s | length) as $n
  | if $n == 0 then null
    elif ($n % 2) == 1 then $s[($n - 1) / 2]
    else ($s[$n / 2 - 1] + $s[$n / 2]) / 2
    end;

def avgOrNull:
  if length == 0 then null else (add / length) end;

def parse_started:
  if . == null then null
  else (try (strptime("%Y%m%d-%H%M%S") | mktime) catch null)
  end;

def run_api_ms: ((.agents.writer.metrics.duration_api_ms // 0) + (.agents.reviewer.metrics.duration_api_ms // 0));
def run_non_api_ms: ((.agents.writer.metrics.non_api_ms // 0) + (.agents.reviewer.metrics.non_api_ms // 0));
def run_tool_calls_arr: (((.agents.writer.metrics.tool_calls // []) + (.agents.reviewer.metrics.tool_calls // [])));
def run_tool_ms: ([run_tool_calls_arr[] | (.duration_ms_sum // 0)] | add // 0);
def run_tool_calls_count: ([run_tool_calls_arr[] | .count] | add // 0);
def run_turns: ((.agents.writer.metrics.turns // 0) + (.agents.reviewer.metrics.turns // 0));
def run_tokens_input: ((.agents.writer.metrics.tokens.input // 0) + (.agents.reviewer.metrics.tokens.input // 0));
def run_tokens_output: ((.agents.writer.metrics.tokens.output // 0) + (.agents.reviewer.metrics.tokens.output // 0));
def run_tokens_cache_read: ((.agents.writer.metrics.tokens.cache_read // 0) + (.agents.reviewer.metrics.tokens.cache_read // 0));
def run_tokens_cache_creation: ((.agents.writer.metrics.tokens.cache_creation // 0) + (.agents.reviewer.metrics.tokens.cache_creation // 0));

def week_key: if ._ts == null then null else (._ts | gmtime | strftime("%G-W%V")) end;
def month_key: if ._ts == null then null else (._ts | gmtime | strftime("%Y-%m")) end;

def period_summary(keyfn):
  group_by(keyfn)
  | map(
      . as $group
      | ($group[0] | keyfn) as $period
      | ($group | map(select(._has_metrics))) as $g_instr
      | ($g_instr | map(run_tokens_cache_read) | add // 0) as $cr_total
      | ($g_instr | map(run_tokens_cache_creation) | add // 0) as $cc_total
      | {
          period: $period,
          n_total: ($group | length),
          n_instrumented: ($g_instr | length),
          wall_mean_s: ($group | map(._wall_s) | map(select(. != null)) | avgOrNull),
          wall_median_s: ($group | map(._wall_s) | map(select(. != null)) | median),
          turns_mean: ($g_instr | map(run_turns) | avgOrNull),
          tool_calls_mean: ($g_instr | map(run_tool_calls_count) | avgOrNull),
          tokens_input_mean: ($g_instr | map(run_tokens_input) | avgOrNull),
          tokens_output_mean: ($g_instr | map(run_tokens_output) | avgOrNull),
          cache_read_mean: ($g_instr | map(run_tokens_cache_read) | avgOrNull),
          cache_creation_mean: ($g_instr | map(run_tokens_cache_creation) | avgOrNull),
          cache_read_pct: (if ($cr_total + $cc_total) > 0 then ($cr_total / ($cr_total + $cc_total) * 100) else null end),
          non_api_ms_mean: ($g_instr | map(run_non_api_ms) | avgOrNull)
        }
    )
  | sort_by(.period);

def summarize_agent:
  {
    n: length,
    turns_mean: (map(.turns) | map(select(. != null)) | avgOrNull),
    cost_usd_mean: (map(.cost_usd) | map(select(. != null)) | avgOrNull),
    cost_usd_total: (map(.cost_usd) | map(select(. != null)) | (if length == 0 then null else add end)),
    duration_ms_mean: (map(.duration_ms) | map(select(. != null)) | avgOrNull),
    duration_api_ms_mean: (map(.duration_api_ms) | map(select(. != null)) | avgOrNull),
    non_api_ms_mean: (map(.non_api_ms) | map(select(. != null)) | avgOrNull),
    tokens_input_mean: (map(.tokens.input) | map(select(. != null)) | avgOrNull),
    tokens_output_mean: (map(.tokens.output) | map(select(. != null)) | avgOrNull),
    tokens_cache_read_mean: (map(.tokens.cache_read) | map(select(. != null)) | avgOrNull),
    tokens_cache_creation_mean: (map(.tokens.cache_creation) | map(select(. != null)) | avgOrNull),
    tool_calls_mean: (map([(.tool_calls // [])[] | .count] | add // 0) | avgOrNull)
  };

def delta_of(f; l):
  {
    first: f,
    last: l,
    pct: (if (f // 0) == 0 then null else (((l // 0) - f) / f * 100) end)
  };

(split("\n") | map(select(length > 0)) | map(try fromjson catch empty) | map(select(type == "object"))) as $raw

| ($raw | map(select(.pipeline == "mefisto-tooling"))) as $all0

| ($all0 | map(select(
    ($desde == "") or
    ((( .started // "")[0:8]) as $d8 | ($d8 | length) == 8 and $d8 >= ($desde | gsub("-"; "")))
  ))) as $all

| ($all | map(. + {
    _wall_s: (if (.agents.writer.duration == null and .agents.reviewer.duration == null) then null
              else ((.agents.writer.duration // 0) + (.agents.reviewer.duration // 0)) end),
    _has_metrics: (((.agents.writer.metrics? // null) != null) or ((.agents.reviewer.metrics? // null) != null)),
    _ts: (.started | parse_started)
  })) as $entries

| ($entries | length) as $total_n
| ($entries | map(select(._has_metrics | not))) as $legacy
| ($entries | map(select(._has_metrics))) as $instr
| ($legacy | length) as $legacy_n
| ($instr | length) as $instr_n

| ( ($instr | map(run_tool_calls_arr) | add) // [] ) as $tool_blocks
| ($tool_blocks
    | group_by(.name)
    | map({
        name: .[0].name,
        calls: (map(.count) | add),
        time_ms: (map(.duration_ms_sum // 0) | add),
        median_ms: (map(.duration_ms_median) | map(select(. != null)) | median)
      })
  ) as $tool_ranking_raw
| ($tool_ranking_raw | map(.time_ms) | add // 0) as $tool_time_grand_total
| ($tool_ranking_raw
    | map(. + {pct: (if $tool_time_grand_total > 0 then (.time_ms / $tool_time_grand_total * 100) else 0 end)})
    | sort_by(-.time_ms)
  ) as $tool_ranking

| ($instr | map(.agents.writer.metrics) | map(select(. != null))) as $wr_metrics
| ($instr | map(.agents.reviewer.metrics) | map(select(. != null))) as $rv_metrics

| ($instr | map(run_api_ms) | add // 0) as $agg_api_ms
| ($instr | map(run_non_api_ms) | add // 0) as $agg_non_api_ms
| ($instr | map(run_tool_ms) | add // 0) as $agg_tool_ms

| ($instr | sort_by(.started) | map({
    issue: .issue,
    started: .started,
    state: .state,
    wall_s: ._wall_s,
    api_ms: run_api_ms,
    non_api_ms: run_non_api_ms,
    tool_ms: run_tool_ms,
    pct_api: (if (run_api_ms + run_non_api_ms) > 0 then (run_api_ms / (run_api_ms + run_non_api_ms) * 100) else null end)
  })) as $per_run

| ($entries | period_summary(week_key)) as $weekly
| ($entries | period_summary(month_key)) as $monthly

| ($monthly | map(select(.n_instrumented > 0))) as $monthly_with_data
| (if ($monthly_with_data | length) >= 2 then
    ($monthly_with_data[0]) as $f
    | ($monthly_with_data[-1]) as $l
    | {
        first: $f,
        last: $l,
        deltas: [
          ({key: "wall_mean_s", label: "Wall medio (issue)", unit: "s"} + delta_of($f.wall_mean_s; $l.wall_mean_s)),
          ({key: "turns_mean", label: "Turnos medios", unit: "count1"} + delta_of($f.turns_mean; $l.turns_mean)),
          ({key: "tool_calls_mean", label: "Tool calls medios", unit: "count1"} + delta_of($f.tool_calls_mean; $l.tool_calls_mean)),
          ({key: "tokens_input_mean", label: "Tokens in medios", unit: "count0"} + delta_of($f.tokens_input_mean; $l.tokens_input_mean)),
          ({key: "non_api_s_mean", label: "No-API medio", unit: "s"} + delta_of(($f.non_api_ms_mean // 0) / 1000; ($l.non_api_ms_mean // 0) / 1000))
        ]
      }
  else null end) as $comparison

| ($legacy | sort_by(.started) | map({issue: .issue, started: .started, state: .state})) as $legacy_list

| {
    meta: {
      total: $total_n,
      instrumented: $instr_n,
      legacy: $legacy_n,
      desde: (if $desde == "" then null else $desde end),
      oldest_started: ($entries | map(.started) | map(select(. != null)) | (sort | .[0])),
      newest_started: ($entries | map(.started) | map(select(. != null)) | (sort | .[-1]))
    },
    tool_ranking: $tool_ranking,
    wallclock: {
      aggregate: {
        n: $instr_n,
        api_ms: $agg_api_ms,
        non_api_ms: $agg_non_api_ms,
        tool_ms: $agg_tool_ms,
        pct_api: (if ($agg_api_ms + $agg_non_api_ms) > 0 then ($agg_api_ms / ($agg_api_ms + $agg_non_api_ms) * 100) else null end),
        pct_non_api: (if ($agg_api_ms + $agg_non_api_ms) > 0 then ($agg_non_api_ms / ($agg_api_ms + $agg_non_api_ms) * 100) else null end),
        pct_tool_of_non_api: (if $agg_non_api_ms > 0 then ($agg_tool_ms / $agg_non_api_ms * 100) else null end)
      },
      per_run: $per_run,
      writer: ($wr_metrics | summarize_agent),
      reviewer: ($rv_metrics | summarize_agent)
    },
    series: {
      weekly: $weekly,
      monthly: $monthly
    },
    legacy: {
      count: $legacy_n,
      issues: $legacy_list
    },
    comparison: $comparison
  }
' 2>/dev/null
}

# fmt_dur_s <segundos|"">
#
# "Xm Ys" si >= 60s, "Ys" si no, "-" si vacio/null. Acepta enteros o floats
# (se redondean al segundo).
fmt_dur_s() {
    local s="$1"
    if [ -z "$s" ] || [ "$s" = "null" ]; then echo "-"; return 0; fi
    local total m r
    total=$(printf '%.0f' "$s")
    m=$((total / 60))
    r=$((total % 60))
    if [ "$m" -gt 0 ]; then
        printf '%dm%02ds' "$m" "$r"
    else
        printf '%ds' "$r"
    fi
}

# fmt_pct <numero|"">
fmt_pct() {
    local v="$1"
    if [ -z "$v" ] || [ "$v" = "null" ]; then echo "-"; return 0; fi
    printf '%.1f%%' "$v"
}

# fmt_signed_pct <numero|"">
fmt_signed_pct() {
    local v="$1"
    if [ -z "$v" ] || [ "$v" = "null" ]; then echo "n/d"; return 0; fi
    printf '%+.1f%%' "$v"
}

render_header() {
    local agg="$1"
    local desde total instr legacy oldest newest
    desde=$(jq -r '.meta.desde // "(todo el historico)"' <<<"$agg")
    total=$(jq -r '.meta.total' <<<"$agg")
    instr=$(jq -r '.meta.instrumented' <<<"$agg")
    legacy=$(jq -r '.meta.legacy' <<<"$agg")
    oldest=$(jq -r '.meta.oldest_started // "-"' <<<"$agg")
    newest=$(jq -r '.meta.newest_started // "-"' <<<"$agg")

    echo "=================================================================="
    echo "Mefisto - Reporte agregado de metricas del pipeline interno"
    echo "=================================================================="
    echo "Filtro --desde: $desde"
    echo "Corridas mefisto-tooling en la ventana: $total (instrumentadas: $instr, sin instrumentar: $legacy)"
    if [ "$total" -gt 0 ]; then
        echo "Rango: $oldest -> $newest"
    fi
}

render_tool_ranking() {
    local agg="$1"
    local n count
    n=$(jq -r '.meta.instrumented' <<<"$agg")
    count=$(jq -r '.tool_ranking | length' <<<"$agg")

    echo ""
    echo "------------------------------------------------------------------"
    echo "RANKING DE HERRAMIENTAS (n=$n corridas instrumentadas)"
    echo "------------------------------------------------------------------"

    if [ "$count" -eq 0 ]; then
        echo "(sin tool calls en corridas instrumentadas dentro de la ventana)"
        return 0
    fi

    printf '%-18s %10s %14s %16s %10s\n' "Herramienta" "Llamadas" "Tiempo total" "Mediana/llamada" "% tiempo"
    while IFS=$'\t' read -r name calls time_s median_s pct; do
        local time_disp median_disp pct_disp
        time_disp=$(printf '%.1fs' "$time_s")
        if [ -z "$median_s" ]; then median_disp="-"; else median_disp=$(printf '%.1fs' "$median_s"); fi
        pct_disp=$(fmt_pct "$pct")
        printf '%-18s %10s %14s %16s %10s\n' "$name" "$calls" "$time_disp" "$median_disp" "$pct_disp"
    done < <(jq -r '.tool_ranking[] | [.name, .calls, (.time_ms/1000), (if .median_ms == null then null else (.median_ms/1000) end), .pct] | @tsv' <<<"$agg")
}

render_wallclock() {
    local agg="$1"
    local n
    n=$(jq -r '.wallclock.aggregate.n' <<<"$agg")

    echo ""
    echo "------------------------------------------------------------------"
    echo "REPARTO DEL WALL-CLOCK (n=$n corridas instrumentadas)"
    echo "------------------------------------------------------------------"

    if [ "$n" -eq 0 ]; then
        echo "(sin corridas instrumentadas en la ventana -- ver SIN INSTRUMENTAR)"
        return 0
    fi

    local api_s non_api_s tool_s pct_api pct_non_api pct_tool
    IFS=$'\t' read -r api_s non_api_s tool_s pct_api pct_non_api pct_tool < <(jq -r '
        .wallclock.aggregate
        | [(.api_ms/1000), (.non_api_ms/1000), (.tool_ms/1000), .pct_api, .pct_non_api, .pct_tool_of_non_api]
        | @tsv' <<<"$agg")

    printf 'Agregado: API %ss (%s)  No-API %ss (%s)\n' \
        "$(printf '%.1f' "$api_s")" "$(fmt_pct "$pct_api")" "$(printf '%.1f' "$non_api_s")" "$(fmt_pct "$pct_non_api")"
    printf '  De lo no-API, atribuible a tool calls: %ss (%s del no-API)\n' \
        "$(printf '%.1f' "$tool_s")" "$(fmt_pct "$pct_tool")"

    echo ""
    echo "Por corrida:"
    printf '%-8s %-17s %-11s %8s %8s %8s %8s %7s\n' "Issue" "Inicio" "Estado" "Wall" "API" "No-API" "Tools" "%API"
    while IFS=$'\t' read -r issue started state wall_s run_api run_non_api run_tool pct_a; do
        printf '#%-7s %-17s %-11s %7ss %7ss %7ss %7ss %6s\n' \
            "$issue" "$started" "$state" \
            "$(printf '%.0f' "$wall_s")" "$(printf '%.1f' "$run_api")" "$(printf '%.1f' "$run_non_api")" \
            "$(printf '%.1f' "$run_tool")" "$(fmt_pct "$pct_a")"
    done < <(jq -r '.wallclock.per_run[] | [.issue, .started, .state, .wall_s, (.api_ms/1000), (.non_api_ms/1000), (.tool_ms/1000), .pct_api] | @tsv' <<<"$agg")

    echo ""
    echo "Writer vs Reviewer:"
    local w_n w_turns w_tin w_tout w_cread w_ccreate w_cost_mean w_cost_total w_dur w_api w_nonapi
    IFS=$'\t' read -r w_n w_turns w_tin w_tout w_cread w_ccreate w_cost_mean w_cost_total w_dur w_api w_nonapi < <(jq -r '
        .wallclock.writer
        | [.n, .turns_mean, .tokens_input_mean, .tokens_output_mean, .tokens_cache_read_mean, .tokens_cache_creation_mean,
           .cost_usd_mean, .cost_usd_total,
           (if .duration_ms_mean == null then null else .duration_ms_mean/1000 end),
           (if .duration_api_ms_mean == null then null else .duration_api_ms_mean/1000 end),
           (if .non_api_ms_mean == null then null else .non_api_ms_mean/1000 end)]
        | @tsv' <<<"$agg")
    local r_n r_turns r_tin r_tout r_cread r_ccreate r_cost_mean r_cost_total r_dur r_api r_nonapi
    IFS=$'\t' read -r r_n r_turns r_tin r_tout r_cread r_ccreate r_cost_mean r_cost_total r_dur r_api r_nonapi < <(jq -r '
        .wallclock.reviewer
        | [.n, .turns_mean, .tokens_input_mean, .tokens_output_mean, .tokens_cache_read_mean, .tokens_cache_creation_mean,
           .cost_usd_mean, .cost_usd_total,
           (if .duration_ms_mean == null then null else .duration_ms_mean/1000 end),
           (if .duration_api_ms_mean == null then null else .duration_api_ms_mean/1000 end),
           (if .non_api_ms_mean == null then null else .non_api_ms_mean/1000 end)]
        | @tsv' <<<"$agg")

    printf '%-24s %14s %14s\n' "" "Writer" "Reviewer"
    printf '%-24s %14s %14s\n' "Corridas (n)" "$w_n" "$r_n"
    printf '%-24s %14s %14s\n' "Turnos medios" "$(_num1 "$w_turns")" "$(_num1 "$r_turns")"
    printf '%-24s %14s %14s\n' "Tokens in medios" "$(_num0 "$w_tin")" "$(_num0 "$r_tin")"
    printf '%-24s %14s %14s\n' "Tokens out medios" "$(_num0 "$w_tout")" "$(_num0 "$r_tout")"
    printf '%-24s %14s %14s\n' "Cache read medio" "$(_num0 "$w_cread")" "$(_num0 "$r_cread")"
    printf '%-24s %14s %14s\n' "Cache creation medio" "$(_num0 "$w_ccreate")" "$(_num0 "$r_ccreate")"
    printf '%-24s %14s %14s\n' "Costo medio (USD)" "$(_money "$w_cost_mean")" "$(_money "$r_cost_mean")"
    printf '%-24s %14s %14s\n' "Costo total (USD)" "$(_money "$w_cost_total")" "$(_money "$r_cost_total")"
    printf '%-24s %14s %14s\n' "Duracion media" "$(fmt_dur_s "$w_dur")" "$(fmt_dur_s "$r_dur")"
    printf '%-24s %14s %14s\n' "  de la cual API" "$(fmt_dur_s "$w_api")" "$(fmt_dur_s "$r_api")"
    printf '%-24s %14s %14s\n' "  de la cual no-API" "$(fmt_dur_s "$w_nonapi")" "$(fmt_dur_s "$r_nonapi")"
}

_num1() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then echo "-"; else printf '%.1f' "$1"; fi
}

_num0() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then echo "-"; else printf '%.0f' "$1"; fi
}

_money() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then echo "-"; else printf '%.2f' "$1"; fi
}

render_period_table() {
    local agg="$1" path="$2" title="$3"
    echo ""
    echo "------------------------------------------------------------------"
    echo "$title"
    echo "------------------------------------------------------------------"
    local count
    count=$(jq -r "${path} | length" <<<"$agg")
    if [ "$count" -eq 0 ]; then
        echo "(sin datos en la ventana)"
        return 0
    fi
    printf '%-10s %-9s %10s %10s %8s %8s %10s %8s\n' \
        "Periodo" "n(t/i)" "Wall.med" "Wall.mna" "Turnos" "Tools" "Tok.in" "cache%"
    while IFS=$'\t' read -r period n_total n_instr wall_mean wall_median turns tools tin cache_pct; do
        local turns_disp tools_disp tin_disp cache_disp
        turns_disp=$(_num1 "$turns")
        tools_disp=$(_num1 "$tools")
        tin_disp=$(_num0 "$tin")
        if [ -z "$cache_pct" ] || [ "$cache_pct" = "null" ]; then cache_disp="-"; else cache_disp=$(printf '%.1f%%' "$cache_pct"); fi
        printf '%-10s %-9s %10s %10s %8s %8s %10s %8s\n' \
            "$period" "${n_total}/${n_instr}" "$(fmt_dur_s "$wall_mean")" "$(fmt_dur_s "$wall_median")" \
            "$turns_disp" "$tools_disp" "$tin_disp" "$cache_disp"
    done < <(jq -r "${path}[] | [.period, .n_total, .n_instrumented, .wall_mean_s, .wall_median_s, .turns_mean, .tool_calls_mean, .tokens_input_mean, .cache_read_pct] | @tsv" <<<"$agg")
}

render_comparison() {
    local agg="$1"
    echo ""
    echo "------------------------------------------------------------------"
    echo "RESUMEN: QUE CRECIO (primer vs ultimo mes con corridas instrumentadas)"
    echo "------------------------------------------------------------------"

    local has_cmp
    has_cmp=$(jq -r 'if .comparison == null then "no" else "yes" end' <<<"$agg")
    if [ "$has_cmp" = "no" ]; then
        echo "(se necesitan al menos 2 meses con corridas instrumentadas para comparar)"
        return 0
    fi

    local fp fn lp ln
    fp=$(jq -r '.comparison.first.period' <<<"$agg")
    fn=$(jq -r '.comparison.first.n_instrumented' <<<"$agg")
    lp=$(jq -r '.comparison.last.period' <<<"$agg")
    ln=$(jq -r '.comparison.last.n_instrumented' <<<"$agg")
    echo "Comparando $fp (n=$fn) vs $lp (n=$ln):"
    echo ""
    printf '%-22s %12s %12s %12s\n' "Metrica" "Primero" "Ultimo" "Variacion"

    while IFS=$'\t' read -r label unit first last pct; do
        local first_disp last_disp
        if [ "$unit" = "s" ]; then
            first_disp=$(fmt_dur_s "$first")
            last_disp=$(fmt_dur_s "$last")
        elif [ "$unit" = "count0" ]; then
            first_disp=$(_num0 "$first")
            last_disp=$(_num0 "$last")
        else
            first_disp=$(_num1 "$first")
            last_disp=$(_num1 "$last")
        fi
        printf '%-22s %12s %12s %12s\n' "$label" "$first_disp" "$last_disp" "$(fmt_signed_pct "$pct")"
    done < <(jq -r '.comparison.deltas[] | [.label, .unit, .first, .last, .pct] | @tsv' <<<"$agg")
}

render_legacy() {
    local agg="$1"
    local count
    count=$(jq -r '.legacy.count' <<<"$agg")
    echo ""
    echo "------------------------------------------------------------------"
    echo "SIN INSTRUMENTAR (n=$count -- corridas previas a #426, solo duracion total)"
    echo "------------------------------------------------------------------"
    if [ "$count" -eq 0 ]; then
        echo "(ninguna en la ventana)"
        return 0
    fi
    while IFS=$'\t' read -r issue started state; do
        printf '#%-8s %-17s %s\n' "$issue" "$started" "$state"
    done < <(jq -r '.legacy.issues[] | [.issue, .started, .state] | @tsv' <<<"$agg")
}

main() {
    local desde=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --desde)
                [ $# -ge 2 ] || { echo "ERROR: --desde requiere un valor YYYY-MM-DD" >&2; exit 1; }
                desde="$2"
                shift 2
                ;;
            --desde=*)
                desde="${1#--desde=}"
                shift
                ;;
            -h|--help)
                cat <<'EOF'
Uso: mefisto-metrics-report.sh [--desde YYYY-MM-DD]

Reporte agregado de las corridas del pipeline mefisto-tooling: ranking de
herramientas, reparto del wall-clock (API vs no-API, writer vs reviewer) y
deriva temporal semanal/mensual. Solo lectura.
EOF
                exit 0
                ;;
            *)
                echo "ERROR: argumento desconocido: $1 (uso: --desde YYYY-MM-DD)" >&2
                exit 1
                ;;
        esac
    done

    if [ -n "$desde" ] && ! printf '%s' "$desde" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
        echo "ERROR: --desde espera formato YYYY-MM-DD (recibido: '$desde')" >&2
        exit 1
    fi

    local history_file="$MEFISTO_REPO_ROOT/.claude/pipeline/pipeline-history.jsonl"

    local agg
    agg=$(compute_metrics_report_json "$history_file" "$desde") || true
    if [ -z "$agg" ]; then
        echo "ERROR: no se pudo procesar el historial ($history_file)" >&2
        exit 1
    fi

    render_header "$agg"

    local total
    total=$(jq -r '.meta.total' <<<"$agg")
    if [ "$total" -eq 0 ]; then
        echo ""
        echo "(sin corridas registradas en la ventana solicitada)"
        return 0
    fi

    render_tool_ranking "$agg"
    render_wallclock "$agg"
    render_period_table "$agg" ".series.weekly" "DERIVA TEMPORAL - SEMANAL"
    render_period_table "$agg" ".series.monthly" "DERIVA TEMPORAL - MENSUAL"
    render_comparison "$agg"
    render_legacy "$agg"

    echo ""
    echo "=================================================================="
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
