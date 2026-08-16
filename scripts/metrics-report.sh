#!/usr/bin/env bash
# metrics-report.sh -- Reporte agregado de metricas de los pipelines del
# consumidor (issue #647, porte publicado de .claude/scripts/mefisto-metrics-report.sh
# del interno #427)
#
# Uso:
#   scripts/metrics-report.sh
#   scripts/metrics-report.sh --desde 2026-08-01
#   scripts/metrics-report.sh --desde 2026-08-01 --hasta 2026-08-15
#
# Agrega .claude/pipeline/pipeline-history.jsonl del consumidor (una linea por
# corrida de tdd-pipeline.sh/tooling-pipeline.sh/iac-pipeline.sh, con
# agents.<stage>.metrics derivado de la traza por #645/#646): ranking de
# herramientas, reparto API vs no-API del wall-clock (agregado y por corrida),
# deriva de turnos por stage con su modelo declarado, y deriva temporal
# semanal/mensual -- todo SEGMENTADO POR PIPELINE (tdd/tooling/infra). Solo
# lectura: nunca escribe en .claude/pipeline/.
#
# Diferencias de generalizacion frente al interno (que solo conocia el par
# writer/reviewer de un unico pipeline):
#
#   1. Multi-pipeline: cada linea trae "pipeline":"tdd"|"tooling"|"infra". El
#      reporte agrega y renderiza una seccion por cada uno. tdd es hoy el
#      unico instrumentado (#646); tooling/infra no exigen metrics -- sus
#      corridas listan bajo SIN INSTRUMENTAR con su duracion plana, el estado
#      de primera clase que el formato mixto ya contempla (CA-5 del #427).
#      Cuando esos pipelines se instrumenten en el futuro, el reporte los
#      cubre sin cambios: agrega/renderiza por el VALOR de "pipeline" que
#      encuentre, no por una lista cerrada -- "tdd"/"tooling"/"infra" solo se
#      fuerzan como orden de presentacion (para que aparezcan aunque su
#      conteo sea 0), cualquier otro valor nuevo se agrega al final.
#   2. Claves de stage heterogeneas por linea: tdd-pipeline.sh escribe hasta 7
#      claves variables (test-writer/implementer/reviewer/coverage-gate/
#      scaffolder/smoke-test-writer/patch-test-writer/patch-implementer);
#      tooling-pipeline.sh solo writer/reviewer; iac-pipeline.sh solo
#      infra-writer/infra-reviewer. El reporte itera las claves PRESENTES en
#      cada linea via `to_entries` (nunca asume un par fijo), y descarta las
#      que no traen "metrics" (null o ausente) sin necesidad de nombrarlas --
#      asi es como coverage-gate (que tiene su propia forma duration/result/
#      gaps/patch_applied, sin "metrics") queda fuera del agregado de turnos/
#      tokens/tool-calls sin un caso especial.
#   3. Deriva de turnos por (stage, agente, modelo): CA-2 exige declarar el
#      modelo y nunca promediar turnos de un mismo stage corrido bajo modelos
#      distintos en una sola cifra (Fase 0: sonnet ~4.5-6.0 s/turno vs opus
#      ~8.0 s/turno). El agente entra en la misma clave por la razon por la
#      que #646 lo persiste dentro de metrics: la ruta read-side despacha
#      projection-test-writer/projection-implementer BAJO LAS MISMAS CLAVES
#      test-writer/implementer, y la Fase 0 los midio como poblaciones
#      distintas (test-writer 118 turnos medianos vs projection-test-writer
#      96). Agrupar solo por clave los promediaria en una sola cifra, que es
#      exactamente lo que CA-2 proscribe para el modelo. Corridas viejas o
#      degradadas sin metrics.agent salen con "-" en esa columna y forman su
#      propio grupo, sin contaminar los de agente conocido.
#
# Dos lecciones NO obvias portadas literalmente del interno (#427):
#
#   (1) El prelude jq `row` -- toda fila destinada a `IFS=$'\t' read` se
#       proyecta con `| row`, nunca `@tsv` a secas: el tabulador es un
#       caracter IFS *whitespace*, bash colapsa tabuladores consecutivos y
#       descarta los iniciales, asi que una sola celda vacia en medio de la
#       fila corre TODAS las columnas siguientes una posicion a la izquierda,
#       en silencio y sin error.
#   (2) "Mediana/llamada" es mediana-de-medianas por corrida: el history
#       guarda por stage solo suma+mediana (no cada llamada individual), asi
#       que la columna es orden de magnitud, no percentil exacto.

set -euo pipefail

