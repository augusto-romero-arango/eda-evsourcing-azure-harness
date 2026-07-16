#!/usr/bin/env bash
# tooling-pipeline.sh -- Pipeline para tareas de tooling (no-TDD)
#
# Uso:
#   ./scripts/tooling-pipeline.sh 42
#   ./scripts/tooling-pipeline.sh --issue 42
#   ./scripts/tooling-pipeline.sh 42 --from-stage 2   # Retomar desde Stage 2
#
# Ciclo: Issue -> Worktree -> Writer -> Reviewer -> Sync main -> PR -> Cleanup
#
# A diferencia del pipeline TDD, este no tiene fases roja/verde.
# Los gates son: compilacion (Stage 1) y compilacion + tests existentes (Stage 2).

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"

# Guard defensivo: este pipeline es del lado publicado y solo aplica al consumidor.
# Si detectamos .claude-plugin/plugin.json en la raiz, estamos en el repo de Mefisto.
_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$_REPO_TOP/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/tooling-pipeline.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Estas en el repo de Mefisto. Para mejorar el plugin, usa .claude/scripts/mefisto-tooling-pipeline.sh." >&2
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
LOG_FILE="$LOG_DIR/tooling-pipeline-$TIMESTAMP.log"

# --- Tracking de estado ---
AGENT_WR_DUR="" AGENT_WR_RES="pending"
AGENT_RV_DUR="" AGENT_RV_RES="pending"
PIPELINE_TESTS=""
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
    echo -e "\n${RED}${BOLD}x ERROR: $1${NC}" | tee -a "${LOG_FILE_ABS:-$LOG_FILE}"
    echo -e "${YELLOW}Revisa el log: ${LOG_FILE_ABS:-$LOG_FILE}${NC}"
    if [ -n "${WORKTREE_PATH:-}" ] && [ -d "$WORKTREE_PATH" ]; then
        echo -e "${YELLOW}El worktree queda en: $WORKTREE_PATH${NC}"
        echo -e "${YELLOW}Para inspeccionar: cd $WORKTREE_PATH${NC}"
    fi
    if [ -n "${PIPELINE_DIR_ABS:-}" ]; then
        update_status "$CURRENT_STAGE" "failed"
        echo "{\"issue\":\"${ISSUE_NUM:-}\",\"title\":\"$(echo "${ISSUE_TITLE:-}" | sed 's/"/\\"/g')\",\"pipeline\":\"tooling\",\"started\":\"${TIMESTAMP:-}\",\"finished\":\"$(date +%Y-%m-%dT%H:%M:%S)\",\"state\":\"failed\",\"stage\":\"$CURRENT_STAGE\",\"error\":\"$PIPELINE_ERROR\"}" \
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
    local tests_val="null" pr_val="null" error_val="null"
    [ -n "$PIPELINE_TESTS" ] && tests_val="$PIPELINE_TESTS"
    [ -n "$PIPELINE_PR" ]    && pr_val="\"$PIPELINE_PR\""
    [ -n "$PIPELINE_ERROR" ] && error_val="\"$PIPELINE_ERROR\""
    cat > "$PIPELINE_DIR_ABS/$STATUS_FILENAME" <<EOJSON
{
  "issue": "${ISSUE_NUM:-null}",
  "title": "$(echo "${ISSUE_TITLE:-}" | sed 's/"/\\"/g')",
  "pipeline": "tooling",
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
  "tests": $tests_val,
  "pr": $pr_val,
  "last_error": $error_val
}
EOJSON
}

# extract_test_count y run_tests_projects viven en _pipeline-common.sh
# (consolidadas desde tdd-pipeline.sh y tooling-pipeline.sh, issue #305).
# Los call sites de este archivo pasan "$WORKTREE_PATH" como primer argumento.

# --- Parsear argumentos ---
ISSUE_NUM=""
FROM_STAGE=1
STATUS_FILENAME="pipeline-status-tooling.json"  # Nombre del archivo de status (parametrizable para paralelismo)

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

# Si no se paso --status-file, usar pipeline-status-tooling-{issue}.json para soportar paralelismo
if [ "$STATUS_FILENAME" = "pipeline-status-tooling.json" ]; then
    STATUS_FILENAME="pipeline-status-tooling-${ISSUE_NUM}.json"
fi

if ! [[ "$FROM_STAGE" =~ ^[1-2]$ ]]; then
    abort "--from-stage debe ser 1 o 2 (recibido: $FROM_STAGE)"
fi

