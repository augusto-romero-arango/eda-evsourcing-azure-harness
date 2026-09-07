#!/usr/bin/env bash
# batch-pipeline.sh --- Ejecuta pipelines para multiples issues secuencialmente
#
# Uso:
#   ./scripts/batch-pipeline.sh 42 43 44                          # enrutamiento automatico por label
#   ./scripts/batch-pipeline.sh --pipeline tooling 60 62 63       # forzar pipeline tooling
#   ./scripts/batch-pipeline.sh --pipeline tdd 42 43              # forzar pipeline tdd
#   ./scripts/batch-pipeline.sh 42 43 --stop-on-error             # abortar en primer fallo
#
# Enrutamiento automatico: sin --pipeline, cada issue se enruta segun su label tipo:*
#   tipo:feature|refactor|projection -> tdd-pipeline.sh
#   tipo:tooling                     -> tooling-pipeline.sh
#   tipo:infra                       -> SKIP (warning, no aborta)
#   sin label tipo:*                 -> SKIP (warning, no aborta)
#
# Flujo por issue: pipeline -> extraer PR -> pr-sync.sh --merge -> siguiente issue
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
LOG_FILE="$LOG_DIR/batch-$TIMESTAMP.log"

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

# ─── Status tracker (compatible bash 3.2, sin declare -A) ────────────────────
ISSUE_STATUS_NUMS=()
ISSUE_STATUS_VALUES=()
ISSUE_STATUS_PRS=()

set_status() {
    local issue="$1" val="$2"
    local i
    for i in "${!ISSUE_STATUS_NUMS[@]}"; do
        if [ "${ISSUE_STATUS_NUMS[$i]}" = "$issue" ]; then
            ISSUE_STATUS_VALUES[$i]="$val"
            return
        fi
    done
    ISSUE_STATUS_NUMS+=("$issue")
    ISSUE_STATUS_VALUES+=("$val")
    ISSUE_STATUS_PRS+=("")
}

get_status() {
    local issue="$1" i
    for i in "${!ISSUE_STATUS_NUMS[@]}"; do
        if [ "${ISSUE_STATUS_NUMS[$i]}" = "$issue" ]; then
            echo "${ISSUE_STATUS_VALUES[$i]}"
            return
        fi
    done
    echo "desconocido"
}

set_pr() {
    local issue="$1" pr="$2"
    local i
    for i in "${!ISSUE_STATUS_NUMS[@]}"; do
        if [ "${ISSUE_STATUS_NUMS[$i]}" = "$issue" ]; then
            ISSUE_STATUS_PRS[$i]="$pr"
            return
        fi
    done
    ISSUE_STATUS_NUMS+=("$issue")
    ISSUE_STATUS_VALUES+=("pendiente")
    ISSUE_STATUS_PRS+=("$pr")
}

get_pr() {
    local issue="$1" i
    for i in "${!ISSUE_STATUS_NUMS[@]}"; do
        if [ "${ISSUE_STATUS_NUMS[$i]}" = "$issue" ]; then
            echo "${ISSUE_STATUS_PRS[$i]:-""}"
            return
        fi
    done
    echo ""
}

# ─── Fallo no fatal de un issue (continúa el loop) ───────────────────────────
HAVE_ERRORS=false

fail_issue() {
    local issue="$1" msg="$2"
    echo -e "\n${RED}${BOLD}✗ Issue #$issue: $msg${NC}" | tee -a "$LOG_FILE_ABS"
    set_status "$issue" "ERROR: $msg"
    HAVE_ERRORS=true
}

