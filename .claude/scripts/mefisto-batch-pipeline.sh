#!/usr/bin/env bash
# mefisto-batch-pipeline.sh -- Procesa issues internos de Mefisto secuencialmente
#
# Uso:
#   ./.claude/scripts/mefisto-batch-pipeline.sh 42 43 44
#   ./.claude/scripts/mefisto-batch-pipeline.sh 42 43 --stop-on-error
#
# Flujo por issue:
#   1. ./.claude/scripts/mefisto-tooling-pipeline.sh <issue>
#   2. Extraer URL del PR del output
#   3. gh pr merge <num> --squash --delete-branch
#   4. git pull origin main (actualiza el worktree principal)
#
# En Mefisto solo existe el pipeline de tooling, asi que no hay flag --pipeline
# ni enrutamiento por label.
#
# Compatible con bash 3.2+ (macOS nativo).

set -euo pipefail

# --- Funciones compartidas ---
source "$(dirname "${BASH_SOURCE[0]}")/_mefisto-common.sh"
assert_in_mefisto || exit 1

# --- Colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Logging ---
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PIPELINE_DIR=".claude/pipeline"
LOG_DIR="$PIPELINE_DIR/logs"
LOG_FILE="$LOG_DIR/mefisto-batch-$TIMESTAMP.log"

_strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
_log_file()   { echo -e "$1" | _strip_ansi >> "$LOG_FILE_ABS"; }

log()     { local m="${BLUE}[$(date +%H:%M:%S)]${NC} $1"; echo -e "$m"; _log_file "$m"; }
success() { local m="${GREEN}${BOLD}v${NC} $1"; echo -e "$m"; _log_file "$m"; }
warn()    { local m="${YELLOW}!${NC} $1"; echo -e "$m"; _log_file "$m"; }
header()  { local m="\n${CYAN}${BOLD}-- $1 --${NC}"; echo -e "$m"; _log_file "$m"; }
abort() {
    echo -e "\n${RED}${BOLD}x ERROR FATAL: $1${NC}" | tee -a "$LOG_FILE_ABS"
    echo -e "${YELLOW}Revisa el log: $LOG_FILE_ABS${NC}"
    exit 1
}

# --- Status tracker (compatible bash 3.2, sin declare -A) ---
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

# --- Fallo no fatal de un issue (continua el loop) ---
HAVE_ERRORS=false

fail_issue() {
    local issue="$1" msg="$2"
    echo -e "\n${RED}${BOLD}x Issue #$issue: $msg${NC}" | tee -a "$LOG_FILE_ABS"
    set_status "$issue" "ERROR: $msg"
    HAVE_ERRORS=true
}

# --- Parsear argumentos ---
ISSUE_NUMS=()
STOP_ON_ERROR=false

if [ $# -eq 0 ]; then
    echo "Uso: $0 <issue1> <issue2> ... [--stop-on-error]"
    echo "  issue1 ...         Numeros de issues a procesar (en orden)"
    echo "  --stop-on-error    Abortar en el primer fallo (por defecto: continuar)"
    exit 1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --stop-on-error) STOP_ON_ERROR=true; shift ;;
        [0-9]*)          ISSUE_NUMS+=("$1"); shift ;;
        *)
            echo "Argumento desconocido: $1"
            exit 1
            ;;
    esac
done

