#!/usr/bin/env bash
# iac-pipeline.sh -- Pipeline IaC automatizado
#
# Uso:
#   ./scripts/iac-pipeline.sh 42
#   ./scripts/iac-pipeline.sh 42 --env dev
#   ./scripts/iac-pipeline.sh 42 --auto-apply    # Omite confirmacion (solo dev)
#   ./scripts/iac-pipeline.sh 42 --skip-apply    # Solo write + review, crea PR (preview)
#   ./scripts/iac-pipeline.sh 42 --from-stage 2  # Retomar desde Stage 2
#   ./scripts/iac-pipeline.sh 42 --from-stage 3  # Aplicar (fase apply del flujo preview)
#
# Ciclo completo: Issue -> Worktree -> Write (HCL) -> Review (plan) -> Apply -> PR -> Cleanup
#
# Flujo preview -> apply (issue #96): con --skip-apply el pipeline escribe+revisa el HCL
# y crea un PR SIN 'Closes #N' (el issue queda abierto), conservando el worktree y el
# tfplan. Tras mergear ese PR, se aplica con --from-stage 3, que reutiliza el worktree y
# el tfplan revisados, provisiona la infra y cierra el issue (representa "infra aplicada").

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"

# Guard defensivo: este pipeline es del lado publicado y solo aplica al consumidor.
# Si detectamos .claude-plugin/plugin.json en la raiz, estamos en el repo de Mefisto.
_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$_REPO_TOP/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/iac-pipeline.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Estas en el repo de Mefisto, que no tiene infraestructura Terraform/Azure." >&2
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
PIPELINE_DIR=".claude/pipeline"
LOG_DIR="$PIPELINE_DIR/logs"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$LOG_DIR/iac-pipeline-$TIMESTAMP.log"

# --- Tracking de estado ---
AGENT_WR_DUR="" AGENT_WR_RES="pending"
AGENT_RV_DUR="" AGENT_RV_RES="pending"
AGENT_AP_DUR="" AGENT_AP_RES="pending"
PIPELINE_ERROR=""
LAST_AGENT_DURATION=0
CURRENT_STAGE="setup"

_strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
_log_file()   { echo -e "$1" | _strip_ansi >> "${LOG_FILE_ABS:-$LOG_FILE}"; }

log()     { local m="${BLUE}[$(date +%H:%M:%S)]${NC} $1"; echo -e "$m"; _log_file "$m"; }
success() { local m="${GREEN}${BOLD}v${NC} $1"; echo -e "$m"; _log_file "$m"; }
warn()    { local m="${YELLOW}!${NC} $1"; echo -e "$m"; _log_file "$m"; }
header()  { local m="\n${CYAN}${BOLD}-- $1 --${NC}"; echo -e "$m"; _log_file "$m"; }
abort() {
    PIPELINE_ERROR="$(echo "$1" | sed 's/"/\\"/g' | tr '\n' ' ')"
    echo -e "\n${RED}${BOLD}x ERROR: $1${NC}" | tee -a "${LOG_FILE_ABS:-$LOG_FILE}"
    echo -e "${YELLOW}Revisa el log: ${LOG_FILE_ABS:-$LOG_FILE}${NC}"
    if [ -n "${WORKTREE_PATH:-}" ] && [ -d "$WORKTREE_PATH" ]; then
        echo -e "${YELLOW}El worktree queda en: $WORKTREE_PATH${NC}"
        echo -e "${YELLOW}Para inspeccionar: cd $WORKTREE_PATH${NC}"
    fi
    if [ -n "${PIPELINE_DIR_ABS:-}" ]; then
        update_status "$CURRENT_STAGE" "failed"
        echo "{\"issue\":\"${ISSUE_NUM:-}\",\"title\":\"$(echo "${ISSUE_TITLE:-}" | sed 's/"/\\"/g')\",\"pipeline\":\"infra\",\"environment\":\"${ENVIRONMENT:-}\",\"started\":\"${TIMESTAMP:-}\",\"finished\":\"$(date +%Y-%m-%dT%H:%M:%S)\",\"state\":\"failed\",\"stage\":\"$CURRENT_STAGE\",\"error\":\"$PIPELINE_ERROR\"}" \
            >> "$PIPELINE_DIR_ABS/pipeline-history.jsonl" 2>/dev/null || true
    fi
    exit 1
}

