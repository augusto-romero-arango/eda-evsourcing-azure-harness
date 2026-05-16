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
#
# Enrutamiento automatico: sin --pipeline, cada issue se enruta segun su label tipo:*
#   tipo:feature|refactor       -> tdd-pipeline.sh
#   tipo:tooling               -> tooling-pipeline.sh
#   tipo:infra                 -> SKIP (warning, no aborta)
#   sin label tipo:*           -> SKIP (warning, no aborta)
#
# Flujo: lanza N pipelines en background (cada uno en su worktree aislado),
# monitorea el progreso consolidado, y crea los PRs sin merge automatico.
#
# Compatible con bash 3.2+ (macOS nativo)

set -euo pipefail

# ─── Funciones compartidas ───────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"

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
PIPELINE_DIR=".claude/pipeline"
LOG_DIR="$PIPELINE_DIR/logs"
LOG_FILE="$LOG_DIR/parallel-$TIMESTAMP.log"

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
mkdir -p "$LOG_DIR"
LOG_FILE_ABS="$REPO_ROOT/$LOG_FILE"
PIPELINE_DIR_ABS="$REPO_ROOT/$PIPELINE_DIR"
touch "$LOG_FILE_ABS"

# ─── Verificar dependencias ───────────────────────────────────────────────────
MISSING_DEPS=""
for dep in claude gh git dotnet; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        MISSING_DEPS="$MISSING_DEPS $dep"
    fi
done
if [ -n "$MISSING_DEPS" ]; then
    echo -e "${RED}${BOLD}✗ Dependencias faltantes:${MISSING_DEPS}${NC}"
    exit 1
fi

# ─── Cabecera ─────────────────────────────────────────────────────────────────
header "parallel-pipeline --- Procesamiento paralelo de issues"
log "Pipeline: $([ -n "$PIPELINE_OVERRIDE" ] && echo "$PIPELINE_OVERRIDE (override)" || echo 'automatico por label')"
log "Issues a procesar: ${ISSUE_NUMS[*]}"
log "Paralelismo maximo: $([ "$MAX_PARALLEL" -gt 0 ] && echo "$MAX_PARALLEL" || echo 'sin limite')"
log "Log: $LOG_FILE_ABS"

# ─── Pre-validacion: verificar estado y resolver pipeline por issue ──────────
# Una sola llamada a gh por issue (estado + labels combinados)
log "Verificando estado de los issues y resolviendo pipelines..."
VALID_ISSUES=()
ISSUE_PIPELINES=()
for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
    STATE_AND_PIPELINE=$(resolve_pipeline_with_state "$ISSUE_NUM" "$PIPELINE_OVERRIDE")
    ISSUE_STATE="${STATE_AND_PIPELINE%%|*}"
    RESOLVED="${STATE_AND_PIPELINE#*|}"

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
    log "Issue #$ISSUE_NUM -> $(basename "$RESOLVED")"
done