# --- Verificar dependencias ---
for cmd in claude gh git dotnet; do
    command -v "$cmd" &>/dev/null || abort "Falta comando requerido: $cmd"
done

# --- Preparar directorio de pipeline ---
mkdir -p "$LOG_DIR"
echo "Pipeline tooling iniciado: $TIMESTAMP" > "$LOG_FILE"

PIPELINE_DIR_ABS="$(realpath "$PIPELINE_DIR")"
LOG_DIR_ABS="$(realpath "$LOG_DIR")"
LOG_FILE_ABS="$(realpath "$LOG_FILE")"
EVENTS_LOG_ABS="$PIPELINE_DIR_ABS/events.log"

echo "=== SESSION TOOLING $TIMESTAMP issue:$ISSUE_NUM from-stage:$FROM_STAGE ===" >> "$EVENTS_LOG_ABS"

# --- Obtener issue ---
header "Preparando contexto"

log "Descargando issue #$ISSUE_NUM..."
ISSUE_JSON=$(gh issue view "$ISSUE_NUM" --json number,title,body,state 2>>"$LOG_FILE") \
    || abort "No se pudo obtener el issue #$ISSUE_NUM"
ISSUE_STATE=$(echo "$ISSUE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])" 2>/dev/null || echo "UNKNOWN")
if [ "$ISSUE_STATE" != "OPEN" ]; then
    abort "El issue #$ISSUE_NUM esta $ISSUE_STATE -- solo se procesan issues abiertos."
fi
ISSUE_TITLE=$(echo "$ISSUE_JSON" | grep -o '"title":"[^"]*"' | sed 's/"title":"//;s/"//')
ISSUE_BODY=$(echo "$ISSUE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['body'])" 2>/dev/null \
    || echo "$ISSUE_JSON" | sed 's/.*"body":"//;s/","[^"]*":".*//;s/\\n/\n/g;s/\\r//g')
ISSUE_CONTEXT="# Issue #$ISSUE_NUM: $ISSUE_TITLE

$ISSUE_BODY"
log "Issue: $ISSUE_TITLE"

echo "$ISSUE_CONTEXT" > "$PIPELINE_DIR/tooling-input.md"

# --- Preparar worktree ---
header "Preparando worktree"

REPO_ROOT=$(git rev-parse --show-toplevel)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