update_status() {
    local stage="$1" state="$2"
    CURRENT_STAGE="$stage"
    local wr_dur="null" rv_dur="null" ap_dur="null"
    [ -n "$AGENT_WR_DUR" ] && wr_dur="$AGENT_WR_DUR"
    [ -n "$AGENT_RV_DUR" ] && rv_dur="$AGENT_RV_DUR"
    [ -n "$AGENT_AP_DUR" ] && ap_dur="$AGENT_AP_DUR"
    local error_val="null"
    [ -n "$PIPELINE_ERROR" ] && error_val="\"$PIPELINE_ERROR\""
    cat > "$PIPELINE_DIR_ABS/$STATUS_FILENAME" <<EOJSON
{
  "issue": "${ISSUE_NUM:-null}",
  "title": "$(echo "${ISSUE_TITLE:-}" | sed 's/"/\\"/g')",
  "environment": "${ENVIRONMENT:-?}",
  "pipeline": "infra",
  "started": "$TIMESTAMP",
  "stage": "$stage",
  "state": "$state",
  "updated": "$(date +%Y-%m-%dT%H:%M:%S)",
  "worktree": "${WORKTREE_PATH:-}",
  "log": "${LOG_FILE_ABS:-$LOG_FILE}",
  "agents": {
    "infra-writer":   {"duration": $wr_dur, "result": "$AGENT_WR_RES"},
    "infra-reviewer": {"duration": $rv_dur, "result": "$AGENT_RV_RES"},
    "infra-applier":  {"duration": $ap_dur, "result": "$AGENT_AP_RES"}
  },
  "last_error": $error_val
}
EOJSON
}

# --- Parsear argumentos ---
ISSUE_NUM=""
ENVIRONMENT="dev"
FROM_STAGE=1
AUTO_APPLY=false
SKIP_APPLY=false
STATUS_FILENAME=""  # Se asigna despues del parseo (necesita ISSUE_NUM); override con --status-file

if [ $# -eq 0 ]; then
    echo "Uso: $0 <issue-num> [--env <dev|staging|prod>] [--auto-apply] [--skip-apply] [--from-stage N] [--status-file NOMBRE]"
    exit 1
fi

POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            [ $# -lt 2 ] && abort "Falta el nombre del ambiente"
            ENVIRONMENT="$2"
            shift 2
            ;;
        --from-stage)
            [ $# -lt 2 ] && abort "Falta el numero de stage"
            FROM_STAGE="$2"
            shift 2
            ;;
        --auto-apply)
            AUTO_APPLY=true
            shift
            ;;
        --skip-apply)
            SKIP_APPLY=true
            shift
            ;;
        --status-file)
            [ $# -lt 2 ] && abort "Falta el nombre del archivo de status"
            STATUS_FILENAME="$2"
            shift 2
            ;;
        [0-9]*)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
        *)
            abort "Argumento no reconocido: $1"
            ;;
    esac
done

