#!/usr/bin/env bash
# tdd-pipeline.sh — Pipeline TDD automatizado
#
# Uso:
#   ./scripts/tdd-pipeline.sh 42
#   ./scripts/tdd-pipeline.sh --issue 42
#   ./scripts/tdd-pipeline.sh --file "docs/Historias de usuario/HU-25.md"
#   ./scripts/tdd-pipeline.sh 42 --from-stage 2   # Retomar desde Stage 2
#   ./scripts/tdd-pipeline.sh 42 --from-stage 3   # Retomar desde Stage 3
#   ./scripts/tdd-pipeline.sh 42 --from-stage 4   # Retomar desde Stage 4 (coverage gate)
#
# Ciclo completo: Issue → Worktree → Test Writer → Implementer → Reviewer → Sync main → Coverage Gate → PR → Cleanup

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"
load_harness_config || exit 1

# ─── Colores ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Logging ─────────────────────────────────────────────────────────────────
PIPELINE_DIR=".claude/pipeline"
LOG_DIR="$PIPELINE_DIR/logs"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$LOG_DIR/pipeline-$TIMESTAMP.log"

# ─── Tracking de estado enriquecido ──────────────────────────────────────────
AGENT_TW_DUR="" AGENT_TW_RES="pending"
AGENT_IM_DUR="" AGENT_IM_RES="pending"
AGENT_ST_DUR="" AGENT_ST_RES="pending"   # smoke-test-writer
AGENT_RV_DUR="" AGENT_RV_RES="pending"
AGENT_CG_DUR="" AGENT_CG_RES="pending"   # coverage-gate
COV_PATCH_APPLIED=false
COV_GAPS_REMAINING=0
COV_TABLE=""
PIPELINE_TESTS=""
PIPELINE_PR=""
HAS_BLOCKAGE=false
PIPELINE_ERROR=""
LAST_AGENT_DURATION=0
CURRENT_STAGE="setup"
IS_REFACTOR=false
REFACTOR_JUSTIFICATION=""
BASELINE_TEST_COUNT="?"

_strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
_log_file()   { echo -e "$1" | _strip_ansi >> "${LOG_FILE_ABS:-$LOG_FILE}"; }

log()     { local m="${BLUE}[$(date +%H:%M:%S)]${NC} $1"; echo -e "$m"; _log_file "$m"; }
success() { local m="${GREEN}${BOLD}✓${NC} $1"; echo -e "$m"; _log_file "$m"; }
warn()    { local m="${YELLOW}⚠${NC} $1"; echo -e "$m"; _log_file "$m"; }
header()  { local m="\n${CYAN}${BOLD}── $1 ──${NC}"; echo -e "$m"; _log_file "$m"; }
abort() {
    PIPELINE_ERROR="$(echo "$1" | sed 's/"/\\"/g' | tr '\n' ' ')"
    echo -e "\n${RED}${BOLD}✗ ERROR: $1${NC}" | tee -a "${LOG_FILE_ABS:-$LOG_FILE}"
    echo -e "${YELLOW}Revisa el log: ${LOG_FILE_ABS:-$LOG_FILE}${NC}"
    if [ -n "${WORKTREE_PATH:-}" ] && [ -d "$WORKTREE_PATH" ]; then
        echo -e "${YELLOW}El worktree queda en: $WORKTREE_PATH${NC}"
        echo -e "${YELLOW}Para inspeccionar: cd $WORKTREE_PATH${NC}"
    fi
    if [ -n "${PIPELINE_DIR_ABS:-}" ]; then
        update_status "$CURRENT_STAGE" "failed"
        # M4: Registrar falla en historial para analisis de patrones
        echo "{\"issue\":\"${ISSUE_NUM:-}\",\"title\":\"$(echo "${ISSUE_TITLE:-}" | sed 's/"/\\"/g')\",\"pipeline\":\"tdd\",\"started\":\"${TIMESTAMP:-}\",\"finished\":\"$(date +%Y-%m-%dT%H:%M:%S)\",\"state\":\"failed\",\"stage\":\"$CURRENT_STAGE\",\"error\":\"$PIPELINE_ERROR\"}" \
            >> "$PIPELINE_DIR_ABS/pipeline-history.jsonl" 2>/dev/null || true
    fi
    exit 1
}

update_status() {
    local stage="$1" state="$2"
    CURRENT_STAGE="$stage"
    local tw_dur="null" im_dur="null" st_dur="null" rv_dur="null" cg_dur="null"
    [ -n "$AGENT_TW_DUR" ] && tw_dur="$AGENT_TW_DUR"
    [ -n "$AGENT_IM_DUR" ] && im_dur="$AGENT_IM_DUR"
    [ -n "$AGENT_ST_DUR" ] && st_dur="$AGENT_ST_DUR"
    [ -n "$AGENT_RV_DUR" ] && rv_dur="$AGENT_RV_DUR"
    [ -n "$AGENT_CG_DUR" ] && cg_dur="$AGENT_CG_DUR"
    local tests_val="null" pr_val="null" error_val="null"
    [ -n "$PIPELINE_TESTS" ] && tests_val="$PIPELINE_TESTS"
    [ -n "$PIPELINE_PR" ]    && pr_val="\"$PIPELINE_PR\""
    [ -n "$PIPELINE_ERROR" ] && error_val="\"$PIPELINE_ERROR\""
    cat > "$PIPELINE_DIR_ABS/$STATUS_FILENAME" <<EOJSON
{
  "issue": "${ISSUE_NUM:-null}",
  "title": "$(echo "${ISSUE_TITLE:-}" | sed 's/"/\\"/g')",
  "pipeline": "tdd",
  "started": "$TIMESTAMP",
  "stage": "$stage",
  "state": "$state",
  "updated": "$(date +%Y-%m-%dT%H:%M:%S)",
  "worktree": "${WORKTREE_PATH:-}",
  "log": "${LOG_FILE_ABS:-$LOG_FILE}",
  "agents": {
    "test-writer":       {"duration": $tw_dur, "result": "$AGENT_TW_RES"},
    "implementer":       {"duration": $im_dur, "result": "$AGENT_IM_RES"},
    "smoke-test-writer": {"duration": $st_dur, "result": "$AGENT_ST_RES"},
    "reviewer":          {"duration": $rv_dur, "result": "$AGENT_RV_RES"},
    "coverage-gate":     {"duration": $cg_dur, "result": "$AGENT_CG_RES"}
  },
  "tests": $tests_val,
  "pr": $pr_val,
  "last_error": $error_val
}
EOJSON
}

# Extraer conteo de tests pasando del resumen de dotnet test.
# Soporta MTP ("correcto: N") y VSTest clásico ("Superado: N" / "Passed: N").
extract_test_count() {
    local count
    count=$(echo "$1" | grep -oiE '(correcto|correctas|passed|superado):[[:space:]]+[0-9]+' \
        | grep -oE '[0-9]+' | head -1)
    echo "${count:-?}"
}

# Ejecutar dotnet test solo sobre los proyectos *.Tests/ (unit + contratos),
# excluyendo *.SmokeTests/. Los smoke tests corren post-deploy via
# smoke-tests-dominio.yml; incluirlos en los gates del pipeline TDD hace que
# un feature que agrega un endpoint HTTP aborte el Gate G3 porque los smoke
# tests reciben 404 (el endpoint aun no esta desplegado en dev).
#
# Uso: run_tests_projects [flags-extra-de-dotnet-test...]
# Imprime: stdout combinado de todos los proyectos.
# Exit code: 0 si todos pasan, primer codigo de fallo (!= 0 y != 8) si alguno
# falla, 8 si NINGUN proyecto tenia tests para ejecutar.
run_tests_projects() {
    local combined_output=""
    local combined_rc=0
    local any_tests_ran=false
    local proj proj_rc proj_output
    for proj in "$WORKTREE_PATH"/tests/${HARNESS_NAMESPACE_PREFIX}.*.Tests/; do
        [ -d "$proj" ] || continue
        proj_rc=0
        proj_output=$(dotnet test --project "$proj" "$@" 2>&1) || proj_rc=$?
        combined_output+="$proj_output"$'\n'
        if [ "$proj_rc" -ne 8 ]; then
            any_tests_ran=true
        fi
        if [ "$proj_rc" -ne 0 ] && [ "$proj_rc" -ne 8 ] && [ "$combined_rc" -eq 0 ]; then
            combined_rc=$proj_rc
        fi
    done
    printf "%s" "$combined_output"
    if [ "$combined_rc" -eq 0 ] && [ "$any_tests_ran" = false ]; then
        return 8
    fi
    return $combined_rc
}

# ─── Parsear argumentos ───────────────────────────────────────────────────────
ISSUE_NUM=""
INPUT_FILE=""
FROM_STAGE=1        # Por defecto, empezar desde Stage 1
STATUS_FILENAME=""  # Se asigna despues del parseo (necesita ISSUE_NUM); override con --status-file
SCAFFOLD_DOMAIN=""  # Nombre del dominio a scaffoldear antes de Stage 1 (kebab-case)

