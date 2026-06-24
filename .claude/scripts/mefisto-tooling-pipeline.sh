#!/usr/bin/env bash
# mefisto-tooling-pipeline.sh -- Pipeline INTERNO de tooling para el repo de Mefisto
#
# Uso:
#   ./.claude/scripts/mefisto-tooling-pipeline.sh 42
#   ./.claude/scripts/mefisto-tooling-pipeline.sh --issue 42
#   ./.claude/scripts/mefisto-tooling-pipeline.sh 42 --from-stage 2
#
# Ciclo: Issue (en repo Mefisto) -> Worktree -> Writer -> Reviewer -> Sync main -> PR -> Cleanup
#
# ALCANCE: solo modifica archivos del propio plugin (commands/, agents/, scripts/,
# hooks/, docs/, .claude-plugin/, .claude/{commands,agents,scripts}/, gobierno).
# No corre dotnet ni terraform. No usa .claude/harness.config.json.

set -euo pipefail

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
PIPELINE_DIR=".claude/pipeline"
LOG_DIR="$PIPELINE_DIR/logs"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$LOG_DIR/mefisto-tooling-pipeline-$TIMESTAMP.log"

# --- Tracking de estado ---
AGENT_WR_DUR="" AGENT_WR_RES="pending"
AGENT_RV_DUR="" AGENT_RV_RES="pending"
PIPELINE_PR=""
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
    echo -e "\n${RED}${BOLD}x ERROR: $1${NC}" | tee -a "${LOG_FILE_ABS:-$LOG_FILE}" >/dev/null
    echo -e "${RED}${BOLD}x ERROR: $1${NC}" >&2
    echo -e "${YELLOW}Revisa el log: ${LOG_FILE_ABS:-$LOG_FILE}${NC}" >&2
    if [ -n "${WORKTREE_PATH:-}" ] && [ -d "$WORKTREE_PATH" ]; then
        echo -e "${YELLOW}El worktree queda en: $WORKTREE_PATH${NC}" >&2
    fi
    if [ -n "${PIPELINE_DIR_ABS:-}" ]; then
        update_status "$CURRENT_STAGE" "failed"
        echo "{\"issue\":\"${ISSUE_NUM:-}\",\"title\":\"$(echo "${ISSUE_TITLE:-}" | sed 's/"/\\"/g')\",\"pipeline\":\"mefisto-tooling\",\"started\":\"${TIMESTAMP:-}\",\"finished\":\"$(date +%Y-%m-%dT%H:%M:%S)\",\"state\":\"failed\",\"stage\":\"$CURRENT_STAGE\",\"error\":\"$PIPELINE_ERROR\"}" \
            >> "$PIPELINE_DIR_ABS/pipeline-history.jsonl" 2>/dev/null || true
    fi
    exit 1
}

update_status() {
    local stage="$1" state="$2"
    CURRENT_STAGE="$stage"
    local wr_dur="null" rv_dur="null"
    [ -n "$AGENT_WR_DUR" ] && wr_dur="$AGENT_WR_DUR"
    [ -n "$AGENT_RV_DUR" ] && rv_dur="$AGENT_RV_DUR"
    local pr_val="null" error_val="null"
    [ -n "$PIPELINE_PR" ]    && pr_val="\"$PIPELINE_PR\""
    [ -n "$PIPELINE_ERROR" ] && error_val="\"$PIPELINE_ERROR\""
    cat > "$PIPELINE_DIR_ABS/$STATUS_FILENAME" <<EOJSON
{
  "issue": "${ISSUE_NUM:-null}",
  "title": "$(echo "${ISSUE_TITLE:-}" | sed 's/"/\\"/g')",
  "pipeline": "mefisto-tooling",
  "started": "$TIMESTAMP",
  "stage": "$stage",
  "state": "$state",
  "updated": "$(date +%Y-%m-%dT%H:%M:%S)",
  "worktree": "${WORKTREE_PATH:-}",
  "log": "${LOG_FILE_ABS:-$LOG_FILE}",
  "agents": {
    "writer":   {"duration": $wr_dur, "result": "$AGENT_WR_RES"},
    "reviewer": {"duration": $rv_dur, "result": "$AGENT_RV_RES"}
  },
  "pr": $pr_val,
  "last_error": $error_val
}
EOJSON
}

