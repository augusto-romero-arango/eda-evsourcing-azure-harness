#!/usr/bin/env bash
# parallel-pipeline.sh --- Ejecuta pipelines para multiples issues en paralelo
#
# Uso:
#   ./scripts/parallel-pipeline.sh 42 43 44                              # enrutamiento automatico por label
#   ./scripts/parallel-pipeline.sh --pipeline tooling 60 62 63           # forzar pipeline tooling
#   ./scripts/parallel-pipeline.sh --pipeline tdd 42 43                  # forzar pipeline tdd
#   ./scripts/parallel-pipeline.sh --pipeline tooling --max-parallel 2 60 62 63
#   ./scripts/parallel-pipeline.sh 42 43 44 --max-parallel 2            # limitar concurrencia
#   ./scripts/parallel-pipeline.sh 42 43 44 --keep-status               # no borrar status files al terminar
#   MEFISTO_RUNTIME=<id> ./scripts/parallel-pipeline.sh 42 43 44         # fijar runtime si la autodeteccion es ambigua
#
# Enrutamiento automatico: sin --pipeline, cada issue se enruta segun su label tipo:*
#   tipo:feature|refactor|projection -> tdd-pipeline.sh
#   tipo:tooling                     -> tooling-pipeline.sh
#   tipo:infra                       -> SKIP (warning, no aborta)
#   sin label tipo:*                 -> SKIP (warning, no aborta)
#
# Flujo: lanza N pipelines en background (cada uno en su worktree aislado),
# monitorea el progreso consolidado, y crea los PRs sin merge automatico.
#
# Serializacion de tipo:projection (issue #372): todas las proyecciones de un
# mismo Bounded Context comparten los archivos del worker de proyecciones
# (MEF-ADR-0034), asi que dos issues tipo:projection NUNCA corren a la vez --
# se serializan entre si dentro del lote, sin afectar el paralelismo del resto
# de issues ni requerir deteccion de BC (un repo = un BC, MEF-ADR-0023).
#
# Compatible con bash 3.2+ (macOS nativo)

set -euo pipefail

# ─── Funciones compartidas ───────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"

# ─── Runtime activo (MEF-ADR-0049/0050, issue #1620) ─────────────────────────
# La clausura publicada conserva src/runtime junto a este script. El scheduler
# solo descubre el runtime: no resuelve modelos y por eso no carga
# mefisto-models.sh.
RUNTIME_DIR="$(cd "$(_pc_script_dir)/../src/runtime" 2>/dev/null && pwd -P)" \
    || { echo "ERROR: no se encontro src/runtime junto al paquete publicado" >&2; exit 1; }
RUNTIME_LIB_DIR="$RUNTIME_DIR/lib"
[ -f "$RUNTIME_LIB_DIR/mefisto-runtime.sh" ] \
    || { echo "ERROR: no se encontro mefisto-runtime.sh en la clausura publicada" >&2; exit 1; }
source "$RUNTIME_LIB_DIR/mefisto-runtime.sh"

# ─── Colores ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Logging ─────────────────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_DIR=""

_strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
_log_file()   { echo -e "$1" | _strip_ansi >> "$LOG_FILE_ABS"; }

log()     { local m="${BLUE}[$(date +%H:%M:%S)]${NC} $1"; echo -e "$m"; _log_file "$m"; }
success() { local m="${GREEN}${BOLD}✓${NC} $1"; echo -e "$m"; _log_file "$m"; }
warn()    { local m="${YELLOW}⚠${NC} $1"; echo -e "$m"; _log_file "$m"; }
header()  { local m="\n${CYAN}${BOLD}── $1 ──${NC}"; echo -e "$m"; _log_file "$m"; }
abort() {
    echo -e "\n${RED}${BOLD}✗ ERROR FATAL: $1${NC}" | tee -a "$LOG_FILE_ABS"
    echo -e "${YELLOW}Revisa el log: $LOG_FILE_ABS${NC}"
    exit 1
}

# ─── Senal de parada suave del lote (issue #974, mismo diseno que el motor ───
# ─── interno #966 y que batch-pipeline.sh) ────────────────────────────────────
# El archivo de mera PRESENCIA que /batch-stop escribe en pipeline-state/
# batch-stop (fuera de .claude/, MEF-ADR-0017). Aqui "detenerse" significa: los
# worktrees YA lanzados terminan su pipeline y abren su PR (CA-3) -- nunca se
# matan --, pero el scheduler deja de lanzar los pendientes de la cola. Se
# consulta en cada pasada del scheduler, antes de evaluar si algun pendiente
# puede lanzarse ya.
BATCH_STOP_SIGNAL="pipeline-state/batch-stop"

batch_stop_requested() {
    [ -f "$BATCH_STOP_SIGNAL" ]
}

# ─── Parsear argumentos ───────────────────────────────────────────────────────
ISSUE_NUMS=()
MAX_PARALLEL=0   # 0 = sin limite
KEEP_STATUS=false
PIPELINE_OVERRIDE=""  # vacio = enrutamiento automatico por label

if [ $# -eq 0 ]; then
    echo "Uso: $0 [--pipeline tdd|tooling] <issue1> <issue2> ... [--max-parallel N] [--keep-status]"
    echo "  --pipeline TYPE    Forzar pipeline: 'tdd' o 'tooling' (sin flag: enruta por label tipo:*)"
    echo "  issue1 ...         Numeros de issues a procesar en paralelo"
    echo "  --max-parallel N   Limitar a N pipelines simultaneos (por defecto: sin limite)"
    echo "  --keep-status      No borrar los archivos status-N.json al terminar"
    exit 1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --pipeline)
            [ $# -lt 2 ] && { echo "Falta el valor de --pipeline"; exit 1; }
            case "$2" in
                tdd|tooling) PIPELINE_OVERRIDE="$2" ;;
                *)           echo "Pipeline desconocido: $2. Usa 'tdd' o 'tooling'"; exit 1 ;;
            esac
            shift 2
            ;;
        --max-parallel)
            [ $# -lt 2 ] && { echo "Falta el valor de --max-parallel"; exit 1; }
            MAX_PARALLEL="$2"
            shift 2
            ;;
        --keep-status) KEEP_STATUS=true; shift ;;
        [0-9,]*)
            # Soportar tanto "42 43" como "42,43,44"
            ARG="${1//,/ }"
            for n in $ARG; do
                ISSUE_NUMS+=("$n")
            done
            shift
            ;;
        *)
            echo "Argumento desconocido: $1"
            exit 1
            ;;
    esac
