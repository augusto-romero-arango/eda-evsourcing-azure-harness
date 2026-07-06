#!/usr/bin/env bash
# scaffold-pipeline.sh - Pipeline standalone para crear un nuevo dominio
#
# Uso:
#   ./scripts/scaffold-pipeline.sh 42                          # issue (extrae dominio del body)
#   ./scripts/scaffold-pipeline.sh 42 --domain calculo-horas   # issue + dominio explicito
#   ./scripts/scaffold-pipeline.sh --domain calculo-horas       # sin issue (solo scaffold + PR)
#   ./scripts/scaffold-pipeline.sh --help
#
# Ciclo: Issue -> Worktree -> Label -> domain-scaffolder -> PR -> Cleanup

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"

# Guard defensivo: este pipeline es del lado publicado y solo aplica al consumidor.
# Si detectamos .claude-plugin/plugin.json en la raiz, estamos en el repo de Mefisto.
_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$_REPO_TOP/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/scaffold-pipeline.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Estas en el repo de Mefisto, que no crea dominios de negocio." >&2
    echo "Para mejorar el plugin usa /mefisto-tooling." >&2
    exit 1
fi
unset _REPO_TOP

load_harness_config || exit 1

# --- Colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Logging ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PIPELINE_DIR="$REPO_ROOT/.claude/pipeline"
LOG_DIR="$PIPELINE_DIR/logs"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$LOG_DIR/scaffold-$TIMESTAMP.log"
EVENTS_LOG="$PIPELINE_DIR/events.log"

mkdir -p "$LOG_DIR"
touch "$EVENTS_LOG"

log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; echo "[$(date +%H:%M:%S)] $1" >> "$LOG_FILE"; }
success() { echo -e "${GREEN}${BOLD}✓${NC} $1"; echo "OK $1" >> "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; echo "WARN $1" >> "$LOG_FILE"; }
header()  { echo -e "\n${CYAN}${BOLD}-- $1 --${NC}"; echo "-- $1 --" >> "$LOG_FILE"; }
abort()   { echo -e "\n${RED}${BOLD}x $1${NC}" >&2; echo "ABORT $1" >> "$LOG_FILE"; exit 1; }

# --- Cleanup on error ---
WORKTREE_PATH=""
cleanup_on_error() {
    if [ -n "$WORKTREE_PATH" ] && [ -d "$WORKTREE_PATH" ]; then
        warn "Error detectado. El worktree queda disponible para inspeccion: $WORKTREE_PATH"
    fi
}
trap cleanup_on_error ERR

# --- Help ---
show_help() {
    cat <<EOF

${CYAN}${BOLD}scaffold-pipeline.sh${NC} - Pipeline para crear un nuevo dominio

${BOLD}Uso:${NC}
  ./scripts/scaffold-pipeline.sh 42                          Issue (extrae dominio del body)
  ./scripts/scaffold-pipeline.sh 42 --domain calculo-horas   Issue + dominio explicito
  ./scripts/scaffold-pipeline.sh --domain calculo-horas       Sin issue (solo scaffold + PR)

${BOLD}El issue debe contener en el body:${NC}
  Dominio: nombre-en-kebab

${BOLD}El script:${NC}
  1. Crea el label dom:X y lo asigna al issue
  2. Crea un worktree aislado
  3. Invoca el agente domain-scaffolder
  4. Crea un PR con "Closes #N"
  5. Limpia el worktree

EOF
}

# --- Parsear argumentos ---
ISSUE_NUM=""
DOMAIN_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            show_help
            exit 0
            ;;
        --domain)
            [ $# -lt 2 ] && abort "Falta el nombre del dominio para --domain"
            DOMAIN_NAME="$2"
            shift 2
            ;;
        --domain=*)
            DOMAIN_NAME="${1#*=}"
            shift
            ;;
        [0-9]*)
            ISSUE_NUM="$1"
            shift
            ;;
        *)
            abort "Argumento desconocido: $1. Usa --help para ver el uso."
            ;;
    esac
done

# --- Verificar dependencias ---
for cmd in claude gh git; do
    command -v "$cmd" &>/dev/null || abort "$cmd no esta instalado"
done

# --- Obtener contexto del issue ---
ISSUE_TITLE=""
ISSUE_BODY=""
REPO_SLUG=""

REPO_SLUG=$(git -C "$REPO_ROOT" remote get-url origin | sed 's/.*github.com[:/]\(.*\)\.git/\1/')