# --- Parsear argumentos ---
ISSUE_NUM=""
FROM_STAGE=1
STATUS_FILENAME="pipeline-status-mefisto-tooling.json"

if [ $# -eq 0 ]; then
    echo "Uso: $0 [--issue NUM | NUM] [--from-stage N]"
    exit 1
fi

POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue)
            [ $# -lt 2 ] && abort "Falta el numero de issue"
            ISSUE_NUM="$2"
            shift 2
            ;;
        --from-stage)
            [ $# -lt 2 ] && abort "Falta el numero de stage"
            FROM_STAGE="$2"
            shift 2
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

if [ "$STATUS_FILENAME" = "pipeline-status-mefisto-tooling.json" ]; then
    STATUS_FILENAME="pipeline-status-mefisto-tooling-${ISSUE_NUM}.json"
fi

if ! [[ "$FROM_STAGE" =~ ^[1-2]$ ]]; then
    abort "--from-stage debe ser 1 o 2 (recibido: $FROM_STAGE)"
fi

# --- Verificar dependencias ---
for cmd in claude gh git; do
    command -v "$cmd" &>/dev/null || abort "Falta comando requerido: $cmd"
done

# --- Preparar directorio de pipeline ---
mkdir -p "$LOG_DIR"
echo "Pipeline mefisto-tooling iniciado: $TIMESTAMP" > "$LOG_FILE"

PIPELINE_DIR_ABS="$(realpath "$PIPELINE_DIR")"
LOG_DIR_ABS="$(realpath "$LOG_DIR")"
LOG_FILE_ABS="$(realpath "$LOG_FILE")"
EVENTS_LOG_ABS="$PIPELINE_DIR_ABS/events.log"
touch "$EVENTS_LOG_ABS"

echo "=== SESSION MEFISTO-TOOLING $TIMESTAMP issue:$ISSUE_NUM from-stage:$FROM_STAGE ===" >> "$EVENTS_LOG_ABS"

# --- Obtener issue ---
header "Preparando contexto"

log "Descargando issue #$ISSUE_NUM del repo de Mefisto..."
ISSUE_JSON=$(gh issue view "$ISSUE_NUM" --json number,title,body,state 2>>"$LOG_FILE") \
    || abort "No se pudo obtener el issue #$ISSUE_NUM (debe existir en este repo)"
ISSUE_STATE=$(echo "$ISSUE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])" 2>/dev/null || echo "UNKNOWN")
if [ "$ISSUE_STATE" != "OPEN" ]; then
    abort "El issue #$ISSUE_NUM esta $ISSUE_STATE -- solo se procesan issues abiertos."
fi
ISSUE_TITLE=$(echo "$ISSUE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])" 2>/dev/null \
    || echo "$ISSUE_JSON" | grep -o '"title":"[^"]*"' | sed 's/"title":"//;s/"//')
ISSUE_BODY=$(echo "$ISSUE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['body'])" 2>/dev/null \
    || echo "$ISSUE_JSON" | sed 's/.*"body":"//;s/","[^"]*":".*//;s/\\n/\n/g;s/\\r//g')
ISSUE_CONTEXT="# Issue #$ISSUE_NUM: $ISSUE_TITLE

$ISSUE_BODY"
log "Issue: $ISSUE_TITLE"

echo "$ISSUE_CONTEXT" > "$PIPELINE_DIR/mefisto-tooling-input.md"

# --- Preparar worktree ---
header "Preparando worktree"

REPO_ROOT="$MEFISTO_REPO_ROOT"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

SLUG=$(echo "$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g' | tr -s '-' | cut -c1-40 | sed 's/-$//')
BRANCH_NAME="worktree-mefisto-issue-${ISSUE_NUM}-${SLUG}"
WORKTREE_PATH="${REPO_ROOT}/../${BRANCH_NAME}"

if [ "$FROM_STAGE" -gt 1 ]; then
    [ -d "$WORKTREE_PATH" ] || abort "No existe el worktree en $WORKTREE_PATH. No se puede retomar desde Stage $FROM_STAGE."
    log "Retomando desde Stage $FROM_STAGE -- worktree existente: $WORKTREE_PATH"
    SNAPSHOT_COMMIT=$(git -C "$WORKTREE_PATH" merge-base HEAD main)
    log "Snapshot detectado: $SNAPSHOT_COMMIT"
else
    # El worktree se ramifica SIEMPRE desde origin/main actualizado, sea cual sea
    # la rama del cwd. El guard queda solo como contexto informativo en el log.
    if [ "$CURRENT_BRANCH" != "main" ] && [ "$CURRENT_BRANCH" != "master" ]; then
        warn "cwd en rama '$CURRENT_BRANCH' (no main/master): el worktree se creara igual desde origin/main"
    fi

    log "Actualizando origin/main..."
    git fetch origin main >>"$LOG_FILE" 2>&1 || abort "No se pudo hacer fetch de origin/main"

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

    # En Mefisto NO existe .claude/settings.json versionado; saltarlo si no esta presente
    if [ -f "$REPO_ROOT/.claude/settings.json" ]; then
        sed "s|\.claude/pipeline/events\.log|${EVENTS_LOG_ABS}|g" \
            "$REPO_ROOT/.claude/settings.json" > "$WORKTREE_PATH/.claude/settings.json"
    fi

    update_status "setup" "running"

    SNAPSHOT_COMMIT=$(git -C "$WORKTREE_PATH" rev-parse HEAD)
    log "Snapshot: $SNAPSHOT_COMMIT"
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
    local log_stage="$LOG_DIR_ABS/mefisto-tooling-stage-${stage}-${agent}-${TIMESTAMP}-issue-${ISSUE_NUM}.log"
    local start_ts
    start_ts=$(date +%s)

    echo "[$(date +%H:%M:%S)] === MEFISTO-TOOLING STAGE $stage: $agent ===" >> "$EVENTS_LOG_ABS"
    case "$agent" in
        writer)   AGENT_WR_RES="running" ;;
        reviewer) AGENT_RV_RES="running" ;;
    esac
    update_status "$stage-$agent" "running"
    log "Invocando $agent..."

    local AGENT_TIMEOUT_SECONDS=1800
    local NONINTERACTIVE_SYSTEM="You are running in non-interactive print mode. There is no human to approve anything. You MUST use Write and Edit tools directly to create and modify files at any path including .claude/. Never output text asking for permissions or confirmations -- doing so causes pipeline failure."
    (cd "$WORKTREE_PATH" && claude -p "$prompt" \
        --permission-mode bypassPermissions \
        --append-system-prompt "$NONINTERACTIVE_SYSTEM" \
        --output-format text \
        >"$log_stage" 2>&1) &
    local CLAUDE_PID=$!
    (sleep $AGENT_TIMEOUT_SECONDS && kill -9 -$CLAUDE_PID 2>/dev/null && echo "[$(date +%H:%M:%S)] TIMEOUT: $agent supero ${AGENT_TIMEOUT_SECONDS}s" >> "$EVENTS_LOG_ABS") </dev/null >/dev/null 2>&1 &
    local WATCHDOG_PID=$!

    local CLAUDE_EXIT=0
    wait $CLAUDE_PID || CLAUDE_EXIT=$?

    kill $WATCHDOG_PID 2>/dev/null || true
    wait $WATCHDOG_PID 2>/dev/null || true
    local elapsed=$(( $(date +%s) - start_ts ))

    if [ "$CLAUDE_EXIT" -ne 0 ]; then
        local failure_type
        if [ "$CLAUDE_EXIT" -eq 137 ] || [ "$CLAUDE_EXIT" -eq 143 ]; then
            failure_type="TIMEOUT (signal $CLAUDE_EXIT, ${elapsed}s)"
        elif grep -q "API Error: 5" "$log_stage" 2>/dev/null; then
            failure_type="API_ERROR_SERVER (exit $CLAUDE_EXIT)"
        elif grep -q "API Error: 4" "$log_stage" 2>/dev/null; then
            failure_type="API_ERROR_CLIENT (exit $CLAUDE_EXIT)"
        else
            failure_type="CLI_ERROR (exit $CLAUDE_EXIT)"
        fi

        log "$agent fallo despues de ${elapsed}s -- tipo: $failure_type"
        echo "[$(date +%H:%M:%S)] FALLO $agent: $failure_type" >> "$EVENTS_LOG_ABS"

        # Verificar si produjo trabajo util a pesar del exit code
        local has_work=false
        if ! git -C "$WORKTREE_PATH" diff --quiet "${SNAPSHOT_COMMIT:-HEAD}..HEAD" 2>/dev/null; then
            has_work=true
        fi
        if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null)" ]; then
            has_work=true
        fi

        if [ "$has_work" = true ]; then
            warn "$agent: CLI retorno error ($failure_type) pero hay trabajo util -- continuando"
            echo "[$(date +%H:%M:%S)] RECUPERADO $agent: trabajo util detectado" >> "$EVENTS_LOG_ABS"
        else
            case "$agent" in
                writer)   AGENT_WR_DUR=$elapsed; AGENT_WR_RES="failed" ;;
                reviewer) AGENT_RV_DUR=$elapsed; AGENT_RV_RES="failed" ;;
            esac
            update_status "$stage-$agent" "failed"
            echo -e "\n${RED}-- Ultimas lineas del log de $agent:${NC}"
            tail -20 "$log_stage"
            abort "$agent fallo ($failure_type). Log completo: $log_stage"
        fi
    fi

    LAST_AGENT_DURATION=$elapsed
    log "$agent completado en ${elapsed}s"
}