if [ ${#POSITIONAL_ARGS[@]} -gt 0 ] && [ -z "$ISSUE_NUM" ]; then
    ISSUE_NUM="${POSITIONAL_ARGS[0]}"
fi

[ -z "$ISSUE_NUM" ] && abort "Falta el numero de issue"

# Si no se paso --status-file, usar convención normalizada con ISSUE_NUM
if [ -z "$STATUS_FILENAME" ]; then
    STATUS_FILENAME="pipeline-status-infra-${ISSUE_NUM}.json"
fi

if ! [[ "$FROM_STAGE" =~ ^[1-3]$ ]]; then
    abort "--from-stage debe ser 1, 2, o 3"
fi

# Proteccion: --auto-apply solo en dev
if [ "$AUTO_APPLY" = true ] && [ "$ENVIRONMENT" != "dev" ]; then
    abort "--auto-apply solo esta permitido en el ambiente 'dev'. En '$ENVIRONMENT' se requiere confirmacion manual."
fi

# Verificar que el directorio del ambiente existe
INFRA_ENV_DIR="infra/environments/$ENVIRONMENT"
[ -d "$INFRA_ENV_DIR" ] || abort "No existe el directorio de ambiente: $INFRA_ENV_DIR"

# --- Verificar dependencias ---
for cmd in claude gh git terraform; do
    command -v "$cmd" &>/dev/null || abort "Falta comando requerido: $cmd"
done

# --- Preparar directorio de pipeline ---
mkdir -p "$LOG_DIR"
echo "Pipeline IaC iniciado: $TIMESTAMP" > "$LOG_FILE"

PIPELINE_DIR_ABS="$(realpath "$PIPELINE_DIR")"
LOG_DIR_ABS="$(realpath "$LOG_DIR")"
LOG_FILE_ABS="$(realpath "$LOG_FILE")"
EVENTS_LOG_ABS="$PIPELINE_DIR_ABS/events.log"

echo "=== SESSION IAC $TIMESTAMP issue:$ISSUE_NUM env:$ENVIRONMENT from-stage:$FROM_STAGE ===" >> "$EVENTS_LOG_ABS"

# --- Obtener issue ---
header "Preparando contexto"

log "Descargando issue #$ISSUE_NUM..."
ISSUE_JSON=$(gh issue view "$ISSUE_NUM" --json number,title,body,state 2>>"$LOG_FILE") \
    || abort "No se pudo obtener el issue #$ISSUE_NUM"
ISSUE_STATE=$(echo "$ISSUE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])" 2>/dev/null || echo "UNKNOWN")
if [ "$ISSUE_STATE" != "OPEN" ]; then
    # Flujo preview -> apply (issue #96): en --skip-apply el PR de preview NO lleva
    # 'Closes #N', asi que tras mergearlo el issue sigue abierto y el apply posterior
    # lo encuentra OPEN. Pero si el issue llego cerrado y estamos reanudando una etapa
    # de apply (--from-stage 3 sin --skip-apply), permitimos continuar: el apply
    # representa "infra aplicada" sobre HCL ya revisado (y, en su caso, ya mergeado).
    # El worktree requerido se valida mas abajo (lineas del bloque FROM_STAGE > 1).
    if [ "$FROM_STAGE" -ge 3 ] && [ "$SKIP_APPLY" = false ]; then
        warn "El issue #$ISSUE_NUM esta $ISSUE_STATE, pero se reanuda el apply (--from-stage 3): se continua para aplicar la infra ya revisada."
    else
        abort "El issue #$ISSUE_NUM esta $ISSUE_STATE -- una corrida nueva solo procesa issues abiertos.
Si la infra ya fue previsualizada (PR de --skip-apply mergeado) y solo falta aplicarla:
  - reanuda el apply con: $0 $ISSUE_NUM --env $ENVIRONMENT --from-stage 3
    (reutiliza el worktree y el tfplan revisados del preview); o
  - reabre el issue si necesitas reescribir/revisar la infra desde cero."
    fi
fi
ISSUE_TITLE=$(echo "$ISSUE_JSON" | grep -o '"title":"[^"]*"' | sed 's/"title":"//;s/"//')
ISSUE_BODY=$(echo "$ISSUE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['body'])" 2>/dev/null \
    || echo "$ISSUE_JSON" | sed 's/.*"body":"//;s/","[^"]*":".*//;s/\\n/\n/g;s/\\r//g')
ISSUE_CONTEXT="# Issue #$ISSUE_NUM: $ISSUE_TITLE

$ISSUE_BODY"
log "Issue: $ISSUE_TITLE"

echo "$ISSUE_CONTEXT" > "$PIPELINE_DIR/infra-input.md"

# --- Preparar worktree ---
header "Preparando worktree"

REPO_ROOT=$(git rev-parse --show-toplevel)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

SLUG=$(echo "$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g' | tr -s '-' | cut -c1-40 | sed 's/-$//')
BRANCH_NAME="infra-issue-${ISSUE_NUM}-${SLUG}"
WORKTREE_PATH="${REPO_ROOT}/../${BRANCH_NAME}"

# Ruta absoluta al directorio del ambiente dentro del worktree
INFRA_ENV_DIR_ABS_WT="$WORKTREE_PATH/$INFRA_ENV_DIR"

if [ "$FROM_STAGE" -gt 1 ]; then
    [ -d "$WORKTREE_PATH" ] || abort "No existe el worktree en $WORKTREE_PATH. No se puede retomar desde Stage $FROM_STAGE."
    log "Retomando desde Stage $FROM_STAGE -- worktree existente: $WORKTREE_PATH"
    SNAPSHOT_COMMIT=$(git -C "$WORKTREE_PATH" merge-base HEAD main)
    log "Snapshot detectado: $SNAPSHOT_COMMIT"
    INFRA_ENV_DIR_ABS="$(realpath "$INFRA_ENV_DIR_ABS_WT")"
else
    # El worktree se ramifica SIEMPRE desde origin/main actualizado, sea cual sea
    # la rama del cwd. El guard queda solo como contexto informativo en el log.
    if [ "$CURRENT_BRANCH" != "main" ] && [ "$CURRENT_BRANCH" != "master" ]; then
        warn "cwd en rama '$CURRENT_BRANCH' (no main/master): el worktree se creara igual desde origin/main"
    fi

    log "Actualizando origin/main..."
    git fetch origin main >>"$LOG_FILE" 2>&1 || abort "No se pudo hacer fetch de origin/main"

    # Idempotencia: si el worktree ya existe, limpiarlo
    if [ -d "$WORKTREE_PATH" ]; then
        warn "El worktree ya existe: $WORKTREE_PATH -- limpiando para reiniciar..."
        git worktree remove --force "$WORKTREE_PATH" >>"$LOG_FILE" 2>&1 || true
        git branch -D "$BRANCH_NAME" >>"$LOG_FILE" 2>&1 || true
    fi
    if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME" 2>/dev/null; then
        warn "La rama $BRANCH_NAME ya existe sin worktree -- eliminandola..."
        git branch -D "$BRANCH_NAME" >>"$LOG_FILE" 2>&1 || true
    fi

    log "Creando worktree: $WORKTREE_PATH (base: origin/main)"
    git worktree add "$WORKTREE_PATH" -b "$BRANCH_NAME" origin/main >>"$LOG_FILE" 2>&1 \
        || abort "No se pudo crear el worktree desde origin/main"

    success "Worktree creado: $WORKTREE_PATH"

    mkdir -p "$WORKTREE_PATH/.claude/pipeline/summaries"

    # Parchear settings.json del worktree con ruta absoluta del events.log
    sed "s|\.claude/pipeline/events\.log|${EVENTS_LOG_ABS}|g" \
        "$REPO_ROOT/.claude/settings.json" > "$WORKTREE_PATH/.claude/settings.json"

    # --- Copiar y commitear backend.tf del working tree al worktree (issue #86) ---
    # bootstrap-backend.sh escribe infra/environments/<env>/backend.tf en el working
    # tree del consumidor, pero este worktree se ramifica SIEMPRE desde origin/main,
    # donde ese backend.tf puede no estar versionado aun (flujo greenfield). Sin esta
    # copia, el terraform init/plan del reviewer correria con estado LOCAL en vez del
    # backend remoto -- justo el fallo que el bootstrap busca eliminar. Copiamos el
    # backend.tf y lo commiteamos en la rama del worktree para que viaje en el PR del
    # pipeline y se versione en main via merge (sin push directo a main).
    BACKEND_SRC="$REPO_ROOT/$INFRA_ENV_DIR/backend.tf"
    if [ -f "$BACKEND_SRC" ]; then
        log "Copiando backend.tf del working tree al worktree..."
        mkdir -p "$INFRA_ENV_DIR_ABS_WT"
        cp "$BACKEND_SRC" "$INFRA_ENV_DIR_ABS_WT/backend.tf"
        # Si el backend.tf ya estaba identico en origin/main (no-greenfield), la copia
        # es un no-op en el diff y no hay nada que commitear.
        if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain -- "$INFRA_ENV_DIR/backend.tf")" ]; then
            git -C "$WORKTREE_PATH" add "$INFRA_ENV_DIR/backend.tf"
            git -C "$WORKTREE_PATH" commit -m "infra($ENVIRONMENT): incluir backend.tf generado por bootstrap"
            success "backend.tf copiado y commiteado en la rama del worktree"
        else
            log "backend.tf ya estaba versionado e identico en origin/main -- sin cambios que commitear"
        fi
    else
        warn "No existe $INFRA_ENV_DIR/backend.tf en el working tree -- el pipeline continua sin abortar; si necesitas backend remoto, ejecuta primero bootstrap-backend.sh"
    fi

    INFRA_ENV_DIR_ABS="$(realpath "$INFRA_ENV_DIR_ABS_WT")"

    update_status "setup" "running"

    SNAPSHOT_COMMIT=$(git -C "$WORKTREE_PATH" rev-parse HEAD)
    log "Snapshot: $SNAPSHOT_COMMIT"
fi

# --- Flujo preview -> apply (issue #96): detectar marcador del PR de preview ---
# Una corrida previa con --skip-apply conserva el worktree y deja este marcador con la
# URL del PR de preview. Si esta presente al reanudar (--from-stage 3), estamos en la
# FASE DE APPLY de un flujo preview -> apply: el HCL ya tiene PR (y se asume mergeado),
# asi que esta corrida solo provisiona (Stage 3) y cierra el issue, sin crear un PR
# nuevo ni re-sincronizar. En una corrida normal el marcador no existe (CA-2 intacto).
PREVIEW_MARKER="$WORKTREE_PATH/.claude/pipeline/.preview-pr"
PREVIEW_PR_URL=""
if [ -f "$PREVIEW_MARKER" ]; then
    PREVIEW_PR_URL=$(cat "$PREVIEW_MARKER" 2>/dev/null || echo "")
    [ -n "$PREVIEW_PR_URL" ] && log "Marcador de preview detectado (PR: $PREVIEW_PR_URL) -- esta corrida solo aplica y cierra el issue."
fi

# --- Funcion auxiliar: recolectar resumen de agente ---
collect_summary() {
    local stage="$1" agent="$2"
    local f="$WORKTREE_PATH/.claude/pipeline/summaries/stage-${stage}-${agent}.md"
    if [ -f "$f" ]; then cat "$f"; else echo "_(El agente no genero resumen)_"; fi
}

# --- Funcion auxiliar para invocar agentes ---
run_agent() {
    local stage="$1"
    local agent="$2"
    local prompt="$3"
    local log_stage="$LOG_DIR_ABS/iac-stage-${stage}-${agent}-${TIMESTAMP}-issue-${ISSUE_NUM}.log"
    local start_ts
    start_ts=$(date +%s)

    echo "[$(date +%H:%M:%S)] === IAC STAGE $stage: $agent ===" >> "$EVENTS_LOG_ABS"
    case "$agent" in
        infra-writer)   AGENT_WR_RES="running" ;;
        infra-reviewer) AGENT_RV_RES="running" ;;
        infra-applier)  AGENT_AP_RES="running" ;;
    esac
    update_status "$stage-$agent" "running"
    log "Invocando $agent..."

    local AGENT_TIMEOUT_SECONDS=1800
    local NONINTERACTIVE_SYSTEM="You are running in non-interactive print mode. There is no human to approve anything. You MUST use Write and Edit tools directly to create and modify files at any path including .claude/. Never output text asking for permissions or confirmations -- doing so causes pipeline failure."
    (cd "$WORKTREE_PATH" && claude -p "$prompt" \
        --agent "$agent" \
        --permission-mode bypassPermissions \
        --append-system-prompt "$NONINTERACTIVE_SYSTEM" \
        --output-format text \
        >"$log_stage" 2>&1) &
    local CLAUDE_PID=$!
    (sleep $AGENT_TIMEOUT_SECONDS && kill $CLAUDE_PID 2>/dev/null && echo "[$(date +%H:%M:%S)] TIMEOUT: $agent supero ${AGENT_TIMEOUT_SECONDS}s" >> "$EVENTS_LOG_ABS") &
    local WATCHDOG_PID=$!
    wait $CLAUDE_PID || {
        kill $WATCHDOG_PID 2>/dev/null || true
        wait $WATCHDOG_PID 2>/dev/null || true
        local elapsed=$(( $(date +%s) - start_ts ))
        case "$agent" in
            infra-writer)   AGENT_WR_DUR=$elapsed; AGENT_WR_RES="failed" ;;
            infra-reviewer) AGENT_RV_DUR=$elapsed; AGENT_RV_RES="failed" ;;
            infra-applier)  AGENT_AP_DUR=$elapsed; AGENT_AP_RES="failed" ;;
        esac
        update_status "$stage-$agent" "failed"
        echo -e "\n${RED}-- Ultimas lineas del log de $agent:${NC}"
        tail -20 "$log_stage"
        abort "$agent fallo. Log completo: $log_stage"
    }

    kill $WATCHDOG_PID 2>/dev/null || true
    wait $WATCHDOG_PID 2>/dev/null || true
    local elapsed=$(( $(date +%s) - start_ts ))
    LAST_AGENT_DURATION=$elapsed
    log "$agent completado en ${elapsed}s"
}

