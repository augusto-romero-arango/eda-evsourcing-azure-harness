#!/usr/bin/env bash
# mefisto-tooling-pipeline.sh -- Pipeline INTERNO de tooling para el repo de Mefisto
#
# Uso:
#   ./.claude/scripts/mefisto-tooling-pipeline.sh 42
#   ./.claude/scripts/mefisto-tooling-pipeline.sh --issue 42
#   ./.claude/scripts/mefisto-tooling-pipeline.sh 42 --from-stage 2
#   ./.claude/scripts/mefisto-tooling-pipeline.sh 42 --models 'reviewer=opus,writer=sonnet'  # Modelo por stage (experimentos)
#   ./.claude/scripts/mefisto-tooling-pipeline.sh 42 --variant experimento-a  # Corrida paralela del mismo issue (sin PR, rama local)
#
# Ciclo: Issue (en repo Mefisto) -> Worktree -> Writer -> Reviewer -> Sync main -> PR -> Cleanup
#
# ALCANCE: solo modifica archivos del propio plugin (commands/, agents/, scripts/,
# hooks/, docs/, .claude-plugin/, .claude/{commands,agents,scripts}/, gobierno).
# No corre dotnet ni terraform. No usa .claude/harness.config.json.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_mefisto-common.sh"
assert_in_mefisto || exit 1

# Version y SHA del propio plugin que corre esta corrida (issue #662),
# calculados UNA sola vez aqui -- ANTES de crear el worktree del issue, sobre
# el repo principal (get_harness_sha opera sobre el cwd). El trap de aborto
# solo interpola las variables ya resueltas, nunca recalcula.
HARNESS_VERSION="$(get_harness_version)"
HARNESS_VERSION_JSON="null"
[ -n "$HARNESS_VERSION" ] && HARNESS_VERSION_JSON="\"$HARNESS_VERSION\""
HARNESS_SHA="$(get_harness_sha)"
HARNESS_SHA_JSON="null"
[ -n "$HARNESS_SHA" ] && HARNESS_SHA_JSON="\"$HARNESS_SHA\""

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

# Lineas de log que abort() reemite al fallar (issue #379): la causa real de un
# fallo externo (gh, git...) vive en el log del pipeline, no en el mensaje de
# abort, y sin esto solo se llega a ella abriendo un segundo archivo.
TAIL_LOG_LINES=20

# --- Tracking de estado ---
AGENT_WR_DUR="" AGENT_WR_RES="pending"
AGENT_RV_DUR="" AGENT_RV_RES="pending"
# Metricas por stage (issue #426): JSON compacto de compute_stage_metrics,
# cosechado en los mismos puntos donde ya se cosecha AGENT_*_DUR.
AGENT_WR_METRICS_JSON=""
AGENT_RV_METRICS_JSON=""
PIPELINE_PR=""
PIPELINE_ERROR=""
LAST_AGENT_DURATION=0
LAST_AGENT_METRICS_JSON=""
CURRENT_STAGE="setup"

_strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
_log_file()   { echo -e "$1" | _strip_ansi >> "${LOG_FILE_ABS:-$LOG_FILE}"; }

# _tail_log_for_abort <log_file> <n>
#
# Emite por stdout las ultimas <n> lineas de <log_file> sin codigos ANSI, bajo
# un encabezado explicito. Usado por abort() para que la causa real de un
# fallo externo (gh, git, dotnet...) viaje al log del batch sin que el humano
# tenga que abrir un segundo archivo (issue #379). Tolera log ausente, vacio o
# con menos de <n> lineas -- en esos casos no imprime nada y no falla. Nunca
# reentra a abort/warn si el propio tail falla.
#
# Emite por stdout a proposito: el stream lo elige quien llama, porque abort()
# no usa el mismo en los tres pipelines (el interno manda todo a stderr, los
# publicados a stdout). Asi el cuerpo de esta funcion es identico en las tres
# copias sin desalinear el stream de ninguna.
_tail_log_for_abort() {
    local log_file="$1" n="$2"
    [ -s "$log_file" ] || return 0
    local tail_lines
    tail_lines="$(tail -n "$n" "$log_file" 2>/dev/null | _strip_ansi)" || return 0
    [ -n "$tail_lines" ] || return 0
    echo -e "${YELLOW}Ultimas $n lineas del log:${NC}"
    echo "$tail_lines"
}