if [ $# -eq 0 ]; then
    echo "Uso: $0 [--issue NUM | --file PATH | NUM] [--from-stage N] [--status-file NOMBRE] [--scaffold-domain KEBAB]"
    exit 1
fi

# Parsear todos los argumentos
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue)
            [ $# -lt 2 ] && abort "Falta el número de issue"
            ISSUE_NUM="$2"
            shift 2
            ;;
        --file)
            [ $# -lt 2 ] && abort "Falta la ruta del archivo"
            INPUT_FILE="$2"
            shift 2
            ;;
        --from-stage)
            [ $# -lt 2 ] && abort "Falta el número de stage"
            FROM_STAGE="$2"
            shift 2
            ;;
        --status-file)
            [ $# -lt 2 ] && abort "Falta el nombre del archivo de status"
            STATUS_FILENAME="$2"
            shift 2
            ;;
        --scaffold-domain)
            [ $# -lt 2 ] && abort "Falta el nombre del dominio para --scaffold-domain"
            SCAFFOLD_DOMAIN="$2"
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

# Procesar argumento posicional (número de issue)
if [ ${#POSITIONAL_ARGS[@]} -gt 0 ] && [ -z "$ISSUE_NUM" ]; then
    ISSUE_NUM="${POSITIONAL_ARGS[0]}"
fi

# [Cambio 3] Validar --from-stage
if ! [[ "$FROM_STAGE" =~ ^[1-4]$ ]]; then
    abort "--from-stage debe ser 1, 2, 3 o 4 (recibido: $FROM_STAGE)"
fi

# Si no se paso --status-file, usar convención normalizada con ISSUE_NUM
if [ -z "$STATUS_FILENAME" ] && [ -n "$ISSUE_NUM" ]; then
    STATUS_FILENAME="pipeline-status-tdd-${ISSUE_NUM}.json"
elif [ -z "$STATUS_FILENAME" ]; then
    STATUS_FILENAME="pipeline-status-tdd.json"
fi

# ─── Verificar dependencias ───────────────────────────────────────────────────
for cmd in claude gh git dotnet; do
    command -v "$cmd" &>/dev/null || abort "Falta comando requerido: $cmd"
done

# ─── Preparar directorio de pipeline ─────────────────────────────────────────
mkdir -p "$LOG_DIR"
echo "Pipeline iniciado: $TIMESTAMP" > "$LOG_FILE"

# Resolver rutas absolutas para uso dentro de subshells (cd al worktree)
PIPELINE_DIR_ABS="$(realpath "$PIPELINE_DIR")"
LOG_DIR_ABS="$(realpath "$LOG_DIR")"
LOG_FILE_ABS="$(realpath "$LOG_FILE")"

# [Cambio 5] Definir EVENTS_LOG_ABS aquí (fuera de bloques condicionales)
# para que esté disponible tanto en modo normal como en --from-stage
EVENTS_LOG_ABS="$PIPELINE_DIR_ABS/events.log"

# Separador de sesión en events.log
echo "─── SESSION $TIMESTAMP issue:${ISSUE_NUM:-file} from-stage:$FROM_STAGE ───" >> "$EVENTS_LOG_ABS"

# ─── Obtener contexto del issue/HU ───────────────────────────────────────────
header "Preparando contexto"

ISSUE_CONTEXT=""
ISSUE_TITLE=""

if [ -n "$ISSUE_NUM" ]; then
    log "Descargando issue #$ISSUE_NUM..."
    ISSUE_JSON=$(gh issue view "$ISSUE_NUM" --json number,title,body,state 2>>"$LOG_FILE") \
        || abort "No se pudo obtener el issue #$ISSUE_NUM"
    ISSUE_STATE=$(echo "$ISSUE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])" 2>/dev/null || echo "UNKNOWN")
    if [ "$ISSUE_STATE" != "OPEN" ]; then
        abort "El issue #$ISSUE_NUM está $ISSUE_STATE — solo se procesan issues abiertos."
    fi
    ISSUE_TITLE=$(echo "$ISSUE_JSON" | grep -o '"title":"[^"]*"' | sed 's/"title":"//;s/"//')
    ISSUE_BODY=$(echo "$ISSUE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['body'])" 2>/dev/null \
        || echo "$ISSUE_JSON" | sed 's/.*"body":"//;s/","[^"]*":".*//;s/\\n/\n/g;s/\\r//g')
    ISSUE_CONTEXT="# Issue #$ISSUE_NUM: $ISSUE_TITLE

$ISSUE_BODY"
    log "Issue: $ISSUE_TITLE"

elif [ -n "$INPUT_FILE" ]; then
    [ -f "$INPUT_FILE" ] || abort "Archivo no encontrado: $INPUT_FILE"
    ISSUE_TITLE=$(basename "$INPUT_FILE" .md)
    ISSUE_CONTEXT=$(cat "$INPUT_FILE")
    log "Archivo: $INPUT_FILE"
fi

# Guardar contexto para referencia
echo "$ISSUE_CONTEXT" > "$PIPELINE_DIR/input.md"

# ─── Preparar worktree ───────────────────────────────────────────────────────
header "Preparando worktree"

REPO_ROOT=$(git rev-parse --show-toplevel)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Generar slug para el nombre del worktree
if [ -n "$ISSUE_NUM" ]; then
    SLUG=$(echo "$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' | tr ' áéíóúàèìòùäëïöü' ' aeiouaeiouaeiou' | sed 's/[^a-z0-9 ]//g' | tr -s ' ' '-' | cut -c1-40 | sed 's/-$//')
    BRANCH_NAME="worktree-issue-${ISSUE_NUM}-${SLUG}"
else
    SLUG=$(echo "$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-zA-Z0-9]/-/g' | tr -s '-' | cut -c1-40 | sed 's/-$//')
    BRANCH_NAME="worktree-tdd-${SLUG}"
fi

WORKTREE_PATH="${REPO_ROOT}/../${BRANCH_NAME}"

if [ "$FROM_STAGE" -gt 1 ]; then
    # ── Modo retomar: el worktree ya debe existir ──
    [ -d "$WORKTREE_PATH" ] || abort "No existe el worktree en $WORKTREE_PATH. No se puede retomar desde Stage $FROM_STAGE."
    log "Retomando desde Stage $FROM_STAGE — worktree existente: $WORKTREE_PATH"
    # [Cambio 4] Eliminado código muerto: solo usar merge-base
    SNAPSHOT_COMMIT=$(git -C "$WORKTREE_PATH" merge-base HEAD main)
    log "Snapshot detectado: $SNAPSHOT_COMMIT"
else
    # ── Modo normal: crear worktree nuevo ──
    if [ "$CURRENT_BRANCH" != "main" ] && [ "$CURRENT_BRANCH" != "master" ]; then
        warn "No estás en main/master (rama actual: $CURRENT_BRANCH)"
        warn "Asegúrate de estar en la rama correcta antes de continuar"
    fi

    log "Actualizando desde origin..."
    git pull origin "${CURRENT_BRANCH}" >>"$LOG_FILE" 2>&1 || warn "No se pudo hacer pull (continuando de todas formas)"

    # [Cambio 8] Idempotencia: si el worktree ya existe, limpiarlo
    if [ -d "$WORKTREE_PATH" ]; then
        warn "El worktree ya existe: $WORKTREE_PATH — limpiando para reiniciar..."
        git worktree remove --force "$WORKTREE_PATH" >>"$LOG_FILE" 2>&1 || true
        git branch -D "$BRANCH_NAME" >>"$LOG_FILE" 2>&1 || true
    fi
    # También limpiar rama huérfana sin worktree
    if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME" 2>/dev/null; then
        warn "La rama $BRANCH_NAME ya existe sin worktree — eliminándola..."
        git branch -D "$BRANCH_NAME" >>"$LOG_FILE" 2>&1 || true
    fi

    log "Creando worktree: $WORKTREE_PATH"
    git worktree add "$WORKTREE_PATH" -b "$BRANCH_NAME" >>"$LOG_FILE" 2>&1 \
        || abort "No se pudo crear el worktree"

    success "Worktree creado: $WORKTREE_PATH"

    mkdir -p "$WORKTREE_PATH/.claude/pipeline/summaries"

    # Parchear settings.json del worktree con ruta absoluta del events.log
    sed "s|\.claude/pipeline/events\.log|${EVENTS_LOG_ABS}|g" \
        "$REPO_ROOT/.claude/settings.json" > "$WORKTREE_PATH/.claude/settings.json"

    update_status "setup" "running"

    SNAPSHOT_COMMIT=$(git -C "$WORKTREE_PATH" rev-parse HEAD)
    log "Snapshot: $SNAPSHOT_COMMIT"

    # --- Stage 0: Scaffold de dominio nuevo (solo en modo normal, no en --from-stage) ---
    if [ -n "$SCAFFOLD_DOMAIN" ]; then
        header "Stage 0: Scaffold del dominio '$SCAFFOLD_DOMAIN'"
        update_status "scaffold" "running"

        LOG_SCAFFOLD="$LOG_DIR_ABS/stage-0-scaffold-${TIMESTAMP}.log"
        SCAFFOLD_START_TS=$(date +%s)
        echo "[$(date +%H:%M:%S)] === STAGE 0: domain-scaffolder ===" >> "$EVENTS_LOG_ABS"

        SCAFFOLD_PROMPT="Crea el scaffold para el dominio '$SCAFFOLD_DOMAIN'. El usuario ya confirmo la creacion — omite la confirmacion del Paso 0 y procede directamente a crear el proyecto."

        SCAFFOLD_TIMEOUT=1800
        local NONINTERACTIVE_SYSTEM="You are running in non-interactive print mode. There is no human to approve anything. You MUST use Write and Edit tools directly to create and modify files at any path including .claude/. Never output text asking for permissions or confirmations -- doing so causes pipeline failure."
        (cd "$WORKTREE_PATH" && claude -p "$SCAFFOLD_PROMPT" \
            --agent domain-scaffolder \
            --permission-mode bypassPermissions \
            --append-system-prompt "$NONINTERACTIVE_SYSTEM" \
            --output-format text \
            >"$LOG_SCAFFOLD" 2>&1) &
        SCAFFOLD_PID=$!
        (sleep $SCAFFOLD_TIMEOUT && kill -9 -$SCAFFOLD_PID 2>/dev/null && \
            echo "[$(date +%H:%M:%S)] TIMEOUT: domain-scaffolder supero ${SCAFFOLD_TIMEOUT}s" >> "$EVENTS_LOG_ABS") </dev/null >/dev/null 2>&1 &
        SCAFFOLD_WATCHDOG=$!

        SCAFFOLD_EXIT=0
        wait $SCAFFOLD_PID || SCAFFOLD_EXIT=$?
        kill $SCAFFOLD_WATCHDOG 2>/dev/null || true
        wait $SCAFFOLD_WATCHDOG 2>/dev/null || true
        SCAFFOLD_ELAPSED=$(( $(date +%s) - SCAFFOLD_START_TS ))

        if [ "$SCAFFOLD_EXIT" -ne 0 ]; then
            echo "[$(date +%H:%M:%S)] FALLO domain-scaffolder (${SCAFFOLD_ELAPSED}s, exit $SCAFFOLD_EXIT)" >> "$EVENTS_LOG_ABS"
            abort "El scaffold del dominio '$SCAFFOLD_DOMAIN' fallo despues de ${SCAFFOLD_ELAPSED}s. Revisa: $LOG_SCAFFOLD"
        fi

        # Verificar que el proyecto fue creado
        PASCAL_CASE=$(echo "$SCAFFOLD_DOMAIN" | awk -F'-' '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1' OFS='')
        if [ ! -d "$WORKTREE_PATH/src/${HARNESS_NAMESPACE_PREFIX}.$PASCAL_CASE" ]; then
            abort "El scaffold no creo src/${HARNESS_NAMESPACE_PREFIX}.$PASCAL_CASE — revisa: $LOG_SCAFFOLD"
        fi

        echo "[$(date +%H:%M:%S)] OK domain-scaffolder (${SCAFFOLD_ELAPSED}s)" >> "$EVENTS_LOG_ABS"
        success "Scaffold del dominio '$SCAFFOLD_DOMAIN' completado en ${SCAFFOLD_ELAPSED}s"
        update_status "scaffold" "completed"

        # Actualizar snapshot: los diffs de Stage 1-3 solo muestran la implementacion, no el scaffold
        SNAPSHOT_COMMIT=$(git -C "$WORKTREE_PATH" rev-parse HEAD)
        log "Snapshot actualizado post-scaffold: $SNAPSHOT_COMMIT"
    fi
fi

# Detectar señal de refactoring pre-existente (worktree previo con --from-stage)
# Ubicacion: pipeline-state/ en la raiz del worktree (NO .claude/) — el runtime
# de Claude Code intercepta escrituras a .claude/** en worktrees aun con
# bypassPermissions, lo que dejaba al agente sin forma de senalizar refactor puro.
# Decision documentada en docs/adr/0023-archivo-senal-refactor-fuera-de-claude.md.
REFACTOR_SIGNAL_PATH="$WORKTREE_PATH/pipeline-state/refactor-signal.md"
# Compatibilidad: aceptar la ubicacion legacy si existe (worktrees previos)
LEGACY_REFACTOR_SIGNAL_PATH="$WORKTREE_PATH/.claude/pipeline/refactor-signal.md"
if [ ! -f "$REFACTOR_SIGNAL_PATH" ] && [ -f "$LEGACY_REFACTOR_SIGNAL_PATH" ]; then
    REFACTOR_SIGNAL_PATH="$LEGACY_REFACTOR_SIGNAL_PATH"
fi
if [ -f "$REFACTOR_SIGNAL_PATH" ]; then
    IS_REFACTOR=true
    REFACTOR_JUSTIFICATION=$(grep "^JUSTIFICATION=" "$REFACTOR_SIGNAL_PATH" | cut -d= -f2- || echo "no especificada")
    log "Señal de refactoring detectada (pre-existente): $REFACTOR_JUSTIFICATION"
fi

# Asegurar que el directorio pipeline-state/ existe en el worktree para que el
# test-writer pueda escribir refactor-signal.md sin restricciones.
mkdir -p "$WORKTREE_PATH/pipeline-state"

# ─── Función auxiliar para recolectar resumen de agente ─────────────────────
collect_summary() {
    local stage="$1" agent="$2"
    local f="$WORKTREE_PATH/.claude/pipeline/summaries/stage-${stage}-${agent}.md"
    if [ -f "$f" ]; then cat "$f"; else echo "_(El agente no generó resumen)_"; fi
}

# ─── Función auxiliar para invocar agentes ───────────────────────────────────
run_agent() {
    local stage="$1"
    local agent="$2"
    local prompt="$3"
    local log_stage="$LOG_DIR_ABS/stage-${stage}-${agent}-${TIMESTAMP}-issue-${ISSUE_NUM}.log"
    local start_ts
    start_ts=$(date +%s)

    echo "[$(date +%H:%M:%S)] === STAGE $stage: $agent ===" >> "$EVENTS_LOG_ABS"
    case "$agent" in
        test-writer) AGENT_TW_RES="running" ;;
        implementer) AGENT_IM_RES="running" ;;
        reviewer)    AGENT_RV_RES="running" ;;
    esac
    update_status "$stage-$agent" "running"
    log "Invocando $agent..."

    local AGENT_TIMEOUT_SECONDS=1800  # 30 minutos por agente
    local NONINTERACTIVE_SYSTEM="You are running in non-interactive print mode. There is no human to approve anything. You MUST use Write and Edit tools directly to create and modify files at any path including .claude/. Never output text asking for permissions or confirmations -- doing so causes pipeline failure."
    (cd "$WORKTREE_PATH" && claude -p "$prompt" \
        --agent "$agent" \
        --permission-mode bypassPermissions \
        --append-system-prompt "$NONINTERACTIVE_SYSTEM" \
        --output-format text \
        >"$log_stage" 2>&1) &
    local CLAUDE_PID=$!
    # M3: usar SIGKILL para garantizar que el proceso muere al timeout
    (sleep $AGENT_TIMEOUT_SECONDS && kill -9 -$CLAUDE_PID 2>/dev/null && echo "[$(date +%H:%M:%S)] TIMEOUT: $agent superó ${AGENT_TIMEOUT_SECONDS}s — eliminado con SIGKILL" >> "$EVENTS_LOG_ABS") </dev/null >/dev/null 2>&1 &
    local WATCHDOG_PID=$!

    local CLAUDE_EXIT=0
    wait $CLAUDE_PID || CLAUDE_EXIT=$?

    kill $WATCHDOG_PID 2>/dev/null || true
    wait $WATCHDOG_PID 2>/dev/null || true
    local elapsed=$(( $(date +%s) - start_ts ))

    if [ "$CLAUDE_EXIT" -ne 0 ]; then
        # M1: Clasificar tipo de fallo por exit code y contenido del log
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
        log "$agent falló después de ${elapsed}s — tipo: $failure_type"
        echo "[$(date +%H:%M:%S)] FALLO $agent: $failure_type" >> "$EVENTS_LOG_ABS"

        # M6: Retry automatico para errores transitorios del servidor sin trabajo previo
        if echo "$failure_type" | grep -q "API_ERROR_SERVER"; then
            local has_work=false
            if ! git -C "$WORKTREE_PATH" diff --quiet "${SNAPSHOT_COMMIT:-HEAD}..HEAD" 2>/dev/null; then
                has_work=true
            fi
            if [ "$has_work" = false ]; then
                warn "$agent: API error 5xx — reintentando una vez..."
                echo "[$(date +%H:%M:%S)] RETRY $agent: API error 5xx, reintentando" >> "$EVENTS_LOG_ABS"
                local log_stage_retry="$LOG_DIR_ABS/stage-${stage}-${agent}-${TIMESTAMP}-issue-${ISSUE_NUM}-retry.log"
                local retry_start
                retry_start=$(date +%s)
                CLAUDE_EXIT=0
                (cd "$WORKTREE_PATH" && claude -p "$prompt" \
                    --agent "$agent" \
                    --permission-mode bypassPermissions \
                    --append-system-prompt "$NONINTERACTIVE_SYSTEM" \
                    --output-format text \
                    >"$log_stage_retry" 2>&1) || CLAUDE_EXIT=$?
                elapsed=$(( $(date +%s) - start_ts ))
                log_stage="$log_stage_retry"
                if [ "$CLAUDE_EXIT" -ne 0 ]; then
                    failure_type="CLI_ERROR_POST_RETRY (exit $CLAUDE_EXIT)"
                    log "$agent falló tambien en reintento — tipo: $failure_type"
                    echo "[$(date +%H:%M:%S)] RETRY_FALLO $agent: $failure_type" >> "$EVENTS_LOG_ABS"
                else
                    log "$agent: reintento exitoso en ${elapsed}s"
                    echo "[$(date +%H:%M:%S)] RETRY_OK $agent: exitoso en ${elapsed}s" >> "$EVENTS_LOG_ABS"
                fi
            fi
        fi

        if [ "$CLAUDE_EXIT" -ne 0 ]; then
            # M2: Verificar si el agente produjo trabajo util antes de abortar
            local has_commits=false
            local gate_passes=false

            if ! git -C "$WORKTREE_PATH" diff --quiet "${SNAPSHOT_COMMIT:-HEAD}..HEAD" 2>/dev/null; then
                has_commits=true
            fi
            if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain -- tests/ src/ 2>/dev/null)" ]; then
                has_commits=true
            fi

            if [ "$has_commits" = true ]; then
                case "$stage" in
                    1)
                        if dotnet build "$WORKTREE_PATH" >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1; then
                            gate_passes=true
                        fi
                        ;;
                    2|3|merge)
                        local test_rc=0
                        run_tests_projects >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1 || test_rc=$?
                        if [ "$test_rc" -eq 0 ]; then
                            gate_passes=true
                        fi
                        ;;
                esac
            fi

            if [ "$has_commits" = true ] && [ "$gate_passes" = true ]; then
                warn "$agent: CLI retorno error ($failure_type) pero hay trabajo util completado — continuando"
                echo "[$(date +%H:%M:%S)] RECUPERADO $agent: trabajo util detectado post-$failure_type, continuando" >> "$EVENTS_LOG_ABS"
                # Continuar sin abortar — los gates del pipeline verificaran el resultado
            else
                case "$agent" in
                    test-writer) AGENT_TW_DUR=$elapsed; AGENT_TW_RES="failed" ;;
                    implementer) AGENT_IM_DUR=$elapsed; AGENT_IM_RES="failed" ;;
                    reviewer)    AGENT_RV_DUR=$elapsed; AGENT_RV_RES="failed" ;;
                esac
                update_status "$stage-$agent" "failed"
                echo -e "\n${RED}── Ultimas lineas del log de $agent:${NC}"
                tail -20 "$log_stage"
                abort "$agent falló ($failure_type). Log completo: $log_stage"
            fi
        fi
    fi

    LAST_AGENT_DURATION=$elapsed
    log "$agent completado en ${elapsed}s"
}