# --- STAGE 1: infra-writer (escribir HCL) ---
if [ "$FROM_STAGE" -le 1 ]; then
    header "Stage 1: infra-writer (escribir HCL)"

    STAGE1_PROMPT="Estas en el directorio raiz del proyecto ${HARNESS_PROJECT_NAME}.

Contexto del issue de infraestructura a implementar:

$ISSUE_CONTEXT

Ambiente target: $ENVIRONMENT
Directorio del ambiente: $INFRA_ENV_DIR_ABS

Tu tarea: escribe o modifica los archivos Terraform necesarios para implementar este issue en el ambiente '$ENVIRONMENT'. Sigue todas las instrucciones de tu rol de infra-writer."

    run_agent "1" "infra-writer" "$STAGE1_PROMPT"

    AGENT_WR_DUR=$LAST_AGENT_DURATION
    AGENT_WR_RES="passed"

    # Gate 1: el HCL debe ser valido
    log "Gate: verificando terraform validate..."
    (cd "$INFRA_ENV_DIR_ABS" && terraform init -backend=false -input=false >>"$LOG_FILE_ABS" 2>&1) \
        || abort "Stage 1 fallido: terraform init fallo"
    (cd "$INFRA_ENV_DIR_ABS" && terraform validate >>"$LOG_FILE_ABS" 2>&1) \
        || abort "Stage 1 fallido: terraform validate fallo. Revisa el log."
    success "Gate 1: HCL valido"

    # Auto-commit si hay cambios
    if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain -- infra/)" ]; then
        log "Commiteando cambios de HCL..."
        git -C "$WORKTREE_PATH" add infra/
        git -C "$WORKTREE_PATH" commit -m "infra($ENVIRONMENT): escritura HCL issue #${ISSUE_NUM}"
    fi

    update_status "1-infra-writer" "passed"