SLUG=$(echo "$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g' | tr -s '-' | cut -c1-40 | sed 's/-$//')
BRANCH_NAME="worktree-issue-${ISSUE_NUM}-${SLUG}"
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
    local log_stage="$LOG_DIR_ABS/tooling-stage-${stage}-${agent}-${TIMESTAMP}-issue-${ISSUE_NUM}.log"
    local start_ts
    start_ts=$(date +%s)

    echo "[$(date +%H:%M:%S)] === TOOLING STAGE $stage: $agent ===" >> "$EVENTS_LOG_ABS"
    case "$agent" in
        writer)   AGENT_WR_RES="running" ;;
        reviewer) AGENT_RV_RES="running" ;;
    esac
    # Modelo por etapa: escritura (writer y merge) en sonnet, revision en opus.
    local AGENT_MODEL
    case "$agent" in
        reviewer) AGENT_MODEL="opus" ;;
        *)        AGENT_MODEL="sonnet" ;;
    esac
    update_status "$stage-$agent" "running"
    log "Invocando $agent..."

    local AGENT_TIMEOUT_SECONDS=1800
    local NONINTERACTIVE_SYSTEM="You are running in non-interactive print mode. There is no human to approve anything. You MUST use Write and Edit tools directly to create and modify files at any path including .claude/. Never output text asking for permissions or confirmations -- doing so causes pipeline failure."
    (cd "$WORKTREE_PATH" && claude -p "$prompt" --model "$AGENT_MODEL" \
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

        # Retry para errores 5xx sin trabajo previo
        if echo "$failure_type" | grep -q "API_ERROR_SERVER"; then
            local has_work=false
            if ! git -C "$WORKTREE_PATH" diff --quiet "${SNAPSHOT_COMMIT:-HEAD}..HEAD" 2>/dev/null; then
                has_work=true
            fi
            if [ "$has_work" = false ]; then
                warn "$agent: API error 5xx -- reintentando una vez..."
                echo "[$(date +%H:%M:%S)] RETRY $agent: API error 5xx" >> "$EVENTS_LOG_ABS"
                local log_stage_retry="$LOG_DIR_ABS/tooling-stage-${stage}-${agent}-${TIMESTAMP}-issue-${ISSUE_NUM}-retry.log"
                CLAUDE_EXIT=0
                (cd "$WORKTREE_PATH" && claude -p "$prompt" --model "$AGENT_MODEL" \
                    --permission-mode bypassPermissions \
                    --append-system-prompt "$NONINTERACTIVE_SYSTEM" \
                    --output-format text \
                    >"$log_stage_retry" 2>&1) || CLAUDE_EXIT=$?
                elapsed=$(( $(date +%s) - start_ts ))
                log_stage="$log_stage_retry"
                if [ "$CLAUDE_EXIT" -ne 0 ]; then
                    log "$agent fallo tambien en reintento"
                    echo "[$(date +%H:%M:%S)] RETRY_FALLO $agent" >> "$EVENTS_LOG_ABS"
                else
                    log "$agent: reintento exitoso en ${elapsed}s"
                    echo "[$(date +%H:%M:%S)] RETRY_OK $agent" >> "$EVENTS_LOG_ABS"
                fi
            fi
        fi

        # Retry para bloqueo por permisos (race condition en ejecucion paralela)
        if [ "$CLAUDE_EXIT" -ne 0 ] && grep -qiE "permisos|permission|bloqueado|blocked|approve" "$log_stage" 2>/dev/null; then
            local has_work_perm=false
            if ! git -C "$WORKTREE_PATH" diff --quiet "${SNAPSHOT_COMMIT:-HEAD}..HEAD" 2>/dev/null; then
                has_work_perm=true
            fi
            if [ "$has_work_perm" = false ]; then
                warn "$agent: bloqueo por permisos detectado -- reintentando una vez..."
                echo "[$(date +%H:%M:%S)] RETRY $agent: bloqueo por permisos" >> "$EVENTS_LOG_ABS"
                local log_stage_perm_retry="$LOG_DIR_ABS/tooling-stage-${stage}-${agent}-${TIMESTAMP}-issue-${ISSUE_NUM}-perm-retry.log"
                CLAUDE_EXIT=0
                (cd "$WORKTREE_PATH" && claude -p "$prompt" --model "$AGENT_MODEL" \
                    --permission-mode bypassPermissions \
                    --append-system-prompt "$NONINTERACTIVE_SYSTEM" \
                    --output-format text \
                    >"$log_stage_perm_retry" 2>&1) || CLAUDE_EXIT=$?
                elapsed=$(( $(date +%s) - start_ts ))
                log_stage="$log_stage_perm_retry"
                if [ "$CLAUDE_EXIT" -ne 0 ]; then
                    log "$agent fallo tambien en reintento por permisos"
                    echo "[$(date +%H:%M:%S)] RETRY_PERM_FALLO $agent" >> "$EVENTS_LOG_ABS"
                else
                    log "$agent: reintento por permisos exitoso en ${elapsed}s"
                    echo "[$(date +%H:%M:%S)] RETRY_PERM_OK $agent" >> "$EVENTS_LOG_ABS"
                fi
            fi
        fi

        if [ "$CLAUDE_EXIT" -ne 0 ]; then
            # Verificar si produjo trabajo util
            local has_commits=false
            local gate_passes=false

            if ! git -C "$WORKTREE_PATH" diff --quiet "${SNAPSHOT_COMMIT:-HEAD}..HEAD" 2>/dev/null; then
                has_commits=true
            fi
            if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain -- tests/ src/ scripts/ .claude/ 2>/dev/null)" ]; then
                has_commits=true
            fi

            if [ "$has_commits" = true ]; then
                if dotnet build "$WORKTREE_PATH" >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1; then
                    gate_passes=true
                fi
            fi

            if [ "$has_commits" = true ] && [ "$gate_passes" = true ]; then
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
    fi

    LAST_AGENT_DURATION=$elapsed
    log "$agent completado en ${elapsed}s"
}

# --- Funcion auxiliar: auto-commit de seguridad ---
auto_commit_if_needed() {
    local phase="$1"
    local msg="$2"

    git -C "$WORKTREE_PATH" checkout -- .claude/settings.json 2>/dev/null || true

    if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain -- tests/ src/ scripts/ .github/ infra/ pipeline-state/)" ]; then
        log "Haciendo commit automatico (fase $phase)..."
        for dir in tests/ src/ scripts/ .github/ infra/ pipeline-state/; do
            git -C "$WORKTREE_PATH" add "$dir" 2>/dev/null || true
        done
        git -C "$WORKTREE_PATH" commit -m "$msg" >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1 || true
    fi
}