# ─── Función auxiliar: auto-commit de seguridad ──────────────────────────────
# Solo commitea cambios en tests/ y src/ (ignora .claude/, bin/, obj/, etc.)
auto_commit_if_needed() {
    local phase="$1"     # "roja", "verde", "refactor"
    local msg="$2"       # mensaje de commit

    # [Cambio 1] Restaurar settings.json antes de verificar estado git
    # El pipeline lo parchea a propósito, pero no debe interferir con git
    git -C "$WORKTREE_PATH" checkout -- .claude/settings.json 2>/dev/null || true

    # Revisar si hay cambios en tests/ o src/ específicamente
    if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain -- tests/ src/)" ]; then
        log "El agente no commitió cambios en tests/src. Haciendo commit automático (fase $phase)..."
        git -C "$WORKTREE_PATH" add tests/ src/ >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1
        git -C "$WORKTREE_PATH" commit -m "$msg" >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1 || true
    fi
}

# ─── STAGE 1: Test Writer (fase roja) ────────────────────────────────────────
if [ "$FROM_STAGE" -le 1 ]; then
    header "Stage 1: Test Writer (fase roja)"

    STAGE1_PROMPT="Estás en el directorio raíz del proyecto ${HARNESS_PROJECT_NAME}.

Contexto de la historia de usuario a implementar:

$ISSUE_CONTEXT

