#!/usr/bin/env bash
# work-status-collect.sh -- Consolida en un unico JSON el estado de los
# pipelines del consumidor (TDD, Tooling, Infra, pr-sync), leyendo el root
# canonico (.mefisto/pipeline/) y el legacy (.claude/pipeline/) sin migrar ni
# escribir nada (MEF-ADR-0053 seccion 4). Reemplaza los Pasos 1, 1b y 3 de
# commands/work-status.md (issue #1597): el script entrega DATOS
# deterministicos (dedup, hold/actividad, porcentaje de avance, ruta de log
# resuelta); el comando /work-status sigue siendo quien RENDERIZA (ancho de
# 78 columnas, truncado, ASCII) -- migracion del comando: issue #1598.
#
# Uso: scripts/work-status-collect.sh --json
#
# --json es el unico argumento aceptado (y obligatorio): la gramatica de
# {{mefisto:run <script> <args>}} exige al menos un argumento
# (validate-published-artifacts.sh ~76). Cualquier otro argumento (o
# ausencia de argumentos) imprime el uso por stderr y sale con 2.
#
# Siempre imprime UN unico JSON por stdout y sale con 0, incluso sin ningun
# estado ni historial presente (CA-1). Es de solo lectura: nunca crea, migra
# ni modifica ningun archivo bajo .mefisto/pipeline/ ni .claude/pipeline/
# (CA-2) -- por eso este script deliberadamente NO usa `set -e`: un fallo
# aislado de un helper (parseo de fecha, jq, hold) nunca debe abortar la
# corrida entera y dejarla sin imprimir el JSON de salida; cada llamada de
# riesgo se guarda explicitamente con `if`/`|| true`.
#
# Forma del JSON de salida:
#   schemaVersion: 1
#   now:      "YYYY-MM-DD HH:MM:SS"
#   rows[]:   pipeline, issue, variant, title, runtime, stage, state,
#             started, updated, origin (canonical|legacy), log, pr,
#             last_error, agents, activity, progress_pct
#   history[]: hasta 5, del mas reciente al mas antiguo -- pipeline, issue,
#             variant, runtime, result, duration, detail, started, origin, log
#   empty:    {status, history} (booleanos)
#
# "runtime" se copia tal cual (null si falta) y nunca se infiere (CA-1).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_pipeline-common.sh"

usage() {
    echo "Uso: $0 --json" >&2
}

if [ "$#" -ne 1 ] || [ "$1" != "--json" ]; then
    usage
    exit 2
fi

NOW_EPOCH=$(date +%s)
NOW_DISPLAY=$(date +'%Y-%m-%d %H:%M:%S')
STALE_THRESHOLD_SECONDS=2100  # 35 minutos (Paso 1b)

CANONICAL_DIR="$MEFISTO_STATE_DIR"
LEGACY_DIR="$MEFISTO_LEGACY_STATE_DIR"
LEGACY_EVENTS="$LEGACY_DIR/events.log"

STATUS_TMP=$(mktemp) || { echo "ERROR: no se pudo crear un temporal" >&2; exit 1; }
HISTORY_TMP=$(mktemp) || { echo "ERROR: no se pudo crear un temporal" >&2; exit 1; }
cleanup_tmp() { rm -f "$STATUS_TMP" "$HISTORY_TMP"; }
trap cleanup_tmp EXIT

_seq=0

# --- Utilidades ---------------------------------------------------------

# infer_pipeline_from_name <basename>
# Infiere el pipeline por el nombre de archivo (solo se usa cuando el campo
# "pipeline" del JSON esta ausente -- formatos antiguos, CA-2).
infer_pipeline_from_name() {
    local name="$1"
    case "$name" in
        *pr-sync*) echo "pr-sync" ;;
        *tooling*) echo "tooling" ;;
        *infra*)   echo "infra" ;;
        *)         echo "tdd" ;;
    esac
}