log()     { local m="${BLUE}[$(date +%H:%M:%S)]${NC} $1"; echo -e "$m"; _log_file "$m"; }
success() { local m="${GREEN}${BOLD}v${NC} $1"; echo -e "$m"; _log_file "$m"; }
warn()    { local m="${YELLOW}!${NC} $1"; echo -e "$m"; _log_file "$m"; }
header()  { local m="\n${CYAN}${BOLD}-- $1 --${NC}"; echo -e "$m"; _log_file "$m"; }
abort() {
    # El tail se captura ANTES de que este mismo abort escriba su linea de ERROR
    # al log: si se leyera despues, las dos ultimas lineas del tail serian un eco
    # del mensaje que se acaba de imprimir -- ruido que ademas se come dos lineas
    # del contexto real que se quiere mostrar (issue #379).
    local log_tail
    log_tail="$(_tail_log_for_abort "${LOG_FILE_ABS:-$LOG_FILE}" "$TAIL_LOG_LINES")" || log_tail=""
    PIPELINE_ERROR="$(echo "$1" | sed 's/"/\\"/g' | tr '\n' ' ')"
    echo -e "\n${RED}${BOLD}x ERROR: $1${NC}" | tee -a "${LOG_FILE_ABS:-$LOG_FILE}" >/dev/null
    echo -e "${RED}${BOLD}x ERROR: $1${NC}" >&2
    echo -e "${YELLOW}Revisa el log: ${LOG_FILE_ABS:-$LOG_FILE}${NC}" >&2
    if [ -n "$log_tail" ]; then echo "$log_tail" >&2; fi
    if [ -n "${WORKTREE_PATH:-}" ] && [ -d "$WORKTREE_PATH" ]; then
        echo -e "${YELLOW}El worktree queda en: $WORKTREE_PATH${NC}" >&2
    fi
    if [ -n "${PIPELINE_DIR_ABS:-}" ]; then
        update_status "$CURRENT_STAGE" "failed"
        # CA-3 (issue #426): agents.<agente>.metrics de los stages ya
        # cerrados en esta corrida -- los fallos son los casos mas caros de
        # entender y hasta este issue quedaban sin ninguna cifra por agente.
        local abort_agents_json
        abort_agents_json=$(build_agents_history_json "${AGENT_WR_DUR:-}" "${AGENT_WR_METRICS_JSON:-}" "${AGENT_RV_DUR:-}" "${AGENT_RV_METRICS_JSON:-}" 2>/dev/null) \
            || abort_agents_json="{\"writer\":{\"duration\":${AGENT_WR_DUR:-null}},\"reviewer\":{\"duration\":${AGENT_RV_DUR:-null}}}"
        echo "{\"issue\":\"${ISSUE_NUM:-}\",\"title\":\"$(echo "${ISSUE_TITLE:-}" | sed 's/"/\\"/g')\",\"pipeline\":\"mefisto-tooling\",\"variant\":${VARIANT_LABEL_JSON:-null},\"harness_version\":${HARNESS_VERSION_JSON:-null},\"harness_sha\":${HARNESS_SHA_JSON:-null},\"started\":\"${TIMESTAMP:-}\",\"finished\":\"$(date +%Y-%m-%dT%H:%M:%S)\",\"state\":\"failed\",\"stage\":\"$CURRENT_STAGE\",\"agents\":$abort_agents_json,\"error\":\"$PIPELINE_ERROR\"}" \
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
  "variant": ${VARIANT_LABEL_JSON:-null},
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
MODELS_SPEC=""  # --models 'agente=modelo[,agente=modelo...]' (issue #709)
VARIANT_LABEL=""  # --variant <label>: corrida paralela del mismo issue, sin PR (issue #711)

if [ $# -eq 0 ]; then
    echo "Uso: $0 [--issue NUM | NUM] [--from-stage N] [--models 'agente=modelo[,agente=modelo...]'] [--variant <label>]"
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
        --models)
            [ $# -lt 2 ] && abort "Falta el valor de --models"
            MODELS_SPEC="$2"
            shift 2
            ;;
        --variant)
            [ $# -lt 2 ] && abort "Falta el valor de --variant"
            VARIANT_LABEL="$2"
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

# --- Resolver --variant (issue #711) --------------------------------------
# Se valida ANTES de crear el worktree (CA-1) y antes de derivar cualquier
# nombre de archivo de la corrida (CA-2), mismo criterio que --models: un
# label malformado debe abortar temprano, y el sufijo tiene que estar puesto
# ya en el primer archivo que se escribe. Mas abajo, en modo variante se
# suprimen push, creacion de PR y comentario al issue (CA-3).
VARIANT_LABEL_JSON="null"
ISSUE_LOG_TAG="$ISSUE_NUM"
if [ -n "$VARIANT_LABEL" ]; then
    validate_variant_label "$VARIANT_LABEL" \
        || abort "--variant mal formado: ${MEFISTO_VARIANT_LABEL_ERROR:-label invalido}"
    VARIANT_LABEL_JSON="\"$VARIANT_LABEL\""
    ISSUE_LOG_TAG="${ISSUE_NUM}-${VARIANT_LABEL}"
    # El log del pipeline tambien lleva el sufijo, no solo los de stage: dos
    # variantes lanzadas en el MISMO segundo comparten $TIMESTAMP y, sin el
    # label, escribirian las dos al mismo archivo -- log entrelazado, y el
    # tail de abort() mostrando lineas de la otra corrida.
    LOG_FILE="$LOG_DIR/mefisto-tooling-pipeline-${TIMESTAMP}-${VARIANT_LABEL}.log"
fi

if [ "$STATUS_FILENAME" = "pipeline-status-mefisto-tooling.json" ]; then
    STATUS_FILENAME="pipeline-status-mefisto-tooling-${ISSUE_NUM}.json"
    [ -n "$VARIANT_LABEL" ] && STATUS_FILENAME="pipeline-status-mefisto-tooling-${ISSUE_NUM}-${VARIANT_LABEL}.json"
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
mkdir -p "$PIPELINE_DIR/metrics"
echo "Pipeline mefisto-tooling iniciado: $TIMESTAMP" > "$LOG_FILE"

PIPELINE_DIR_ABS="$(realpath "$PIPELINE_DIR")"
LOG_DIR_ABS="$(realpath "$LOG_DIR")"
LOG_FILE_ABS="$(realpath "$LOG_FILE")"
EVENTS_LOG_ABS="$PIPELINE_DIR_ABS/events.log"
touch "$EVENTS_LOG_ABS"

echo "=== SESSION MEFISTO-TOOLING $TIMESTAMP issue:$ISSUE_NUM from-stage:$FROM_STAGE ===" >> "$EVENTS_LOG_ABS"

# --- Resolver --models (issue #709) --------------------------------------
# Se valida ANTES de crear el worktree: un --models malformado debe abortar
# temprano, no a mitad de Stage 1 con un worktree ya en disco.
parse_stage_models "$MODELS_SPEC" \
    || abort "--models mal formado: ${MEFISTO_STAGE_MODELS_ERROR:-formato invalido}"
if [ -n "$MEFISTO_STAGE_MODELS" ]; then
    STAGE_MODELS_LOG="$(format_stage_models_for_log)"
    log "Modelos por stage (--models): $STAGE_MODELS_LOG"
    echo "[$(date +%H:%M:%S)] MODELS: $STAGE_MODELS_LOG" >> "$EVENTS_LOG_ABS"
fi

# --- Anunciar el modo variante (issue #711) -------------------------------
# El label ya se valido y ya derivo los nombres de archivo arriba, junto al
# parseo de argumentos; aqui solo se anuncia, que es lo primero que se puede
# hacer una vez existen el log del pipeline y events.log.
if [ -n "$VARIANT_LABEL" ]; then
    log "Modo variante: '$VARIANT_LABEL' -- sin push, sin PR, sin comentario al issue (CA-3); rama queda local"
    echo "[$(date +%H:%M:%S)] VARIANT: $VARIANT_LABEL" >> "$EVENTS_LOG_ABS"
fi

# --- Obtener issue ---
header "Preparando contexto"

log "Descargando issue #$ISSUE_NUM del repo de Mefisto..."
ISSUE_JSON=$(gh issue view "$ISSUE_NUM" --json number,title,body,state 2>>"${LOG_FILE_ABS:-$LOG_FILE}") \
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
# Modo variante (CA-2): worktree y rama llevan el sufijo -<label>, para que N
# corridas simultaneas del mismo issue coexistan sin colision de paths ni ramas.
[ -n "$VARIANT_LABEL" ] && BRANCH_NAME="${BRANCH_NAME}-${VARIANT_LABEL}"
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

    # .claude/settings.json (issue #523) ya viaja VERSIONADO con el worktree,
    # checked out desde origin/main: el pipeline no lo inyecta ni lo revierte.
    #
    # El pipeline del consumidor (scripts/tooling-pipeline.sh) si lo hace --
    # copia el settings.json del repo base sustituyendo la ruta relativa de
    # events.log por la absoluta de la corrida, y lo revierte con
    # `git checkout --` antes de cada commit para no ensuciar el PR. Ese par
    # inyeccion/reversion aqui seria activamente daniino:
    #
    #   1. La copia vendria de $REPO_ROOT (el arbol de trabajo del clon
    #      principal, que puede estar sucio o en otra rama), pisando con el
    #      un archivo que el worktree ya tiene correcto desde origin/main.
    #   2. `git checkout -- .claude/settings.json` revierte cualquier edicion
    #      NO comiteada del archivo. Ahora que esta versionado, un issue que
    #      anada un hook nuevo perderia el trabajo del writer en silencio --
    #      y el bloque ECONOMIA DE TURNOS le pide justamente no re-inspeccionar
    #      el arbol, asi que nadie se enteraria hasta ver el PR vacio.
    #   3. La sustitucion no cambia nada: el unico hook de Mefisto
    #      (mefisto-scope-hook.sh) no escribe a events.log.
    #
    # Si algun dia un hook interno necesita la ruta absoluta del events.log
    # centralizado, hay que resolverlo sin `git checkout --` sobre un archivo
    # que el writer puede estar editando legitimamente (p. ej. leyendo
    # $CLAUDE_PROJECT_DIR desde el propio hook).

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
    local log_base="$LOG_DIR_ABS/mefisto-tooling-stage-${stage}-${agent}-${TIMESTAMP}-issue-${ISSUE_LOG_TAG}"
    local log_stage="${log_base}.log"
    local stream_file="${log_base}.stream.jsonl"
    local stderr_file="${log_base}.stderr.log"
    local start_ts
    start_ts=$(date +%s)

    echo "[$(date +%H:%M:%S)] === MEFISTO-TOOLING STAGE $stage: $agent ===" >> "$EVENTS_LOG_ABS"
    case "$agent" in
        writer)   AGENT_WR_RES="running" ;;
        reviewer) AGENT_RV_RES="running" ;;
    esac
    # Modelo por etapa: escritura (writer y merge) en sonnet, revision en opus.
    # resolve_stage_model (issue #709) aplica el override de --models por clave
    # exacta de agente; sin entrada en el mapa (o sin --models), cae en este
    # default -- byte a byte el comportamiento previo al flag.
    local AGENT_MODEL AGENT_MODEL_DEFAULT
    case "$agent" in
        reviewer) AGENT_MODEL_DEFAULT="opus" ;;
        *)        AGENT_MODEL_DEFAULT="sonnet" ;;
    esac
    AGENT_MODEL="$(resolve_stage_model "$agent" "$AGENT_MODEL_DEFAULT")"
    # Constancia por stage del override que SI hizo match: el mapa que se
    # loguea al arrancar no dice cuales claves aplicaron, y una clave con typo
    # ('revieweer=opus') no sobreescribe nada -- sin esta linea el experimento
    # correria con los defaults y el reporte lo atribuiria al override.
    if [ "$AGENT_MODEL" != "$AGENT_MODEL_DEFAULT" ]; then
        echo "[$(date +%H:%M:%S)] MODELS: stage $stage/$agent -> $AGENT_MODEL (default: $AGENT_MODEL_DEFAULT)" >> "$EVENTS_LOG_ABS"
    fi
    update_status "$stage-$agent" "running"
    log "Invocando $agent..."

    local AGENT_TIMEOUT_SECONDS=1800
    local NONINTERACTIVE_SYSTEM="You are running in non-interactive print mode. There is no human to approve anything. You MUST use Write and Edit tools directly to create and modify files at any path including .claude/. Never output text asking for permissions or confirmations -- doing so causes pipeline failure."

    # --- Reintento ante fallo transitorio del servidor (issue #534) ---
    # Ambos parametros son overridables por entorno para que los tests puedan
    # ejercer el bucle sin esperar 120s reales.
    local MAX_ATTEMPTS="${MEFISTO_AGENT_MAX_ATTEMPTS:-3}"
    local RETRY_BACKOFF_SECONDS="${MEFISTO_AGENT_RETRY_BACKOFF_SECONDS:-120}"

    # CA-4: estado del worktree AL ENTRAR al stage, para poder restaurarlo
    # entre reintentos. No sirve $SNAPSHOT_COMMIT: ese es el commit de entrada
    # al PIPELINE, y en stage 2 resetear ahi borraria el commit del writer.
    #
    # Solo se restaura si el worktree entraba LIMPIO. El pipeline tolera que
    # el writer deje trabajo sin commitear (ver HAS_UNSTAGED tras stage 1), y
    # en ese caso un reset --hard destruiria trabajo legitimo: ante la duda no
    # se toca nada y se reintenta sobre el estado actual.
    local ENTRY_COMMIT="" ENTRY_CLEAN=false
    ENTRY_COMMIT=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || echo "")
    if [ -z "$(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null)" ]; then
        ENTRY_CLEAN=true
    fi

    local CLAUDE_EXIT=0 TIMED_OUT=false failure_type="" metrics_json="" elapsed=0
    local attempt=1
    while :; do
        local attempt_start_ts
        attempt_start_ts=$(date +%s)

        # La senal del watchdog lleva el numero de intento: si el watchdog de
        # un intento anterior sobrevivio a su kill, no puede marcar como
        # TIMEOUT al intento siguiente (el nombre ya no colisiona).
        local TIMEOUT_SIGNAL_FILE="$PIPELINE_DIR_ABS/watchdog-timeout-${stage}-${agent}-${TIMESTAMP}-${attempt}"

        CLAUDE_EXIT=$(run_agent_with_watchdog "$WORKTREE_PATH" "$AGENT_TIMEOUT_SECONDS" "$stream_file" "$stderr_file" "$EVENTS_LOG_ABS" "$agent" "$TIMEOUT_SIGNAL_FILE" \
            claude -p "$prompt" --model "$AGENT_MODEL" \
            --permission-mode bypassPermissions \
            --append-system-prompt "$NONINTERACTIVE_SYSTEM" \
            --output-format stream-json --verbose)
        elapsed=$(( $(date +%s) - attempt_start_ts ))

        # CA-1/CA-3: el stream crudo (una linea JSON por evento) queda en
        # $stream_file para analisis posterior; $log_stage se deriva de el (texto
        # del asistente + una linea por tool call) mas el contenido de
        # $stderr_file, con el mismo nombre de archivo de siempre -- la
        # clasificacion de fallos de mas abajo sigue leyendo $log_stage sin
        # cambios.
        derive_stage_log_from_stream "$stream_file" "$stderr_file" "$log_stage"

        # CA-1 (issue #426): metricas por stage derivadas de la misma traza cruda
        # que ya deriva el log legible de arriba. Se escriben SIEMPRE (stage
        # exitoso o fallido) -- un fallo de instrumentacion (jq ausente, stream
        # vacio, sin evento result) degrada a "null" y nunca aborta el pipeline.
        metrics_json=$(compute_stage_metrics "$stream_file")
        echo "$metrics_json" > "$PIPELINE_DIR_ABS/metrics/mefisto-tooling-${TIMESTAMP}-issue-${ISSUE_LOG_TAG}-stage-${stage}-${agent}.json" 2>/dev/null || true

        TIMED_OUT=false
        [ -f "$TIMEOUT_SIGNAL_FILE" ] && TIMED_OUT=true
        rm -f "$TIMEOUT_SIGNAL_FILE"

        failure_type=""
        if [ "$CLAUDE_EXIT" -ne 0 ] || [ "$TIMED_OUT" = true ]; then
            failure_type=$(classify_agent_failure "$TIMED_OUT" "$CLAUDE_EXIT" "$elapsed" "$log_stage" "$stream_file")
        fi

        # Salida normal: exito, fallo no reintentable, o reintentos agotados.
        [ -z "$failure_type" ] && break
        agent_failure_is_retryable "$failure_type" || break
        [ "$attempt" -ge "$MAX_ATTEMPTS" ] && break

        # CA-6: el reintento deja rastro. Sin esta linea un post-mortem no
        # puede distinguir "salio a la primera" de "salio al tercer intento".
        warn "$agent: $failure_type -- reintentando ($((attempt + 1))/$MAX_ATTEMPTS) tras ${RETRY_BACKOFF_SECONDS}s"
        echo "[$(date +%H:%M:%S)] REINTENTO $agent: $failure_type (intento $attempt/$MAX_ATTEMPTS, espera ${RETRY_BACKOFF_SECONDS}s)" >> "$EVENTS_LOG_ABS"

        # El log y la traza del intento fallido se preservan aparte: el
        # siguiente intento sobrescribe los nombres canonicos, y sin esta
        # copia la evidencia del fallo que motivo el reintento se perderia.
        cp -f "$log_stage" "${log_base}.attempt-${attempt}.log" 2>/dev/null || true
        cp -f "$stream_file" "${log_base}.attempt-${attempt}.stream.jsonl" 2>/dev/null || true

        if [ "$ENTRY_CLEAN" = true ] && [ -n "$ENTRY_COMMIT" ]; then
            # CA-5: `clean -fd` va sin -x a proposito -- .claude/pipeline/ esta
            # gitignored y sus summaries deben sobrevivir al reintento.
            git -C "$WORKTREE_PATH" reset --hard "$ENTRY_COMMIT" >/dev/null 2>&1 || true
            git -C "$WORKTREE_PATH" clean -fd >/dev/null 2>&1 || true
            log "Worktree restaurado a ${ENTRY_COMMIT:0:8} para el reintento"
        else
            log "El worktree ya tenia cambios al entrar al stage: NO se restaura (se reintenta sobre el estado actual)"
        fi

        sleep "$RETRY_BACKOFF_SECONDS"
        attempt=$((attempt + 1))
    done

    # El wall-clock del stage incluye todos los intentos y sus esperas: es lo
    # que de verdad costo, y es lo que se reporta al historial.
    local total_elapsed=$(( $(date +%s) - start_ts ))

    if [ -n "$failure_type" ]; then
        log "$agent fallo despues de ${elapsed}s -- tipo: $failure_type"
        echo "[$(date +%H:%M:%S)] FALLO $agent: $failure_type" >> "$EVENTS_LOG_ABS"

        # CA-4: un TIMEOUT o un corte de stream a mitad de respuesta nunca es
        # recuperable via has_work -- el incidente de #416 fue justo esto (el
        # reviewer murio con "API Error: Connection closed mid-response" y el
        # pipeline abrio igual el PR con una revision truncada a mitad de frase).
        # PR #446: la traza entra como cuarto argumento -- un `result` de
        # exito en ella exime al stage de esa regla (la muerte fue posterior al
        # trabajo), sin saltarse los gates de agent_work_is_trustworthy.
        local UNRECOVERABLE=false
        if agent_failure_is_unrecoverable "$TIMED_OUT" "$CLAUDE_EXIT" "$log_stage" "$stream_file"; then
            UNRECOVERABLE=true
        fi

        # CA-5: para el resto de fallos, has_work exige ademas que el resumen
        # de stage exista y no este vacio -- evidencia de que el agente llego
        # al final de su contrato (ver agent_work_is_trustworthy).
        local SUMMARY_FILE="$WORKTREE_PATH/.claude/pipeline/summaries/stage-${stage}-${agent}.md"

        if agent_work_is_trustworthy "$WORKTREE_PATH" "${SNAPSHOT_COMMIT:-HEAD}" "$UNRECOVERABLE" "$SUMMARY_FILE"; then
            warn "$agent: CLI retorno error ($failure_type) pero hay trabajo util -- continuando"
            echo "[$(date +%H:%M:%S)] RECUPERADO $agent: trabajo util detectado" >> "$EVENTS_LOG_ABS"
        else
            case "$agent" in
                writer)   AGENT_WR_DUR=$total_elapsed; AGENT_WR_RES="failed" ;;
                reviewer) AGENT_RV_DUR=$total_elapsed; AGENT_RV_RES="failed" ;;
            esac
            # Las metricas se cosechan por STAGE, no por agente: el stage de
            # resolucion de conflictos corre como `run_agent "merge" "writer"`,
            # asi que un case por "$agent" haria que un merge fallido pisara
            # las metricas del writer de stage 1 y el historial reportara,
            # bajo agents.writer.metrics, los turnos y tokens de otro stage.
            # Las del merge no se pierden: quedan en su propio archivo
            # metrics/...-stage-merge-writer.json (CA-1).
            case "$stage" in
                1) AGENT_WR_METRICS_JSON="$metrics_json" ;;
                2) AGENT_RV_METRICS_JSON="$metrics_json" ;;
            esac
            update_status "$stage-$agent" "failed"
            echo -e "\n${RED}-- Ultimas lineas del log de $agent:${NC}"
            tail -20 "$log_stage"
            abort "$agent fallo ($failure_type). Log completo: $log_stage"
        fi
    fi

    LAST_AGENT_DURATION=$total_elapsed
    LAST_AGENT_METRICS_JSON="$metrics_json"
    if [ "$attempt" -gt 1 ]; then
        log "$agent completado en ${total_elapsed}s (intento $attempt/$MAX_ATTEMPTS; ${elapsed}s el ultimo)"
    else
        log "$agent completado en ${total_elapsed}s"
    fi
}