if [ -n "$ISSUE_NUM" ]; then
    header "Descargando issue #$ISSUE_NUM"

    ISSUE_JSON=$(gh issue view "$ISSUE_NUM" --json number,title,body,state --repo "$REPO_SLUG" 2>>"$LOG_FILE") \
        || abort "No se pudo obtener el issue #$ISSUE_NUM"

    ISSUE_STATE=$(echo "$ISSUE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])")
    [ "$ISSUE_STATE" = "OPEN" ] || abort "El issue #$ISSUE_NUM no esta abierto (estado: $ISSUE_STATE)"

    ISSUE_TITLE=$(echo "$ISSUE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")
    ISSUE_BODY=$(echo "$ISSUE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['body'])")

    log "Issue: #$ISSUE_NUM - $ISSUE_TITLE"

    # Extraer dominio del body si no fue dado explicitamente
    if [ -z "$DOMAIN_NAME" ]; then
        DOMAIN_NAME=$(echo "$ISSUE_BODY" | sed -n 's/.*[Dd]ominio:[[:space:]]*\([a-zA-Z][a-zA-Z0-9-]*\).*/\1/p' | head -1 || true)
        if [ -n "$DOMAIN_NAME" ]; then
            log "Dominio extraido del issue: $DOMAIN_NAME"
        fi
    fi
fi

# --- Validar que hay nombre de dominio ---
if [ -z "$DOMAIN_NAME" ]; then
    abort "No se pudo determinar el nombre del dominio. Usa --domain <nombre> o incluye 'Dominio: nombre' en el body del issue."
fi

# Normalizar dominio a kebab-case (acepta PascalCase, camelCase, snake_case)
DOMAIN_NAME=$(echo "$DOMAIN_NAME" \
    | sed 's/_/-/g' \
    | sed 's/\([a-z0-9]\)\([A-Z]\)/\1-\2/g' \
    | tr '[:upper:]' '[:lower:]')

# Validar formato kebab-case
if ! echo "$DOMAIN_NAME" | grep -qE '^[a-z][a-z0-9]*(-[a-z0-9]+)*$'; then
    abort "El nombre del dominio no se pudo normalizar a kebab-case. Recibido: $DOMAIN_NAME"
fi

# Derivar PascalCase
PASCAL_CASE=$(echo "$DOMAIN_NAME" | awk -F'-' '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1' OFS='')

log "Dominio: $DOMAIN_NAME (PascalCase: $PASCAL_CASE)"

# Verificar que el dominio no existe ya
if [ -d "$REPO_ROOT/src/${HARNESS_NAMESPACE_PREFIX}.$PASCAL_CASE" ]; then
    abort "El dominio ya existe: src/${HARNESS_NAMESPACE_PREFIX}.$PASCAL_CASE"
fi

# --- Crear label dom:X ---
header "Configurando label"

gh label create "dom:$DOMAIN_NAME" --color "0E8A16" --description "Dominio $PASCAL_CASE" --force --repo "$REPO_SLUG" >>"$LOG_FILE" 2>&1 \
    || warn "No se pudo crear el label dom:$DOMAIN_NAME (puede que ya exista)"
success "Label dom:$DOMAIN_NAME listo"

if [ -n "$ISSUE_NUM" ]; then
    gh issue edit "$ISSUE_NUM" --add-label "dom:$DOMAIN_NAME" --repo "$REPO_SLUG" >>"$LOG_FILE" 2>&1 \
        || warn "No se pudo asignar el label al issue #$ISSUE_NUM"
    log "Label asignado al issue #$ISSUE_NUM"
fi

# --- Preparar worktree ---
header "Preparando worktree"

CURRENT_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)

# El worktree se ramifica SIEMPRE desde origin/main actualizado, sea cual sea
# la rama del cwd. El guard queda solo como contexto informativo en el log.
if [ "$CURRENT_BRANCH" != "main" ] && [ "$CURRENT_BRANCH" != "master" ]; then
    warn "cwd en rama '$CURRENT_BRANCH' (no main/master): el worktree se creara igual desde origin/main"
fi

log "Actualizando origin/main..."
git -C "$REPO_ROOT" fetch origin main >>"$LOG_FILE" 2>&1 \
    || abort "No se pudo hacer fetch de origin/main"

if [ -n "$ISSUE_NUM" ]; then
    BRANCH_NAME="scaffold-issue-${ISSUE_NUM}-${DOMAIN_NAME}"
else
    BRANCH_NAME="scaffold-${DOMAIN_NAME}"
fi
WORKTREE_PATH="${REPO_ROOT}/../${BRANCH_NAME}"

# Idempotencia: limpiar worktree/rama existente
if [ -d "$WORKTREE_PATH" ]; then
    warn "El worktree ya existe: $WORKTREE_PATH -- limpiando para reiniciar..."
    git -C "$REPO_ROOT" worktree remove --force "$WORKTREE_PATH" >>"$LOG_FILE" 2>&1 || true
    git -C "$REPO_ROOT" branch -D "$BRANCH_NAME" >>"$LOG_FILE" 2>&1 || true