if [ ${#VALID_ISSUES[@]} -eq 0 ]; then
    abort "No hay issues validos para procesar."
fi

ISSUE_NUMS=("${VALID_ISSUES[@]}")
TOTAL=${#ISSUE_NUMS[@]}
log "$TOTAL issue(s) valido(s): ${ISSUE_NUMS[*]}"

# ─── Lanzar pipelines en paralelo ─────────────────────────────────────────────
PIDS=()          # PID de cada proceso background
STATUS_FILES=()  # Archivo status correspondiente a cada PID
ISSUE_LOGS=()    # Log individual de cada issue
START_TIMES=()   # Timestamp de inicio de cada pipeline

launch_pipeline() {
    local issue="$1"
    local pipeline_script="$2"
    # Determinar tipo de pipeline segun el script
    local pipeline_type="tdd"
    case "$(basename "$pipeline_script")" in
        *tooling*) pipeline_type="tooling" ;;
        *iac*)     pipeline_type="infra" ;;
    esac
    local status_file="pipeline-status-${pipeline_type}-${issue}.json"
    local issue_log="$REPO_ROOT/$LOG_DIR/parallel-issue-${issue}-${TIMESTAMP}.log"
    touch "$issue_log"

    "$pipeline_script" "$issue" --status-file "$status_file" \
        >"$issue_log" 2>&1 &

    PIDS+=($!)
    STATUS_FILES+=("$PIPELINE_DIR_ABS/$status_file")
    ISSUE_LOGS+=("$issue_log")
    START_TIMES+=("$(date +%s)")

    log "Lanzado issue #$issue con $(basename "$pipeline_script") (PID $!) -> $status_file"
}

if [ "$MAX_PARALLEL" -eq 0 ] || [ "$TOTAL" -le "$MAX_PARALLEL" ]; then
    # Lanzar todos de una vez
    for i in "${!ISSUE_NUMS[@]}"; do
        launch_pipeline "${ISSUE_NUMS[$i]}" "${ISSUE_PIPELINES[$i]}"
    done
else
    # Lanzar los primeros N y agregar mas a medida que terminan
    PENDING_IDX=0
    # Lanzar los primeros MAX_PARALLEL
    for ((i=0; i<MAX_PARALLEL && i<TOTAL; i++)); do
        launch_pipeline "${ISSUE_NUMS[$i]}" "${ISSUE_PIPELINES[$i]}"
        PENDING_IDX=$((PENDING_IDX + 1))
    done

    # A medida que terminen, lanzar los siguientes
    while [ "$PENDING_IDX" -lt "$TOTAL" ]; do
        sleep 5
        for i in "${!PIDS[@]}"; do
            if [ -n "${PIDS[$i]}" ] && ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
                # Este slot termino, lanzar el siguiente pendiente
                if [ "$PENDING_IDX" -lt "$TOTAL" ]; then
                    launch_pipeline "${ISSUE_NUMS[$PENDING_IDX]}" "${ISSUE_PIPELINES[$PENDING_IDX]}"
                    PENDING_IDX=$((PENDING_IDX + 1))
                fi
            fi
        done
    done
fi

# ─── Función de lectura de status ────────────────────────────────────────────
read_status_field() {
    local file="$1" field="$2"
    [ -f "$file" ] || { echo "-"; return; }
    python3 -c "
import json, sys
try:
    d = json.load(open('$file'))
    print(d.get('$field', '-') or '-')
except:
    print('-')
" 2>/dev/null || echo "-"
}

read_agent_result() {
    local file="$1" agent="$2" subfield="$3"
    [ -f "$file" ] || { echo "-"; return; }
    python3 -c "
import json, sys
try:
    d = json.load(open('$file'))
    print(d.get('agents', {}).get('$agent', {}).get('$subfield', '-') or '-')
except:
    print('-')
" 2>/dev/null || echo "-"
}

# ─── Dashboard de progreso ────────────────────────────────────────────────────
print_dashboard() {
    local now
    now=$(date +%s)
    local header_str="${CYAN}${BOLD}parallel-pipeline — $TOTAL issue(s) en proceso${NC}"
    echo -e "\n$header_str"
    printf "%s\n" "----------------------------------------------------------------------"
    printf "  ${BOLD}%-6s  %-14s  %-8s  %s${NC}\n" "Issue" "Stage" "Tiempo" "Agentes"
    printf "%s\n" "----------------------------------------------------------------------"

    for i in "${!ISSUE_NUMS[@]}"; do
        local issue="${ISSUE_NUMS[$i]}"
        local status_file="${STATUS_FILES[$i]}"
        local pid="${PIDS[$i]}"
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

        printf "  ${status_color}%-6s  %-14s  %-8s  %s${NC}\n" \
            "#$issue" "${status_label:0:14}" "$time_str" "$agents_str"
    done

    printf "%s\n" "----------------------------------------------------------------------"
}

# ─── Loop de monitoreo ────────────────────────────────────────────────────────
log "Todos los pipelines lanzados. Monitoreando progreso (Ctrl+C para cancelar)..."
echo ""

MONITOR_INTERVAL=10
while true; do
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

for i in "${!ISSUE_NUMS[@]}"; do
    local_pid="${PIDS[$i]}"
    local_issue="${ISSUE_NUMS[$i]}"
    local_status="${STATUS_FILES[$i]}"
    local_start="${START_TIMES[$i]}"

    PIPELINE_EXIT=0
    wait "$local_pid" || PIPELINE_EXIT=$?

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
    elif echo "$RESULT" | grep -q "^ERROR"; then
        COLOR="$RED"
    else
        COLOR="$YELLOW"
    fi

    printf "${COLOR}%-10s  %-50s  %-10s  %s${NC}\n" \
        "#$ISSUE_NUM" "${RESULT:0:50}" "$DUR" "${PR:-(sin PR)}"
done

echo ""
echo -e "  Total: $TOTAL  |  ${GREEN}Completados: $COMPLETED${NC}  |  ${RED}Fallidos: $FAILED${NC}"
echo -e "  Log: $LOG_FILE_ABS"
echo ""
echo -e "  ${YELLOW}Nota: los PRs NO se mergearon automáticamente.${NC}"
echo -e "  Para integrar a main usa: ${CYAN}./scripts/pr-sync.sh <PR_NUM> --merge${NC}"
echo ""

# ─── Cleanup de status files ──────────────────────────────────────────────────
if [ "$KEEP_STATUS" = "false" ]; then
    for issue in "${ISSUE_NUMS[@]}"; do
        # Borrar archivos de status con patron normalizado (cualquier tipo de pipeline)
        for sf in "$PIPELINE_DIR_ABS"/pipeline-status-*-"${issue}.json"; do
            [ -f "$sf" ] && rm -f "$sf"
        done
    done
fi

if [ "$FAILED" -gt 0 ]; then
    warn "Algunos issues tuvieron errores. Revisa el log: $LOG_FILE_ABS"
    exit 1
fi
success "parallel-pipeline completado. Log: $LOG_FILE_ABS"