# --- STAGE 1: Writer (implementacion) ---
if [ "$FROM_STAGE" -le 1 ]; then
    header "Stage 1: Writer (implementacion)"

    STAGE1_PROMPT="Estas en el directorio raiz del proyecto consumidor ${HARNESS_PROJECT_NAME} (un consumidor del plugin Mefisto).

Contexto de la tarea de tooling a implementar:

$ISSUE_CONTEXT

Tu tarea: implementa lo descrito en el issue. Esto es una tarea de TOOLING del CONSUMIDOR (workflows de GitHub Actions, configuracion local, fixtures de test, scripts ad-hoc del consumidor), NO logica de dominio y NO modificaciones al plugin Mefisto.

ALCANCE PERMITIDO de escritura:
- .github/workflows/                         (workflows del consumidor)
- .claude/harness.config.json                (configuracion del consumidor)
- .claude/settings.json                      (configuracion Claude del consumidor)
- .claude/pipeline/                          (estado runtime; .gitignored)
- pipeline-state/                            (senales del pipeline)
- scripts/                                   (scripts ad-hoc del consumidor)
- tests/                                     (SOLO fixtures, helpers, builders - NO logica de dominio)
- docs/bitacora/, docs/eda/, docs/adr-proyecto/  (documentacion del consumidor)

PROHIBIDO MODIFICAR (pertenece al plugin Mefisto, no a este repo):
- commands/, agents/, hooks/, .claude-plugin/
- docs/adr/ (los ADRs del marco viven en el repo del plugin)
- src/ (eso es para /implement, no para /tooling)

Si la tarea requiere modificar el plugin Mefisto, NO la ejecutes. En su lugar, propon crear un draft con:
  gh issue create -R augusto-romero-arango/eda-evsourcing-azure-harness --label \"estado:borrador,tipo:tooling\" --title \"...\" --body \"...\"
Y registra esto en el resumen del stage.

CONTEXTO DE EJECUCION:
- Modo no-interactivo (print mode). No hay un humano al otro lado.
- Nadie puede aprobar, confirmar ni responder preguntas.
- DEBES usar las herramientas Write y Edit directamente para crear y modificar archivos.
- Responder con texto pidiendo aprobacion causa un fallo del pipeline.
- Tienes permisos completos (bypassPermissions activo).

Instrucciones:
1. Lee los archivos existentes relevantes antes de escribir codigo nuevo.
2. Reutiliza patrones y convenciones del proyecto (mira archivos similares).
3. Haz commits frecuentes con mensajes descriptivos en espanol.
4. Verifica que el proyecto compila con 'dotnet build' si modificaste codigo C#.
5. Al terminar, escribe un resumen de lo que hiciste en .claude/pipeline/summaries/stage-1-writer.md"

    run_agent "1" "writer" "$STAGE1_PROMPT"

    # Validar que genero cambios reales (excluir .claude/settings.json y .claude/pipeline/
    # que el pipeline modifica antes de invocar al agente)
    git -C "$WORKTREE_PATH" checkout -- .claude/settings.json 2>/dev/null || true
    HAS_COMMITS=false
    HAS_UNSTAGED=false
    if ! git -C "$WORKTREE_PATH" diff --quiet "$SNAPSHOT_COMMIT" HEAD 2>/dev/null; then
        HAS_COMMITS=true
    fi
    if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain -- tests/ src/ scripts/ .github/ infra/ pipeline-state/ 2>/dev/null)" ]; then
        HAS_UNSTAGED=true
    fi
    if [ "$HAS_COMMITS" = false ] && [ "$HAS_UNSTAGED" = false ]; then
        # Detectar si el writer pidio permisos en vez de usar herramientas
        local writer_log="$LOG_DIR_ABS/tooling-stage-1-writer-${TIMESTAMP}-issue-${ISSUE_NUM}.log"
        if grep -qiE "necesito.*permiso|aprobar.*permiso|confirma.*escritura|approve.*permission|permiso.*escritura" "$writer_log" 2>/dev/null; then
            warn "Writer pidio permisos en modo no-interactivo -- reintentando con prompt reforzado..."
            echo "[$(date +%H:%M:%S)] RETRY writer: solicitud de permisos detectada en output" >> "$EVENTS_LOG_ABS"

            RETRY_PROMPT="ATENCION: El intento anterior fallo porque generaste texto pidiendo permisos en lugar de usar herramientas Write/Edit.