Tu tarea: escribe los tests unitarios para esta HU y crea los stubs mínimos de compilación. Sigue todas las instrucciones de tu rol de test-writer."

    run_agent "1" "test-writer" "$STAGE1_PROMPT"

    # Detectar señal de refactor ANTES del gate de "no genero archivos".
    # Si el agente concluyo refactoring puro, la senal es la unica evidencia
    # esperada en tests/ y src/ — abortar antes de chequearla seria un falso negativo.
    # Tambien re-evaluamos el path por si el agente uso la ubicacion legacy.
    if [ ! -f "$REFACTOR_SIGNAL_PATH" ] && [ -f "$LEGACY_REFACTOR_SIGNAL_PATH" ]; then
        REFACTOR_SIGNAL_PATH="$LEGACY_REFACTOR_SIGNAL_PATH"
    fi
    if [ -f "$REFACTOR_SIGNAL_PATH" ] && [ "$IS_REFACTOR" = false ]; then
        IS_REFACTOR=true
        REFACTOR_JUSTIFICATION=$(grep "^JUSTIFICATION=" "$REFACTOR_SIGNAL_PATH" | cut -d= -f2- || echo "no especificada")
        log "Señal de refactoring detectada: $REFACTOR_JUSTIFICATION"
    fi

    # Validar que el agente produjo trabajo: cambios en tests/src O senal de refactor.
    # Si no hay nada, distinguir entre "agente realmente fallo" y "razono refactor pero
    # no pudo escribir la senal" (Bug 1: runtime intercepta escrituras a .claude/**).
    if [ "$IS_REFACTOR" = false ] \
       && git -C "$WORKTREE_PATH" diff --quiet "$SNAPSHOT_COMMIT" HEAD 2>/dev/null \
       && [ -z "$(git -C "$WORKTREE_PATH" status --porcelain -- tests/ src/)" ]; then
        STAGE1_LOG="$LOG_DIR_ABS/stage-1-test-writer-${TIMESTAMP}-issue-${ISSUE_NUM}.log"
        if [ -f "$STAGE1_LOG" ] && grep -qiE "refactor.*pur|REFACTOR_ONLY|refactor-signal|refactoring puro" "$STAGE1_LOG"; then
            abort "El test-writer detecto refactor puro pero no creo el archivo señal en $REFACTOR_SIGNAL_PATH (ni en la ubicacion legacy). Probable causa: el runtime intercepto la escritura. Revisa el log: $STAGE1_LOG"
        fi
        abort "El test-writer no generó ningún archivo. Verifica que la definición del agente (.claude/agents/test-writer.md) existe en el repo."
    fi

    # Gate 1a: debe compilar
    log "Gate: verificando compilación..."
    dotnet build "$WORKTREE_PATH" >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1 \
        || abort "Stage 1 fallido: el proyecto no compila después del test-writer. Revisa $LOG_DIR/stage-1-test-writer.log"

    if [ "$IS_REFACTOR" = false ]; then
        # Gate 1b: los tests nuevos deben FALLAR (exit code != 0)
        # Exit codes de Microsoft Testing Platform: 0=pasan, 2=fallan, 8=no hay tests, 1=agregado mixto
        # Gate 1a ya verifico compilacion, asi que exit != 0 aqui significa tests fallando
        log "Gate: verificando fase roja (tests deben fallar)..."
        g1_rc=0
        TEST_OUTPUT_G1=$(run_tests_projects --no-build 2>&1) || g1_rc=$?
        echo "$TEST_OUTPUT_G1" | tee -a "${LOG_FILE_ABS:-$LOG_FILE}" >/dev/null
        if [ "$g1_rc" -eq 0 ]; then
            abort "Stage 1 fallido: todos los tests pasan (exit code: 0) — el test-writer pudo haber escrito implementacion real en lugar de stubs"
        fi
        if [ "$g1_rc" -eq 8 ]; then
            abort "Stage 1 fallido: no se encontraron tests para ejecutar (exit code: 8) — el test-writer no genero tests validos"
        fi
        log "Fase roja confirmada (exit code: $g1_rc)"
    fi

    # Auto-commit de seguridad (solo si hay cambios uncommitted en tests/ o src/)
    auto_commit_if_needed "roja" "test(hu-${ISSUE_NUM:-?}): tests fase roja"

    if [ "$IS_REFACTOR" = true ]; then
        # Baseline: verificar que todos los tests pasan antes del refactoring
        log "Gate: verificando baseline verde para refactoring..."
        baseline_rc=0
        TEST_OUTPUT_BASELINE=$(run_tests_projects 2>&1) || baseline_rc=$?
        echo "$TEST_OUTPUT_BASELINE" | tee -a "${LOG_FILE_ABS:-$LOG_FILE}" >/dev/null
        if [ "$baseline_rc" -ne 0 ]; then
            abort "Refactoring señalizado pero hay tests fallando (exit code: $baseline_rc). No se puede refactorizar sobre una base roja."
        fi
        BASELINE_TEST_COUNT=$(extract_test_count "$TEST_OUTPUT_BASELINE")
        log "Baseline refactoring: $BASELINE_TEST_COUNT tests pasando"
        success "Baseline verde confirmado"
    fi

    AGENT_TW_DUR=$LAST_AGENT_DURATION
    AGENT_TW_RES="passed"
    update_status "1-test-writer" "passed"
    success "Stage 1 completado — fase roja confirmada"
else
    log "Saltando Stage 1 (--from-stage $FROM_STAGE)"
fi

# [Cambio 6] Capturar archivos y verificar que hay contenido
if [ "$IS_REFACTOR" = false ]; then
    STAGE1_FILES=$(git -C "$WORKTREE_PATH" diff --name-only "$SNAPSHOT_COMMIT"..HEAD)
    if [ -z "$STAGE1_FILES" ]; then
        abort "No se detectaron archivos nuevos después de Stage 1. El test-writer no generó ni commitió cambios válidos. Verifica el log del test-writer."
    fi
    log "Archivos del test-writer:"
    echo "$STAGE1_FILES" | while read -r f; do log "  + $f"; done
else
    STAGE1_FILES=""
    log "Refactoring puro: no se esperan archivos de test nuevos"
fi

# ─── STAGE 2: Implementer (fase verde) ───────────────────────────────────────
if [ "$IS_REFACTOR" = true ]; then
    log "Saltando Stage 2 (refactoring puro — no hay tests que hacer pasar)"
    AGENT_IM_RES="skipped"
    update_status "2-implementer" "skipped"
elif [ "$FROM_STAGE" -le 2 ]; then
    header "Stage 2: Implementer (fase verde)"

    STAGE2_PROMPT="Estás en el directorio raíz del proyecto ${HARNESS_PROJECT_NAME}.

Contexto de la historia de usuario:

$ISSUE_CONTEXT

El test-writer creó/modificó los siguientes archivos:
$STAGE1_FILES

Tu tarea: implementa la lógica de negocio para hacer pasar todos los tests. Sigue todas las instrucciones de tu rol de implementer."

    run_agent "2" "implementer" "$STAGE2_PROMPT"

    # Gate 2: verificar tests
    log "Gate: verificando fase verde..."
    g2_rc=0
    TEST_OUTPUT_G2=$(run_tests_projects 2>&1) || g2_rc=$?
    echo "$TEST_OUTPUT_G2" | tee -a "${LOG_FILE_ABS:-$LOG_FILE}" >/dev/null
    if [ "$g2_rc" -ne 0 ]; then
        BLOCKAGE_REPORT="$WORKTREE_PATH/.claude/pipeline/blockage-report.md"
        if [ -f "$BLOCKAGE_REPORT" ]; then
            warn "Stage 2: hay tests rojos pero el implementer reporto bloqueo — continuando al reviewer"
            echo "[$(date +%H:%M:%S)] BLOCKAGE: implementer reporto tests bloqueados, continuando" >> "$EVENTS_LOG_ABS"
            HAS_BLOCKAGE=true
        else
            echo "$TEST_OUTPUT_G2" | tail -20
            abort "Stage 2 fallido: no todos los tests pasan después del implementer (exit code: $g2_rc). Revisa $LOG_DIR_ABS/stage-2-implementer.log"
        fi
    fi

    TEST_COUNT=$(extract_test_count "$TEST_OUTPUT_G2")
    PIPELINE_TESTS="$TEST_COUNT"
    log "Tests pasando: $TEST_COUNT"

    # Auto-commit de seguridad
    auto_commit_if_needed "verde" "feat(hu-${ISSUE_NUM:-?}): implementación fase verde"

    AGENT_IM_DUR=$LAST_AGENT_DURATION
    if [ "$HAS_BLOCKAGE" = true ]; then
        AGENT_IM_RES="blocked"
        update_status "2-implementer" "blocked"
        warn "Stage 2 completado con tests bloqueados — el reviewer intentara resolverlos"
    else
        AGENT_IM_RES="passed"
        update_status "2-implementer" "passed"
        success "Stage 2 completado — fase verde confirmada"
    fi
else
    log "Saltando Stage 2 (--from-stage $FROM_STAGE)"
fi

# ─── STAGE 2b: Smoke Test Writer (condicional) ───────────────────────────────
# Solo se ejecuta si hay Function Apps modificadas y el proyecto SmokeTests existe
if [ "$IS_REFACTOR" != true ] && [ "$FROM_STAGE" -le 2 ]; then
    SMOKE_FILES=$(git -C "$WORKTREE_PATH" diff --name-only "$SNAPSHOT_COMMIT"..HEAD | grep -E 'Function/' || true)

    if [ -n "$SMOKE_FILES" ]; then
        # Detectar dominio desde los archivos modificados
        SMOKE_DOMAIN=$(echo "$SMOKE_FILES" | head -1 | sed "s|src/${HARNESS_NAMESPACE_PREFIX}\.\([^/]*\)/.*|\1|")
        SMOKE_TEST_PROJECT="tests/${HARNESS_NAMESPACE_PREFIX}.${SMOKE_DOMAIN}.SmokeTests"

        if [ -d "$WORKTREE_PATH/$SMOKE_TEST_PROJECT" ]; then
            header "Stage 2b: Smoke Test Writer"

            STAGE2B_PROMPT="Estás en el directorio raíz del proyecto ${HARNESS_PROJECT_NAME}.

Contexto de la historia de usuario:

$ISSUE_CONTEXT

El implementer creó/modificó los siguientes endpoints:
$SMOKE_FILES

Tu tarea: escribe smoke tests para los endpoints nuevos o modificados.
IMPORTANTE: Solo escribe y compila. NO ejecutes los tests (el entorno dev puede no tener este código desplegado aún).
Usa 'dotnet build' para verificar compilación, pero NO uses 'dotnet test'.

Sigue todas las instrucciones de tu rol de smoke-test-writer."

            run_agent "2b" "smoke-test-writer" "$STAGE2B_PROMPT"

            # Gate: solo compilación del proyecto de smoke tests
            log "Gate: verificando que smoke tests compilan..."
            st_build_rc=0
            ST_BUILD_OUTPUT=$(dotnet build "$WORKTREE_PATH/$SMOKE_TEST_PROJECT" 2>&1) || st_build_rc=$?
            echo "$ST_BUILD_OUTPUT" | tee -a "${LOG_FILE_ABS:-$LOG_FILE}" >/dev/null
            if [ "$st_build_rc" -ne 0 ]; then
                echo "$ST_BUILD_OUTPUT" | tail -20
                abort "Stage 2b fallido: smoke tests no compilan (exit code: $st_build_rc). Revisa el log."
            fi

            auto_commit_if_needed "smoke" "test(hu-${ISSUE_NUM:-?}): smoke tests para endpoints"

            AGENT_ST_DUR=$LAST_AGENT_DURATION
            AGENT_ST_RES="passed"
            update_status "2b-smoke-test-writer" "passed"
            success "Stage 2b completado — smoke tests escritos"
        else
            log "Proyecto SmokeTests no existe para $SMOKE_DOMAIN — saltando smoke tests"
            AGENT_ST_RES="skipped"
            update_status "2b-smoke-test-writer" "skipped"
        fi
    else
        log "No se detectaron Function Apps modificadas — saltando smoke tests"
        AGENT_ST_RES="skipped"
        update_status "2b-smoke-test-writer" "skipped"
    fi
else
    if [ "$IS_REFACTOR" = true ]; then
        log "Saltando Stage 2b (refactoring puro)"
    else
        log "Saltando Stage 2b (--from-stage $FROM_STAGE)"
    fi
    AGENT_ST_RES="skipped"
fi

# ─── STAGE 3: Reviewer (fase refactor) ───────────────────────────────────────
if [ "$FROM_STAGE" -le 3 ]; then
    header "Stage 3: Reviewer (fase refactor)"

    if [ "$IS_REFACTOR" = true ]; then
        STAGE3_PROMPT="Estás en el directorio raíz del proyecto ${HARNESS_PROJECT_NAME}.

Esta es una tarea de REFACTORING PURO. No hay fases roja ni verde previas.
Justificación del refactoring: $REFACTOR_JUSTIFICATION

Contexto de la tarea:

$ISSUE_CONTEXT

Tu misión: ejecutar el refactoring descrito en el issue. Los tests existentes DEBEN seguir pasando en todo momento.

Reglas:
1. Corre dotnet test ANTES de empezar para confirmar el baseline verde.
2. Ejecuta el refactoring en pasos pequeños y seguros.
3. Después de cada cambio significativo, corre dotnet test.
4. Si un cambio rompe tests, reviértelo inmediatamente: git checkout -- <archivo>
5. Al terminar, corre dotnet test una última vez para confirmar que todo sigue verde.
6. Haz commit de tu trabajo con mensaje: refactor(hu-${ISSUE_NUM:-?}): [descripción]

Sigue todas las instrucciones de tu rol de reviewer."
    else
        FULL_DIFF=$(git -C "$WORKTREE_PATH" diff "$SNAPSHOT_COMMIT"..HEAD)

        STAGE3_PROMPT="Estás en el directorio raíz del proyecto ${HARNESS_PROJECT_NAME}.

Contexto de la historia de usuario:

$ISSUE_CONTEXT

Diff completo de las fases roja y verde:

$FULL_DIFF

Tu tarea: revisa la calidad del código, refactoriza si es necesario, y verifica que los criterios de aceptación estén bien cubiertos.
Si el diff incluye smoke tests (archivos en *SmokeTests/), revísalos también: verifica que cubran los escenarios principales del endpoint (camino feliz, validación, duplicados) y que sigan las convenciones del proyecto.
Sigue todas las instrucciones de tu rol de reviewer."
    fi

    # Agregar contexto de bloqueo al prompt si el implementer reporto tests bloqueados
    if [ "${HAS_BLOCKAGE:-false}" = true ]; then
        BLOCKAGE_REPORT="$WORKTREE_PATH/.claude/pipeline/blockage-report.md"
        if [ -f "$BLOCKAGE_REPORT" ]; then
            STAGE3_PROMPT="$STAGE3_PROMPT

ATENCION: El implementer reporto tests bloqueados. Lee el reporte en .claude/pipeline/blockage-report.md y sigue las instrucciones de tu seccion 2b para intentar resolverlos."
        fi
    fi

    run_agent "3" "reviewer" "$STAGE3_PROMPT"

    # Gate 3: tests deben seguir pasando (exit code 0 = verde)
    log "Gate: verificando que refactor no rompió tests..."
    g3_rc=0
    TEST_OUTPUT_G3=$(run_tests_projects 2>&1) || g3_rc=$?
    echo "$TEST_OUTPUT_G3" | tee -a "${LOG_FILE_ABS:-$LOG_FILE}" >/dev/null
    if [ "$g3_rc" -ne 0 ]; then
        BLOCKAGE_REPORT="$WORKTREE_PATH/.claude/pipeline/blockage-report.md"
        if [ "${HAS_BLOCKAGE:-false}" = true ] && [ -f "$BLOCKAGE_REPORT" ]; then
            warn "Stage 3: hay tests rojos pero el bloqueo persiste desde el implementer — continuando a PR"
            echo "[$(date +%H:%M:%S)] BLOCKAGE_PERSISTS: reviewer no resolvio tests bloqueados" >> "$EVENTS_LOG_ABS"
        else
            echo "$TEST_OUTPUT_G3" | tail -20
            abort "Stage 3 fallido: el reviewer rompió tests al refactorizar (exit code: $g3_rc). Revisa $LOG_DIR_ABS/stage-3-reviewer.log"
        fi
    fi

    # Verificación adicional para refactoring: no deben perderse tests
    if [ "$IS_REFACTOR" = true ]; then
        POST_TEST_COUNT=$(extract_test_count "$TEST_OUTPUT_G3")
        log "Tests post-refactoring: $POST_TEST_COUNT (baseline: $BASELINE_TEST_COUNT)"
        if [ "$POST_TEST_COUNT" != "?" ] && [ "$BASELINE_TEST_COUNT" != "?" ]; then
            if [ "$POST_TEST_COUNT" -lt "$BASELINE_TEST_COUNT" ]; then
                abort "El refactoring perdió tests: antes=$BASELINE_TEST_COUNT, después=$POST_TEST_COUNT"
            fi
        fi
        PIPELINE_TESTS="$POST_TEST_COUNT"
    fi

    # Auto-commit de seguridad
    auto_commit_if_needed "refactor" "refactor(hu-${ISSUE_NUM:-?}): revisión y refactor"

    AGENT_RV_DUR=$LAST_AGENT_DURATION
    AGENT_RV_RES="passed"
    update_status "3-reviewer" "passed"
    success "Stage 3 completado — fase refactor confirmada"
else
    log "Saltando Stage 3 (--from-stage $FROM_STAGE)"
fi

# ─── Verificar que hay commits antes de crear PR ─────────────────────────────
COMMITS_LIST=$(git -C "$WORKTREE_PATH" log "${SNAPSHOT_COMMIT}..HEAD" --oneline)
if [ -z "$COMMITS_LIST" ]; then
    abort "No hay commits en la rama $BRANCH_NAME. Los agentes no commitieron su trabajo y el auto-commit falló."
fi

# ─── Sincronizar con main antes de crear PR ──────────────────────────────────
header "Sincronizando con main"

log "Actualizando main desde origin..."
git -C "$WORKTREE_PATH" fetch origin main >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1 \
    || abort "No se pudo hacer fetch de origin/main"

BEHIND_COUNT=$(git -C "$WORKTREE_PATH" rev-list HEAD..origin/main --count)
if [ "$BEHIND_COUNT" -eq 0 ]; then
    log "La rama ya está al día con main"
else
    log "main tiene $BEHIND_COUNT commit(s) nuevos. Haciendo merge..."

    if git -C "$WORKTREE_PATH" merge origin/main --no-edit >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1; then
        success "Merge automático exitoso"
    else
        warn "Merge con conflictos. Invocando agente para resolverlos..."

        CONFLICT_FILES=$(git -C "$WORKTREE_PATH" diff --name-only --diff-filter=U)

        MERGE_PROMPT="Estás en el directorio raíz del proyecto ${HARNESS_PROJECT_NAME}.

Hay conflictos de merge con la rama main en los siguientes archivos:
$CONFLICT_FILES

Resuelve los conflictos manteniendo tanto la funcionalidad nueva (de esta rama) como la existente (de main).
Después de resolver cada archivo, haz git add del archivo.
Cuando todos estén resueltos, haz git commit para completar el merge.
NO elimines código de ninguna de las dos ramas — integra ambos cambios."

        run_agent "merge" "implementer" "$MERGE_PROMPT"

        # Verificar que no quedan conflictos
        REMAINING_CONFLICTS=$(git -C "$WORKTREE_PATH" diff --name-only --diff-filter=U 2>/dev/null || true)
        if [ -n "$REMAINING_CONFLICTS" ]; then
            abort "Aún quedan conflictos después del agente: $REMAINING_CONFLICTS. Revisa manualmente: cd $WORKTREE_PATH"
        fi
        success "Conflictos resueltos"
    fi

    # Re-correr tests post-merge
    log "Verificando tests después del merge..."
    merge_rc=0
    TEST_OUTPUT_MERGE=$(run_tests_projects 2>&1) || merge_rc=$?
    echo "$TEST_OUTPUT_MERGE" | tee -a "${LOG_FILE_ABS:-$LOG_FILE}" >/dev/null
    if [ "$merge_rc" -ne 0 ]; then
        abort "Tests fallan después del merge con main (exit code: $merge_rc). Revisa manualmente: cd $WORKTREE_PATH"
    fi
    success "Tests pasan después del merge con main"
fi

# ─── STAGE 4: Coverage Gate ─────────────────────────────────────────────────
# Mide cobertura de lineas sobre archivos de logica del PR.
# Si hay brechas, genera patch spec y relanza test-writer (+implementer si necesario).
# Maximo 1 iteracion de remediacion.
if [ "$IS_REFACTOR" != true ] && [ "$FROM_STAGE" -le 4 ]; then
    header "Stage 4: Coverage Gate"

    CG_START=$(date +%s)
    update_status "4-coverage-gate" "running"
    echo "[$(date +%H:%M:%S)] === STAGE 4: coverage-gate ===" >> "$EVENTS_LOG_ABS"
    AGENT_CG_RES="running"

    # --- 4a: Verificar que dotnet-coverage esta disponible ---
    if ! command -v dotnet-coverage &>/dev/null; then
        warn "dotnet-coverage no encontrado — saltando coverage gate"
        echo "[$(date +%H:%M:%S)] SKIP coverage-gate: dotnet-coverage no disponible" >> "$EVENTS_LOG_ABS"
        AGENT_CG_RES="skipped"
        AGENT_CG_DUR=$(( $(date +%s) - CG_START ))
        update_status "4-coverage-gate" "skipped"
    else

    # --- 4b: Identificar archivos .cs del PR (src/ solamente, excluir tests/obj/bin) ---
    PR_SRC_FILES=$(git -C "$WORKTREE_PATH" diff --name-only "$SNAPSHOT_COMMIT"..HEAD -- 'src/*.cs' \
        | grep -v '/obj/' | grep -v '/bin/' || true)

    if [ -z "$PR_SRC_FILES" ]; then
        log "No hay archivos .cs en src/ modificados — saltando coverage gate"
        AGENT_CG_RES="skipped"
        AGENT_CG_DUR=$(( $(date +%s) - CG_START ))
        update_status "4-coverage-gate" "skipped"
    else

    log "Archivos .cs del PR:"
    echo "$PR_SRC_FILES" | while read -r f; do log "  $f"; done

    # --- 4c: Clasificar archivos ---
    # Resultado: LOGIC_FILES (requiere 95%) y EXCLUDED_FILES
    LOGIC_FILES=""
    EXCLUDED_FILES=""
    NOT_EVALUATED_FILES=""

    classify_file() {
        local filepath="$1"
        local basename
        basename=$(basename "$filepath")
        local dirname
        dirname=$(dirname "$filepath")

        # Excluidos por nombre
        case "$basename" in
            HealthCheck.cs|Program.cs|*Mensajes.cs|*AssemblyMarker.cs|ConfiguracionSerializacion*.cs|*.resx)
                echo "excluded"; return ;;
        esac

        # Excluidos por directorio de infraestructura (wiring puro)
        if echo "$dirname" | grep -q '/Infraestructura/'; then
            case "$basename" in
                RequestValidator.cs|ServiceBusDeserializador.cs)
                    echo "excluded"; return ;;
            esac
        fi

        # Logica: patrones que requieren 95%
        case "$basename" in
            *CommandHandler.cs|*AggregateRoot.cs|*Validator.cs|FunctionEndpoint.cs)
                echo "logic"; return ;;
        esac

        # Logica: Eventos con factory Crear()
        if echo "$dirname" | grep -q '/Eventos/\|/Entities/'; then
            if [ -f "$WORKTREE_PATH/$filepath" ] && grep -q 'static.*Crear(' "$WORKTREE_PATH/$filepath" 2>/dev/null; then
                echo "logic"; return
            fi
        fi

        # Logica: ValueObjects con factory Crear()
        if echo "$dirname" | grep -q '/ValueObjects/'; then
            if [ -f "$WORKTREE_PATH/$filepath" ] && grep -q 'static.*Crear(' "$WORKTREE_PATH/$filepath" 2>/dev/null; then
                echo "logic"; return
            fi
        fi

        # Excluir: records DTO puros (solo 'public record X(...)' sin metodos)
        if [ -f "$WORKTREE_PATH/$filepath" ]; then
            local content
            content=$(grep -v '^\s*//' "$WORKTREE_PATH/$filepath" | grep -v '^\s*$' | grep -v '^using ' | grep -v '^namespace ' || true)
            local line_count
            line_count=$(echo "$content" | wc -l | tr -d ' ')
            if [ "$line_count" -le 3 ] && echo "$content" | grep -qE '^\s*public\s+record\s+\w+\(' 2>/dev/null; then
                echo "excluded"; return
            fi
        fi

        echo "not_evaluated"
    }

    while IFS= read -r file; do
        classification=$(classify_file "$file")
        case "$classification" in
            logic) LOGIC_FILES="${LOGIC_FILES:+$LOGIC_FILES
}$file" ;;
            excluded) EXCLUDED_FILES="${EXCLUDED_FILES:+$EXCLUDED_FILES
}$file" ;;
            not_evaluated) NOT_EVALUATED_FILES="${NOT_EVALUATED_FILES:+$NOT_EVALUATED_FILES
}$file" ;;
        esac
    done <<< "$PR_SRC_FILES"

    if [ -n "$LOGIC_FILES" ]; then
        log "Archivos de logica (requieren 95%):"
        echo "$LOGIC_FILES" | while read -r f; do log "  * $f"; done
    fi
    if [ -n "$EXCLUDED_FILES" ]; then
        log "Archivos excluidos:"
        echo "$EXCLUDED_FILES" | while read -r f; do log "  - $f"; done
    fi
    if [ -n "$NOT_EVALUATED_FILES" ]; then
        log "Archivos no evaluados:"
        echo "$NOT_EVALUATED_FILES" | while read -r f; do log "  ? $f"; done
    fi

    if [ -z "$LOGIC_FILES" ]; then
        log "No hay archivos de logica para evaluar — coverage gate pasa trivialmente"
        # Construir tabla solo con excluidos/no-evaluados
        COV_TABLE="| Archivo | Cobertura | Umbral | Estado |