# --- Funcion auxiliar: auto-commit de seguridad (solo paths del scope de Mefisto) ---
auto_commit_if_needed() {
    local phase="$1"
    local msg="$2"

    git -C "$WORKTREE_PATH" checkout -- .claude/settings.json 2>/dev/null || true

    local paths="commands/ agents/ scripts/ hooks/ docs/ .claude-plugin/ .claude/commands/ .claude/agents/ .claude/scripts/ README.md CHANGELOG.md CLAUDE.md .gitignore"

    if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain -- $paths 2>/dev/null)" ]; then
        log "Haciendo commit automatico (fase $phase)..."
        for dir in $paths; do
            git -C "$WORKTREE_PATH" add "$dir" 2>/dev/null || true
        done
        git -C "$WORKTREE_PATH" commit -m "$msg" >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1 || true
    fi
}

# --- STAGE 1: Writer (implementacion) ---
if [ "$FROM_STAGE" -le 1 ]; then
    header "Stage 1: Writer (implementacion)"

    STAGE1_PROMPT="Estas en el directorio raiz del repo de Mefisto (${MEFISTO_PROJECT_NAME}), un Claude Code Plugin para proyectos .NET serverless en Azure.

Contexto de la tarea de tooling a implementar:

\$ISSUE_CONTEXT