Estas en modo NO-INTERACTIVO. No hay humano. DEBES usar Write/Edit directamente. Cualquier respuesta de texto sin tool calls causa un fallo del pipeline.

$STAGE1_PROMPT"

            run_agent "1" "writer" "$RETRY_PROMPT"

            # Re-validar cambios despues del retry
            git -C "$WORKTREE_PATH" checkout -- .claude/settings.json 2>/dev/null || true
            HAS_COMMITS=false; HAS_UNSTAGED=false
            if ! git -C "$WORKTREE_PATH" diff --quiet "$SNAPSHOT_COMMIT" HEAD 2>/dev/null; then HAS_COMMITS=true; fi
            if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain -- tests/ src/ scripts/ .github/ infra/ pipeline-state/ 2>/dev/null)" ]; then HAS_UNSTAGED=true; fi
        fi

        if [ "$HAS_COMMITS" = false ] && [ "$HAS_UNSTAGED" = false ]; then
            abort "El writer no genero ningun cambio. Revisa el log: $LOG_DIR_ABS/tooling-stage-1-writer-${TIMESTAMP}-issue-${ISSUE_NUM}.log"
        fi
    fi

    # Gate 1: debe compilar (si hay codigo C#)
    if [ -n "$(git -C "$WORKTREE_PATH" diff --name-only "$SNAPSHOT_COMMIT"..HEAD -- '*.cs' '*.csproj' 2>/dev/null)" ] \
       || [ -n "$(git -C "$WORKTREE_PATH" status --porcelain -- '*.cs' '*.csproj' 2>/dev/null)" ]; then
        log "Gate: verificando compilacion..."
        dotnet build "$WORKTREE_PATH" >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1 \
            || abort "Stage 1 fallido: el proyecto no compila despues del writer."
        success "Gate 1: compilacion exitosa"
    else
        log "No hay cambios en C# -- saltando gate de compilacion"
    fi

    auto_commit_if_needed "writer" "tooling(#${ISSUE_NUM}): implementacion"

    # Gate de scope: rechazar si el writer toco rutas reservadas al plugin
    if ! validate_consumer_scope_changes "$WORKTREE_PATH" "$SNAPSHOT_COMMIT"; then
        abort "Stage 1 fallido: el writer toco rutas reservadas al plugin Mefisto."
    fi

    AGENT_WR_DUR=$LAST_AGENT_DURATION
    AGENT_WR_RES="passed"
    update_status "1-writer" "passed"
    success "Stage 1 completado"
fi

# --- STAGE 2: Reviewer (revision) ---
if [ "$FROM_STAGE" -le 2 ]; then
    header "Stage 2: Reviewer (revision)"

    FULL_DIFF=$(git -C "$WORKTREE_PATH" diff "$SNAPSHOT_COMMIT"..HEAD)

    STAGE2_PROMPT="Estas en el directorio raiz del proyecto consumidor ${HARNESS_PROJECT_NAME}.

Contexto de la tarea:

$ISSUE_CONTEXT

Diff completo de los cambios del writer:

$FULL_DIFF

Tu tarea: revisa la calidad del codigo producido por el writer.

ALCANCE PERMITIDO de escritura (igual al del writer):
.github/workflows/, .claude/harness.config.json, .claude/settings.json,
.claude/pipeline/, pipeline-state/, scripts/, tests/ (fixtures/helpers),
docs/bitacora/, docs/eda/, docs/adr-proyecto/.

PROHIBIDO: commands/, agents/, hooks/, .claude-plugin/, docs/adr/, src/.

Si el writer toco rutas prohibidas, reviertelas o reporta el problema en el resumen
y NO hagas cambios extra al plugin.

CONTEXTO DE EJECUCION:
- Modo no-interactivo (print mode). No hay un humano al otro lado.
- Nadie puede aprobar, confirmar ni responder preguntas.
- DEBES usar las herramientas Write y Edit directamente para corregir problemas.
- Responder con texto pidiendo aprobacion causa un fallo del pipeline.
- Tienes permisos completos (bypassPermissions activo).