|---|---|---|---|"
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            COV_TABLE="$COV_TABLE
| $(basename "$f") | - | excluido | - |"
        done <<< "$EXCLUDED_FILES"
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            COV_TABLE="$COV_TABLE
| $(basename "$f") | - | no evaluado | - |"
        done <<< "$NOT_EVALUATED_FILES"

        AGENT_CG_RES="passed"
        AGENT_CG_DUR=$(( $(date +%s) - CG_START ))
        update_status "4-coverage-gate" "passed"
        success "Stage 4 completado — sin archivos de logica que evaluar"
    else

    # --- 4d: Instrumentar y recoger cobertura ---
    measure_coverage() {
        # Retorna 0 si exito, 1 si fallo. Deja coverage.cobertura.xml en el worktree.
        log "Compilando proyecto para instrumentacion..."
        if ! dotnet build "$WORKTREE_PATH" >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1; then
            warn "Build fallo antes de instrumentacion"
            return 1
        fi

        log "Instrumentando DLLs..."
        local settings_xml="$WORKTREE_PATH/dotnet-coverage.settings.xml"
        local instrumented=0
        local seen_dlls=0
        local skipped_tests=0
        local skipped_duplicates=0
        # Set de basenames ya instrumentados (compatible bash 3.2, sin declare -A).
        # Cadena con espacios como delimitadores; se consulta con [[ "$set" == *" $bn "* ]].
        local instrumented_basenames=" "
        for dll in "$WORKTREE_PATH"/tests/${HARNESS_NAMESPACE_PREFIX}.*.Tests/bin/Debug/net10.0/${HARNESS_NAMESPACE_PREFIX}.*.dll; do
            [[ ! -f "$dll" ]] && continue
            seen_dlls=$((seen_dlls + 1))
            local bn
            bn="$(basename "$dll")"
            if [[ "$bn" == *Tests.dll ]]; then
                skipped_tests=$((skipped_tests + 1))
                continue
            fi
            if [[ "$instrumented_basenames" == *" $bn "* ]]; then
                skipped_duplicates=$((skipped_duplicates + 1))
                continue
            fi
            if dotnet-coverage instrument "$dll" --settings "$settings_xml" >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1; then
                instrumented=$((instrumented + 1))
                instrumented_basenames+="$bn "
            else
                warn "No se pudo instrumentar: $bn"
            fi
        done
        log "Instrumentacion: vistas=$seen_dlls, omitidas_tests=$skipped_tests, omitidas_duplicadas=$skipped_duplicates, instrumentadas=$instrumented"

        if [ "$instrumented" -eq 0 ]; then
            warn "No se instrumento ninguna DLL"
            return 1
        fi
        log "$instrumented DLL(s) instrumentada(s)"

        log "Recolectando cobertura..."
        local cov_output="$WORKTREE_PATH/coverage.cobertura.xml"
        if ! dotnet-coverage collect \
            --output "$cov_output" \
            --output-format cobertura \
            "dotnet test --solution $WORKTREE_PATH/${HARNESS_SOLUTION_FILE} --no-build" \
            >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1; then
            warn "dotnet-coverage collect fallo"
            return 1
        fi

        if [ ! -f "$cov_output" ]; then
            warn "No se genero archivo de cobertura"
            return 1
        fi

        log "Cobertura recolectada: $cov_output"
        return 0
    }

    # Extraer cobertura por archivo del XML cobertura.
    # Usa python3 para parsear XML de forma confiable.
    # Recibe: archivo cobertura XML, lista de archivos de logica (newline-separated)
    # Imprime: archivo|line_rate por cada archivo encontrado
    extract_file_coverage() {
        local cov_xml="$1"
        local logic_files="$2"
        python3 -c "
import xml.etree.ElementTree as ET
import sys, os

tree = ET.parse('$cov_xml')
root = tree.getroot()

# Archivos de logica a buscar (basenames)
logic_basenames = {}
for line in '''$logic_files'''.strip().split('\n'):
    if line.strip():
        bn = os.path.basename(line.strip())
        logic_basenames[bn] = line.strip()

# Buscar en el XML
for pkg in root.findall('.//package'):
    for cls in pkg.findall('.//class'):
        filename = cls.get('filename', '')
        bn = os.path.basename(filename)
        if bn in logic_basenames:
            line_rate = cls.get('line-rate', '0')
            pct = round(float(line_rate) * 100, 1)
            print(f'{logic_basenames[bn]}|{pct}')
            del logic_basenames[bn]

# Archivos de logica no encontrados en el reporte
for bn, fullpath in logic_basenames.items():
    print(f'{fullpath}|N/A')
" 2>>"${LOG_FILE_ABS:-$LOG_FILE}" || true
    }

    # --- 4d: Medir cobertura ---
    CG_MEASUREMENT_OK=false
    CG_TIMEOUT_MEASURE=600  # 10 minutos para medicion

    (
        measure_coverage
    ) &
    CG_MEASURE_PID=$!
    (sleep $CG_TIMEOUT_MEASURE && kill -9 $CG_MEASURE_PID 2>/dev/null && \
        echo "[$(date +%H:%M:%S)] TIMEOUT: coverage measurement supero ${CG_TIMEOUT_MEASURE}s" >> "$EVENTS_LOG_ABS") </dev/null >/dev/null 2>&1 &
    CG_MEASURE_WATCHDOG=$!

    CG_MEASURE_EXIT=0
    wait $CG_MEASURE_PID || CG_MEASURE_EXIT=$?
    kill $CG_MEASURE_WATCHDOG 2>/dev/null || true
    wait $CG_MEASURE_WATCHDOG 2>/dev/null || true

    if [ "$CG_MEASURE_EXIT" -eq 0 ] && [ -f "$WORKTREE_PATH/coverage.cobertura.xml" ]; then
        CG_MEASUREMENT_OK=true
    fi

    if [ "$CG_MEASUREMENT_OK" = false ]; then
        warn "La instrumentacion/medicion de cobertura fallo — continuando sin coverage gate"
        echo "[$(date +%H:%M:%S)] SKIP coverage-gate: instrumentacion fallo" >> "$EVENTS_LOG_ABS"
        AGENT_CG_RES="skipped"
        AGENT_CG_DUR=$(( $(date +%s) - CG_START ))
        update_status "4-coverage-gate" "skipped"
    else

    # --- 4e: Extraer y evaluar cobertura ---
    COVERAGE_DATA=$(extract_file_coverage "$WORKTREE_PATH/coverage.cobertura.xml" "$LOGIC_FILES")
    THRESHOLD=95

    COV_TABLE="| Archivo | Cobertura | Umbral | Estado |
|---|---|---|---|"

    GAPS=""
    GAPS_COUNT=0

    while IFS='|' read -r filepath pct; do
        [ -z "$filepath" ] && continue
        local_basename=$(basename "$filepath")
        if [ "$pct" = "N/A" ]; then
            COV_TABLE="$COV_TABLE
| $local_basename | N/A | ${THRESHOLD}% | sin datos |"
        else
            pct_int=${pct%.*}
            if [ "$pct_int" -ge "$THRESHOLD" ]; then
                COV_TABLE="$COV_TABLE
| $local_basename | ${pct}% | ${THRESHOLD}% | ok |"
            else
                COV_TABLE="$COV_TABLE