done

if [ ${#ISSUE_NUMS[@]} -eq 0 ]; then
    echo -e "${RED}${BOLD}✗ No se especificaron issues.${NC}"
    exit 1
fi

# ─── Verificar que estamos en el repo correcto ────────────────────────────────
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
    || { echo "No estás en un repositorio git"; exit 1; }

# Guard defensivo: este pipeline es del lado publicado y solo aplica al consumidor.
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: parallel-pipeline.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Estás en el repo de Mefisto. Los pipelines internos no soportan paralelismo aún;" >&2
    echo "trabaja los issues de Mefisto secuencialmente con /mefisto-tooling." >&2
    exit 1
fi

cd "$REPO_ROOT"

# Validación de homogeneidad: todos los issues del grupo deben pertenecer al
# repo actual del consumidor. `gh issue view <num>` consulta el repo del cwd
# por defecto; si un issue no existe en este repo, gh retorna UNKNOWN y el
# script lo descarta automáticamente más abajo. No se admiten flags -R para
# evitar mezclar repos.

# ─── Inicializar log ──────────────────────────────────────────────────────────
LOG_DIR="$(dirname "$(mefisto_state_path 'logs/.state')")"
LOG_FILE_ABS="$(mefisto_state_path "logs/parallel-$TIMESTAMP.log")"
touch "$LOG_FILE_ABS"

# events.log del checkout (issue #973): el MISMO archivo que tdd-pipeline.sh/
# tooling-pipeline.sh/iac-pipeline.sh escriben para cada worktree que lanza
# este scheduler (los tres lo resuelven contra este cwd, no contra el
# worktree del issue). hold_recently_active/format_hold_status
# (_pipeline-common.sh) lo consultan para saber si HAY una espera activa
# ahora mismo, sin bloquear a este proceso.
EVENTS_LOG_ABS="$(mefisto_state_path 'events.log')"
EVENTS_LOG_LEGACY_ABS="$MEFISTO_LEGACY_STATE_DIR/events.log"
touch "$EVENTS_LOG_ABS"

# Linea del archivo al arrancar: todo lo anterior es de corridas pasadas y no
# se mira. Sin esta marca, un events.log cuyo ultimo hold quedo colgado (una
# corrida anterior interrumpida con Ctrl+C a mitad de una siesta) haria que
# este scheduler se negara a lanzar la cola por una espera que ya no existe.
EVENTS_LOG_LINES_AT_START=$(wc -l < "$EVENTS_LOG_ABS" 2>/dev/null | tr -d ' ')
[ -z "$EVENTS_LOG_LINES_AT_START" ] && EVENTS_LOG_LINES_AT_START=0
EVENTS_LOG_LEGACY_LINES_AT_START=0
if [ -f "$EVENTS_LOG_LEGACY_ABS" ]; then
    EVENTS_LOG_LEGACY_LINES_AT_START=$(wc -l < "$EVENTS_LOG_LEGACY_ABS" 2>/dev/null | tr -d ' ')
    [ -z "$EVENTS_LOG_LEGACY_LINES_AT_START" ] && EVENTS_LOG_LEGACY_LINES_AT_START=0
fi

# ─── Verificar dependencias ───────────────────────────────────────────────────
MISSING_DEPS=""
for dep in gh git dotnet; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        MISSING_DEPS="$MISSING_DEPS $dep"
    fi
done
if [ -n "$MISSING_DEPS" ]; then
    echo -e "${RED}${BOLD}✗ Dependencias faltantes:${MISSING_DEPS}${NC}"
    exit 1
fi

# ─── Resolver runtime activo (CA-2/CA-3, issue #1620) ────────────────────────
# Se resuelve antes de la pre-validacion para no consultar ni lanzar issues si
# el entorno no puede desambiguar el runtime activo.
if ! mefisto_resolve_runtime >/dev/null; then
    echo -e "${RED}${BOLD}✗ No se pudo resolver el runtime activo: ${MEFISTO_RUNTIME_ERROR:-motivo desconocido}${NC}"
    exit 1
fi
PARALLEL_RUNTIME="$MEFISTO_RESOLVED_RUNTIME"

if ! runtime_cli_available "$PARALLEL_RUNTIME"; then
    echo -e "${RED}${BOLD}✗ Dependencias faltantes: CLI del runtime '$PARALLEL_RUNTIME'${NC}"
    exit 1
fi

# Cada pipeline hijo hereda la misma resolucion para que el lote no diverja.
export MEFISTO_RUNTIME="$PARALLEL_RUNTIME"

# Referencia de ejecucion de toda la cola (issue #1861, MEF-ADR-0055): abierta antes
# del primer lanzamiento y viva hasta que termina el ultimo hijo, incluidos los huecos
# por --max-parallel, hold y parada suave. Sin perfil/runtime autorizado: camino previo.
_PARALLEL_PKG_ROOT="$(cd "$(_pc_script_dir)/.." && pwd -P)"
orchestrator_execution_open parallel "$REPO_ROOT" "$_PARALLEL_PKG_ROOT" "$RUNTIME_LIB_DIR" "$(_pc_script_dir)/run-published-agent.sh" \
    || abort "No se pudo abrir la ejecucion preparada del lote (contexto invalido, ocupado o revocado)"
orchestrator_install_exit_trap

# ─── Cabecera ─────────────────────────────────────────────────────────────────
header "parallel-pipeline --- Procesamiento paralelo de issues"
log "Runtime: $MEFISTO_RUNTIME"
log "Pipeline: $([ -n "$PIPELINE_OVERRIDE" ] && echo "$PIPELINE_OVERRIDE (override)" || echo 'automatico por label')"
log "Issues a procesar: ${ISSUE_NUMS[*]}"
log "Paralelismo maximo: $([ "$MAX_PARALLEL" -gt 0 ] && echo "$MAX_PARALLEL" || echo 'sin limite')"
log "Log: $LOG_FILE_ABS"
log "Parada suave: /batch-stop deja de lanzar issues de la cola sin matar los ya en vuelo (issue #974)"

# ─── Pre-validacion: verificar estado y resolver pipeline por issue ──────────
# Una sola llamada a gh por issue (estado + labels combinados): resolve_issue_facts
# devuelve tambien el flag de tipo:projection que necesita el scheduler (issue
# #372), derivado de los mismos labels, sin una segunda consulta a la API.
log "Verificando estado de los issues y resolviendo pipelines..."
VALID_ISSUES=()
ISSUE_PIPELINES=()
ISSUE_IS_PROJECTION=()   # "true"/"false" paralelo a VALID_ISSUES (issue #372)
for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
    ISSUE_FACTS=$(resolve_issue_facts "$ISSUE_NUM" "$PIPELINE_OVERRIDE")
    ISSUE_STATE="${ISSUE_FACTS%%|*}"
    FACTS_REST="${ISSUE_FACTS#*|}"
    IS_PROJECTION="${FACTS_REST%%|*}"
    RESOLVED="${FACTS_REST#*|}"

    if [ "$ISSUE_STATE" != "OPEN" ]; then
        warn "Issue #$ISSUE_NUM esta $ISSUE_STATE --- saltando."
        continue
    fi

    if [[ "$RESOLVED" == SKIP:* ]]; then
        local_reason="${RESOLVED#SKIP:}"
        warn "Issue #$ISSUE_NUM saltado ($local_reason) --- no se puede enrutar a un pipeline."
        continue
    fi

    VALID_ISSUES+=("$ISSUE_NUM")
    ISSUE_PIPELINES+=("$RESOLVED")
    ISSUE_IS_PROJECTION+=("$IS_PROJECTION")
    log "Issue #$ISSUE_NUM -> $(basename "$RESOLVED")$([ "$IS_PROJECTION" = "true" ] && echo " (read-side: se serializa con otras projections)")"
done

if [ ${#VALID_ISSUES[@]} -eq 0 ]; then
    abort "No hay issues validos para procesar."
fi

ISSUE_NUMS=("${VALID_ISSUES[@]}")
TOTAL=${#ISSUE_NUMS[@]}
log "$TOTAL issue(s) valido(s): ${ISSUE_NUMS[*]}"

PROJECTION_COUNT=0
for _flag in "${ISSUE_IS_PROJECTION[@]}"; do
    [ "$_flag" = "true" ] && PROJECTION_COUNT=$((PROJECTION_COUNT + 1))
done
if [ "$PROJECTION_COUNT" -gt 1 ]; then
    warn "$PROJECTION_COUNT issues tipo:projection detectados --- se serializaran entre si (comparten el worker de proyecciones del BC, MEF-ADR-0034)."
fi

# ─── Estado y helpers de lanzamiento ──────────────────────────────────────────
# (el scheduler que los usa vive mas abajo, despues de print_dashboard)
#
# Los issues tipo:projection de un mismo lote se serializan entre si (nunca 2
# corriendo a la vez), ademas de respetar --max-parallel para el resto (issue
# #372). PIDS/STATUS_FILES/ISSUE_LOGS/START_TIMES quedan indexados IGUAL que
# ISSUE_NUMS/ISSUE_PIPELINES/ISSUE_IS_PROJECTION (asignacion por indice, no
# '+='), porque el scheduler puede lanzar issues fuera de orden cuando un
# tipo:projection anterior todavia bloquea su turno -- el dashboard y la
# recoleccion de resultados mas abajo dependen de esa correspondencia posicional.
PIDS=()
STATUS_FILES=()
ISSUE_LOGS=()
START_TIMES=()
CHILD_IDS=()       # contexto hijo reservado por indice (issue #1861); se cierra al observar su exit
CHILD_DIGESTS=()
NOT_LAUNCHED=()    # NOT_LAUNCHED[i]=motivo si la reserva fallo y el hijo nunca se lanzo
DEFERRED_FLAG=()   # DEFERRED_FLAG[i]="true" si el issue en esa posicion quedo aplazado (issue #974, CA-3)
PREFLIGHT_NOT_STARTED=()   # PREFLIGHT_NOT_STARTED[i]="<status>: <codigos>" si el preflight de autonomia le impidio arrancar (issue #1871)

# defer_pending_issues
#
# Consume la senal (CA-5: se borra para no envenenar la corrida siguiente) y
# marca "aplazado" (DEFERRED_FLAG) todos los indices que seguian en
# PENDING_IDXS sin lanzar. Vacia PENDING_IDXS para que el scheduler termine su
# loop de inmediato. Nunca toca PIDS ni FAILED (CA-5: una parada solicitada no
# es un fallo) -- los worktrees ya lanzados siguen su curso normal, esta
# funcion solo afecta a los que todavia no arrancaron.
defer_pending_issues() {
    local idx
    rm -f "$BATCH_STOP_SIGNAL"
    for idx in ${PENDING_IDXS[@]+"${PENDING_IDXS[@]}"}; do
        DEFERRED_FLAG[$idx]="true"
    done
    PENDING_IDXS=()
}

# ─── Preflight de autonomia (issue #1871, MEF-ADR-0055) ──────────────────────
# Gate de CONSULTA: delega en autonomy-preflight.sh (#1870) un plan cerrado
# launchKind:parallel con las filas que el scheduler esta por lanzar (mismo
# VALID_ISSUES/ISSUE_PIPELINES; sin releer bodies). No pide aprobacion, no repara
# perfil/permisos ni certifica la sesion futura: ready-to-dispatch deja sus checks
# `deferred` al guard por instancia del stage (#1858). `legacy` (sin perfil/runtime
# sin contexto) conserva el flujo previo; blocked/incomplete/75/salida invalida/
# evaluador ausente impiden NUEVOS lanzamientos y nunca degradan a legacy. El trabajo
# ya en vuelo no se mata: termina y se recolecta normalmente.
PARALLEL_PREFLIGHT_BLOCKED=false
PREFLIGHT_STATUS=""
PREFLIGHT_DIAG=""
PREFLIGHT_DEFERRED=""

# parallel_autonomy_preflight <numero:pipelineKind>...
# 0 = legacy|ready-to-dispatch; 1 = no se puede lanzar (PREFLIGHT_STATUS/DIAG con codigos).
parallel_autonomy_preflight() {
    local bin plan out rc=0 src=direct args
    PREFLIGHT_STATUS=""; PREFLIGHT_DIAG=""; PREFLIGHT_DEFERRED=""
    bin="$(_pc_script_dir)/autonomy-preflight.sh"
    args=(--project-root "$REPO_ROOT" --runtime "$PARALLEL_RUNTIME")
    if [ -n "${MEFISTO_EXECUTION_CONTEXT:-}" ]; then
        src=command
        args+=(--context "$MEFISTO_EXECUTION_CONTEXT")
    fi
    if [ ! -x "$bin" ]; then
        PREFLIGHT_STATUS="unavailable"; PREFLIGHT_DIAG="PREFLIGHT_UNAVAILABLE"
        return 1
    fi
    plan=$(jq -cn --arg s "$src" '{schemaVersion:1,launchKind:"parallel",source:$s,requestedOperations:[],
        issues:[$ARGS.positional[] | split(":") | {number:(.[0]|tonumber),pipelineKind:.[1]}]}' --args "$@" 2>/dev/null) \
        || { PREFLIGHT_STATUS="unavailable"; PREFLIGHT_DIAG="PREFLIGHT_PLAN_INVALID"; return 1; }
    out=$(printf '%s' "$plan" | "$bin" "${args[@]}" 2>/dev/null) || rc=$?
    PREFLIGHT_STATUS=$(printf '%s' "$out" | jq -r '.status // empty' 2>/dev/null) || PREFLIGHT_STATUS=""
    PREFLIGHT_DIAG=$(printf '%s' "$out" | jq -r '[.diagnostics[]? | select(type == "string" and test("^[A-Za-z0-9_#:.-]+$"))] | join(",")' 2>/dev/null) || PREFLIGHT_DIAG=""
    PREFLIGHT_DEFERRED=$(printf '%s' "$out" | jq -r '[.checks[]? | select(.state == "deferred" and (.code|type) == "string" and (.owner|type) == "string") | "\(.code)@\(.owner)"] | map(select(test("^[A-Za-z0-9_#:./@-]+$"))) | join(",")' 2>/dev/null) || PREFLIGHT_DEFERRED=""
    if [ "$rc" -eq 0 ]; then
        case "$PREFLIGHT_STATUS" in
            legacy)
                # Un contexto transportado nunca degrada a legacy.
                [ "$src" = command ] || return 0
                PREFLIGHT_STATUS="invalid"; PREFLIGHT_DIAG="PREFLIGHT_LEGACY_WITH_CONTEXT"; return 1 ;;
            ready-to-dispatch)
                # Fail-closed: todo check clasificado; deferred solo con propietario.
                if printf '%s' "$out" | jq -e '(.checks | type == "array") and all(.checks[];
                        (.state | IN("pass","deferred","not-applicable"))
                        and (.state != "deferred" or ((.owner | type) == "string" and (.owner | length) > 0)))' >/dev/null 2>&1; then
                    return 0
                fi
                PREFLIGHT_STATUS="invalid"; PREFLIGHT_DIAG="PREFLIGHT_CHECKS_INCONSISTENT"; return 1 ;;
        esac
    fi
    if [ "$rc" -eq 75 ]; then
        PREFLIGHT_STATUS="busy"; PREFLIGHT_DIAG="${PREFLIGHT_DIAG:-PREFLIGHT_BUSY}"
    else
        case "$PREFLIGHT_STATUS" in
            blocked|incomplete) ;;
            *) PREFLIGHT_STATUS="invalid"; PREFLIGHT_DIAG="${PREFLIGHT_DIAG:-PREFLIGHT_RC_$rc}" ;;
        esac
    fi
    return 1
}