Instrucciones:
1. Verifica que los cambios cumplen con lo pedido en el issue.
2. Revisa calidad: reutilizacion de patrones existentes, naming, legibilidad.
3. Si hay codigo C#, verifica que compila y que los tests existentes pasan.
4. Corrige problemas que encuentres directamente (no solo los reportes).
5. Haz commit de tus correcciones con mensajes descriptivos.
6. Al terminar, escribe un resumen en .claude/pipeline/summaries/stage-2-reviewer.md"

    run_agent "2" "reviewer" "$STAGE2_PROMPT"

    # Gate 2: compilacion + tests existentes
    if [ -n "$(git -C "$WORKTREE_PATH" diff --name-only "$SNAPSHOT_COMMIT"..HEAD -- '*.cs' '*.csproj' 2>/dev/null)" ]; then
        log "Gate: verificando compilacion y tests..."
        g2_rc=0
        TEST_OUTPUT_G2=$(run_tests_projects "$WORKTREE_PATH" 2>&1) || g2_rc=$?
        echo "$TEST_OUTPUT_G2" | tee -a "${LOG_FILE_ABS:-$LOG_FILE}" >/dev/null
        if [ "$g2_rc" -ne 0 ]; then
            echo "$TEST_OUTPUT_G2" | tail -20
            abort "Stage 2 fallido: tests fallan despues del reviewer (exit code: $g2_rc)."
        fi
        TEST_COUNT=$(extract_test_count "$TEST_OUTPUT_G2")
        PIPELINE_TESTS="$TEST_COUNT"
        log "Tests pasando: $TEST_COUNT"
        success "Gate 2: compilacion y tests OK"
    else
        log "No hay cambios en C# -- saltando gate de tests"
    fi

    auto_commit_if_needed "reviewer" "tooling(#${ISSUE_NUM}): revision y correcciones"

    # Gate de scope: rechazar si el reviewer toco rutas reservadas al plugin
    if ! validate_consumer_scope_changes "$WORKTREE_PATH" "$SNAPSHOT_COMMIT"; then
        abort "Stage 2 fallido: el reviewer toco rutas reservadas al plugin Mefisto."
    fi

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

    # Re-correr tests post-merge si hay C#
    if [ -n "$(git -C "$WORKTREE_PATH" diff --name-only "$SNAPSHOT_COMMIT"..HEAD -- '*.cs' '*.csproj' 2>/dev/null)" ]; then
        log "Verificando tests despues del merge..."
        merge_rc=0
        TEST_OUTPUT_MERGE=$(run_tests_projects "$WORKTREE_PATH" 2>&1) || merge_rc=$?
        echo "$TEST_OUTPUT_MERGE" | tee -a "${LOG_FILE_ABS:-$LOG_FILE}" >/dev/null
        if [ "$merge_rc" -ne 0 ]; then
            abort "Tests fallan despues del merge con main (exit code: $merge_rc)."
        fi
        success "Tests pasan despues del merge"
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

Pipeline tooling completado:
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
    --repo "$(git -C "$WORKTREE_PATH" remote get-url origin | sed 's/.*github.com[:/]\(.*\)\.git/\1/')" \
    2>>"$LOG_FILE") \
    || abort "No se pudo crear el PR"

PIPELINE_PR="$PR_URL"
update_status "done" "completed"
success "PR creado: $PR_URL"

gh issue comment "$ISSUE_NUM" \
    --body "Pipeline tooling completado. PR: $PR_URL" \
    --repo "$(git -C "$WORKTREE_PATH" remote get-url origin | sed 's/.*github.com[:/]\(.*\)\.git/\1/')" \
    >>"$LOG_FILE" 2>&1 || warn "No se pudo comentar en el issue #$ISSUE_NUM"

# Historial
echo "{\"issue\":\"$ISSUE_NUM\",\"title\":\"$(echo "$ISSUE_TITLE" | sed 's/"/\\"/g')\",\"pipeline\":\"tooling\",\"started\":\"$TIMESTAMP\",\"finished\":\"$(date +%Y-%m-%dT%H:%M:%S)\",\"state\":\"completed\",\"agents\":{\"writer\":{\"duration\":${AGENT_WR_DUR:-null}},\"reviewer\":{\"duration\":${AGENT_RV_DUR:-null}}},\"tests\":${PIPELINE_TESTS:-null},\"pr\":\"$PR_URL\"}" \
    >> "$PIPELINE_DIR_ABS/pipeline-history.jsonl"

# Eliminar archivo de estado individual (ya esta en el historial)
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
echo -e "${CYAN}${BOLD}=== Pipeline tooling completado ===${NC}"
echo ""
TOTAL_COMMITS=$(echo "$COMMITS_LIST" | wc -l | tr -d ' ')
echo -e "  Commits: $TOTAL_COMMITS"
echo -e "  Rama:    $BRANCH_NAME"
echo -e "  PR:      $PR_URL"
echo -e "  Log:     $LOG_FILE"
echo ""