| $local_basename | ${pct}% | ${THRESHOLD}% | gap |"
                GAPS="${GAPS:+$GAPS
}$filepath|$pct"
                GAPS_COUNT=$((GAPS_COUNT + 1))
            fi
        fi
    done <<< "$COVERAGE_DATA"

    # Agregar excluidos y no evaluados a la tabla
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        COV_TABLE="$COV_TABLE
| $(basename "$f") | - | excluido | - |"
    done <<< "$EXCLUDED_FILES"
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        COV_TABLE="$COV_TABLE
| $(basename "$f") | - | no evaluado | - |"
    done <<< "$NOT_EVALUATED_FILES"

    log "Tabla de cobertura:"
    echo "$COV_TABLE" | while read -r line; do log "  $line"; done

    # --- 4f: Remediacion si hay gaps ---
    COV_REMEDIATION_SUMMARY=""
    if [ "$GAPS_COUNT" -gt 0 ]; then
        log "Detectados $GAPS_COUNT archivo(s) con cobertura insuficiente"
        echo "[$(date +%H:%M:%S)] GAPS: $GAPS_COUNT archivos bajo ${THRESHOLD}%" >> "$EVENTS_LOG_ABS"

        # Generar coverage-patch-spec.md
        PATCH_SPEC="$WORKTREE_PATH/.claude/pipeline/coverage-patch-spec.md"
        mkdir -p "$(dirname "$PATCH_SPEC")"

        {
            echo "## Coverage Patch Spec"
            echo ""
            echo "Archivos con cobertura insuficiente detectados en Stage 4."
            echo "El test-writer debe agregar tests para cubrir los metodos/lineas listados."
            echo ""
            while IFS='|' read -r gpath gpct; do
                [ -z "$gpath" ] && continue
                echo "### $gpath (${gpct}% - requiere ${THRESHOLD}%)"
                echo ""
                # Extraer lineas no cubiertas del XML
                python3 -c "
import xml.etree.ElementTree as ET
import os

tree = ET.parse('$WORKTREE_PATH/coverage.cobertura.xml')
root = tree.getroot()
target_bn = os.path.basename('$gpath')

for pkg in root.findall('.//package'):
    for cls in pkg.findall('.//class'):
        filename = cls.get('filename', '')
        if os.path.basename(filename) == target_bn:
            uncovered = []
            for line in cls.findall('.//line'):
                if line.get('hits', '0') == '0':
                    uncovered.append(int(line.get('number', 0)))
            if uncovered:
                # Agrupar lineas consecutivas en rangos
                ranges = []
                start = uncovered[0]
                end = uncovered[0]
                for ln in uncovered[1:]:
                    if ln == end + 1:
                        end = ln
                    else:
                        ranges.append((start, end))
                        start = ln
                        end = ln
                ranges.append((start, end))
                print('Lineas no cubiertas:')
                for s, e in ranges:
                    if s == e:
                        print(f'- L{s}')
                    else:
                        print(f'- L{s}-L{e}')
            else:
                print('No se detectaron lineas sin cubrir en el XML (posible error de instrumentacion)')
            break
" 2>>"${LOG_FILE_ABS:-$LOG_FILE}" || echo "_(no se pudieron extraer lineas no cubiertas)_"
                echo ""
            done <<< "$GAPS"
        } > "$PATCH_SPEC"

        log "Patch spec generado: $PATCH_SPEC"
        COV_PATCH_APPLIED=true

        # Relanzar test-writer con prompt de patch
        PATCH_SPEC_CONTENT=$(cat "$PATCH_SPEC")
        PATCH_TW_PROMPT="Estas en el directorio raiz del proyecto ${HARNESS_PROJECT_NAME}.

El pipeline detecto brechas de cobertura en la implementacion existente. Tu tarea es agregar tests adicionales para cubrir los metodos y lineas que no estan siendo ejecutados por los tests existentes.

$PATCH_SPEC_CONTENT

IMPORTANTE:
- Lee los archivos de produccion listados para entender que hacen los metodos/branches no cubiertos
- Escribe tests que ejerciten esos paths especificos
- Dado que la implementacion ya existe, los tests nuevos probablemente PASARAN directamente
- Sigue las mismas convenciones de testing del proyecto (Given/When/Then, AwesomeAssertions)
- Haz commit con mensaje: test(hu-${ISSUE_NUM:-?}): tests de cobertura para brechas detectadas"

        CG_REMEDIATION_TIMEOUT=1800  # 30 minutos para remediacion

        log "Relanzando test-writer para remediacion..."
        LOG_CG_TW="$LOG_DIR_ABS/stage-4-test-writer-patch-${TIMESTAMP}.log"
        echo "[$(date +%H:%M:%S)] REMEDIATION: relanzando test-writer" >> "$EVENTS_LOG_ABS"

        (cd "$WORKTREE_PATH" && claude -p "$PATCH_TW_PROMPT" \
            --agent test-writer \
            --permission-mode bypassPermissions \
            --append-system-prompt "You are running in non-interactive print mode. No human is present. Use Write and Edit tools directly. Never ask for permissions." \
            --output-format text \
            >"$LOG_CG_TW" 2>&1) &
        CG_TW_PID=$!
        (sleep $CG_REMEDIATION_TIMEOUT && kill -9 $CG_TW_PID 2>/dev/null && \
            echo "[$(date +%H:%M:%S)] TIMEOUT: coverage test-writer supero ${CG_REMEDIATION_TIMEOUT}s" >> "$EVENTS_LOG_ABS") </dev/null >/dev/null 2>&1 &
        CG_TW_WATCHDOG=$!

        CG_TW_EXIT=0
        wait $CG_TW_PID || CG_TW_EXIT=$?
        kill $CG_TW_WATCHDOG 2>/dev/null || true
        wait $CG_TW_WATCHDOG 2>/dev/null || true

        if [ "$CG_TW_EXIT" -ne 0 ]; then
            warn "Test-writer de remediacion fallo (exit $CG_TW_EXIT) — continuando con gaps pendientes"
            echo "[$(date +%H:%M:%S)] REMEDIATION_FAILED: test-writer exit $CG_TW_EXIT" >> "$EVENTS_LOG_ABS"
            COV_REMEDIATION_SUMMARY="El test-writer de remediacion fallo (exit $CG_TW_EXIT). Los gaps quedan pendientes."
        else
            # Auto-commit si necesario
            auto_commit_if_needed "cobertura" "test(hu-${ISSUE_NUM:-?}): tests de cobertura para brechas detectadas"

            # Verificar compilacion y tests
            log "Gate: verificando compilacion post-remediacion..."
            cg_build_rc=0
            dotnet build "$WORKTREE_PATH" >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1 || cg_build_rc=$?

            if [ "$cg_build_rc" -ne 0 ]; then
                warn "Build fallo post-remediacion — relanzando implementer..."
                echo "[$(date +%H:%M:%S)] REMEDIATION: build fallo, relanzando implementer" >> "$EVENTS_LOG_ABS"

                PATCH_IM_PROMPT="Estas en el directorio raiz del proyecto ${HARNESS_PROJECT_NAME}.

El coverage gate detecto brechas de cobertura y el test-writer agrego tests adicionales, pero no compilan.
Tu tarea: haz que SOLO los tests nuevos de cobertura compilen y pasen. No modifiques la logica de negocio existente.

Pista: revisa los ultimos archivos de test creados/modificados y corrige errores de compilacion."

                LOG_CG_IM="$LOG_DIR_ABS/stage-4-implementer-patch-${TIMESTAMP}.log"
                echo "[$(date +%H:%M:%S)] REMEDIATION: relanzando implementer" >> "$EVENTS_LOG_ABS"

                (cd "$WORKTREE_PATH" && claude -p "$PATCH_IM_PROMPT" \
                    --agent implementer \
                    --permission-mode bypassPermissions \
                    --append-system-prompt "You are running in non-interactive print mode. No human is present. Use Write and Edit tools directly. Never ask for permissions." \
                    --output-format text \
                    >"$LOG_CG_IM" 2>&1) &
                CG_IM_PID=$!
                (sleep $CG_REMEDIATION_TIMEOUT && kill -9 $CG_IM_PID 2>/dev/null && \
                    echo "[$(date +%H:%M:%S)] TIMEOUT: coverage implementer supero ${CG_REMEDIATION_TIMEOUT}s" >> "$EVENTS_LOG_ABS") </dev/null >/dev/null 2>&1 &
                CG_IM_WATCHDOG=$!

                CG_IM_EXIT=0
                wait $CG_IM_PID || CG_IM_EXIT=$?
                kill $CG_IM_WATCHDOG 2>/dev/null || true
                wait $CG_IM_WATCHDOG 2>/dev/null || true

                if [ "$CG_IM_EXIT" -ne 0 ]; then
                    warn "Implementer de remediacion fallo (exit $CG_IM_EXIT)"
                    echo "[$(date +%H:%M:%S)] REMEDIATION_FAILED: implementer exit $CG_IM_EXIT" >> "$EVENTS_LOG_ABS"
                fi

                auto_commit_if_needed "cobertura" "feat(hu-${ISSUE_NUM:-?}): fix compilacion tests de cobertura"
            fi

            # Gate: verificar tests verdes post-remediacion
            log "Gate: verificando tests post-remediacion..."
            cg_test_rc=0
            CG_TEST_OUTPUT=$(run_tests_projects 2>&1) || cg_test_rc=$?
            echo "$CG_TEST_OUTPUT" | tee -a "${LOG_FILE_ABS:-$LOG_FILE}" >/dev/null

            if [ "$cg_test_rc" -ne 0 ]; then
                warn "Tests fallan post-remediacion (exit $cg_test_rc) — continuando con gaps pendientes"
                echo "[$(date +%H:%M:%S)] REMEDIATION: tests fallan post-remediacion" >> "$EVENTS_LOG_ABS"
                COV_REMEDIATION_SUMMARY="Se agregaron tests de remediacion pero hay tests fallando (exit $cg_test_rc). Requiere atencion humana."
            else
                # Re-medir cobertura una vez (con timeout de medicion)
                log "Re-midiendo cobertura post-remediacion..."
                CG_REMEASURE_OK=false
                (measure_coverage) &
                CG_REMEASURE_PID=$!
                (sleep $CG_TIMEOUT_MEASURE && kill -9 $CG_REMEASURE_PID 2>/dev/null && \
                    echo "[$(date +%H:%M:%S)] TIMEOUT: re-medicion cobertura supero ${CG_TIMEOUT_MEASURE}s" >> "$EVENTS_LOG_ABS") </dev/null >/dev/null 2>&1 &
                CG_REMEASURE_WATCHDOG=$!
                CG_REMEASURE_EXIT=0
                wait $CG_REMEASURE_PID || CG_REMEASURE_EXIT=$?
                kill $CG_REMEASURE_WATCHDOG 2>/dev/null || true
                wait $CG_REMEASURE_WATCHDOG 2>/dev/null || true
                if [ "$CG_REMEASURE_EXIT" -eq 0 ] && [ -f "$WORKTREE_PATH/coverage.cobertura.xml" ]; then
                    CG_REMEASURE_OK=true
                fi
                if [ "$CG_REMEASURE_OK" = true ]; then
                    COVERAGE_DATA_POST=$(extract_file_coverage "$WORKTREE_PATH/coverage.cobertura.xml" "$LOGIC_FILES")

                    # Reconstruir tabla
                    COV_TABLE="| Archivo | Cobertura | Umbral | Estado |
|---|---|---|---|"
                    GAPS_COUNT=0
                    REMAINING_GAPS=""

                    while IFS='|' read -r filepath pct; do
                        [ -z "$filepath" ] && continue
                        local_basename=$(basename "$filepath")
                        if [ "$pct" = "N/A" ]; then
                            COV_TABLE="$COV_TABLE
| $local_basename | N/A | ${THRESHOLD}% | sin datos |"
                        else
                            pct_int=${pct%.*}
                            if [ "$pct_int" -ge "$THRESHOLD" ]; then
                                COV_TABLE="$COV_TABLE
| $local_basename | ${pct}% | ${THRESHOLD}% | ok |"
                            else
                                COV_TABLE="$COV_TABLE
| $local_basename | ${pct}% | ${THRESHOLD}% | gap |"
                                GAPS_COUNT=$((GAPS_COUNT + 1))
                                REMAINING_GAPS="${REMAINING_GAPS:+$REMAINING_GAPS, }$local_basename (${pct}%)"
                            fi
                        fi
                    done <<< "$COVERAGE_DATA_POST"

                    # Agregar excluidos y no evaluados
                    while IFS= read -r f; do
                        [ -z "$f" ] && continue
                        COV_TABLE="$COV_TABLE