# --- Funcion auxiliar: auto-commit de seguridad (solo paths del scope de Mefisto) ---
auto_commit_if_needed() {
    local phase="$1"
    local msg="$2"

    # changelog.d/ va en la lista (issue #380): desde el gate de fragmentos, el
    # fragmento es lo UNICO que acredita el cambio notable, y el gate lo da por
    # bueno viendolo tambien en el working tree. Si el auto-commit no lo stagea,
    # el gate pasa pero el fragmento no entra al PR y /mefisto-release no tiene
    # nada que consolidar: la anotacion se perderia en silencio.
    #
    # .claude/settings.json va en la lista (issue #523): sin ella, un writer
    # que cree o edite el archivo de hooks confiando en el auto-commit (en vez
    # de comitearlo el mismo) lo dejaria sin stagear -- `git push` solo manda
    # commits, asi que el archivo nunca llegaria al PR. El pipeline ya no
    # inyecta ni revierte este archivo (ver el bloque de creacion del
    # worktree), asi que lo unico que puede aparecer aqui es una edicion
    # legitima del agente.
    local paths="commands/ agents/ scripts/ hooks/ docs/ .claude-plugin/ .claude/commands/ .claude/agents/ .claude/scripts/ .claude/settings.json changelog.d/ README.md CHANGELOG.md CLAUDE.md .gitignore"

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
- .claude/settings.json  (hooks del pipeline interno; entrada EXACTA, no toda .claude/)
- changelog.d/  (fragmentos de CHANGELOG e indice de ADRs, ver instruccion 5 abajo)
- README.md, CHANGELOG.md, CLAUDE.md, .gitignore  (gobierno del repo)

Si el issue requiere escribir en una ruta o tipo de artefacto que NO esta en el listado anterior, verifica antes la allowlist autoritativa: la funcion is_path_in_mefisto_scope de .claude/scripts/_mefisto-common.sh, tal como esta en main. Es la que el gate del pipeline evalua, y el listado de arriba puede quedarse corto frente a ella. Si la ruta tampoco esta ahi, NO intentes crear archivos en ella aunque el issue lo describa: primero hace falta un PR que la registre en los gates de scope/changelog (ver MEF-ADR-0019, seccion E -- registrar una ruta y usarla son dos PRs distintos, el de registro va primero y no crea archivos bajo la ruta que registra). Reporta ese bloqueo en tu resumen de stage 1 para que el PR de registro se abra antes de continuar con este issue.

NO MODIFIQUES NADA FUERA DE ESE SCOPE. Mefisto no tiene src/, tests/, infra/, ni .github/workflows/.

CONTEXTO DE EJECUCION:
- Modo no-interactivo (print mode). No hay un humano al otro lado.
- Nadie puede aprobar, confirmar ni responder preguntas.
- DEBES usar las herramientas Write y Edit directamente.
- Responder con texto pidiendo aprobacion causa un fallo del pipeline.
- Tienes permisos completos (bypassPermissions activo).
- PROHIBIDO hacer 'git push' o 'gh pr create' (ni ninguna operacion de publicacion de rama/PR): eso es responsabilidad exclusiva del pipeline, nunca tuya.

ECONOMIA DE TURNOS:
Cada turno tuyo cuesta ~13 s de reloj (el 96,6% del tiempo de una corrida es el modelo escribiendo tokens, no las herramientas ejecutandose). El trabajo que ese turno manda a hacer cuesta ~1 s: la suite de guards tarda 1,05 s y las 22 suites completas 25 s. Lo caro es el turno, no el trabajo. Con eso en mente:
- Agrupa en un mismo turno las tool calls independientes entre si (varias busquedas, varias lecturas, varias escrituras a archivos distintos). No las encadenes de a una: hoy el 82% de los turnos del pipeline gasta una sola tool call, y cada una de esas cadenas paga 13 s por eslabon.
- La suite de tests (scripts/tests/, .claude/scripts/tests/) correla UNA vez, al final, cuando ya no vayas a tocar mas archivos. No la corras despues de cada edicion. Correrla al cerrar es obligatorio -- lo que sobra es repetirla.
- No re-inspecciones el arbol con 'git status' ni 'git diff' para confirmar algo que acabas de escribir: Write y Edit fallan con error si no aplican, asi que el exito de la herramienta ya es la confirmacion.
- No verifiques el scope de un archivo antes de escribirlo (ni con 'git status' ni releyendo is_path_in_mefisto_scope): un hook PostToolUse te avisa EN EL INSTANTE, gratis, si un Edit/Write cae fuera de la allowlist -- no hay motivo para inspeccionar preventivamente algo que el hook ya te va a decir si sale mal. Eso no reemplaza el gate final (validate_mefisto_scope_changes sigue corriendo al cierre del stage): el hook es aviso temprano, no el juez.
Estas reglas no cubren todos los casos; ante cualquier otro, decide con el mismo criterio -- un turno extra cuesta ~13 s, y solo vale la pena si te ahorra un error que costaria mas.

Instrucciones:
1. Lee los archivos existentes relevantes antes de escribir nuevos.
2. Reutiliza patrones y convenciones del repo (mira archivos similares).
3. Haz commits frecuentes con mensajes descriptivos en espanol.
4. Si modificaste un skill o agente publicado, considera si necesitas tambien la version interna (con prefijo mefisto-).
5. Anota el cambio como FRAGMENTO en changelog.d/ (issue #380): NUNCA edites CHANGELOG.md ni la tabla \"Indice tematico\" de CLAUDE.md directamente -- son archivos-indice compartidos que /mefisto-release consolida en su propia rama de release, no cada PR (editarlos por-issue es exactamente la contencion que este mecanismo elimina). En su lugar:
   - Crea 'changelog.d/${ISSUE_NUM}.<categoria>.md' con una o mas lineas '- texto de la entrada' en estilo Keep a Changelog, donde <categoria> es 'added' (funcionalidad nueva), 'changed' (cambio de comportamiento), 'fixed' (bug) o 'removed' (eliminacion).
   - Si el issue anade o enmienda un ADR (docs/adr/), crea ademas 'changelog.d/${ISSUE_NUM}.adr-index.md' con la fila '| <Tema del ADR> | MEF-ADR-XXXX |' lista para insertarse en la tabla de indice de CLAUDE.md.
   - Ve changelog.d/README.md para el formato completo y ejemplos.
   Excepcion: si el cambio toca exclusivamente bitacora (docs/bitacora/**) u otros archivos de gobierno no notables (README.md, CLAUDE.md, .gitignore), omite el fragmento. Un gate del pipeline aborta el PR si un cambio notable llega sin fragmento en changelog.d/.
6. Al terminar, escribe un resumen de lo que hiciste en .claude/pipeline/summaries/stage-1-writer.md"

    # Sustituir $ISSUE_CONTEXT manualmente (evita expansion temprana en la heredoc)
    STAGE1_PROMPT="${STAGE1_PROMPT//\$ISSUE_CONTEXT/$ISSUE_CONTEXT}"

    run_agent "1" "writer" "$STAGE1_PROMPT"

    # Validar que genero cambios reales
    HAS_COMMITS=false
    HAS_UNSTAGED=false
    if ! git -C "$WORKTREE_PATH" diff --quiet "$SNAPSHOT_COMMIT" HEAD 2>/dev/null; then
        HAS_COMMITS=true
    fi
    if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain -- commands/ agents/ scripts/ hooks/ docs/ .claude-plugin/ .claude/commands/ .claude/agents/ .claude/scripts/ .claude/settings.json changelog.d/ README.md CHANGELOG.md CLAUDE.md .gitignore 2>/dev/null)" ]; then
        HAS_UNSTAGED=true
    fi
    if [ "$HAS_COMMITS" = false ] && [ "$HAS_UNSTAGED" = false ]; then
        abort "El writer no genero ningun cambio. Revisa el log: $LOG_DIR_ABS/mefisto-tooling-stage-1-writer-${TIMESTAMP}-issue-${ISSUE_LOG_TAG}.log"
    fi

    # Gate de scope: rechazar cambios fuera del alcance del repo de Mefisto
    if ! validate_mefisto_scope_changes "$WORKTREE_PATH" "$SNAPSHOT_COMMIT"; then
        abort "Stage 1 fallido: el writer toco archivos fuera del scope de Mefisto."
    fi

    auto_commit_if_needed "writer" "mefisto-tooling(#${ISSUE_NUM}): implementacion"

    AGENT_WR_DUR=$LAST_AGENT_DURATION
    AGENT_WR_METRICS_JSON=$LAST_AGENT_METRICS_JSON
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
.claude/commands/, .claude/agents/, .claude/scripts/, .claude/settings.json,
changelog.d/, README.md, CHANGELOG.md, CLAUDE.md, .gitignore.

CONTEXTO DE EJECUCION:
- Modo no-interactivo (print mode). DEBES usar Write/Edit directamente.
- Responder con texto pidiendo aprobacion causa un fallo del pipeline.
- Tienes permisos completos (bypassPermissions activo).
- PROHIBIDO hacer 'git push' o 'gh pr create' (ni ninguna operacion de publicacion de rama/PR): eso es responsabilidad exclusiva del pipeline, nunca tuya.

ECONOMIA DE TURNOS:
Cada turno tuyo cuesta ~13 s de reloj (el 96,6% del tiempo de una corrida es el modelo escribiendo tokens, no las herramientas ejecutandose). El trabajo que ese turno manda a hacer cuesta ~1 s: la suite de guards tarda 1,05 s y las 22 suites completas 25 s. Lo caro es el turno, no el trabajo. Con eso en mente:
- Agrupa en un mismo turno las tool calls independientes entre si (varias busquedas, varias lecturas, varias escrituras a archivos distintos). No las encadenes de a una: hoy el 82% de los turnos del pipeline gasta una sola tool call, y cada una de esas cadenas paga 13 s por eslabon.
- La suite de tests (scripts/tests/, .claude/scripts/tests/) correla UNA vez, al final, cuando ya no vayas a tocar mas archivos. No la corras despues de cada correccion. Correrla al cerrar es obligatorio -- lo que sobra es repetirla.
- Ya tienes el diff completo del writer aqui arriba: no lo vuelvas a pedir con 'git diff'. Y no re-inspecciones el arbol con 'git status' para confirmar algo que acabas de escribir -- Write y Edit fallan con error si no aplican, asi que el exito de la herramienta ya es la confirmacion.
- No verifiques el scope de un archivo antes de escribirlo: un hook PostToolUse te avisa EN EL INSTANTE, gratis, si un Edit/Write cae fuera de la allowlist -- no hay motivo para inspeccionar preventivamente algo que el hook ya te va a decir si sale mal. Eso no reemplaza el gate final (validate_mefisto_scope_changes sigue corriendo al cierre del stage): el hook es aviso temprano, no el juez.
Estas reglas no cubren todos los casos; ante cualquier otro, decide con el mismo criterio -- un turno extra cuesta ~13 s, y solo vale la pena si te ahorra un error que costaria mas.

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
    AGENT_RV_METRICS_JSON=$LAST_AGENT_METRICS_JSON
    AGENT_RV_RES="passed"
    update_status "2-reviewer" "passed"
    success "Stage 2 completado"
fi

# --- Verificar que hay commits ---
COMMITS_LIST=$(git -C "$WORKTREE_PATH" log "${SNAPSHOT_COMMIT}..HEAD" --oneline)
if [ -z "$COMMITS_LIST" ]; then
    abort "No hay commits en la rama $BRANCH_NAME."
fi

# --- Gate de fragmentos de CHANGELOG (changelog.d/, issue #380) ---
# Reemplaza el gate cinturon+tirantes sobre CHANGELOG.md (issue #70) que exigia
# editar directamente '## [Unreleased]': esa edicion por-PR era el punto de
# contencion (varios PRs tocando las mismas pocas lineas de un archivo-indice
# compartido) que este mecanismo elimina. Ahora el gate exige un FRAGMENTO
# propio en changelog.d/ -- CHANGELOG.md y el indice de ADRs de CLAUDE.md dejan
# de ser rutas editadas por-issue; los consolida /mefisto-release en su propia
# rama de release. Si todas las rutas tocadas son exentas (bitacora / gobierno
# no notable) no se exige fragmento y el gate pasa. Corre tras el reviewer
# (Stage 2) y antes de crear el PR.
header "Verificando fragmento de CHANGELOG (changelog.d/)"

if changelog_fragment_added "$WORKTREE_PATH" "$SNAPSHOT_COMMIT"; then
    success "El PR anota su cambio como fragmento en changelog.d/"
elif ! changes_require_changelog "$WORKTREE_PATH" "$SNAPSHOT_COMMIT"; then
    success "Cambio exento (solo bitacora/gobierno no notable): no se exige fragmento"
else
    abort "Cambio notable sin fragmento en changelog.d/.
El writer debio crear 'changelog.d/${ISSUE_NUM}.<categoria>.md' (added/changed/fixed/removed)
-- ver changelog.d/README.md para el formato. NUNCA se edita CHANGELOG.md directamente.
Crea el fragmento en el worktree ($WORKTREE_PATH) y retoma con:
  ./.claude/scripts/mefisto-tooling-pipeline.sh $ISSUE_NUM --from-stage 2${VARIANT_LABEL:+ --variant $VARIANT_LABEL}"
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
Despues de resolver cada archivo, haz git add. Cuando todos esten resueltos, haz git commit.
PROHIBIDO hacer 'git push' o 'gh pr create': eso es responsabilidad exclusiva del pipeline, nunca tuya."

        run_agent "merge" "writer" "$MERGE_PROMPT"

        REMAINING_CONFLICTS=$(git -C "$WORKTREE_PATH" diff --name-only --diff-filter=U 2>/dev/null || true)
        if [ -n "$REMAINING_CONFLICTS" ]; then
            abort "Aun quedan conflictos: $REMAINING_CONFLICTS. Revisa manualmente: cd $WORKTREE_PATH"
        fi
        success "Conflictos resueltos"
    fi
fi

# --- Crear PR (en modo variante: NO -- CA-3) ---
if [ -n "$VARIANT_LABEL" ]; then
    header "Modo variante: sin PR"
    warn "Variante '$VARIANT_LABEL': se omiten push, creacion de PR y comentario al issue (CA-3)."
    log "La rama '$BRANCH_NAME' queda LOCAL -- no se publica a origin."
    PR_URL=""
else
    header "Creando PR"

    log "Haciendo push de la rama..."
    git -C "$WORKTREE_PATH" push -u origin "$BRANCH_NAME" >>"${LOG_FILE_ABS:-$LOG_FILE}" 2>&1 \
        || abort "No se pudo hacer push de la rama $BRANCH_NAME"

    log "Verificando si ya existe un PR abierto para la rama..."
    EXISTING_PR_URL=$(find_open_pr_for_branch "$BRANCH_NAME")

    if [ -n "$EXISTING_PR_URL" ]; then
        PR_URL="$EXISTING_PR_URL"
        success "PR existente reutilizado: $PR_URL"
    else
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
            2>>"${LOG_FILE_ABS:-$LOG_FILE}") \
            || abort "No se pudo crear el PR"

        success "PR creado: $PR_URL"
    fi

    gh issue comment "$ISSUE_NUM" \
        --body "Pipeline mefisto-tooling completado. PR: $PR_URL" \
        >>"$LOG_FILE" 2>&1 || warn "No se pudo comentar en el issue #$ISSUE_NUM"
fi

PIPELINE_PR="$PR_URL"
update_status "done" "completed"

# Historial
# CA-2 (issue #426): agents.<agente>.metrics se agrega sin tocar "duration"
# -- si build_agents_history_json fallara por cualquier motivo, el fallback
# reproduce exactamente el formato plano que ya escribia esta linea (CA-5).
COMPLETED_AGENTS_JSON=$(build_agents_history_json "${AGENT_WR_DUR:-}" "${AGENT_WR_METRICS_JSON:-}" "${AGENT_RV_DUR:-}" "${AGENT_RV_METRICS_JSON:-}" 2>/dev/null) \
    || COMPLETED_AGENTS_JSON="{\"writer\":{\"duration\":${AGENT_WR_DUR:-null}},\"reviewer\":{\"duration\":${AGENT_RV_DUR:-null}}}"
PR_JSON="null"
[ -n "$PR_URL" ] && PR_JSON="\"$PR_URL\""
echo "{\"issue\":\"$ISSUE_NUM\",\"title\":\"$(echo "$ISSUE_TITLE" | sed 's/"/\\"/g')\",\"pipeline\":\"mefisto-tooling\",\"variant\":${VARIANT_LABEL_JSON:-null},\"harness_version\":${HARNESS_VERSION_JSON:-null},\"harness_sha\":${HARNESS_SHA_JSON:-null},\"started\":\"$TIMESTAMP\",\"finished\":\"$(date +%Y-%m-%dT%H:%M:%S)\",\"state\":\"completed\",\"agents\":$COMPLETED_AGENTS_JSON,\"pr\":$PR_JSON}" \
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
TOTAL_COMMITS=$(echo "$COMMITS_LIST" | wc -l | tr -d ' ')
if [ -n "$VARIANT_LABEL" ]; then
    echo -e "${CYAN}${BOLD}=== Pipeline mefisto-tooling (variante '$VARIANT_LABEL') completado ===${NC}"
    echo ""
    echo -e "  Commits: $TOTAL_COMMITS"
    echo -e "  Rama:    $BRANCH_NAME"
    echo -e "  Estado:  LOCAL -- sin push, sin PR, sin comentario al issue (modo variante)"
    echo -e "  Log:     $LOG_FILE"
    echo ""
    echo -e "${YELLOW}Si esta variante gana la comparacion, promuevela a mano:${NC}"
    echo -e "${YELLOW}  git -C $REPO_ROOT push -u origin $BRANCH_NAME${NC}"
    echo -e "${YELLOW}  gh pr create --base main --head $BRANCH_NAME --title \"$ISSUE_TITLE\" --body \"Closes #$ISSUE_NUM\"${NC}"
    echo -e "${YELLOW}O relanza el pipeline sin --variant para que una corrida normal abra el PR.${NC}"
else
    echo -e "${CYAN}${BOLD}=== Pipeline mefisto-tooling completado ===${NC}"
    echo ""
    echo -e "  Commits: $TOTAL_COMMITS"
    echo -e "  Rama:    $BRANCH_NAME"
    echo -e "  PR:      $PR_URL"
    echo -e "  Log:     $LOG_FILE"
fi
echo ""