fi
if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH_NAME" 2>/dev/null; then
    warn "La rama $BRANCH_NAME ya existe sin worktree -- eliminandola..."
    git -C "$REPO_ROOT" branch -D "$BRANCH_NAME" >>"$LOG_FILE" 2>&1 || true
fi

log "Creando worktree: $WORKTREE_PATH (base: origin/main)"
git -C "$REPO_ROOT" worktree add "$WORKTREE_PATH" -b "$BRANCH_NAME" origin/main >>"$LOG_FILE" 2>&1 \
    || abort "No se pudo crear el worktree desde origin/main"

success "Worktree creado: $WORKTREE_PATH"

# Parchear settings.json del worktree con ruta absoluta del events.log
if [ -f "$REPO_ROOT/.claude/settings.json" ]; then
    sed "s|\.claude/pipeline/events\.log|${EVENTS_LOG}|g" \
        "$REPO_ROOT/.claude/settings.json" > "$WORKTREE_PATH/.claude/settings.json"
fi

# --- Invocar domain-scaffolder ---
header "Invocando domain-scaffolder"

SCAFFOLD_PROMPT="Crea el scaffold para el dominio '$DOMAIN_NAME'. El usuario ya confirmo la creacion -- omite la confirmacion del Paso 0 y procede directamente a crear el proyecto."
SCAFFOLD_TIMEOUT=1800
SCAFFOLD_LOG="$LOG_DIR/scaffold-agent-$TIMESTAMP.log"

echo "[$(date +%H:%M:%S)] === SCAFFOLD: domain-scaffolder para '$DOMAIN_NAME' ===" >> "$EVENTS_LOG"

scaffold_start=$(date +%s)

(cd "$WORKTREE_PATH" && claude -p "$SCAFFOLD_PROMPT" \
    --agent domain-scaffolder \
    --permission-mode bypassPermissions \
    --output-format text \
    >"$SCAFFOLD_LOG" 2>&1) &
SCAFFOLD_PID=$!

(sleep $SCAFFOLD_TIMEOUT && kill -9 $SCAFFOLD_PID 2>/dev/null && \
    echo "[$(date +%H:%M:%S)] TIMEOUT: domain-scaffolder supero ${SCAFFOLD_TIMEOUT}s" >> "$EVENTS_LOG") &
WATCHDOG_PID=$!

SCAFFOLD_EXIT=0
wait $SCAFFOLD_PID || SCAFFOLD_EXIT=$?
kill $WATCHDOG_PID 2>/dev/null || true
wait $WATCHDOG_PID 2>/dev/null || true

scaffold_elapsed=$(( $(date +%s) - scaffold_start ))

if [ "$SCAFFOLD_EXIT" -ne 0 ]; then
    echo "[$(date +%H:%M:%S)] FALLO domain-scaffolder (${scaffold_elapsed}s, exit $SCAFFOLD_EXIT)" >> "$EVENTS_LOG"
    abort "El scaffold del dominio '$DOMAIN_NAME' fallo despues de ${scaffold_elapsed}s. Revisa: $SCAFFOLD_LOG"
fi

# Verificar que el proyecto fue creado
if [ ! -d "$WORKTREE_PATH/src/${HARNESS_NAMESPACE_PREFIX}.$PASCAL_CASE" ]; then
    abort "El scaffold no creo src/${HARNESS_NAMESPACE_PREFIX}.$PASCAL_CASE -- revisa: $SCAFFOLD_LOG"
fi

echo "[$(date +%H:%M:%S)] OK domain-scaffolder (${scaffold_elapsed}s)" >> "$EVENTS_LOG"
success "Scaffold completado en ${scaffold_elapsed}s"

# --- Push + Crear PR ---
header "Creando PR"

log "Haciendo push de la rama..."
git -C "$WORKTREE_PATH" push -u origin "$BRANCH_NAME" >>"$LOG_FILE" 2>&1 \
    || abort "No se pudo hacer push de la rama $BRANCH_NAME"

CLOSES_LINE=""
if [ -n "$ISSUE_NUM" ]; then
    CLOSES_LINE="Closes #$ISSUE_NUM"
fi

# Listar commits en la rama
COMMITS_LIST=$(git -C "$WORKTREE_PATH" log --oneline main..HEAD 2>/dev/null || echo "(sin commits)")

PR_TITLE="scaffold($DOMAIN_NAME): nuevo dominio $PASCAL_CASE"
if [ -n "$ISSUE_NUM" ]; then
    PR_TITLE="#$ISSUE_NUM scaffold($DOMAIN_NAME): nuevo dominio $PASCAL_CASE"