fi

# --- STAGE 2: infra-reviewer (plan y revision) ---
if [ "$FROM_STAGE" -le 2 ]; then
    header "Stage 2: infra-reviewer (revision y plan)"

    DIFF_CONTEXT=$(git -C "$WORKTREE_PATH" diff main...HEAD -- infra/ 2>/dev/null | head -200 || echo "(sin diff disponible)")

    STAGE2_PROMPT="Estas en el directorio raiz del proyecto ${HARNESS_PROJECT_NAME}.

Contexto del issue:

$ISSUE_CONTEXT

Ambiente target: $ENVIRONMENT
Directorio del ambiente: $INFRA_ENV_DIR_ABS

Diff de archivos .tf modificados en esta rama:
$DIFF_CONTEXT

Tu tarea: revisa el HCL producido por infra-writer, corrige problemas de seguridad o calidad, y ejecuta 'terraform plan -out=tfplan' en '$INFRA_ENV_DIR_ABS'. Sigue todas las instrucciones de tu rol de infra-reviewer."

    run_agent "2" "infra-reviewer" "$STAGE2_PROMPT"

    AGENT_RV_DUR=$LAST_AGENT_DURATION
    AGENT_RV_RES="passed"

    # Gate 2: el tfplan debe existir
    [ -f "$INFRA_ENV_DIR_ABS/tfplan" ] \
        || abort "Stage 2 fallido: el infra-reviewer no genero el archivo tfplan en $INFRA_ENV_DIR_ABS"
    success "Gate 2: tfplan generado"

    # Commit de correcciones del reviewer si las hubo
    if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain -- infra/)" ]; then
        log "Commiteando correcciones del reviewer..."
        git -C "$WORKTREE_PATH" add infra/
        git -C "$WORKTREE_PATH" commit -m "infra($ENVIRONMENT): correcciones de revision issue #${ISSUE_NUM}"
    fi

    update_status "2-infra-reviewer" "passed"