# parallel_preflight_items <idx>...
# Arma los items numero:pipelineKind en PREFLIGHT_ITEMS (omite filas sin kind).
parallel_preflight_items() {
    local idx kind
    PREFLIGHT_ITEMS=()
    for idx in "$@"; do
        kind=$(orchestrator_kind_for_script "${ISSUE_PIPELINES[$idx]}")
        [ -n "$kind" ] || continue
        PREFLIGHT_ITEMS+=("${ISSUE_NUMS[$idx]}:$kind")
    done
}

# parallel_preflight_block_pending <momento>
# Corta los NUEVOS lanzamientos: marca los pendientes como "no iniciado por preflight"
# (nunca "aplazado"), no consume batch-stop ni toca PIDS: lo ya en vuelo sigue y se recolecta.
parallel_preflight_block_pending() {
    local when="$1" idx
    PARALLEL_PREFLIGHT_BLOCKED=true
    for idx in ${PENDING_IDXS[@]+"${PENDING_IDXS[@]}"}; do
        PREFLIGHT_NOT_STARTED[$idx]="${PREFLIGHT_STATUS}: ${PREFLIGHT_DIAG:-sin-detalle}"
    done
    PENDING_IDXS=()
    echo -e "\n${RED}${BOLD}✗ Preflight de autonomia ${when}: ${PREFLIGHT_STATUS} [${PREFLIGHT_DIAG:-sin-detalle}]. No se lanzan mas issues; los ya en vuelo terminan normalmente.${NC}" | tee -a "$LOG_FILE_ABS"
}