# Guard defensivo: este script es del lado publicado y solo aplica al
# consumidor (mismo patron que scripts/appinsights-query.sh). Si detectamos
# .claude-plugin/plugin.json en la raiz del repo, estamos en el repo de
# Mefisto -- su propio historico interno lo cubre .claude/scripts/mefisto-metrics-report.sh.
_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$_REPO_TOP/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/metrics-report.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Mefisto tiene su propio reporte interno: .claude/scripts/mefisto-metrics-report.sh" >&2
    exit 1
fi

# El historial vive SIEMPRE en el .claude/pipeline/ del repo principal: los
# pipelines resuelven PIPELINE_DIR_ABS antes de hacer cd al worktree del issue.
# Como los worktrees son justo donde uno esta parado mientras corre un pipeline,
# quedarse con --show-toplevel haria que el reporte dijera "0 corridas" en
# silencio. --git-common-dir devuelve el .git compartido: absoluto desde un
# worktree, relativo (".git") desde el repo principal.
_GIT_COMMON=$(git -C "$_REPO_TOP" rev-parse --git-common-dir 2>/dev/null || true)
case "$_GIT_COMMON" in
    "")  _MAIN_REPO_TOP="$_REPO_TOP" ;;
    /*)  _MAIN_REPO_TOP=$(dirname "$_GIT_COMMON") ;;
    *)   _MAIN_REPO_TOP=$(cd "$_REPO_TOP/$(dirname "$_GIT_COMMON")" 2>/dev/null && pwd) || _MAIN_REPO_TOP="" ;;
esac
[ -n "$_MAIN_REPO_TOP" ] || _MAIN_REPO_TOP="$_REPO_TOP"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: este reporte requiere jq (no encontrado en PATH). Instalalo (p.ej. 'brew install jq') y reintenta." >&2
    exit 1
fi

JQ_ROW='def row: map(if . == null or . == "" then "null" else . end) | @tsv;'

# Reglas horizontales. 102 columnas: ancho exacto de la tabla mas ancha (la de
# "Por stage", que lleva stage + agente + modelo antes de las cifras) y cubre
# de sobra al ranking de herramientas, el detalle por corrida y la deriva
# temporal con sus cuatro desgloses de tokens.
RULE_MAJOR=$(printf '%0102d' 0 | tr '0' '=')
RULE_MINOR=$(printf '%0102d' 0 | tr '0' '-')

# compute_metrics_report_json <history_file> <desde> <hasta>
#
# Agrega pipeline-history.jsonl en un unico objeto JSON compacto, segmentado
# por pipeline: ranking de herramientas, reparto del wall-clock agregado/por-
# corrida/por-stage-y-modelo, series semanal y mensual, comparacion primer-vs-
# ultimo periodo con datos y el conteo de corridas "sin instrumentar". <desde>/
# <hasta> son "" (sin limite) o "YYYY-MM-DD". Tolera archivo ausente/vacio y
# lineas corruptas (se ignoran). Nunca aborta: ante cualquier fallo de jq
# devuelve vacio y el caller decide.
compute_metrics_report_json() {
    local history_file="$1" desde="$2" hasta="$3"
    local raw_content=""
    [ -f "$history_file" ] && raw_content="$(cat "$history_file" 2>/dev/null || true)"

    printf '%s' "$raw_content" | jq -R -s -c --arg desde "$desde" --arg hasta "$hasta" '
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

# run_stage_pairs -- las entradas de .agents (clave, metrics) cuya "metrics"
# no es null. Indexar una clave ausente (coverage-gate no tiene "metrics") o
# un valor null da null en jq sin error, asi que ninguna clave se nombra aqui:
# la exclusion de coverage-gate es un efecto de su forma, no un caso especial.
def run_stage_pairs:
  ((.agents // {}) | to_entries | map(select(.value.metrics != null)) | map({stage: .key, metrics: .value.metrics}));

def run_wall_s:
  (.agents // {}) as $ag
  | ($ag | [.[] | .duration]) as $durs
  | if ($durs | all(. == null)) then null else ($durs | map(. // 0) | add) end;

def run_has_metrics:
  ((.agents // {}) | [.[] | .metrics] | any(. != null));

def run_api_ms: ([run_stage_pairs[] | (.metrics.duration_api_ms // 0)] | add // 0);
def run_non_api_ms: ([run_stage_pairs[] | (.metrics.non_api_ms // 0)] | add // 0);
def run_tool_calls_arr: ([run_stage_pairs[] | (.metrics.tool_calls // [])[]]);
def run_tool_ms: ([run_tool_calls_arr[] | (.duration_ms_sum // 0)] | add // 0);
def run_tool_calls_count: ([run_tool_calls_arr[] | .count] | add // 0);
def run_turns: ([run_stage_pairs[] | (.metrics.turns // 0)] | add // 0);
def run_tokens_input: ([run_stage_pairs[] | (.metrics.tokens.input // 0)] | add // 0);
def run_tokens_output: ([run_stage_pairs[] | (.metrics.tokens.output // 0)] | add // 0);
def run_tokens_cache_read: ([run_stage_pairs[] | (.metrics.tokens.cache_read // 0)] | add // 0);
def run_tokens_cache_creation: ([run_stage_pairs[] | (.metrics.tokens.cache_creation // 0)] | add // 0);

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
          period: ($period // "(s/fecha)"),
          n_total: ($group | length),
          n_instrumented: ($g_instr | length),
          wall_mean_s: ($group | map(._wall_s) | map(select(. != null)) | avgOrNull),
          wall_median_s: ($group | map(._wall_s) | map(select(. != null)) | median),
          # Media del wall SOLO sobre las corridas instrumentadas: el resto de
          # la fila (turnos, tools, tokens) solo existe para esas, y mezclar
          # denominadores volveria incomparable justo la atribucion que el
          # reporte existe para hacer (ver build_comparison).
          wall_mean_instr_s: ($g_instr | map(._wall_s) | map(select(. != null)) | avgOrNull),
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
  | sort_by([(.period == "(s/fecha)"), .period]);

def summarize_stage_group:
  {
    n: length,
    turns_mean: (map(.turns) | map(select(. != null)) | avgOrNull),
    cost_usd_mean: (map(.cost_usd) | map(select(. != null)) | avgOrNull),
    cost_usd_total: (map(.cost_usd) | map(select(. != null)) | (if length == 0 then null else add end)),
    duration_ms_mean: (map(.duration_ms) | map(select(. != null)) | avgOrNull),
    duration_api_ms_mean: (map(.duration_api_ms) | map(select(. != null)) | avgOrNull),
    non_api_ms_mean: (map(.non_api_ms) | map(select(. != null)) | avgOrNull),
    tokens_input_mean: (map(.tokens_input) | map(select(. != null)) | avgOrNull),
    tokens_output_mean: (map(.tokens_output) | map(select(. != null)) | avgOrNull),
    tokens_cache_read_mean: (map(.tokens_cache_read) | map(select(. != null)) | avgOrNull),
    tokens_cache_creation_mean: (map(.tokens_cache_creation) | map(select(. != null)) | avgOrNull)
  };

def delta_of(f; l):
  {
    first: f,
    last: l,
    pct: (if (f // 0) == 0 then null else (((l // 0) - f) / f * 100) end)
  };

def periods_with_data:
  map(select(.period != "(s/fecha)" and .n_instrumented > 0));

# build_comparison(weekly; monthly) -- CA-4: operativo desde el primer mes
# instrumentado, sin exigir 2 meses calendario (limitacion del interno).
# Prefiere la granularidad semanal si ya trae >= 2 periodos con datos dentro
# de la ventana (--desde/--hasta la acotan); si no, cae a mensual.
def build_comparison(weekly; monthly):
  (weekly | periods_with_data) as $pw
  | (monthly | periods_with_data) as $pm
  | (if ($pw | length) >= 2 then {granularity: "semanal", first: $pw[0], last: $pw[-1]}
     elif ($pm | length) >= 2 then {granularity: "mensual", first: $pm[0], last: $pm[-1]}
     else null end) as $c
  | if $c == null then null
    else
      $c + {
        deltas: [
          ({key: "wall_mean_s", label: "Wall medio (corrida)", unit: "s"} + delta_of($c.first.wall_mean_instr_s; $c.last.wall_mean_instr_s)),
          ({key: "turns_mean", label: "Turnos medios", unit: "count1"} + delta_of($c.first.turns_mean; $c.last.turns_mean)),
          ({key: "tool_calls_mean", label: "Tool calls medios", unit: "count1"} + delta_of($c.first.tool_calls_mean; $c.last.tool_calls_mean)),
          ({key: "tokens_input_mean", label: "Tokens in medios", unit: "count0"} + delta_of($c.first.tokens_input_mean; $c.last.tokens_input_mean)),
          ({key: "non_api_s_mean", label: "No-API medio", unit: "s"} + delta_of(($c.first.non_api_ms_mean // 0) / 1000; ($c.last.non_api_ms_mean // 0) / 1000))
        ]
      }
    end;

# pipeline_report -- toma la lista de entradas YA aumentadas (_wall_s/
# _has_metrics/_ts) y filtradas a un solo pipeline, y produce su seccion
# completa del reporte.
def pipeline_report:
  . as $all
  | ($all | map(select(._has_metrics))) as $instr
  | ($all | map(select(._has_metrics | not))) as $legacy
  | ($all | length) as $total_n
  | ($instr | length) as $instr_n
  | ($legacy | length) as $legacy_n
  | (($instr | map(run_tool_calls_arr) | add) // []) as $tool_blocks
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
  | ($instr | map(run_api_ms) | add // 0) as $agg_api_ms
  | ($instr | map(run_non_api_ms) | add // 0) as $agg_non_api_ms
  | ($instr | map(run_tool_ms) | add // 0) as $agg_tool_ms
  | ($instr | sort_by(.started) | map({
      issue: .issue, started: .started, state: .state, wall_s: ._wall_s,
      api_ms: run_api_ms, non_api_ms: run_non_api_ms, tool_ms: run_tool_ms,
      pct_api: (if (run_api_ms + run_non_api_ms) > 0 then (run_api_ms / (run_api_ms + run_non_api_ms) * 100) else null end)
    })) as $per_run
  | ([$all[] | . as $e | ($e | run_stage_pairs)[] | {
      stage: .stage, agent: .metrics.agent, model: (.metrics.model // "(desconocido)"),
      turns: .metrics.turns, cost_usd: .metrics.cost_usd,
      duration_ms: .metrics.duration_ms, duration_api_ms: .metrics.duration_api_ms,
      non_api_ms: .metrics.non_api_ms,
      tokens_input: .metrics.tokens.input, tokens_output: .metrics.tokens.output,
      tokens_cache_read: .metrics.tokens.cache_read, tokens_cache_creation: .metrics.tokens.cache_creation
    }]) as $stage_rows
  | ($stage_rows
      | group_by([.stage, .agent, .model])
      | map(summarize_stage_group + {stage: .[0].stage, agent: .[0].agent, model: .[0].model})
      | sort_by([.stage, (.agent // ""), .model])
    ) as $by_stage
  | ($all | period_summary(week_key)) as $weekly
  | ($all | period_summary(month_key)) as $monthly
  | ($legacy | sort_by(.started) | map({issue: .issue, started: .started, state: .state})) as $legacy_list
  | {
      meta: {
        total: $total_n,
        instrumented: $instr_n,
        legacy: $legacy_n,
        oldest_started: ($all | map(.started) | map(select(. != null)) | (sort | .[0])),
        newest_started: ($all | map(.started) | map(select(. != null)) | (sort | .[-1]))
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
        by_stage: $by_stage
      },
      series: { weekly: $weekly, monthly: $monthly },
      legacy: { count: $legacy_n, issues: $legacy_list },
      comparison: build_comparison($weekly; $monthly)
    };

(split("\n") | map(select(length > 0)) | map(try fromjson catch empty) | map(select(type == "object"))) as $raw

| ($raw | map(select(
    (($desde == "") or ((( .started // "")[0:8]) as $d8 | ($d8 | length) == 8 and $d8 >= ($desde | gsub("-"; ""))))
    and
    (($hasta == "") or ((( .started // "")[0:8]) as $d8 | ($d8 | length) == 8 and $d8 <= ($hasta | gsub("-"; ""))))
  ))) as $windowed

| ($windowed | map(. + {
    _wall_s: run_wall_s,
    _has_metrics: run_has_metrics,
    _ts: (.started | parse_started),
    # Una linea sin "pipeline" (o con un valor no-string) cae a su propio
    # cajon en vez de desaparecer: sin esto quedaria contada en el total
    # global y en ninguna seccion, la unica forma de que el reporte pierda
    # corridas en silencio.
    _pipeline: (if (.pipeline | type) == "string" then .pipeline else "(sin-pipeline)" end)
  })) as $entries

| ($entries | map(._pipeline) | unique) as $present_pipelines
| (["tdd", "tooling", "infra"] + $present_pipelines | unique) as $pipeline_names

| ($pipeline_names
    | map(. as $name | {key: $name, value: (($entries | map(select(._pipeline == $name))) | pipeline_report)})
    | from_entries
  ) as $pipelines

| {
    meta: {
      total: ($entries | length),
      desde: (if $desde == "" then null else $desde end),
      hasta: (if $hasta == "" then null else $hasta end),
      oldest_started: ($entries | map(.started) | map(select(. != null)) | (sort | .[0])),
      newest_started: ($entries | map(.started) | map(select(. != null)) | (sort | .[-1])),
      by_pipeline: ($pipeline_names | map({
        pipeline: .,
        total: $pipelines[.].meta.total,
        instrumented: $pipelines[.].meta.instrumented,
        legacy: $pipelines[.].meta.legacy
      }))
    },
    pipelines: $pipelines
  }
' 2>/dev/null
}

# --- Formateadores ------------------------------------------------------------

# fmt_dur_s <segundos|"">
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

fmt_pct() {
    local v="$1"
    if [ -z "$v" ] || [ "$v" = "null" ]; then echo "-"; return 0; fi
    printf '%.1f%%' "$v"
}

fmt_signed_pct() {
    local v="$1"
    if [ -z "$v" ] || [ "$v" = "null" ]; then echo "n/d"; return 0; fi
    printf '%+.1f%%' "$v"
}

_num1() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then echo "-"; else printf '%.1f' "$1"; fi
}

_num0() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then echo "-"; else printf '%.0f' "$1"; fi
}

# _txt <texto|null|""> -- texto tal cual, "-" si falta. Evita que el literal
# "null" con que `row` rellena las celdas vacias llegue crudo a la pantalla.
_txt() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then echo "-"; else printf '%s' "$1"; fi
}

# _secs / _secs0 <segundos|null|""> -- segundos con y sin decimal, "-" si falta.
_secs() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then echo "-"; else printf '%.1fs' "$1"; fi
}

_secs0() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then echo "-"; else printf '%.0fs' "$1"; fi
}

# _numk <numero|null|""> -- miles compactos (12345 -> 12.3k), "-" si falta.
_numk() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then echo "-"; return 0; fi
    awk -v v="$1" 'BEGIN{ if (v >= 1000) printf "%.1fk", v/1000; else printf "%.0f", v }'
}

_money() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then echo "-"; else printf '%.2f' "$1"; fi
}

# --- Render: encabezado global (todos los pipelines) --------------------------

render_overall_header() {
    local agg="$1"
    local desde hasta total oldest newest
    desde=$(jq -r '.meta.desde // "(sin limite inferior)"' <<<"$agg")
    hasta=$(jq -r '.meta.hasta // "(sin limite superior)"' <<<"$agg")
    total=$(jq -r '.meta.total' <<<"$agg")
    oldest=$(jq -r '.meta.oldest_started // "-"' <<<"$agg")
    newest=$(jq -r '.meta.newest_started // "-"' <<<"$agg")

    echo "$RULE_MAJOR"
    echo "Mefisto - Reporte agregado de metricas de pipelines del consumidor"
    echo "$RULE_MAJOR"
    echo "Filtro --desde: $desde  --hasta: $hasta"
    echo "Corridas totales en la ventana: $total"
    if [ "$total" -gt 0 ]; then
        echo "Rango: $oldest -> $newest"
    fi
    echo ""
    echo "Por pipeline:"
    while IFS=$'\t' read -r name t i l; do
        printf '  %-8s %5s corridas (instrumentadas: %s, sin instrumentar: %s)\n' "$(_txt "$name")" "$t" "$i" "$l"
    done < <(jq -r "$JQ_ROW"'.meta.by_pipeline[] | [.pipeline, .total, .instrumented, .legacy] | row' <<<"$agg")
}

# --- Render: seccion de un pipeline --------------------------------------------

render_pipeline_header() {
    local agg="$1" name="$2"
    local total instr legacy
    total=$(jq -r '.meta.total' <<<"$agg")
    instr=$(jq -r '.meta.instrumented' <<<"$agg")
    legacy=$(jq -r '.meta.legacy' <<<"$agg")
    echo ""
    echo "$RULE_MAJOR"
    printf 'PIPELINE: %s (total=%s, instrumentadas=%s, sin instrumentar=%s)\n' "$name" "$total" "$instr" "$legacy"
    echo "$RULE_MAJOR"
}

render_tool_ranking() {
    local agg="$1"
    local n count
    n=$(jq -r '.meta.instrumented' <<<"$agg")
    count=$(jq -r '.tool_ranking | length' <<<"$agg")

    echo ""
    echo "$RULE_MINOR"
    echo "RANKING DE HERRAMIENTAS (n=$n corridas instrumentadas)"
    echo "$RULE_MINOR"

    if [ "$count" -eq 0 ]; then
        echo "(sin tool calls en corridas instrumentadas dentro de la ventana)"
        return 0
    fi

    printf '%-18s %10s %14s %16s %10s\n' "Herramienta" "Llamadas" "Tiempo total" "Mediana/llamada" "% tiempo"
    while IFS=$'\t' read -r name calls time_s median_s pct; do
        local time_disp median_disp pct_disp
        time_disp=$(_secs "$time_s")
        median_disp=$(_secs "$median_s")
        pct_disp=$(fmt_pct "$pct")
        printf '%-18s %10s %14s %16s %10s\n' "$name" "$calls" "$time_disp" "$median_disp" "$pct_disp"
    done < <(jq -r "$JQ_ROW"'.tool_ranking[] | [.name, .calls, (.time_ms/1000), (if .median_ms == null then null else (.median_ms/1000) end), .pct] | row' <<<"$agg")

    echo ""
    echo "Nota: 'Mediana/llamada' es la mediana de las medianas por corrida (el"
    echo "      historial guarda por stage solo suma+mediana, no cada llamada);"
    echo "      leela como orden de magnitud, no como percentil exacto."
}

render_wallclock() {
    local agg="$1"
    local n
    n=$(jq -r '.wallclock.aggregate.n' <<<"$agg")

    echo ""
    echo "$RULE_MINOR"
    echo "REPARTO DEL WALL-CLOCK (n=$n corridas instrumentadas)"
    echo "$RULE_MINOR"

    if [ "$n" -eq 0 ]; then
        echo "(sin corridas instrumentadas en la ventana -- ver SIN INSTRUMENTAR)"
        return 0
    fi

    local api_s non_api_s tool_s pct_api pct_non_api pct_tool
    IFS=$'\t' read -r api_s non_api_s tool_s pct_api pct_non_api pct_tool < <(jq -r "$JQ_ROW"'
        .wallclock.aggregate
        | [(.api_ms/1000), (.non_api_ms/1000), (.tool_ms/1000), .pct_api, .pct_non_api, .pct_tool_of_non_api]
        | row' <<<"$agg")

    printf 'Agregado: API %s (%s)  No-API %s (%s)\n' \
        "$(_secs "$api_s")" "$(fmt_pct "$pct_api")" "$(_secs "$non_api_s")" "$(fmt_pct "$pct_non_api")"
    printf '  De lo no-API, atribuible a tool calls: %s (%s del no-API)\n' \
        "$(_secs "$tool_s")" "$(fmt_pct "$pct_tool")"
    echo "  (las tool calls en paralelo se suman por separado, asi que ese % puede pasar de 100)"

    echo ""
    echo "Por corrida:"
    printf '%-8s %-17s %-11s %8s %8s %8s %8s %7s\n' "Issue" "Inicio" "Estado" "Wall" "API" "No-API" "Tools" "%API"
    while IFS=$'\t' read -r issue started state wall_s run_api run_non_api run_tool pct_a; do
        printf '#%-7s %-17s %-11s %8s %8s %8s %8s %7s\n' \
            "$issue" "$(_txt "$started")" "$(_txt "$state")" \
            "$(_secs0 "$wall_s")" "$(_secs "$run_api")" "$(_secs "$run_non_api")" \
            "$(_secs "$run_tool")" "$(fmt_pct "$pct_a")"
    done < <(jq -r "$JQ_ROW"'.wallclock.per_run[] | [.issue, .started, .state, .wall_s, (.api_ms/1000), (.non_api_ms/1000), (.tool_ms/1000), .pct_api] | row' <<<"$agg")

    render_by_stage "$agg"
}

# render_by_stage -- CA-2: deriva de turnos por stage, agrupada tambien por
# agente (metrics.agent) y modelo (metrics.model): cada fila declara los suyos,
# nunca se promedian turnos de un mismo stage corrido bajo modelos distintos
# -- ni bajo agentes distintos, que en la ruta read-side comparten clave.
render_by_stage() {
    local agg="$1"
    local count
    count=$(jq -r '.wallclock.by_stage | length' <<<"$agg")

    echo ""
    echo "Por stage (n = corridas instrumentadas de ESE stage; agente y modelo declarados, CA-2):"

    if [ "$count" -eq 0 ]; then
        echo "(sin corridas instrumentadas de ningun stage en la ventana)"
        return 0
    fi

    printf '%-18s %-22s %-16s %4s %6s %8s %7s %7s %6s\n' \
        "Stage" "Agente" "Modelo" "n" "Turnos" "Duracion" "API" "No-API" "Costo"
    while IFS=$'\t' read -r stage agent model n turns dur api nonapi cost; do
        printf '%-18s %-22s %-16s %4s %6s %8s %7s %7s %6s\n' \
            "$(_txt "$stage")" "$(_txt "$agent")" "$(_txt "$model")" "$n" "$(_num1 "$turns")" \
            "$(fmt_dur_s "$dur")" "$(fmt_dur_s "$api")" "$(fmt_dur_s "$nonapi")" "$(_money "$cost")"
    done < <(jq -r "$JQ_ROW"'
        .wallclock.by_stage[]
        | [.stage, .agent, .model, .n, .turns_mean,
           (if .duration_ms_mean == null then null else .duration_ms_mean/1000 end),
           (if .duration_api_ms_mean == null then null else .duration_api_ms_mean/1000 end),
           (if .non_api_ms_mean == null then null else .non_api_ms_mean/1000 end),
           .cost_usd_mean]
        | row' <<<"$agg")
}

render_period_table() {
    local agg="$1" path="$2" title="$3"
    echo ""
    echo "$RULE_MINOR"
    echo "$title"
    echo "$RULE_MINOR"
    local count
    count=$(jq -r "${path} | length" <<<"$agg")
    if [ "$count" -eq 0 ]; then
        echo "(sin datos en la ventana)"
        return 0
    fi
    echo "n(t/i) = corridas totales / de ellas instrumentadas. El wall usa las"
    echo "totales; turnos, tools y tokens solo las instrumentadas."
    echo ""
    printf '%-10s %-8s %9s %9s %7s %7s %8s %8s %8s %8s %7s\n' \
        "Periodo" "n(t/i)" "WallMedia" "WallP50" "Turnos" "Tools" "Tok.in" "Tok.out" "Cache.rd" "Cache.cr" "%rd"
    while IFS=$'\t' read -r period n_total n_instr wall_mean wall_median turns tools tin tout crd ccr cache_pct; do
        local cache_disp
        if [ "$cache_pct" = "null" ]; then cache_disp="-"; else cache_disp=$(printf '%.1f%%' "$cache_pct"); fi
        printf '%-10s %-8s %9s %9s %7s %7s %8s %8s %8s %8s %7s\n' \
            "$period" "${n_total}/${n_instr}" "$(fmt_dur_s "$wall_mean")" "$(fmt_dur_s "$wall_median")" \
            "$(_num1 "$turns")" "$(_num1 "$tools")" "$(_numk "$tin")" "$(_numk "$tout")" \
            "$(_numk "$crd")" "$(_numk "$ccr")" "$cache_disp"
    done < <(jq -r "$JQ_ROW ${path}[] | [.period, .n_total, .n_instrumented, .wall_mean_s, .wall_median_s, .turns_mean, .tool_calls_mean, .tokens_input_mean, .tokens_output_mean, .cache_read_mean, .cache_creation_mean, .cache_read_pct] | row" <<<"$agg")
    echo ""
    echo "%rd = cache_read / (cache_read + cache_creation): cae cuando el contexto"
    echo "      deja de acertar en cache."
}

render_comparison() {
    local agg="$1"
    echo ""
    echo "$RULE_MINOR"
    echo "RESUMEN: QUE CRECIO (primer vs ultimo periodo con corridas instrumentadas)"
    echo "$RULE_MINOR"

    local has_cmp
    has_cmp=$(jq -r 'if .comparison == null then "no" else "yes" end' <<<"$agg")
    if [ "$has_cmp" = "no" ]; then
        echo "(se necesitan al menos 2 periodos -- semanales o mensuales -- con corridas"
        echo " instrumentadas dentro de la ventana para comparar; ajusta --desde/--hasta)"
        return 0
    fi

    local gran fp fn lp ln
    gran=$(jq -r '.comparison.granularity' <<<"$agg")
    fp=$(jq -r '.comparison.first.period' <<<"$agg")
    fn=$(jq -r '.comparison.first.n_instrumented' <<<"$agg")
    lp=$(jq -r '.comparison.last.period' <<<"$agg")
    ln=$(jq -r '.comparison.last.n_instrumented' <<<"$agg")
    echo "Granularidad: $gran. Comparando $fp (n=$fn) vs $lp (n=$ln):"
    echo "Todas las filas, el wall incluido, se calculan solo sobre esas corridas"
    echo "instrumentadas -- si no compartieran denominador la atribucion no valdria."
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
    done < <(jq -r "$JQ_ROW"'.comparison.deltas[] | [.label, .unit, .first, .last, .pct] | row' <<<"$agg")
}

render_legacy() {
    local agg="$1"
    local count
    count=$(jq -r '.legacy.count' <<<"$agg")
    echo ""
    echo "$RULE_MINOR"
    echo "SIN INSTRUMENTAR (n=$count -- corridas de este pipeline sin agents.<stage>.metrics)"
    echo "$RULE_MINOR"
    if [ "$count" -eq 0 ]; then
        echo "(ninguna en la ventana)"
        return 0
    fi
    while IFS=$'\t' read -r issue started state; do
        printf '#%-8s %-17s %s\n' "$issue" "$(_txt "$started")" "$(_txt "$state")"
    done < <(jq -r "$JQ_ROW"'.legacy.issues[] | [.issue, .started, .state] | row' <<<"$agg")
}

main() {
    local desde="" hasta=""
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
            --hasta)
                [ $# -ge 2 ] || { echo "ERROR: --hasta requiere un valor YYYY-MM-DD" >&2; exit 1; }
                hasta="$2"
                shift 2
                ;;
            --hasta=*)
                hasta="${1#--hasta=}"
                shift
                ;;
            -h|--help)
                cat <<'EOF'
Uso: metrics-report.sh [--desde YYYY-MM-DD] [--hasta YYYY-MM-DD]

Reporte agregado de las corridas de los pipelines del consumidor (tdd/tooling/
infra), segmentado por pipeline: ranking de herramientas, reparto del
wall-clock (API vs no-API), deriva de turnos por stage (con su modelo
declarado) y deriva temporal semanal/mensual. --desde/--hasta acotan la
ventana analizada (por defecto, todo el historico). Solo lectura.
EOF
                exit 0
                ;;
            *)
                echo "ERROR: argumento desconocido: $1 (uso: --desde YYYY-MM-DD --hasta YYYY-MM-DD)" >&2
                exit 1
                ;;
        esac
    done

    if [ -n "$desde" ] && ! printf '%s' "$desde" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
        echo "ERROR: --desde espera formato YYYY-MM-DD (recibido: '$desde')" >&2
        exit 1
    fi
    if [ -n "$hasta" ] && ! printf '%s' "$hasta" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
        echo "ERROR: --hasta espera formato YYYY-MM-DD (recibido: '$hasta')" >&2
        exit 1
    fi
    if [ -n "$desde" ] && [ -n "$hasta" ] && [ "$desde" \> "$hasta" ]; then
        echo "ERROR: --desde ($desde) es posterior a --hasta ($hasta)" >&2
        exit 1
    fi

    local history_file="$_MAIN_REPO_TOP/.claude/pipeline/pipeline-history.jsonl"

    local agg
    agg=$(compute_metrics_report_json "$history_file" "$desde" "$hasta") || true
    if [ -z "$agg" ]; then
        echo "ERROR: no se pudo procesar el historial ($history_file)" >&2
        exit 1
    fi

    render_overall_header "$agg"
    if [ "$_MAIN_REPO_TOP" != "$_REPO_TOP" ]; then
        echo ""
        echo "Nota: estas parado en un worktree; el historial se leyo del repo principal"
        echo "      ($history_file), que es donde lo escriben los pipelines."
    fi

    local total
    total=$(jq -r '.meta.total' <<<"$agg")
    if [ "$total" -eq 0 ]; then
        echo ""
        echo "(sin corridas registradas en la ventana solicitada)"
        return 0
    fi

    # Orden de presentacion fijo tdd/tooling/infra (aparecen aunque su conteo
    # sea 0), seguido de cualquier otro valor de "pipeline" que aparezca en el
    # historial y no este en esa lista (forward-compat, ver cabecera).
    local -a ordered=(tdd tooling infra)
    local extra known name
    while IFS= read -r extra; do
        [ -z "$extra" ] && continue
        known=false
        for name in "${ordered[@]}"; do
            [ "$name" = "$extra" ] && { known=true; break; }
        done
        [ "$known" = true ] || ordered+=("$extra")
    done < <(jq -r '.pipelines | keys[]' <<<"$agg")

    local pipe_agg pipe_total
    for name in "${ordered[@]}"; do
        pipe_agg=$(jq -c --arg n "$name" '.pipelines[$n]' <<<"$agg")
        [ "$pipe_agg" = "null" ] && continue
        render_pipeline_header "$pipe_agg" "$name"
        pipe_total=$(jq -r '.meta.total' <<<"$pipe_agg")
        if [ "$pipe_total" -eq 0 ]; then
            echo "(sin corridas de este pipeline en la ventana)"
            continue
        fi
        render_tool_ranking "$pipe_agg"
        render_wallclock "$pipe_agg"
        render_period_table "$pipe_agg" ".series.weekly" "DERIVA TEMPORAL - SEMANAL"
        render_period_table "$pipe_agg" ".series.monthly" "DERIVA TEMPORAL - MENSUAL"
        render_comparison "$pipe_agg"
        render_legacy "$pipe_agg"
    done

    echo ""
    echo "$RULE_MAJOR"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