fi

# --- STAGE 3: infra-applier (aplicar) ---
if [ "$SKIP_APPLY" = true ]; then
    warn "Flag --skip-apply activo: omitiendo Stage 3 (apply)"
    update_status "skip-apply" "completed"
else
    if [ "$FROM_STAGE" -le 3 ]; then
        header "Stage 3: infra-applier (aplicar)"

        if [ "$AUTO_APPLY" = true ]; then
            export IAC_AUTO_APPLY=true
            log "Modo auto-apply activo (ambiente: $ENVIRONMENT)"
        fi

        STAGE3_PROMPT="Estas en el directorio raiz del proyecto ${HARNESS_PROJECT_NAME}.

El infra-reviewer ya genero el plan de Terraform en: $INFRA_ENV_DIR_ABS/tfplan
Ambiente: $ENVIRONMENT
Auto-apply: $AUTO_APPLY

Tu tarea: aplica el plan Terraform pre-generado siguiendo todas las instrucciones de tu rol de infra-applier."

        run_agent "3" "infra-applier" "$STAGE3_PROMPT"

        AGENT_AP_DUR=$LAST_AGENT_DURATION
        AGENT_AP_RES="passed"
        update_status "3-infra-applier" "passed"
    fi
fi

REPO_SLUG="$(git -C "$WORKTREE_PATH" remote get-url origin | sed 's/.*github.com[:/]\(.*\)\.git/\1/')"

if [ -n "$PREVIEW_PR_URL" ]; then
    # ===== Fase APPLY de un flujo preview -> apply (issue #96) =====
    # El PR con el HCL ya existe (corrida --skip-apply) y se asume mergeado a main. No
    # re-sincronizamos, no empujamos la rama ni creamos un PR nuevo: el Stage 3 ya
    # provisiono la infra. Solo cerramos el issue, que el PR de preview dejo abierto
    # (no llevaba 'Closes #N'), para que represente "infra aplicada".
    header "Apply de infra previsualizada"

    PR_URL="$PREVIEW_PR_URL"
    PIPELINE_PR="$PR_URL"
    COMMITS_LIST=$(git -C "$WORKTREE_PATH" log "${SNAPSHOT_COMMIT}..HEAD" --oneline 2>/dev/null || echo "")

    if [ "$AGENT_AP_RES" = "passed" ]; then
        log "Cerrando el issue #$ISSUE_NUM (infra aplicada)..."
        gh issue close "$ISSUE_NUM" \
            --comment "Infra aplicada en $ENVIRONMENT (flujo preview -> apply). PR del HCL: $PREVIEW_PR_URL" \
            --repo "$REPO_SLUG" >>"$LOG_FILE_ABS" 2>&1 \
            && success "Issue #$ISSUE_NUM cerrado: infra aplicada" \
            || warn "No se pudo cerrar el issue #$ISSUE_NUM automaticamente; cierralo manualmente."
    else
        warn "El apply no quedo marcado como 'passed'; el issue #$ISSUE_NUM se deja abierto."
    fi