# _parse_epoch <timestamp>
# Traduce a epoch los dos formatos de timestamp que escriben los pipelines:
# ISO "YYYY-MM-DDTHH:MM:SS" (campo "updated"/"finished") y el TIMESTAMP propio
# "YYYYMMDD-HHMMSS" (campo "started"). BSD/macOS primero, GNU como fallback.
# Nunca aborta: retorna 1 sin imprimir nada si no pudo parsear.
_parse_epoch() {
    local ts="$1" out
    [ -n "$ts" ] || return 1
    case "$ts" in
        ????-??-??T??:??:??)
            if out=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$ts" +%s 2>/dev/null); then
                printf '%s\n' "$out"; return 0
            fi
            if out=$(date -d "$ts" +%s 2>/dev/null); then
                printf '%s\n' "$out"; return 0
            fi
            ;;
        ????????-??????)
            if out=$(date -j -f '%Y%m%d-%H%M%S' "$ts" +%s 2>/dev/null); then
                printf '%s\n' "$out"; return 0
            fi
            if out=$(date -d "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}:${ts:13:2}" +%s 2>/dev/null); then
                printf '%s\n' "$out"; return 0
            fi
            ;;
        ????-??-??\ ??:??:??)
            if out=$(date -j -f '%Y-%m-%d %H:%M:%S' "$ts" +%s 2>/dev/null); then
                printf '%s\n' "$out"; return 0
            fi
            if out=$(date -d "$ts" +%s 2>/dev/null); then
                printf '%s\n' "$out"; return 0
            fi
            ;;
    esac
    return 1
}

# reconstruct_log <pipeline> <stage> <started> <issue> <variant>
# Reconstruye el nombre legacy de log por stage (Paso 3): TDD
# stage-{N}-{agent}-{TIMESTAMP}-issue-{N}.log, Tooling
# tooling-stage-{N}-{agent}-{TIMESTAMP}.log, Infra
# iac-stage-{N}-{agent}-{TIMESTAMP}.log. Prueba primero bajo logs/ canonico y
# despues bajo logs/ legacy. Imprime la ruta si existe; retorna 1 si no.
reconstruct_log() {
    local pipeline="$1" stage="$2" started="$3" issue="$4" variant="$5"
    [ -n "$stage" ] || return 1
    case "$stage" in *-*) ;; *) return 1 ;; esac
    [ -n "$started" ] || return 1

    local stage_num="${stage%%-*}" agent="${stage#*-}"
    local issue_tag="$issue"
    [ -n "$variant" ] && issue_tag="${issue}-${variant}"

    local fname=""
    case "$pipeline" in
        tdd)
            fname="stage-${stage_num}-${agent}-${started}-issue-${issue_tag}.log" ;;
        tooling)
            fname="tooling-stage-${stage_num}-${agent}-${started}.log" ;;
        infra)
            fname="iac-stage-${stage_num}-${agent}-${started}.log" ;;
        *)
            return 1 ;;
    esac

    local dir
    for dir in "$CANONICAL_DIR/logs" "$LEGACY_DIR/logs"; do
        if [ -f "$dir/$fname" ]; then
            printf '%s\n' "$dir/$fname"
            return 0
        fi
    done
    return 1
}

# --- Fase 1: recolectar status (Paso 1, con fallback por root) ----------