if [ ${#ISSUE_NUMS[@]} -eq 0 ]; then
    echo -e "${RED}${BOLD}x No se especificaron issues.${NC}"
    exit 1
fi

# --- Repo root (validado por assert_in_mefisto) ---
REPO_ROOT="$MEFISTO_REPO_ROOT"
cd "$REPO_ROOT"

# --- Inicializar log ---
mkdir -p "$LOG_DIR"
LOG_FILE_ABS="$REPO_ROOT/$LOG_FILE"
touch "$LOG_FILE_ABS"

# Inicializar status tracker
for issue in "${ISSUE_NUMS[@]}"; do
    set_status "$issue" "pendiente"
done

# --- Verificar dependencias ---
MISSING_DEPS=""
for dep in claude gh git; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        MISSING_DEPS="$MISSING_DEPS $dep"
    fi
done
if [ -n "$MISSING_DEPS" ]; then
    echo -e "${RED}${BOLD}x Dependencias faltantes:${MISSING_DEPS}${NC}"
    exit 1
fi

# --- Cabecera ---
header "mefisto-batch-pipeline --- Procesamiento secuencial de issues internos"
log "Pipeline: mefisto-tooling (unico pipeline interno de Mefisto)"
log "Issues a procesar: ${ISSUE_NUMS[*]}"
log "Modo en error: $([ "$STOP_ON_ERROR" = true ] && echo 'detener' || echo 'continuar')"
log "Log: $LOG_FILE_ABS"

PIPELINE_SCRIPT="./.claude/scripts/mefisto-tooling-pipeline.sh"
if [ ! -x "$PIPELINE_SCRIPT" ]; then
    abort "No se encontro el pipeline interno: $PIPELINE_SCRIPT"
fi

# --- Loop principal ---
COMPLETED=0
FAILED=0
TOTAL=${#ISSUE_NUMS[@]}

for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
    CURRENT=$((COMPLETED + FAILED + 1))
    header "Issue #$ISSUE_NUM ($CURRENT/$TOTAL)"

    # -- Stage 1: Ejecutar pipeline interno --
    # El propio pipeline interno valida que el issue exista y este OPEN.
    # Aqui solo capturamos el exit code y lo registramos como error del issue.
    log "Ejecutando mefisto-tooling-pipeline.sh para issue #$ISSUE_NUM..."

    ISSUE_LOG="$REPO_ROOT/$LOG_DIR/mefisto-batch-issue-${ISSUE_NUM}-${TIMESTAMP}.log"
    touch "$ISSUE_LOG"

    PIPELINE_EXIT=0
    "$PIPELINE_SCRIPT" "$ISSUE_NUM" 2>&1 | tee "$ISSUE_LOG" || PIPELINE_EXIT=$?

    # Agregar el log del issue al log general (sin codigos ANSI)
    _strip_ansi < "$ISSUE_LOG" >> "$LOG_FILE_ABS"

    if [ "$PIPELINE_EXIT" -ne 0 ]; then
        fail_issue "$ISSUE_NUM" "pipeline fallo (exit $PIPELINE_EXIT). Log: $ISSUE_LOG"
        FAILED=$((FAILED + 1))
        if [ "$STOP_ON_ERROR" = true ]; then
            abort "Detenido por --stop-on-error en issue #$ISSUE_NUM"
        fi
        continue
    fi

    # -- Stage 2: Extraer numero de PR del output --
    # mefisto-tooling-pipeline.sh imprime entre otras lineas:
    #   "v PR creado: https://github.com/owner/repo/pull/NNN"
    #   "  PR:      https://github.com/owner/repo/pull/NNN"
    PR_URL=$(_strip_ansi < "$ISSUE_LOG" \
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
    success "Pipeline completado -> PR #$PR_NUM ($PR_URL)"

    # -- Stage 3: Merge del PR --
    # En Mefisto no usamos pr-sync.sh (es del lado publicado). Mergeamos con
    # gh pr merge directo, con squash + delete-branch (consistente con
    # .claude/commands/mefisto-merge.md).
    log "Mergeando PR #$PR_NUM a main (squash + delete-branch)..."

    MERGE_EXIT=0
    gh pr merge "$PR_NUM" --squash --delete-branch 2>&1 | tee -a "$ISSUE_LOG" || MERGE_EXIT=$?

    _strip_ansi < "$ISSUE_LOG" >> "$LOG_FILE_ABS"

    if [ "$MERGE_EXIT" -ne 0 ]; then
        fail_issue "$ISSUE_NUM" "merge del PR #$PR_NUM fallo (exit $MERGE_EXIT). Log: $ISSUE_LOG"
        FAILED=$((FAILED + 1))
        if [ "$STOP_ON_ERROR" = true ]; then
            abort "Detenido por --stop-on-error en issue #$ISSUE_NUM"
        fi
        continue
    fi

    # -- Stage 4: Actualizar main local para el siguiente issue --
    log "Actualizando main local..."
    git pull origin main >>"$LOG_FILE_ABS" 2>&1 || warn "git pull origin main fallo (continuando)"

    set_status "$ISSUE_NUM" "completado (PR #$PR_NUM mergeado)"
    COMPLETED=$((COMPLETED + 1))
    success "Issue #$ISSUE_NUM completado y mergeado"
done

# --- Resumen final ---
header "Resumen"
echo -e ""
printf "${BOLD}%-10s %-8s %-45s${NC}\n" "Issue" "PR" "Estado"
printf "%s\n" "-----------------------------------------------------------------"

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

echo ""
echo -e "  Total: $TOTAL  |  ${GREEN}Completados: $COMPLETED${NC}  |  ${RED}Fallidos: $FAILED${NC}"
echo -e "  Log: $LOG_FILE_ABS"
echo ""

if [ "$HAVE_ERRORS" = true ]; then
    warn "Algunos issues tuvieron errores. Revisa el log: $LOG_FILE_ABS"
    exit 1
fi
success "mefisto-batch-pipeline completado. Log: $LOG_FILE_ABS"