# launch_pipeline <idx>
#
# Lanza el issue en la posicion <idx> de ISSUE_NUMS/ISSUE_PIPELINES y registra
# PID/status/log/inicio en esa MISMA posicion.
launch_pipeline() {
    local idx="$1"
    local issue="${ISSUE_NUMS[$idx]}"
    local pipeline_script="${ISSUE_PIPELINES[$idx]}"
    # Determinar tipo de pipeline segun el script
    local pipeline_type="tdd"
    case "$(basename "$pipeline_script")" in
        *tooling*) pipeline_type="tooling" ;;
        *iac*)     pipeline_type="infra" ;;
    esac
    local status_file="pipeline-status-${pipeline_type}-${issue}.json"
    local issue_log="$LOG_DIR/parallel-issue-${issue}-${TIMESTAMP}.log"
    touch "$issue_log"

    # Reserva ANTES del spawn: sin reserva el hijo no se lanza ni se reporta ejecutado.
    if ! orchestrator_reserve_child "$(orchestrator_kind_for_script "$pipeline_script")" "$REPO_ROOT"; then
        NOT_LAUNCHED[$idx]="no se pudo reservar el contexto de ejecucion; el pipeline no se lanzo"
        ISSUE_LOGS[$idx]="$issue_log"
        warn "Issue #$issue no se lanza: ${NOT_LAUNCHED[$idx]}"
        return 0
    fi
    if [ -n "$ORCH_CHILD_ID" ]; then
        CHILD_IDS[$idx]="$ORCH_CHILD_ID"
        CHILD_DIGESTS[$idx]="$ORCH_CHILD_DIGEST"
        MEFISTO_EXECUTION_CONTEXT="$ORCH_CHILD_CONTEXT" MEFISTO_EXECUTION_DIGEST="$ORCH_CHILD_DIGEST" \
            "$pipeline_script" "$issue" --status-file "$status_file" \
            >"$issue_log" 2>&1 &
    else
        "$pipeline_script" "$issue" --status-file "$status_file" \
            >"$issue_log" 2>&1 &
    fi

    PIDS[$idx]=$!
    STATUS_FILES[$idx]="$status_file"
    ISSUE_LOGS[$idx]="$issue_log"
    START_TIMES[$idx]="$(date +%s)"

    log "Lanzado issue #$issue con $(basename "$pipeline_script") (PID $!) -> $status_file"
}