Tu tarea: implementa lo descrito en el issue. Esto es una tarea de TOOLING sobre el propio plugin Mefisto: skills (en commands/), agentes (en agents/), pipelines bash (en scripts/), hooks (en hooks/), ADRs (en docs/adr/), metadata del plugin (.claude-plugin/), o equivalentes internos en .claude/{commands,agents,scripts}/.

ALCANCE DE ESCRITURA PERMITIDO:
- commands/        (skills publicados)
- agents/          (agentes publicados)
- scripts/         (pipelines bash publicados)
- hooks/           (hooks publicados)
- docs/            (ADRs, testing, field-notes, cheatsheets)
- .claude-plugin/  (plugin.json, marketplace.json)
- .claude/commands/, .claude/agents/, .claude/scripts/  (skills/agentes/pipelines INTERNOS de Mefisto)
- README.md, CHANGELOG.md, CLAUDE.md, .gitignore  (gobierno del repo)

NO MODIFIQUES NADA FUERA DE ESE SCOPE. Mefisto no tiene src/, tests/, infra/, ni .github/workflows/.

CONTEXTO DE EJECUCION:
- Modo no-interactivo (print mode). No hay un humano al otro lado.
- Nadie puede aprobar, confirmar ni responder preguntas.
- DEBES usar las herramientas Write y Edit directamente.
- Responder con texto pidiendo aprobacion causa un fallo del pipeline.
- Tienes permisos completos (bypassPermissions activo).