fi

log "Creando PR..."
PR_URL=$(gh pr create \
    --title "$PR_TITLE" \
    --body "$(cat <<EOF
## Resumen

Scaffold del dominio **$PASCAL_CASE** (\`$DOMAIN_NAME\`) creado con domain-scaffolder.

### Incluye
- Function App: \`src/${HARNESS_NAMESPACE_PREFIX}.$PASCAL_CASE/\`
- Tests: \`tests/${HARNESS_NAMESPACE_PREFIX}.$PASCAL_CASE.Tests/\`
- Smoke Tests: \`tests/${HARNESS_NAMESPACE_PREFIX}.$PASCAL_CASE.SmokeTests/\`
- Terraform: storage account + function app en \`infra/environments/dev/main.tf\`
- GitHub Actions: \`.github/workflows/deploy-$DOMAIN_NAME.yml\` (+ workflows \`smoke-tests-dominio.yml\` y \`smoke-tests.yml\` la primera vez en el repo)
- Smoke tests: registro del dominio en \`.github/smoke-tests-dominios.json\`

## Commits

$COMMITS_LIST

$CLOSES_LINE
EOF
)" \
    --base main \
    --head "$BRANCH_NAME" \
    --repo "$REPO_SLUG" \
    2>>"$LOG_FILE") \
    || abort "No se pudo crear el PR"

success "PR creado: $PR_URL"

if [ -n "$ISSUE_NUM" ]; then
    gh issue comment "$ISSUE_NUM" \
        --body "Scaffold del dominio \`$DOMAIN_NAME\` completado. PR: $PR_URL" \
        --repo "$REPO_SLUG" \
        >>"$LOG_FILE" 2>&1 || warn "No se pudo comentar en el issue #$ISSUE_NUM"
fi

# Append al historial
echo "{\"type\":\"scaffold\",\"domain\":\"$DOMAIN_NAME\",\"issue\":\"${ISSUE_NUM:-}\",\"started\":\"$TIMESTAMP\",\"finished\":\"$(date +%Y-%m-%dT%H:%M:%S)\",\"duration\":$scaffold_elapsed,\"pr\":\"$PR_URL\"}" \
    >> "$PIPELINE_DIR/history.jsonl"

# --- Cleanup ---
header "Cleanup"

log "Eliminando worktree..."
cd "$REPO_ROOT"
git -C "$WORKTREE_PATH" checkout -- .claude/ 2>/dev/null || true
git worktree remove --force "$WORKTREE_PATH" >>"$LOG_FILE" 2>&1 \
    || warn "No se pudo eliminar el worktree automaticamente. Eliminalo manualmente: git worktree remove --force $WORKTREE_PATH"

WORKTREE_PATH=""
success "Worktree eliminado"

# --- Resumen final ---
echo ""
echo -e "${GREEN}${BOLD}========================================${NC}"
echo -e "${GREEN}${BOLD}  Scaffold completado exitosamente${NC}"
echo -e "${GREEN}${BOLD}========================================${NC}"
echo ""
echo -e "  Dominio:  ${BOLD}$PASCAL_CASE${NC} ($DOMAIN_NAME)"
[ -n "$ISSUE_NUM" ] && echo -e "  Issue:    ${BOLD}#$ISSUE_NUM${NC}"
echo -e "  PR:       ${BOLD}$PR_URL${NC}"
echo -e "  Duracion: ${BOLD}${scaffold_elapsed}s${NC}"
echo -e "  Log:      $LOG_FILE"
echo ""
echo -e "${YELLOW}Proximos pasos:${NC}"
echo -e "  1. Configura los secrets OIDC de Azure en GitHub con ${BOLD}setup-github-ci.sh${NC} si no existen"
echo -e "     (${BOLD}AZURE_CLIENT_ID${NC}, ${BOLD}AZURE_TENANT_ID${NC}, ${BOLD}AZURE_SUBSCRIPTION_ID${NC}; sin AZURE_CREDENTIALS, ver ADR-0022):"
echo -e "     CI los necesita para aplicar la infraestructura al mergear."
echo -e "  2. Revisar y mergear el PR: al mergear a ${BOLD}main${NC}, CI aplica la infraestructura"
echo -e "     (${BOLD}terraform apply${NC}, workflow Infra CD) y despliega el codigo. No ejecutes"
echo -e "     ${BOLD}terraform apply${NC} en local (ADR-0021, ADR-0022)."
echo -e "  3. Crear issues de implementacion y usar ${BOLD}/implement${NC}"
echo ""