else
    # ===== Flujo normal (write+review+apply) o preview (--skip-apply) =====

    # --- Verificar que hay commits ---
    COMMITS_LIST=$(git -C "$WORKTREE_PATH" log "${SNAPSHOT_COMMIT}..HEAD" --oneline)
    if [ -z "$COMMITS_LIST" ]; then
        abort "No hay commits en la rama $BRANCH_NAME."
    fi

    # --- Sincronizar con main ---
    header "Sincronizando con main"

    log "Actualizando main desde origin..."
    git -C "$WORKTREE_PATH" fetch origin main >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1 \
        || abort "No se pudo hacer fetch de origin/main"

    BEHIND_COUNT=$(git -C "$WORKTREE_PATH" rev-list HEAD..origin/main --count)
    if [ "$BEHIND_COUNT" -eq 0 ]; then
        log "La rama ya esta al dia con main"
    else
        log "main tiene $BEHIND_COUNT commit(s) nuevos. Haciendo merge..."
        git -C "$WORKTREE_PATH" merge origin/main --no-edit >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1 \
            || abort "Merge con main tiene conflictos. Resuelve manualmente en: $WORKTREE_PATH"
        success "Merge automatico exitoso"
    fi

    # --- Crear PR ---
    header "Creando PR"

    log "Haciendo push de la rama..."
    git -C "$WORKTREE_PATH" push -u origin "$BRANCH_NAME" >>"$LOG_FILE_ABS" 2>&1 \
        || abort "No se pudo hacer push de la rama $BRANCH_NAME"

    APPLY_STATUS="pendiente de aplicar"
    [ "$SKIP_APPLY" = false ] && [ "$AGENT_AP_RES" = "passed" ] && APPLY_STATUS="aplicado en $ENVIRONMENT"

    # CA-1/CA-2 (issue #96): el 'Closes #N' solo se emite cuando el apply realmente
    # ocurrio en ESTA corrida (flujo normal). En --skip-apply (preview) el PR NO cierra
    # el issue: representa "infra previsualizada", no "aplicada", y el issue se cierra
    # recien en el apply posterior (corrida --from-stage 3 sobre este worktree).
    if [ "$SKIP_APPLY" = false ]; then
        CLOSES_LINE="Closes #$ISSUE_NUM"
    else
        CLOSES_LINE="> **Preview (\`--skip-apply\`)**: este PR no cierra el issue #$ISSUE_NUM. Tras mergearlo, aplica la infra revisada con \`iac-pipeline.sh $ISSUE_NUM --env $ENVIRONMENT --from-stage 3\` (reutiliza este worktree y el tfplan); el apply cerrara el issue."
    fi

    WR_SUMMARY=$(collect_summary "1" "infra-writer")
    RV_SUMMARY=$(collect_summary "2" "infra-reviewer")

    _fmt_dur() { local s="${1:-0}"; echo "$((s/60))m $((s%60))s"; }
    WR_DUR_FMT=$(_fmt_dur "${AGENT_WR_DUR:-0}")
    RV_DUR_FMT=$(_fmt_dur "${AGENT_RV_DUR:-0}")
    AP_DUR_FMT=$(_fmt_dur "${AGENT_AP_DUR:-0}")

    PR_URL=$(gh pr create \
        --title "infra($ENVIRONMENT): #$ISSUE_NUM $ISSUE_TITLE" \
        --body "$(cat <<EOF
## Infraestructura

Implementa los cambios de infraestructura del issue #$ISSUE_NUM.

- **Ambiente**: $ENVIRONMENT
- **Estado**: $APPLY_STATUS
- **Pipeline**: iac-pipeline.sh

## Decisiones del pipeline

<details>
<summary>infra-writer -- ${WR_DUR_FMT}</summary>

${WR_SUMMARY}

</details>

<details>
<summary>infra-reviewer -- ${RV_DUR_FMT}</summary>

${RV_SUMMARY}

</details>

## Cambios Terraform

$(git -C "$WORKTREE_PATH" diff main...HEAD --stat -- infra/ 2>/dev/null || echo "(ver diff del PR)")

## Commits

$COMMITS_LIST

$CLOSES_LINE
EOF
)" \
        --base main \
        --head "$BRANCH_NAME" \
        --repo "$REPO_SLUG" \
        2>>"$LOG_FILE_ABS") || warn "No se pudo crear el PR automaticamente"

    [ -n "${PR_URL:-}" ] && success "PR creado: $PR_URL"

    PIPELINE_PR="${PR_URL:-}"

    if [ "$SKIP_APPLY" = true ]; then
        ISSUE_COMMENT="Preview IaC completado (sin aplicar). PR: ${PR_URL:-pendiente}. Tras mergearlo, aplica con: iac-pipeline.sh $ISSUE_NUM --env $ENVIRONMENT --from-stage 3"
    else
        ISSUE_COMMENT="Pipeline IaC completado. PR: ${PR_URL:-pendiente}"
    fi
    gh issue comment "$ISSUE_NUM" \
        --body "$ISSUE_COMMENT" \
        --repo "$REPO_SLUG" \
        >>"$LOG_FILE" 2>&1 || warn "No se pudo comentar en el issue #$ISSUE_NUM"