# running_count
#
# Cuenta procesos lanzados que siguen vivos. PIDS puede tener huecos (indices
# aun no lanzados); "${!PIDS[@]}" solo recorre los que ya tienen valor.
running_count() {
    local c=0 i
    for i in "${!PIDS[@]}"; do
        [ -n "${PIDS[$i]:-}" ] && kill -0 "${PIDS[$i]}" 2>/dev/null && c=$((c + 1))
    done
    echo "$c"
}

# is_projection_running
#
# Retorna 0 si algun issue tipo:projection ya lanzado sigue vivo.
is_projection_running() {
    local i
    for i in "${!PIDS[@]}"; do
        if [ -n "${PIDS[$i]:-}" ] && [ "${ISSUE_IS_PROJECTION[$i]}" = "true" ] \
            && kill -0 "${PIDS[$i]}" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# ─── Función de lectura de status ────────────────────────────────────────────
read_status_field() {
    local file="$1" field="$2" status_path
    status_path=$(mefisto_state_read_first "$file" 2>/dev/null) || { echo "-"; return; }
    python3 -c "
import json, sys
try:
    d = json.load(open('$status_path'))
    print(d.get('$field', '-') or '-')
except:
    print('-')
" 2>/dev/null || echo "-"
}

read_agent_result() {
    local file="$1" agent="$2" subfield="$3" status_path
    status_path=$(mefisto_state_read_first "$file" 2>/dev/null) || { echo "-"; return; }
    python3 -c "
import json, sys
try:
    d = json.load(open('$status_path'))
    print(d.get('agents', {}).get('$agent', {}).get('$subfield', '-') or '-')
except:
    print('-')
" 2>/dev/null || echo "-"
}

hold_active_in_any_events_log() {
    hold_recently_active "$EVENTS_LOG_ABS" "$EVENTS_LOG_LINES_AT_START" && return 0
    [ -f "$EVENTS_LOG_LEGACY_ABS" ] \
        && hold_recently_active "$EVENTS_LOG_LEGACY_ABS" "$EVENTS_LOG_LEGACY_LINES_AT_START"
}

format_active_hold_status() {
    format_hold_status "$EVENTS_LOG_ABS" "$EVENTS_LOG_LINES_AT_START" && return 0
    [ -f "$EVENTS_LOG_LEGACY_ABS" ] \
        && format_hold_status "$EVENTS_LOG_LEGACY_ABS" "$EVENTS_LOG_LEGACY_LINES_AT_START"
}

# ─── Dashboard de progreso ────────────────────────────────────────────────────
print_dashboard() {
    local now
    now=$(date +%s)
    # Calculado UNA vez por refresco (issue #973, CA-2): format_hold_status
    # relee events.log; evitarlo por fila no cambia el resultado (el archivo
    # no se toca dentro de este mismo refresco) y ahorra N-1 lecturas.
    local hold_status
    hold_status=$(format_active_hold_status) || hold_status=""
    local header_str="${CYAN}${BOLD}parallel-pipeline — $TOTAL issue(s) en proceso${NC}"
    echo -e "\n$header_str"
    printf "%s\n" "----------------------------------------------------------------------"
    printf "  ${BOLD}%-6s  %-14s  %-8s  %s${NC}\n" "Issue" "Stage" "Tiempo" "Agentes"
    printf "%s\n" "----------------------------------------------------------------------"

    for i in "${!ISSUE_NUMS[@]}"; do
        local issue="${ISSUE_NUMS[$i]}"
        local pid="${PIDS[$i]:-}"

        # Issue aplazado por la senal de parada (issue #974): ya no espera
        # turno, nunca se va a lanzar en esta corrida. Sin esta rama el
        # dashboard lo seguiria mostrando "en espera" en cada refresco del
        # monitoreo, contradiciendo el aviso de parada que ya se imprimio.
        if [ "${DEFERRED_FLAG[$i]:-false}" = "true" ]; then
            printf "  ${YELLOW}%-6s  %-14s  %-8s  %s${NC}\n" "#$issue" "aplazado" "-" ""
            continue
        fi
        if [ -n "${PREFLIGHT_NOT_STARTED[$i]:-}" ]; then
            printf "  ${RED}%-6s  %-14s  %-8s  %s${NC}\n" "#$issue" "no iniciado" "-" ""
            continue
        fi
        if [ -n "${NOT_LAUNCHED[$i]:-}" ]; then
            printf "  ${RED}%-6s  %-14s  %-8s  %s${NC}\n" "#$issue" "no lanzado" "-" ""
            continue
        fi

        # Issue todavia sin lanzar: el scheduler le esta reteniendo el turno
        # (--max-parallel copado, u otra tipo:projection viva -- issue #372). No
        # hay status file ni cronometro que leer todavia.
        if [ -z "$pid" ]; then
            printf "  ${YELLOW}%-6s  %-14s  %-8s  %s${NC}\n" "#$issue" "en espera" "-" ""
            continue
        fi

        local status_file="${STATUS_FILES[$i]}"
        local start="${START_TIMES[$i]}"
        local elapsed=$(( now - start ))
        local mins=$(( elapsed / 60 ))
        local secs=$(( elapsed % 60 ))
        local time_str="$(printf '%dm%02ds' $mins $secs)"

        # Detectar si el proceso sigue corriendo
        local running=false
        kill -0 "$pid" 2>/dev/null && running=true

        local stage
        stage=$(read_status_field "$status_file" "stage")
        local state
        state=$(read_status_field "$status_file" "state")

        local tw_res tw_dur im_res im_dur rv_res rv_dur
        tw_res=$(read_agent_result "$status_file" "test-writer" "result")
        tw_dur=$(read_agent_result "$status_file" "test-writer" "duration")
        im_res=$(read_agent_result "$status_file" "implementer" "result")
        im_dur=$(read_agent_result "$status_file" "implementer" "duration")
        rv_res=$(read_agent_result "$status_file" "reviewer" "result")
        rv_dur=$(read_agent_result "$status_file" "reviewer" "duration")

        # Construir resumen de agentes
        local agents_str=""
        [ "$tw_res" = "passed" ] && agents_str="${agents_str}tw:${tw_dur}s "
        [ "$im_res" = "passed" ] && agents_str="${agents_str}im:${im_dur}s "
        [ "$rv_res" = "passed" ] && agents_str="${agents_str}rv:${rv_dur}s"

        local status_color="$NC"
        local status_label=""
        if [ "$state" = "running" ] || [ "$running" = "true" -a "$state" = "-" ]; then
            status_color="$BLUE"
            status_label="${stage:-iniciando}"
        elif [ "$state" = "completed" ]; then
            status_color="$GREEN"
            local pr
            pr=$(read_status_field "$status_file" "pr")
            status_label="completado"
            [ "$pr" != "-" ] && status_label="PR: $pr"
        elif [ "$state" = "failed" ]; then
            status_color="$RED"
            local err
            err=$(read_status_field "$status_file" "last_error")
            status_label="ERROR: ${err:0:35}"
        elif [ "$running" = "false" ]; then
            status_color="$YELLOW"
            status_label="terminado"
        else
            status_label="${stage:--}"
        fi

        # Espera (hold) activa (issue #973, CA-2): un issue todavia corriendo
        # (no completado ni fallido) durante una espera global se muestra
        # como "espera/hold" con la causa y la proxima sonda en vez de su
        # stage -- sin esto el dashboard seguiria mostrando el mismo stage con
        # el cronometro creciendo, indistinguible de un pipeline colgado (la
        # motivacion original del issue). La etiqueta NO es "en espera": esta
        # columna ya usa esa frase para el issue que espera TURNO de la cola
        # (arriba, sin PID), y confundir "no ha arrancado" con "arranco y
        # esta durmiendo por limite de uso" es justo la distincion que este
        # issue viene a dar. No se distingue DE CUAL worktree es la espera
        # (ver la nota de cabecera en _pipeline-common.sh): se aplica a todo
        # issue en vuelo mientras la espera este activa.
        if [ "$running" = "true" ] && [ "$state" != "completed" ] && [ "$state" != "failed" ] \
            && [ -n "$hold_status" ]; then
            status_color="$YELLOW"
            status_label="espera/hold"
            agents_str="$hold_status"
        fi

        printf "  ${status_color}%-6s  %-14s  %-8s  %s${NC}\n" \
            "#$issue" "${status_label:0:14}" "$time_str" "$agents_str"
    done

    printf "%s\n" "----------------------------------------------------------------------"
}

MONITOR_INTERVAL=10

# ─── Scheduler de lanzamiento ─────────────────────────────────────────────────
# Recorre los pendientes en cada pasada y lanza los que ya pueden correr
# (can_launch_now de _pipeline-common.sh). Un pendiente bloqueado no detiene a
# los demas: se reintenta en la siguiente pasada mientras otros pendientes que
# si pueden correr avanzan. Va DESPUES de print_dashboard (y no junto a
# launch_pipeline) porque mientras retiene turnos ya hay pipelines vivos que
# reportar: sin dibujar el dashboard aca, un lote con dos tipo:projection
# quedaria mudo durante todo el primer pipeline -- decenas de minutos sin
# ninguna senal de los issues que si estan corriendo.
PENDING_IDXS=()
for ((i = 0; i < TOTAL; i++)); do PENDING_IDXS+=("$i"); done

# Preflight de autonomia, plan inicial (issue #1871): ANTES del primer launch_pipeline y
# despues de honrar un batch-stop ya existente (sin consulta para trabajo que no arrancara).
# Un bloqueo aqui deja cero hijos lanzados. Con la parada ya pedida el loop de abajo aplaza
# todo con el comportamiento vigente.
PREFLIGHT_FRESH=false
if [ ${#PENDING_IDXS[@]} -gt 0 ] && ! batch_stop_requested; then
    parallel_preflight_items "${PENDING_IDXS[@]}"
    if [ ${#PREFLIGHT_ITEMS[@]} -gt 0 ]; then
        if parallel_autonomy_preflight "${PREFLIGHT_ITEMS[@]}"; then
            log "Preflight de autonomia: $PREFLIGHT_STATUS"
            if [ "$PREFLIGHT_STATUS" = "ready-to-dispatch" ] && [ -n "$PREFLIGHT_DEFERRED" ]; then
                log "Verificaciones diferidas al stage (no es permiso efectivo futuro): $PREFLIGHT_DEFERRED"
            fi
            PREFLIGHT_FRESH=true
        else
            parallel_preflight_block_pending "antes del primer lanzamiento"
        fi
    fi
fi

while [ ${#PENDING_IDXS[@]} -gt 0 ]; do
    if batch_stop_requested; then
        _deferred_count=${#PENDING_IDXS[@]}
        defer_pending_issues
        warn "Parada solicitada ($BATCH_STOP_SIGNAL): $_deferred_count issue(s) en cola quedan aplazados, sin lanzar ningun worktree. Los ya lanzados terminan su pipeline y abren su PR."
        break
    fi

    # Espera (hold) activa en algun worktree en vuelo (issue #973, CA-3): un
    # limite de uso agotado pone en espera a TODOS los que esten corriendo a
    # la vez, asi que lanzar mas de la cola solo multiplicaria los que
    # esperan. Se reintenta en la siguiente pasada -- ninguno de los
    # pendientes se marca "aplazado" (a diferencia de la parada suave de
    # arriba, esto no es una parada: en cuanto la espera se resuelva, el
    # scheduler retoma el lanzamiento normal sin intervencion humana).
    if hold_active_in_any_events_log; then
        PREFLIGHT_FRESH=false
        print_dashboard
        echo ""
        log "Espera (hold) activa -- $(format_active_hold_status). ${#PENDING_IDXS[@]} issue(s) en cola esperan a que se libere antes de lanzar el siguiente."
        sleep "$MONITOR_INTERVAL"
        continue
    fi

    # Subconjunto que puede salir en ESTA pasada (mismas reglas de can_launch_now, con
    # el contador simulado): se revalida identidad/perfil/recursos justo antes de lanzar,
    # sin cache. La pasada inmediata al chequeo inicial no lo repite (#1871).
    LAUNCH_SET=" "
    _sim_running=$(running_count)
    _sim_proj="false"
    is_projection_running && _sim_proj="true"
    _sim_idxs=()
    for idx in "${PENDING_IDXS[@]}"; do
        if can_launch_now "$MAX_PARALLEL" "$_sim_running" "${ISSUE_IS_PROJECTION[$idx]}" "$_sim_proj"; then
            _sim_idxs+=("$idx")
            LAUNCH_SET="${LAUNCH_SET}${idx} "
            _sim_running=$((_sim_running + 1))
            [ "${ISSUE_IS_PROJECTION[$idx]}" = "true" ] && _sim_proj="true"
        fi
    done
    if [ ${#_sim_idxs[@]} -gt 0 ] && [ "$PREFLIGHT_FRESH" != true ]; then
        parallel_preflight_items "${_sim_idxs[@]}"
        if [ ${#PREFLIGHT_ITEMS[@]} -gt 0 ] && ! parallel_autonomy_preflight "${PREFLIGHT_ITEMS[@]}"; then
            parallel_preflight_block_pending "antes de lanzar nuevos issues"
            break
        fi
    fi
    PREFLIGHT_FRESH=false

    NEXT_PENDING=()
    for idx in "${PENDING_IDXS[@]}"; do
        _proj_running="false"
        is_projection_running && _proj_running="true"
        if [[ "$LAUNCH_SET" == *" $idx "* ]] && can_launch_now "$MAX_PARALLEL" "$(running_count)" "${ISSUE_IS_PROJECTION[$idx]}" "$_proj_running"; then
            launch_pipeline "$idx"
        else
            NEXT_PENDING+=("$idx")
        fi
    done
    # Reasignar evitando "${NEXT_PENDING[@]}" cuando queda vacio: en bash 3.2
    # (macOS) un array declarado pero sin elementos se trata como "unset" bajo
    # 'set -u' y expandirlo aborta el script (fijo en bash 4.4+, no disponible aqui).
    if [ ${#NEXT_PENDING[@]} -gt 0 ]; then
        PENDING_IDXS=("${NEXT_PENDING[@]}")
    else
        PENDING_IDXS=()
    fi
    if [ ${#PENDING_IDXS[@]} -gt 0 ]; then
        print_dashboard
        echo ""
        log "${#PENDING_IDXS[@]} issue(s) esperando turno. Actualizando en ${MONITOR_INTERVAL}s... (Ctrl+C para cancelar)"
        sleep "$MONITOR_INTERVAL"
    fi
done

# La senal pudo aparecer despues de que el ultimo pendiente ya se lanzo (nada
# que aplazar): se consume igual (CA-4), para no envenenar la corrida
# siguiente, y se avisa para que el humano no busque aplazados inexistentes.
if batch_stop_requested; then
    rm -f "$BATCH_STOP_SIGNAL"
    if [ "$PARALLEL_PREFLIGHT_BLOCKED" = true ]; then
        warn "Parada solicitada ($BATCH_STOP_SIGNAL) tras un bloqueo del preflight de autonomia: los pendientes ya quedaron 'no iniciado por preflight', no aplazados. La senal se consumio igual, para no afectar la corrida siguiente."
    else
        warn "Parada solicitada ($BATCH_STOP_SIGNAL): no quedaba ningun issue en cola por lanzar (todos ya estaban en vuelo). La senal se consumio igual, para no afectar la corrida siguiente."
    fi
fi

# ─── Loop de monitoreo ────────────────────────────────────────────────────────
# Con la parada solicitada ANTES de lanzar el primer issue (issue #974) no hay
# ningun proceso en vuelo: PIDS queda vacio y no hay nada que monitorear. La
# condicion del while no es cosmetica -- bash 3.2 aborta con "unbound variable"
# al expandir "${PIDS[@]}" vacio bajo `set -u`, y el resumen (que justo ahi
# tiene todos los aplazados por reportar) nunca se imprimiria. PIDS solo crece,
# asi que con al menos un lanzamiento el loop se comporta igual que antes.
if [ ${#PIDS[@]} -gt 0 ]; then
    log "Todos los pipelines lanzados. Monitoreando progreso (Ctrl+C para cancelar)..."
else
    log "Ningun pipeline quedo en vuelo: no hay nada que monitorear."
fi
echo ""

while [ ${#PIDS[@]} -gt 0 ]; do
    # Verificar si todos los procesos terminaron
    ALL_DONE=true
    for pid in "${PIDS[@]}"; do
        kill -0 "$pid" 2>/dev/null && ALL_DONE=false && break
    done

    print_dashboard

    if [ "$ALL_DONE" = "true" ]; then
        break
    fi

    echo ""
    log "Actualizando en ${MONITOR_INTERVAL}s... (Ctrl+C para cancelar monitoreo)"
    sleep "$MONITOR_INTERVAL"
done

# ─── Recolectar resultados ─────────────────────────────────────────────────────
header "Recolectando resultados"

ISSUE_RESULTS=()   # "completado" o "ERROR: ..."
ISSUE_PRS=()       # URL del PR o ""
ISSUE_DURATIONS=() # segundos totales o "-"
COMPLETED=0
FAILED=0
NOT_STARTED=0

for i in "${!ISSUE_NUMS[@]}"; do
    if [ "${DEFERRED_FLAG[$i]:-false}" = "true" ]; then
        ISSUE_RESULTS+=("aplazado (parada solicitada; no se proceso en esta corrida)")
        ISSUE_PRS+=("")
        ISSUE_DURATIONS+=("-")
        continue
    fi

    if [ -n "${PREFLIGHT_NOT_STARTED[$i]:-}" ]; then
        ISSUE_RESULTS+=("no iniciado por preflight (${PREFLIGHT_NOT_STARTED[$i]})")
        ISSUE_PRS+=("")
        ISSUE_DURATIONS+=("-")
        NOT_STARTED=$((NOT_STARTED + 1))
        continue
    fi

    if [ -n "${NOT_LAUNCHED[$i]:-}" ]; then
        ISSUE_RESULTS+=("ERROR: ${NOT_LAUNCHED[$i]}")
        ISSUE_PRS+=("")
        ISSUE_DURATIONS+=("-")
        FAILED=$((FAILED + 1))
        continue
    fi

    local_pid="${PIDS[$i]}"
    local_issue="${ISSUE_NUMS[$i]}"
    local_status="${STATUS_FILES[$i]}"
    local_start="${START_TIMES[$i]}"

    PIPELINE_EXIT=0
    wait "$local_pid" || PIPELINE_EXIT=$?
    if [ -n "${CHILD_IDS[$i]:-}" ]; then
        ORCH_CHILD_ID="${CHILD_IDS[$i]}"; ORCH_CHILD_DIGEST="${CHILD_DIGESTS[$i]}"
        orchestrator_finish_child "$(orchestrator_outcome_for "$PIPELINE_EXIT")" || true
    fi

    local_end=$(date +%s)
    local_dur=$(( local_end - local_start ))
    ISSUE_DURATIONS+=("${local_dur}s")

    if [ "$PIPELINE_EXIT" -eq 0 ]; then
        PR_URL=$(read_status_field "$local_status" "pr")
        [ "$PR_URL" = "-" ] && PR_URL=""
        # Intentar extraer PR del log si status no lo tiene
        if [ -z "$PR_URL" ] && [ -f "${ISSUE_LOGS[$i]}" ]; then
            PR_URL=$(sed 's/\x1b\[[0-9;]*m//g' "${ISSUE_LOGS[$i]}" \
                | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' \
                | head -1 || true)
        fi
        ISSUE_RESULTS+=("completado")
        ISSUE_PRS+=("${PR_URL:-}")
        COMPLETED=$((COMPLETED + 1))
    else
        ERR=$(read_status_field "$local_status" "last_error")
        [ "$ERR" = "-" ] && ERR="exit $PIPELINE_EXIT"
        ISSUE_RESULTS+=("ERROR: $ERR")
        ISSUE_PRS+=("")
        FAILED=$((FAILED + 1))
    fi
done

# ─── Resumen final ────────────────────────────────────────────────────────────
header "Resumen final"
echo -e ""
printf "${BOLD}%-10s  %-50s  %-10s  %s${NC}\n" "Issue" "Estado" "Duración" "PR"
printf "%s\n" "──────────────────────────────────────────────────────────────────────────────"

for i in "${!ISSUE_NUMS[@]}"; do
    ISSUE_NUM="${ISSUE_NUMS[$i]}"
    RESULT="${ISSUE_RESULTS[$i]}"
    PR="${ISSUE_PRS[$i]}"
    DUR="${ISSUE_DURATIONS[$i]}"

    if echo "$RESULT" | grep -q "^completado"; then
        COLOR="$GREEN"
    elif echo "$RESULT" | grep -qE "^(ERROR|no iniciado por preflight)"; then
        COLOR="$RED"
    else
        COLOR="$YELLOW"
    fi

    printf "${COLOR}%-10s  %-50s  %-10s  %s${NC}\n" \
        "#$ISSUE_NUM" "${RESULT:0:50}" "$DUR" "${PR:-(sin PR)}"
done

# Issues aplazados (issue #974, CA-4): mismo orden que ISSUE_NUMS, para que la
# linea de relanzamiento respete el orden del lote.
DEFERRED=0
DEFERRED_NUMS=()
for i in "${!ISSUE_NUMS[@]}"; do
    if [ "${DEFERRED_FLAG[$i]:-false}" = "true" ]; then
        DEFERRED_NUMS+=("${ISSUE_NUMS[$i]}")
        DEFERRED=$((DEFERRED + 1))
    fi
done

echo ""
echo -e "  Total: $TOTAL  |  ${GREEN}Completados: $COMPLETED${NC}  |  ${RED}Fallidos: $FAILED${NC}  |  ${YELLOW}Aplazados: $DEFERRED${NC}  |  ${RED}No iniciados por preflight: $NOT_STARTED${NC}"
echo -e "  Log: $LOG_FILE_ABS"
echo ""

if [ "$DEFERRED" -gt 0 ]; then
    warn "Parada solicitada: $DEFERRED issue(s) quedaron aplazados en esta corrida. No es un fallo del lote: el exit code no cambia por esto y ningun worktree lanzado quedo a medio pipeline."
    # Mismo formato que batch-pipeline.sh y que el motor interno (issue #966),
    # pero apuntando al orquestador que se detuvo: /parallel lanza un pane por
    # issue sin cola (tmux-pipeline.sh --parallel), asi que este scheduler solo
    # corre cuando se invoca el script directo. Proponer /sequential aqui
    # degradaria en silencio el lote paralelo a secuencial.
    echo -e "  Relanza los aplazados, en el mismo orden: ${BOLD}parallel-pipeline.sh ${DEFERRED_NUMS[*]}${NC}"
    echo ""
fi

echo -e "  ${YELLOW}Nota: los PRs NO se mergearon automáticamente.${NC}"
echo -e "  Para integrar a main usa: ${CYAN}/merge <PR_NUM>${NC}"
echo ""

# ─── Cleanup de status files ──────────────────────────────────────────────────
if [ "$KEEP_STATUS" = "false" ]; then
    for issue in "${ISSUE_NUMS[@]}"; do
        # Borrar archivos de status con patron normalizado (cualquier tipo de pipeline)
        for state_dir in "$MEFISTO_STATE_DIR" "$MEFISTO_LEGACY_STATE_DIR"; do
            for sf in "$state_dir"/pipeline-status-*-"${issue}.json"; do
                [ -f "$sf" ] && rm -f "$sf"
            done
        done
    done
fi

if [ "$NOT_STARTED" -gt 0 ]; then
    warn "Preflight de autonomia: $NOT_STARTED issue(s) no iniciados por preflight (distinto de aplazado por parada solicitada). No se reintento ni se amplio ningun permiso; el trabajo en vuelo se recolecto. Log: $LOG_FILE_ABS"
    exit 1
fi
if [ "$FAILED" -gt 0 ]; then
    warn "Algunos issues tuvieron errores. Revisa el log: $LOG_FILE_ABS"
    exit 1
fi
success "parallel-pipeline completado. Log: $LOG_FILE_ABS"