# ─── Senal de parada suave del batch (issue #974, mismo diseno que el motor ──
# ─── interno #966) ────────────────────────────────────────────────────────────
# Un batch largo no se podia frenar sin matar el pane de tmux/herdr, dejando el
# eslabon en curso a medio pipeline. La senal es un archivo de mera PRESENCIA
# (sin campos que parsear) que /batch-stop escribe desde el checkout principal.
# Vive en pipeline-state/batch-stop -- fuera de .claude/ por construccion
# (MEF-ADR-0017: el runtime intercepta toda escritura bajo .claude/**, incluidas
# redirecciones de Bash) --, misma ubicacion que refactor-signal.md. Que no se
# versione no depende de este script: el bloque de .gitignore que emite
# infra-base-scaffolder lista pipeline-state/ en greenfield (un consumidor ya
# scaffoldeado tiene que anadir la linea a mano, issue #485) y el auto-commit de
# tooling-pipeline.sh la excluye de su `git add` en cualquier caso.
#
# Se consulta en dos momentos (CA-1): antes de arrancar el primer eslabon, y
# despues de cada eslabon completado (pipeline + PR + merge) -- el unico punto
# seguro de la cadena. Un eslabon que fallo nunca llega al segundo chequeo: su
# `continue` lo salta, asi que la senal no interrumpe una cadena que ya estaba
# fallando por otra razon -- solo el camino de exito la consulta.
BATCH_STOP_SIGNAL="pipeline-state/batch-stop"

batch_stop_requested() {
    [ -f "$BATCH_STOP_SIGNAL" ]
}