Instrucciones:
1. Lee los archivos existentes relevantes antes de escribir nuevos.
2. Reutiliza patrones y convenciones del repo (mira archivos similares).
3. Haz commits frecuentes con mensajes descriptivos en espanol.
4. Si modificaste un skill o agente publicado, considera si necesitas tambien la version interna (con prefijo mefisto-).
5. Actualiza el CHANGELOG: como parte de implementar el issue, anade una entrada bajo '## [Unreleased]' en CHANGELOG.md siguiendo Keep a Changelog, con la categoria correcta ('Added' para funcionalidad nueva, 'Changed' para cambios de comportamiento, 'Fixed' para bugs, 'Removed' para eliminaciones). Excepcion: si el cambio toca exclusivamente bitacora (docs/bitacora/**) u otros archivos de gobierno no notables (README.md, CLAUDE.md, .gitignore), omite la entrada. Un gate del pipeline aborta el PR si un cambio notable llega sin entrada en [Unreleased].
6. Al terminar, escribe un resumen de lo que hiciste en .claude/pipeline/summaries/stage-1-writer.md"

    # Sustituir $ISSUE_CONTEXT manualmente (evita expansion temprana en la heredoc)
    STAGE1_PROMPT="${STAGE1_PROMPT//\$ISSUE_CONTEXT/$ISSUE_CONTEXT}"

    run_agent "1" "writer" "$STAGE1_PROMPT"

    # Validar que genero cambios reales
    git -C "$WORKTREE_PATH" checkout -- .claude/settings.json 2>/dev/null || true
    HAS_COMMITS=false
    HAS_UNSTAGED=false
    if ! git -C "$WORKTREE_PATH" diff --quiet "$SNAPSHOT_COMMIT" HEAD 2>/dev/null; then
        HAS_COMMITS=true
    fi
    if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain -- commands/ agents/ scripts/ hooks/ docs/ .claude-plugin/ .claude/commands/ .claude/agents/ .claude/scripts/ README.md CHANGELOG.md CLAUDE.md .gitignore 2>/dev/null)" ]; then
        HAS_UNSTAGED=true
    fi
    if [ "$HAS_COMMITS" = false ] && [ "$HAS_UNSTAGED" = false ]; then
        abort "El writer no genero ningun cambio. Revisa el log: $LOG_DIR_ABS/mefisto-tooling-stage-1-writer-${TIMESTAMP}-issue-${ISSUE_NUM}.log"
    fi

    # Gate de scope: rechazar cambios fuera del alcance del repo de Mefisto
    if ! validate_mefisto_scope_changes "$WORKTREE_PATH" "$SNAPSHOT_COMMIT"; then
        abort "Stage 1 fallido: el writer toco archivos fuera del scope de Mefisto."
    fi

    auto_commit_if_needed "writer" "mefisto-tooling(#${ISSUE_NUM}): implementacion"

    AGENT_WR_DUR=$LAST_AGENT_DURATION
    AGENT_WR_RES="passed"
    update_status "1-writer" "passed"
    success "Stage 1 completado"
fi

# --- STAGE 2: Reviewer (revision) ---
if [ "$FROM_STAGE" -le 2 ]; then
    header "Stage 2: Reviewer (revision)"

    FULL_DIFF=$(git -C "$WORKTREE_PATH" diff "$SNAPSHOT_COMMIT"..HEAD)

    STAGE2_PROMPT="Estas en el directorio raiz del repo de Mefisto (${MEFISTO_PROJECT_NAME}).

Contexto de la tarea:

\$ISSUE_CONTEXT

Diff completo de los cambios del writer:

\$FULL_DIFF

Tu tarea: revisa la calidad de los cambios producidos por el writer.

ALCANCE DE ESCRITURA PERMITIDO (igual al del writer):
commands/, agents/, scripts/, hooks/, docs/, .claude-plugin/,
.claude/commands/, .claude/agents/, .claude/scripts/,
README.md, CHANGELOG.md, CLAUDE.md, .gitignore.

CONTEXTO DE EJECUCION:
- Modo no-interactivo (print mode). DEBES usar Write/Edit directamente.
- Responder con texto pidiendo aprobacion causa un fallo del pipeline.
- Tienes permisos completos (bypassPermissions activo).

Instrucciones:
1. Verifica que los cambios cumplen con lo pedido en el issue.
2. Revisa coherencia con las convenciones del proyecto (CLAUDE.md, ADRs).
3. Revisa que los skills/agentes/pipelines modificados sigan los patrones del resto.
4. Corrige problemas que encuentres directamente (no solo los reportes).
5. Haz commit de tus correcciones con mensajes descriptivos.
6. Al terminar, escribe un resumen en .claude/pipeline/summaries/stage-2-reviewer.md"

    STAGE2_PROMPT="${STAGE2_PROMPT//\$ISSUE_CONTEXT/$ISSUE_CONTEXT}"
    STAGE2_PROMPT="${STAGE2_PROMPT//\$FULL_DIFF/$FULL_DIFF}"

    run_agent "2" "reviewer" "$STAGE2_PROMPT"

    # Re-validar scope despues del reviewer
    if ! validate_mefisto_scope_changes "$WORKTREE_PATH" "$SNAPSHOT_COMMIT"; then
        abort "Stage 2 fallido: el reviewer toco archivos fuera del scope de Mefisto."
    fi

    auto_commit_if_needed "reviewer" "mefisto-tooling(#${ISSUE_NUM}): revision y correcciones"

    AGENT_RV_DUR=$LAST_AGENT_DURATION
    AGENT_RV_RES="passed"
    update_status "2-reviewer" "passed"
    success "Stage 2 completado"
fi

# --- Verificar que hay commits ---
COMMITS_LIST=$(git -C "$WORKTREE_PATH" log "${SNAPSHOT_COMMIT}..HEAD" --oneline)
if [ -z "$COMMITS_LIST" ]; then
    abort "No hay commits en la rama $BRANCH_NAME."
fi

# --- Gate del CHANGELOG [Unreleased] (cinturon + tirantes, issue #70) ---
# Cinturon: el writer (Stage 1) redacta la entrada por defecto. Tirantes: aqui el
# script ABORTA si un cambio NOTABLE llega al PR sin entrada en [Unreleased].
# Si todas las rutas tocadas son exentas (bitacora / gobierno no notable) no se
# exige entrada y el gate pasa. Reemplaza el warning informativo de #36, que en
# modo no-interactivo se ignoraba y dejaba PRs sin entrada que /mefisto-release
# tenia que backfillear. Corre tras el reviewer (Stage 2) y antes de crear el PR.
# Degradacion benigna: sin python3, check_unreleased_touched retorna 0 y no aborta.
header "Verificando CHANGELOG [Unreleased]"

if check_unreleased_touched "$WORKTREE_PATH" "$SNAPSHOT_COMMIT"; then
    success "El PR actualiza la seccion [Unreleased] del CHANGELOG"
elif ! changes_require_changelog "$WORKTREE_PATH" "$SNAPSHOT_COMMIT"; then
    success "Cambio exento (solo bitacora/gobierno no notable): no se exige entrada en [Unreleased]"
else
    abort "Cambio notable sin entrada bajo '## [Unreleased]' en CHANGELOG.md.
El writer debio redactar la entrada con la categoria Keep a Changelog correcta
(Added/Changed/Fixed/Removed). La fase prepare de /mefisto-release aborta si
[Unreleased] esta vacio, asi que ningun PR notable debe crearse sin ella.
Anade la entrada en CHANGELOG.md del worktree ($WORKTREE_PATH) y retoma con:
  ./.claude/scripts/mefisto-tooling-pipeline.sh $ISSUE_NUM --from-stage 2"
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

    if git -C "$WORKTREE_PATH" merge origin/main --no-edit >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1; then
        success "Merge automatico exitoso"
    else
        warn "Merge con conflictos. Resolviendo..."

        CONFLICT_FILES=$(git -C "$WORKTREE_PATH" diff --name-only --diff-filter=U)

        MERGE_PROMPT="Hay conflictos de merge con main en los siguientes archivos:
$CONFLICT_FILES

Resuelve los conflictos manteniendo tanto la funcionalidad nueva como la existente.
Despues de resolver cada archivo, haz git add. Cuando todos esten resueltos, haz git commit."

        run_agent "merge" "writer" "$MERGE_PROMPT"

        REMAINING_CONFLICTS=$(git -C "$WORKTREE_PATH" diff --name-only --diff-filter=U 2>/dev/null || true)
        if [ -n "$REMAINING_CONFLICTS" ]; then
            abort "Aun quedan conflictos: $REMAINING_CONFLICTS. Revisa manualmente: cd $WORKTREE_PATH"
        fi
        success "Conflictos resueltos"
    fi
fi

# --- Crear PR ---
header "Creando PR"

log "Haciendo push de la rama..."
git -C "$WORKTREE_PATH" push -u origin "$BRANCH_NAME" >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1 \
    || abort "No se pudo hacer push de la rama $BRANCH_NAME"

log "Creando PR..."

WR_SUMMARY=$(collect_summary "1" "writer")
RV_SUMMARY=$(collect_summary "2" "reviewer")

_fmt_dur() { local s="${1:-0}"; echo "$((s/60))m $((s%60))s"; }
WR_DUR_FMT=$(_fmt_dur "${AGENT_WR_DUR:-0}")
RV_DUR_FMT=$(_fmt_dur "${AGENT_RV_DUR:-0}")

PR_URL=$(gh pr create \
    --title "$ISSUE_TITLE" \
    --body "$(cat <<EOF
## Resumen

Pipeline mefisto-tooling completado:
- Writer: implementacion de la tarea
- Reviewer: revision de calidad

## Decisiones del pipeline

<details>
<summary>Writer -- ${WR_DUR_FMT}</summary>

${WR_SUMMARY}

</details>

<details>
<summary>Reviewer -- ${RV_DUR_FMT}</summary>

${RV_SUMMARY}

</details>

## Commits

$COMMITS_LIST

Closes #$ISSUE_NUM
EOF
)" \
    --base main \
    --head "$BRANCH_NAME" \
    2>>"$LOG_FILE") \
    || abort "No se pudo crear el PR"

PIPELINE_PR="$PR_URL"
update_status "done" "completed"
success "PR creado: $PR_URL"

gh issue comment "$ISSUE_NUM" \
    --body "Pipeline mefisto-tooling completado. PR: $PR_URL" \
    >>"$LOG_FILE" 2>&1 || warn "No se pudo comentar en el issue #$ISSUE_NUM"

# Historial
echo "{\"issue\":\"$ISSUE_NUM\",\"title\":\"$(echo "$ISSUE_TITLE" | sed 's/"/\\"/g')\",\"pipeline\":\"mefisto-tooling\",\"started\":\"$TIMESTAMP\",\"finished\":\"$(date +%Y-%m-%dT%H:%M:%S)\",\"state\":\"completed\",\"agents\":{\"writer\":{\"duration\":${AGENT_WR_DUR:-null}},\"reviewer\":{\"duration\":${AGENT_RV_DUR:-null}}},\"pr\":\"$PR_URL\"}" \
    >> "$PIPELINE_DIR_ABS/pipeline-history.jsonl"

rm -f "$PIPELINE_DIR_ABS/$STATUS_FILENAME"

# --- Cleanup ---
header "Cleanup"

log "Eliminando worktree..."
cd "$REPO_ROOT"
git -C "$WORKTREE_PATH" checkout -- .claude/ 2>/dev/null || true
git worktree remove --force "$WORKTREE_PATH" >>"$LOG_FILE" 2>&1 \
    || warn "No se pudo eliminar el worktree. Eliminalo manualmente: git worktree remove --force $WORKTREE_PATH"

WORKTREE_PATH=""

success "Worktree eliminado"

echo ""
echo -e "${CYAN}${BOLD}=== Pipeline mefisto-tooling completado ===${NC}"
echo ""
TOTAL_COMMITS=$(echo "$COMMITS_LIST" | wc -l | tr -d ' ')
echo -e "  Commits: $TOTAL_COMMITS"
echo -e "  Rama:    $BRANCH_NAME"
echo -e "  PR:      $PR_URL"
echo -e "  Log:     $LOG_FILE"
echo ""