| $(basename "$f") | - | excluido | - |"
                    done <<< "$EXCLUDED_FILES"
                    while IFS= read -r f; do
                        [ -z "$f" ] && continue
                        COV_TABLE="$COV_TABLE
| $(basename "$f") | - | no evaluado | - |"
                    done <<< "$NOT_EVALUATED_FILES"

                    if [ "$GAPS_COUNT" -gt 0 ]; then
                        COV_REMEDIATION_SUMMARY="Se agregaron tests de remediacion. Gaps restantes: $REMAINING_GAPS"
                    else
                        COV_REMEDIATION_SUMMARY="Se agregaron tests de remediacion y todos los gaps fueron cerrados."
                    fi
                else
                    warn "Re-medicion de cobertura fallo — manteniendo tabla anterior"
                    COV_REMEDIATION_SUMMARY="Se agregaron tests de remediacion pero la re-medicion fallo. Gaps originales pueden persistir."
                fi
            fi
        fi

        COV_GAPS_REMAINING=$GAPS_COUNT
    else
        log "Todos los archivos de logica superan el umbral de ${THRESHOLD}%"
        COV_GAPS_REMAINING=0
    fi

    AGENT_CG_DUR=$(( $(date +%s) - CG_START ))
    if [ "$COV_GAPS_REMAINING" -gt 0 ]; then
        AGENT_CG_RES="gaps"
        update_status "4-coverage-gate" "gaps"
        warn "Stage 4 completado con $COV_GAPS_REMAINING gap(s) pendiente(s)"
    else
        AGENT_CG_RES="passed"
        update_status "4-coverage-gate" "passed"
        success "Stage 4 completado — cobertura verificada"
    fi
    echo "[$(date +%H:%M:%S)] DONE coverage-gate: ${AGENT_CG_DUR}s, result=$AGENT_CG_RES, gaps=$COV_GAPS_REMAINING" >> "$EVENTS_LOG_ABS"

    fi  # cierre de CG_MEASUREMENT_OK
    fi  # cierre de LOGIC_FILES no vacio
    fi  # cierre de PR_SRC_FILES no vacio
    fi  # cierre de dotnet-coverage disponible
else
    if [ "$IS_REFACTOR" = true ]; then
        log "Saltando Stage 4 (refactoring puro)"
    else
        log "Saltando Stage 4 (--from-stage $FROM_STAGE)"
    fi
    AGENT_CG_RES="skipped"
fi

# ─── Crear PR ─────────────────────────────────────────────────────────────────
header "Creando PR"

log "Haciendo push de la rama..."
git -C "$WORKTREE_PATH" push -u origin "$BRANCH_NAME" >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1 \
    || abort "No se pudo hacer push de la rama $BRANCH_NAME"

CLOSES_LINE=""
if [ -n "$ISSUE_NUM" ]; then
    CLOSES_LINE="Closes #$ISSUE_NUM"
fi

log "Creando PR..."

# Recolectar resumenes de agentes
TW_SUMMARY=$(collect_summary "1" "test-writer")
IM_SUMMARY=$(collect_summary "2" "implementer")
ST_SUMMARY=$(collect_summary "2b" "smoke-test-writer")
RV_SUMMARY=$(collect_summary "3" "reviewer")

# Formatear duraciones
_fmt_dur() { local s="${1:-0}"; echo "$((s/60))m $((s%60))s"; }
TW_DUR_FMT=$(_fmt_dur "${AGENT_TW_DUR:-0}")
IM_DUR_FMT=$(_fmt_dur "${AGENT_IM_DUR:-0}")
ST_DUR_FMT=$(_fmt_dur "${AGENT_ST_DUR:-0}")
RV_DUR_FMT=$(_fmt_dur "${AGENT_RV_DUR:-0}")
CG_DUR_FMT=$(_fmt_dur "${AGENT_CG_DUR:-0}")

if [ "$IS_REFACTOR" = true ]; then
    PR_BODY_SUMMARY="Pipeline TDD completado (refactoring puro):
- Análisis: no se requieren tests nuevos
- Justificación: $REFACTOR_JUSTIFICATION
- Baseline: $BASELINE_TEST_COUNT tests pasando
- Refactoring ejecutado manteniendo todos los tests verdes"
    IMPLEMENTER_SECTION=""
    SMOKE_TEST_SECTION=""
else
    if [ "$AGENT_ST_RES" = "passed" ]; then
        PR_BODY_SUMMARY="Pipeline TDD completado:
- Fase roja: tests escritos con stubs
- Fase verde: implementación completa
- Smoke tests: escritos para endpoints detectados
- Fase refactor: revisión de calidad"
    else
        PR_BODY_SUMMARY="Pipeline TDD completado:
- Fase roja: tests escritos con stubs
- Fase verde: implementación completa
- Fase refactor: revisión de calidad"
    fi
    IMPLEMENTER_SECTION="<details>
<summary>Implementer (fase verde) — ${IM_DUR_FMT}</summary>

${IM_SUMMARY}

</details>
"
    if [ "$AGENT_ST_RES" = "passed" ]; then
        SMOKE_TEST_SECTION="<details>
<summary>Smoke Test Writer — ${ST_DUR_FMT}</summary>

${ST_SUMMARY}

</details>
"
    else
        SMOKE_TEST_SECTION=""
    fi
fi

# Construir seccion de cobertura para el PR
COVERAGE_SECTION=""
if [ -n "$COV_TABLE" ]; then
    COVERAGE_SECTION="## Cobertura

$COV_TABLE
"
    if [ "$COV_PATCH_APPLIED" = true ] && [ -n "$COV_REMEDIATION_SUMMARY" ]; then
        COVERAGE_SECTION="${COVERAGE_SECTION}
### Remediacion

$COV_REMEDIATION_SUMMARY
"
    fi
    if [ "$COV_GAPS_REMAINING" -gt 0 ]; then
        COVERAGE_SECTION="${COVERAGE_SECTION}
> **Gaps pendientes**: $COV_GAPS_REMAINING archivo(s) no alcanzan el umbral de cobertura. Requiere revision humana.
"
    fi
fi

PR_URL=$(gh pr create \
    --title "$ISSUE_TITLE" \
    --body "$(cat <<EOF
## Resumen

$PR_BODY_SUMMARY

## Decisiones del pipeline

<details>
<summary>Test Writer (fase roja) — ${TW_DUR_FMT}</summary>

${TW_SUMMARY}

</details>

${IMPLEMENTER_SECTION}${SMOKE_TEST_SECTION}<details>
<summary>Reviewer (fase refactor) — ${RV_DUR_FMT}</summary>

${RV_SUMMARY}

</details>

${COVERAGE_SECTION}## Commits

$COMMITS_LIST

$CLOSES_LINE
EOF
)" \
    --base main \
    --head "$BRANCH_NAME" \
    --repo "$(git -C "$WORKTREE_PATH" remote get-url origin | sed 's/.*github.com[:/]\(.*\)\.git/\1/')" \
    2>>"$LOG_FILE") \
    || abort "No se pudo crear el PR"

# Si hay bloqueo, agregar label y nota al PR
if [ "${HAS_BLOCKAGE:-false}" = true ]; then
    PR_NUM=$(echo "$PR_URL" | grep -o '[0-9]*$')
    REPO_SLUG=$(git -C "$WORKTREE_PATH" remote get-url origin | sed 's/.*github.com[:/]\(.*\)\.git/\1/')
    gh pr edit "$PR_NUM" --add-label "bloqueado" --repo "$REPO_SLUG" >>"$LOG_FILE" 2>&1 \
        || warn "No se pudo agregar label 'bloqueado' al PR"
    BLOCKAGE_REPORT="$WORKTREE_PATH/.claude/pipeline/blockage-report.md"
    if [ -f "$BLOCKAGE_REPORT" ]; then
        BLOCKAGE_CONTENT=$(cat "$BLOCKAGE_REPORT")
        gh pr comment "$PR_NUM" \
            --body "## Tests bloqueados

Este PR tiene tests en rojo que ni el implementer ni el reviewer pudieron resolver. Se requiere atencion humana.

<details>
<summary>Reporte de bloqueo</summary>

$BLOCKAGE_CONTENT

</details>" \
            --repo "$REPO_SLUG" >>"$LOG_FILE" 2>&1 \
            || warn "No se pudo comentar reporte de bloqueo en el PR"
    fi
fi

PIPELINE_PR="$PR_URL"
update_status "done" "completed"
success "PR creado: $PR_URL"

if [ -n "$ISSUE_NUM" ]; then
    gh issue comment "$ISSUE_NUM" \
        --body "Pipeline TDD completado. Decisiones de los agentes en el PR: $PR_URL" \
        --repo "$(git -C "$WORKTREE_PATH" remote get-url origin | sed 's/.*github.com[:/]\(.*\)\.git/\1/')" \
        >>"$LOG_FILE" 2>&1 || warn "No se pudo comentar en el issue #$ISSUE_NUM"
fi

# Append al historial
echo "{\"issue\":\"${ISSUE_NUM:-}\",\"title\":\"$(echo "${ISSUE_TITLE:-}" | sed 's/"/\\"/g')\",\"pipeline\":\"tdd\",\"started\":\"$TIMESTAMP\",\"finished\":\"$(date +%Y-%m-%dT%H:%M:%S)\",\"state\":\"completed\",\"agents\":{\"test-writer\":{\"duration\":${AGENT_TW_DUR:-null}},\"implementer\":{\"duration\":${AGENT_IM_DUR:-null}},\"reviewer\":{\"duration\":${AGENT_RV_DUR:-null}},\"coverage-gate\":{\"duration\":${AGENT_CG_DUR:-null},\"result\":\"$AGENT_CG_RES\",\"gaps\":$COV_GAPS_REMAINING,\"patch_applied\":$COV_PATCH_APPLIED}},\"tests\":${PIPELINE_TESTS:-null},\"pr\":\"$PR_URL\"}" \
    >> "$PIPELINE_DIR_ABS/pipeline-history.jsonl"

# Eliminar archivo de estado individual (ya esta en el historial)
rm -f "$PIPELINE_DIR_ABS/$STATUS_FILENAME"

# ─── Cleanup ──────────────────────────────────────────────────────────────────
header "Cleanup"

# [Cambio 1/2] Restaurar archivos sucios antes de remover, y usar --force
log "Eliminando worktree..."
cd "$REPO_ROOT"
git -C "$WORKTREE_PATH" checkout -- .claude/ 2>/dev/null || true
git worktree remove --force "$WORKTREE_PATH" >>"$LOG_FILE" 2>&1 \
    || warn "No se pudo eliminar el worktree automáticamente. Elimínalo manualmente: git worktree remove --force $WORKTREE_PATH"

WORKTREE_PATH=""  # Marcar como eliminado para el trap de errores

success "Worktree eliminado"

# ─── Resumen final ────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}═══ Pipeline completado ═══${NC}"
echo ""
TOTAL_COMMITS=$(echo "$COMMITS_LIST" | wc -l | tr -d ' ')
echo -e "  Commits: $TOTAL_COMMITS"
echo -e "  Rama:    $BRANCH_NAME"
echo -e "  PR:      $PR_URL"
echo -e "  Log:     $LOG_FILE"
echo ""