collect_status_root() {
    local dir="$1" origin="$2"
    [ -d "$dir" ] || return 0

    local -a files=()
    local f
    for f in "$dir"/pipeline-status-*.json; do
        [ -f "$f" ] && files+=("$f")
    done
    if [ ${#files[@]} -eq 0 ]; then
        for f in "$dir"/status*.json "$dir"/tooling-status*.json "$dir"/infra-status.json; do
            [ -f "$f" ] && files+=("$f")
        done
    fi

    for f in ${files[@]+"${files[@]}"}; do
        local base guess
        base="$(basename "$f")"
        guess="$(infer_pipeline_from_name "$base")"
        _seq=$((_seq + 1))
        jq -c --arg origin "$origin" --arg guess "$guess" --argjson seq "$_seq" '
            {
                origin: $origin,
                seq: $seq,
                pipeline: (.pipeline // $guess),
                issue: (.issue // null),
                variant: (.variant // null),
                title: (.title // null),
                runtime: (.runtime // null),
                stage: (.stage // null),
                state: (.state // null),
                started: (.started // null),
                updated: (.updated // null),
                log: (.log // null),
                pr: (.pr // null),
                last_error: (.last_error // null),
                agents: (.agents // null),
                hold: (.hold // null)
            }
        ' "$f" 2>/dev/null >> "$STATUS_TMP" || true
    done
}

collect_status_root "$CANONICAL_DIR" canonical
collect_status_root "$LEGACY_DIR" legacy

STATUS_ARR=$(jq -s '.' "$STATUS_TMP" 2>/dev/null) || STATUS_ARR='[]'
[ -n "$STATUS_ARR" ] || STATUS_ARR='[]'

# --- Fase 2: recolectar historial (Paso 1, con fallback por root) -------

collect_history_root() {
    local dir="$1" origin="$2"
    [ -d "$dir" ] || return 0

    local modern="$dir/pipeline-history.jsonl"
    local -a files=()
    if [ -s "$modern" ]; then
        files+=("$modern")
    else
        local cand
        for cand in "$dir/history.jsonl" "$dir/tooling-history.jsonl" "$dir/infra-history.jsonl"; do
            [ -s "$cand" ] && files+=("$cand")
        done
    fi

    local f
    for f in ${files[@]+"${files[@]}"}; do
        local base guess line
        base="$(basename "$f")"
        guess="$(infer_pipeline_from_name "$base")"
        while IFS= read -r line || [ -n "$line" ]; do
            [ -n "$line" ] || continue
            _seq=$((_seq + 1))
            local started_raw epoch epoch_json
            started_raw=$(printf '%s' "$line" | jq -r '.started // ""' 2>/dev/null) || started_raw=""
            epoch_json="null"
            if [ -n "$started_raw" ]; then
                if epoch=$(_parse_epoch "$started_raw"); then
                    epoch_json="$epoch"
                fi
            fi
            printf '%s' "$line" | jq -c --arg origin "$origin" --arg guess "$guess" \
                --argjson seq "$_seq" --argjson epoch "$epoch_json" '
                {
                    origin: $origin,
                    seq: $seq,
                    started_epoch: $epoch,
                    pipeline: (.pipeline // $guess),
                    issue: (.issue // null),
                    variant: (.variant // null),
                    runtime: (.runtime // null),
                    stage: (.stage // null),
                    state: (.state // null),
                    started: (.started // null),
                    finished: (.finished // null),
                    log: (.log // null),
                    tests: (.tests // null),
                    environment: (.environment // null),
                    pr: (.pr // null)
                }
            ' 2>/dev/null >> "$HISTORY_TMP" || true
        done < "$f"
    done
}

collect_history_root "$CANONICAL_DIR" canonical
collect_history_root "$LEGACY_DIR" legacy

HISTORY_ARR=$(jq -s '.' "$HISTORY_TMP" 2>/dev/null) || HISTORY_ARR='[]'
[ -n "$HISTORY_ARR" ] || HISTORY_ARR='[]'

# --- Fase 3: deduplicar (CA-2) -------------------------------------------
# Clave de status: (pipeline, issue, variant); variant ausente = "".
# Clave de historial: (pipeline, issue, variant, started); started ausente
# tambien se normaliza a "" solo para la clave (nunca en el valor de salida).
# En ambos casos gana el origen canonico ante empate.
# "issue" se compara como texto: los status modernos lo escriben como string y
# los formatos antiguos pueden traerlo numerico.

DEDUPED_STATUS=$(jq -c '
    def keyof(x): [x.pipeline, (x.issue | tostring), (x.variant // "")];
    group_by(keyof(.))
    | map(sort_by(if .origin == "canonical" then 0 else 1 end) | .[0])
' <<< "$STATUS_ARR" 2>/dev/null) || DEDUPED_STATUS='[]'
[ -n "$DEDUPED_STATUS" ] || DEDUPED_STATUS='[]'

DEDUPED_HISTORY=$(jq -c '
    def keyof(x): [x.pipeline, (x.issue | tostring), (x.variant // ""), (x.started // "")];
    group_by(keyof(.))
    | map(sort_by(if .origin == "canonical" then 0 else 1 end) | .[0])
' <<< "$HISTORY_ARR" 2>/dev/null) || DEDUPED_HISTORY='[]'
[ -n "$DEDUPED_HISTORY" ] || DEDUPED_HISTORY='[]'

# Orden final del historial: fechadas primero (started_epoch desc), despues
# las que carecen de "started" (orden de lectura inverso -- CA-2), y se
# recorta a 5.
SORTED_HISTORY=$(jq -c '
    ([ .[] | select(.started_epoch != null) ] | sort_by(-.started_epoch))
    + ([ .[] | select(.started_epoch == null) ] | sort_by(-.seq))
    | .[0:5]
' <<< "$DEDUPED_HISTORY" 2>/dev/null) || SORTED_HISTORY='[]'
[ -n "$SORTED_HISTORY" ] || SORTED_HISTORY='[]'

# --- Fase 4: activity/hold textual (Paso 1b, CA-3) -----------------------
# El fallback textual es exclusivamente legacy y solo se aplica cuando hay
# UNA SOLA fila legacy "running" elegible (sin hold estructurado) en todo el
# root legacy -- nunca se propaga entre filas ni entre runtimes.

LEGACY_ELIGIBLE_COUNT=$(jq '
    [ .[] | select(.origin == "legacy" and .state == "running"
        and ((.hold // null) == null or (.hold.cause // null) == null)) ]
    | length
' <<< "$DEDUPED_STATUS" 2>/dev/null) || LEGACY_ELIGIBLE_COUNT=0
[ -n "$LEGACY_ELIGIBLE_COUNT" ] || LEGACY_ELIGIBLE_COUNT=0

TEXT_FALLBACK_JSON="null"
if [ "$LEGACY_ELIGIBLE_COUNT" -eq 1 ] && [ -f "$LEGACY_EVENTS" ]; then
    if hold_recently_active "$LEGACY_EVENTS"; then
        line=""
        if line=$(last_hold_line "$LEGACY_EVENTS"); then :; fi
        if [ -n "$line" ]; then
            stripped=$(printf '%s' "$line" | sed -E 's/^\[[0-9:]+\]\[hold\] //')
            cause_raw=$(printf '%s' "$stripped" | sed -nE 's/^([A-Za-z_]+): esperando.*/\1/p')
            probe=$(printf '%s' "$stripped" | sed -nE 's/.*proxima sonda ([0-9]{2}:[0-9]{2}:[0-9]{2}).*/\1/p')
            ceiling=$(printf '%s' "$stripped" | sed -nE 's/.*techo ([0-9]{2}:[0-9]{2}).*/\1/p')
            case "$cause_raw" in
                RATE_LIMIT) cause_translated="limite de uso" ;;
                PROVIDER_UNAVAILABLE) cause_translated="proveedor caido" ;;
                *) cause_translated="$cause_raw" ;;
            esac
            TEXT_FALLBACK_JSON=$(jq -cn --arg cause "$cause_translated" --arg probe "$probe" --arg ceiling "$ceiling" '
                {
                    kind: "hold",
                    cause: $cause,
                    next_probe: (if $probe == "" then null else $probe end),
                    ceiling: (if $ceiling == "" then null else $ceiling end)
                }
            ' 2>/dev/null) || TEXT_FALLBACK_JSON="null"
        fi
    fi
fi

# --- Fase 5: enriquecer filas de status (CA-1, CA-3, CA-4) --------------
# Se excluyen las filas en estado terminal exitoso ("completed"): tdd/
# tooling/infra ya borran su archivo de status al completar, pero pr-sync
# (issue #1586/#1601) deja el suyo escrito indefinidamente -- rows[] solo
# expone las dos categorias que declara CA-1 (running/failed).

FINAL_ROWS='[]'
while IFS= read -r row_json; do
    [ -n "$row_json" ] || continue

    pipeline=$(jq -r '.pipeline // ""' <<< "$row_json")
    issue=$(jq -r '.issue // ""' <<< "$row_json")
    variant=$(jq -r '.variant // ""' <<< "$row_json")
    stage=$(jq -r '.stage // ""' <<< "$row_json")
    state=$(jq -r '.state // ""' <<< "$row_json")
    started=$(jq -r '.started // ""' <<< "$row_json")
    updated=$(jq -r '.updated // ""' <<< "$row_json")
    origin=$(jq -r '.origin // ""' <<< "$row_json")
    declared_log=$(jq -r '.log // ""' <<< "$row_json")
    hold_cause=$(jq -r '.hold.cause // ""' <<< "$row_json")

    [ "$state" = "completed" ] && continue

    # activity: kind stale (>35min sin novedades), evaluado solo si no hubo
    # hold estructurado ni textual (la prioridad la resuelve el jq de abajo).
    stale_flag="false"
    if [ -n "$updated" ]; then
        if upd_epoch=$(_parse_epoch "$updated"); then
            if [ $(( NOW_EPOCH - upd_epoch )) -gt "$STALE_THRESHOLD_SECONDS" ]; then
                stale_flag="true"
            fi
        fi
    fi

    row_text_fallback="null"
    if [ "$origin" = "legacy" ] && [ "$state" = "running" ] && [ -z "$hold_cause" ] \
        && [ "$LEGACY_ELIGIBLE_COUNT" -eq 1 ]; then
        row_text_fallback="$TEXT_FALLBACK_JSON"
    fi

    # progress_pct (CA-4): tabla de la especificacion Paso 2.
    agent="${stage#*-}"
    progress_pct_json="null"
    case "$pipeline" in
        tdd)
            case "$agent" in
                test-writer|projection-test-writer) progress_pct_json=10 ;;
                implementer|projection-implementer) progress_pct_json=40 ;;
                smoke-test-writer) progress_pct_json=55 ;;
                reviewer) progress_pct_json=70 ;;
                coverage-gate) progress_pct_json=90 ;;
            esac
            ;;
        tooling)
            case "$agent" in
                writer) progress_pct_json=25 ;;
                reviewer) progress_pct_json=70 ;;
            esac
            ;;
        infra)
            case "$agent" in
                infra-writer) progress_pct_json=30 ;;
                infra-reviewer) progress_pct_json=80 ;;
            esac
            ;;
    esac

    # log (CA-4): declarado y existente, o reconstruido (canonico primero).
    resolved_log=""
    if [ -n "$declared_log" ] && [ -f "$declared_log" ]; then
        resolved_log="$declared_log"
    else
        if resolved_log=$(reconstruct_log "$pipeline" "$stage" "$started" "$issue" "$variant"); then :; else resolved_log=""; fi
    fi

    enriched=$(jq -c \
        --argjson text_fallback "$row_text_fallback" \
        --arg resolved_log "$resolved_log" \
        --argjson stale "$stale_flag" \
        --argjson progress_pct "$progress_pct_json" '
        . as $row
        | ($row.hold // null) as $h
        | (
            if $row.state == "failed" then null
            elif ($h != null and ($h.cause // null) != null) then
                {kind: "hold", cause: $h.cause, next_probe: ($h.next_probe // null), ceiling: ($h.ceiling_seconds // null)}
            elif $text_fallback != null then
                $text_fallback
            elif $stale then
                {kind: "stale"}
            else
                {kind: "stage"}
            end
        ) as $activity
        | {
            pipeline: $row.pipeline,
            issue: $row.issue,
            variant: $row.variant,
            title: $row.title,
            runtime: $row.runtime,
            stage: $row.stage,
            state: $row.state,
            started: $row.started,
            updated: $row.updated,
            origin: $row.origin,
            log: (if $resolved_log == "" then null else $resolved_log end),
            pr: $row.pr,
            last_error: $row.last_error,
            agents: $row.agents,
            activity: $activity,
            progress_pct: $progress_pct
        }
    ' <<< "$row_json" 2>/dev/null) || enriched=""
    [ -n "$enriched" ] || continue

    FINAL_ROWS=$(jq -c --argjson row "$enriched" '. + [$row]' <<< "$FINAL_ROWS" 2>/dev/null) || true
done < <(jq -c '.[]' <<< "$DEDUPED_STATUS" 2>/dev/null)

# --- Fase 6: enriquecer historial (CA-1, CA-4) ---------------------------

FINAL_HISTORY='[]'
while IFS= read -r row_json; do
    [ -n "$row_json" ] || continue

    pipeline=$(jq -r '.pipeline // ""' <<< "$row_json")
    issue=$(jq -r '.issue // ""' <<< "$row_json")
    variant=$(jq -r '.variant // ""' <<< "$row_json")
    stage=$(jq -r '.stage // ""' <<< "$row_json")
    started=$(jq -r '.started // ""' <<< "$row_json")
    finished=$(jq -r '.finished // ""' <<< "$row_json")
    declared_log=$(jq -r '.log // ""' <<< "$row_json")

    duration_json="null"
    if [ -n "$started" ] && [ -n "$finished" ]; then
        if s_epoch=$(_parse_epoch "$started") && f_epoch=$(_parse_epoch "$finished"); then
            duration_json=$(( f_epoch - s_epoch ))
        fi
    fi

    resolved_log=""
    if [ -n "$declared_log" ] && [ -f "$declared_log" ]; then
        resolved_log="$declared_log"
    else
        if resolved_log=$(reconstruct_log "$pipeline" "$stage" "$started" "$issue" "$variant"); then :; else resolved_log=""; fi
    fi

    enriched=$(jq -c \
        --argjson duration "$duration_json" \
        --arg resolved_log "$resolved_log" '
        . as $row
        | (
            if ($row.tests // null) != null then
                (($row.tests | tostring) + " tests")
            elif ($row.environment // null) != null then
                ("env:" + $row.environment)
            elif ($row.pr // null) != null and $row.pr != "" then
                ("PR #" + ($row.pr | tostring | split("/") | last))
            else
                null
            end
        ) as $detail
        | {
            pipeline: $row.pipeline,
            issue: $row.issue,
            variant: $row.variant,
            runtime: $row.runtime,
            result: $row.state,
            duration: $duration,
            detail: $detail,
            started: $row.started,
            origin: $row.origin,
            log: (if $resolved_log == "" then null else $resolved_log end)
        }
    ' <<< "$row_json" 2>/dev/null) || enriched=""
    [ -n "$enriched" ] || continue

    FINAL_HISTORY=$(jq -c --argjson row "$enriched" '. + [$row]' <<< "$FINAL_HISTORY" 2>/dev/null) || true
done < <(jq -c '.[]' <<< "$SORTED_HISTORY" 2>/dev/null)

# --- Fase 7: ensamblar salida --------------------------------------------

jq -n \
    --arg now "$NOW_DISPLAY" \
    --argjson rows "$FINAL_ROWS" \
    --argjson history "$FINAL_HISTORY" '
    {
        schemaVersion: 1,
        now: $now,
        rows: $rows,
        history: $history,
        empty: {
            status: ($rows | length == 0),
            history: ($history | length == 0)
        }
    }
'
exit 0