# defer_from_index <indice-0-based>
#
# Consume la senal (CA-5: se borra para no envenenar la corrida siguiente) y
# marca "aplazado" (CA-2) todos los issues de ISSUE_NUMS desde <indice> en
# adelante. Nunca toca HAVE_ERRORS/FAILED/--stop-on-error (CA-5: una parada
# solicitada no es un fallo del batch).
defer_from_index() {
    local from="$1" i
    rm -f "$BATCH_STOP_SIGNAL"
    for ((i = from; i < ${#ISSUE_NUMS[@]}; i++)); do
        set_status "${ISSUE_NUMS[$i]}" "aplazado (parada solicitada; no se proceso en esta corrida)"
    done
}

# ─── Parsear argumentos ───────────────────────────────────────────────────────
ISSUE_NUMS=()
STOP_ON_ERROR=false
PIPELINE_OVERRIDE=""  # vacio = enrutamiento automatico por label

if [ $# -eq 0 ]; then
    echo "Uso: $0 [--pipeline tdd|tooling] <issue1> <issue2> ... [--stop-on-error]"
    echo "  --pipeline TYPE    Forzar pipeline: 'tdd' o 'tooling' (sin flag: enruta por label tipo:*)"
    echo "  issue1 ...         Numeros de issues a procesar (en orden)"
    echo "  --stop-on-error    Abortar en el primer fallo (por defecto: continuar)"
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
        --stop-on-error) STOP_ON_ERROR=true; shift ;;
        [0-9]*)          ISSUE_NUMS+=("$1"); shift ;;
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
    echo "ERROR: batch-pipeline.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Estás en el repo de Mefisto. Trabaja los issues internos secuencialmente con /mefisto-tooling." >&2
    exit 1
fi

cd "$REPO_ROOT"

# Validación de homogeneidad: igual que en parallel-pipeline.sh, todos los issues
# del batch se asumen del repo actual; gh issue view N consulta el repo del cwd.

# ─── Inicializar log ──────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
LOG_FILE_ABS="$REPO_ROOT/$LOG_FILE"
touch "$LOG_FILE_ABS"

# Inicializar status tracker
for issue in "${ISSUE_NUMS[@]}"; do
    set_status "$issue" "pendiente"
done

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
header "batch-pipeline --- Procesamiento secuencial de issues"
log "Pipeline: $([ -n "$PIPELINE_OVERRIDE" ] && echo "$PIPELINE_OVERRIDE (override)" || echo 'automatico por label')"
log "Issues a procesar: ${ISSUE_NUMS[*]}"
log "Modo en error: $([ "$STOP_ON_ERROR" = true ] && echo 'detener' || echo 'continuar')"
log "Log: $LOG_FILE_ABS"
log "Parada suave: /batch-stop detiene el batch tras el eslabon en curso (issue #974)"

# ─── Loop principal ───────────────────────────────────────────────────────────
COMPLETED=0
FAILED=0
TOTAL=${#ISSUE_NUMS[@]}

# Cola efectiva de esta corrida (issue #974): ISSUE_NUMS conserva el orden
# pedido -- es lo que recorre el resumen final --, mientras BATCH_QUEUE es lo
# que el loop realmente procesa. Vaciarla es como se salta el loop completo sin
# envolverlo en un `if` (que forzaria a reindentar todo su cuerpo).
BATCH_QUEUE=("${ISSUE_NUMS[@]}")

# Parada suave, momento 1 (CA-1): la senal ya estaba puesta antes de arrancar
# el primer eslabon, asi que ningun issue se procesa en esta corrida.
if batch_stop_requested; then
    warn "Parada solicitada ($BATCH_STOP_SIGNAL) antes de arrancar el primer eslabon: ningun issue se procesa en esta corrida."
    defer_from_index 0
    BATCH_QUEUE=()
fi

# ${a[@]+"${a[@]}"}: bash 3.2 aborta con "unbound variable" al expandir un array
# vacio bajo `set -u` (este script corre con `set -euo pipefail`), y la cola
# queda vacia justamente cuando la parada se pidio antes del primer eslabon.
for ISSUE_NUM in ${BATCH_QUEUE[@]+"${BATCH_QUEUE[@]}"}; do
    CURRENT=$((COMPLETED + FAILED + 1))
    header "Issue #$ISSUE_NUM ($CURRENT/$TOTAL)"

    # ── Pre-validacion y resolucion de pipeline (una sola llamada API) ──────
    STATE_AND_PIPELINE=$(resolve_pipeline_with_state "$ISSUE_NUM" "$PIPELINE_OVERRIDE")
    ISSUE_STATE="${STATE_AND_PIPELINE%%|*}"
    PIPELINE_SCRIPT="${STATE_AND_PIPELINE#*|}"

    if [ "$ISSUE_STATE" != "OPEN" ]; then
        log "Issue #$ISSUE_NUM esta $ISSUE_STATE --- saltando."
        FAILED=$((FAILED + 1))
        continue
    fi

    if [[ "$PIPELINE_SCRIPT" == SKIP:* ]]; then
        local_reason="${PIPELINE_SCRIPT#SKIP:}"
        warn "Issue #$ISSUE_NUM saltado ($local_reason) --- no se puede enrutar a un pipeline."
        FAILED=$((FAILED + 1))
        continue
    fi

    PIPELINE_NAME=$(basename "$PIPELINE_SCRIPT")

    # ── Stage 1: Ejecutar pipeline ────────────────────────────────────────────
    log "Ejecutando $PIPELINE_NAME para issue #$ISSUE_NUM..."

    ISSUE_LOG="$REPO_ROOT/$LOG_DIR/batch-issue-${ISSUE_NUM}-${TIMESTAMP}.log"
    touch "$ISSUE_LOG"

    PIPELINE_EXIT=0
    "$PIPELINE_SCRIPT" "$ISSUE_NUM" 2>&1 | tee "$ISSUE_LOG" || PIPELINE_EXIT=$?

    # Agregar el log del issue al log general
    cat "$ISSUE_LOG" | _strip_ansi >> "$LOG_FILE_ABS"

    if [ "$PIPELINE_EXIT" -ne 0 ]; then
        fail_issue "$ISSUE_NUM" "pipeline fallo (exit $PIPELINE_EXIT). Log: $ISSUE_LOG"
        FAILED=$((FAILED + 1))
        if [ "$STOP_ON_ERROR" = true ]; then
            abort "Detenido por --stop-on-error en issue #$ISSUE_NUM"
        fi
        continue
    fi

    # ── Stage 2: Extraer número de PR ────────────────────────────────────────
    # tdd-pipeline.sh imprime: "PR creado: https://github.com/owner/repo/pull/NNN"
    # y también: "  PR:      https://github.com/owner/repo/pull/NNN"
    PR_URL=$(cat "$ISSUE_LOG" \
        | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' \
        | head -1)

    if [ -z "$PR_URL" ]; then
        fail_issue "$ISSUE_NUM" "no se pudo extraer la URL del PR del output. Log: $ISSUE_LOG"
        FAILED=$((FAILED + 1))
        if [ "$STOP_ON_ERROR" = true ]; then
            abort "Detenido por --stop-on-error en issue #$ISSUE_NUM"
        fi
        continue
    fi

    PR_NUM=$(echo "$PR_URL" | grep -oE '[0-9]+$')
    set_pr "$ISSUE_NUM" "$PR_NUM"
    success "Pipeline completado → PR #$PR_NUM ($PR_URL)"

    # ── Stage 3: Merge del PR ─────────────────────────────────────────────────
    log "Mergeando PR #$PR_NUM a main..."

    SYNC_EXIT=0
    "$(_pc_script_dir)/pr-sync.sh" "$PR_NUM" --merge 2>&1 | tee -a "$ISSUE_LOG" || SYNC_EXIT=$?

    cat "$ISSUE_LOG" | _strip_ansi >> "$LOG_FILE_ABS"

    if [ "$SYNC_EXIT" -ne 0 ]; then
        fail_issue "$ISSUE_NUM" "merge del PR #$PR_NUM falló (exit $SYNC_EXIT). Log: $ISSUE_LOG"
        FAILED=$((FAILED + 1))
        if [ "$STOP_ON_ERROR" = true ]; then
            abort "Detenido por --stop-on-error en issue #$ISSUE_NUM"
        fi
        continue
    fi

    # ── Stage 4: Actualizar main local para el siguiente issue ────────────────
    log "Actualizando main local..."
    git pull origin main >>"$LOG_FILE_ABS" 2>&1 || warn "git pull origin main falló (continuando)"

    set_status "$ISSUE_NUM" "completado (PR #$PR_NUM mergeado)"
    COMPLETED=$((COMPLETED + 1))
    success "Issue #$ISSUE_NUM completado y mergeado"

    # Parada suave, momento 2 (CA-1): el unico punto seguro de la cadena -- el
    # PR ya esta mergeado. Un eslabon fallido (pipeline/PR/merge) nunca llega
    # aqui: sus `continue` de arriba lo saltan.
    if batch_stop_requested; then
        if [ "$CURRENT" -lt "$TOTAL" ]; then
            warn "Parada solicitada ($BATCH_STOP_SIGNAL) tras completar #$ISSUE_NUM: los eslabones restantes quedan aplazados, sin arrancar ningun worktree."
        else
            warn "Parada solicitada ($BATCH_STOP_SIGNAL) tras completar #$ISSUE_NUM, que era el ultimo eslabon del batch: no quedaba ninguno por arrancar. La senal se consumio igual, para no afectar la corrida siguiente."
        fi
        defer_from_index "$CURRENT"
        break
    fi
done

# ─── Resumen final ────────────────────────────────────────────────────────────
header "Resumen"
echo -e ""
printf "${BOLD}%-10s %-8s %-45s${NC}\n" "Issue" "PR" "Estado"
printf "%s\n" "─────────────────────────────────────────────────────────────────"

for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
    PR=$(get_pr "$ISSUE_NUM")
    STATUS=$(get_status "$ISSUE_NUM")
    if echo "$STATUS" | grep -q "^completado"; then
        COLOR="$GREEN"
    elif echo "$STATUS" | grep -q "^ERROR"; then
        COLOR="$RED"
    else
        COLOR="$YELLOW"
    fi
    printf "${COLOR}%-10s %-8s %-45s${NC}\n" "#$ISSUE_NUM" "${PR:-(n/a)}" "$STATUS"
done

# Issues aplazados (issue #974, CA-4): en el mismo orden en que quedaron en
# ISSUE_NUMS, para que la linea de relanzamiento respete el orden del batch.
DEFERRED_NUMS=()
for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
    case "$(get_status "$ISSUE_NUM")" in
        aplazado*) DEFERRED_NUMS+=("$ISSUE_NUM") ;;
    esac
done
DEFERRED=${#DEFERRED_NUMS[@]}

echo ""
echo -e "  Total: $TOTAL  |  ${GREEN}Completados: $COMPLETED${NC}  |  ${RED}Fallidos: $FAILED${NC}  |  ${YELLOW}Aplazados: $DEFERRED${NC}"
echo -e "  Log: $LOG_FILE_ABS"
echo ""

if [ "$DEFERRED" -gt 0 ]; then
    warn "Parada solicitada: $DEFERRED issue(s) quedaron aplazados en esta corrida. No es un fallo del batch: el exit code no cambia por esto y nada quedo a medio pipeline."
    echo -e "  Relanza los aplazados, en el mismo orden: ${BOLD}/sequential ${DEFERRED_NUMS[*]}${NC}"
    echo ""
fi

if [ "$HAVE_ERRORS" = true ]; then
    warn "Algunos issues tuvieron errores. Revisa el log: $LOG_FILE_ABS"
    exit 1
fi
success "batch-pipeline completado. Log: $LOG_FILE_ABS"