fi

# --- Historial ---
echo "{\"issue\":\"$ISSUE_NUM\",\"title\":\"$(echo "$ISSUE_TITLE" | sed 's/"/\\"/g')\",\"pipeline\":\"infra\",\"environment\":\"$ENVIRONMENT\",\"started\":\"$TIMESTAMP\",\"finished\":\"$(date +%Y-%m-%dT%H:%M:%S)\",\"state\":\"completed\",\"agents\":{\"infra-writer\":{\"duration\":${AGENT_WR_DUR:-null},\"result\":\"$AGENT_WR_RES\"},\"infra-reviewer\":{\"duration\":${AGENT_RV_DUR:-null},\"result\":\"$AGENT_RV_RES\"},\"infra-applier\":{\"duration\":${AGENT_AP_DUR:-null},\"result\":\"$AGENT_AP_RES\"}},\"pr\":\"${PR_URL:-}\"}" \
    >> "$PIPELINE_DIR_ABS/pipeline-history.jsonl"

update_status "completed" "completed"

# Eliminar archivo de estado individual (ya esta en el historial)
rm -f "$PIPELINE_DIR_ABS/$STATUS_FILENAME"

# --- Cleanup ---
header "Cleanup"

if [ "$SKIP_APPLY" = true ]; then
    # Flujo preview -> apply (issue #96): NO eliminamos el worktree. El apply posterior
    # (--from-stage 3) reutiliza este worktree y el tfplan ya revisados, sin reescribir
    # ni re-planear. Dejamos el marcador con la URL del PR de preview: la corrida de
    # apply lo detecta para cerrar el issue sin crear un PR duplicado.
    mkdir -p "$WORKTREE_PATH/.claude/pipeline"
    echo "${PR_URL:-}" > "$PREVIEW_MARKER"

    cd "$REPO_ROOT"
    warn "Modo --skip-apply: el worktree se conserva para el apply posterior ($WORKTREE_PATH)."

    echo ""
    echo -e "${CYAN}${BOLD}=== Preview IaC completado (sin aplicar) ===${NC}"
    echo ""
    echo -e "  Issue:     #$ISSUE_NUM -- $ISSUE_TITLE"
    echo -e "  Ambiente:  $ENVIRONMENT"
    echo -e "  Rama:      $BRANCH_NAME"
    echo -e "  Worktree:  $WORKTREE_PATH"
    [ -n "${PR_URL:-}" ] && echo -e "  PR:        $PR_URL"
    echo -e "  Log:       $LOG_FILE_ABS"
    echo ""
    echo -e "${YELLOW}${BOLD}Siguiente paso (preview -> apply):${NC}"
    echo -e "  1. Revisa y mergea el PR de preview. ${YELLOW}No cierra el issue${NC} (no lleva 'Closes')."
    echo -e "  2. Aplica la infra revisada reanudando el apply:"
    echo -e "       ${BOLD}iac-pipeline.sh $ISSUE_NUM --env $ENVIRONMENT --from-stage 3${NC}"
    echo -e "     Reutiliza este worktree y el tfplan; al aplicar, el pipeline cierra el issue #$ISSUE_NUM."
    echo ""
    exit 0
fi

log "Eliminando worktree..."
cd "$REPO_ROOT"
git -C "$WORKTREE_PATH" checkout -- .claude/ 2>/dev/null || true
git worktree remove --force "$WORKTREE_PATH" >>"$LOG_FILE" 2>&1 \
    || warn "No se pudo eliminar el worktree. Eliminalo manualmente: git worktree remove --force $WORKTREE_PATH"

WORKTREE_PATH=""

success "Worktree eliminado"

echo ""
echo -e "${CYAN}${BOLD}=== Pipeline IaC completado ===${NC}"
echo ""
echo -e "  Issue:     #$ISSUE_NUM -- $ISSUE_TITLE"
echo -e "  Ambiente:  $ENVIRONMENT"
TOTAL_COMMITS=$(echo "$COMMITS_LIST" | wc -l | tr -d ' ')
echo -e "  Commits:   $TOTAL_COMMITS"
echo -e "  Rama:      $BRANCH_NAME"
[ -n "${PR_URL:-}" ] && echo -e "  PR:        $PR_URL"
echo -e "  Log:       $LOG_FILE_ABS"
echo ""
