#!/usr/bin/env bash
# tmux-pipeline.sh --- Wrapper para ejecutar pipelines dentro de sesiones tmux
#
# Uso:
#   ./scripts/tmux-pipeline.sh 42                        # issue unico (enruta por label)
#   ./scripts/tmux-pipeline.sh --pipeline tooling 42     # forzar pipeline tooling
#   ./scripts/tmux-pipeline.sh --batch 42 43 44          # secuencial (enruta por label)
#   ./scripts/tmux-pipeline.sh --parallel 42 43 44       # paralelo (enruta por label)
#   ./scripts/tmux-pipeline.sh --parallel 42 43 --max-parallel 2
#   ./scripts/tmux-pipeline.sh --attach                  # reconectar sesion existente
#   ./scripts/tmux-pipeline.sh --attach tdd-42           # reconectar sesion especifica
#
# Enrutamiento automatico: sin --pipeline, cada issue se enruta segun su label tipo:*
#
# Recomendado: ejecutar desde iTerm2 con tmux -CC para UI nativa.
# Los scripts subyacentes (tdd-pipeline.sh, batch-pipeline.sh, parallel-pipeline.sh)
# no se modifican y siguen funcionando independientemente.

set -euo pipefail

# --- Funciones compartidas ---
source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"

# Guard defensivo: este pipeline es del lado publicado y solo aplica al consumidor.
# Si detectamos .claude-plugin/plugin.json en la raiz, estamos en el repo de Mefisto.
_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$_REPO_TOP/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/tmux-pipeline.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Estas en el repo de Mefisto. Para trabajar issues del plugin en tmux usa los skills internos /mefisto-tooling o /mefisto-sequential." >&2
    exit 1
fi
unset _REPO_TOP

# --- Colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVENTS_LOG="$PROJECT_ROOT/.claude/pipeline/events.log"

log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
success() { echo -e "${GREEN}${BOLD}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
abort()   { echo -e "\n${RED}${BOLD}✗ $1${NC}" >&2; exit 1; }

# --- Verificaciones previas ---
check_tmux() {
    if ! command -v tmux &>/dev/null; then
        abort "tmux no esta instalado. Instala con: brew install tmux"
    fi
}

# Detectar si estamos dentro de una sesion tmux activa
inside_tmux() {
    [ -n "${TMUX:-}" ]
}

# Asegurar que events.log existe para que tail no falle
ensure_events_log() {
    mkdir -p "$(dirname "$EVENTS_LOG")"
    touch "$EVENTS_LOG"
}

# Nombre de sesion seguro para tmux (sin espacios ni caracteres especiales)
safe_session_name() {
    echo "$1" | tr ' /:' '-' | tr -cd 'a-zA-Z0-9-'
}

# Verificar si una sesion tmux existe
session_exists() {
    tmux has-session -t "$1" 2>/dev/null
}

# Imprimir instrucciones de conexion
print_connect_hint() {
    local session="$1"
    echo ""
    echo -e "${CYAN}${BOLD}Sesion tmux lista: $session${NC}"
    echo ""
    echo -e "  ${BOLD}En iTerm2 (recomendado):${NC}"
    echo -e "    tmux -CC attach -t $session"
    echo ""
    echo -e "  ${BOLD}En terminal estandar:${NC}"
    echo -e "    tmux attach -t $session"
    echo ""
    echo -e "  ${BOLD}Ver todas las sesiones:${NC}"
    echo -e "    tmux ls"
    echo ""
}

# --- Modo ATTACH ---
cmd_attach() {
    local target="${1:-}"
    check_tmux

    if [ -n "$target" ]; then
        if ! session_exists "$target"; then
            # Mostrar sesiones disponibles
            echo -e "${YELLOW}Sesion '$target' no existe. Sesiones disponibles:${NC}"
            tmux ls 2>/dev/null || echo "  (ninguna)"
            exit 1
        fi
        exec tmux attach -t "$target"
    else
        # Adjuntar a la primera sesion disponible
        if ! tmux ls &>/dev/null; then
            abort "No hay sesiones tmux activas."
        fi
        exec tmux attach
    fi
}

# --- Modo SINGLE (un issue) ---
cmd_single() {
    local issue="$1"
    local extra_args="${2:-}"
    local pipeline_override="${3:-}"

    # Resolver pipeline por label o override
    local resolved
    resolved=$(resolve_pipeline "$issue" "$pipeline_override")
    if [[ "$resolved" == SKIP:* ]]; then
        local reason="${resolved#SKIP:}"
        abort "Issue #$issue no se puede enrutar a un pipeline ($reason)."
    fi

    local pipeline_name
    pipeline_name=$(basename "$resolved" .sh)
    local session
    session=$(safe_session_name "$pipeline_name-$issue")

    check_tmux
    ensure_events_log

    if session_exists "$session"; then
        warn "Ya existe una sesion '$session'."
        print_connect_hint "$session"
        exit 0
    fi

    log "Creando sesion tmux '$session' para issue #$issue ($pipeline_name)..."

    # Crear sesion con ventana unica y panes lado a lado
    tmux new-session -d -s "$session" -n "main" -c "$PROJECT_ROOT"
    tmux set-option -t "$session" remain-on-exit on
    tmux send-keys -t "$session:main" "tail -f '$EVENTS_LOG'" Enter

    # Pane derecho: pipeline
    tmux split-window -h -t "$session:main" -c "$PROJECT_ROOT"
    tmux send-keys -t "$session:main.1" "$resolved $issue $extra_args" Enter

    tmux select-layout -t "$session:main" even-horizontal

    success "Pipeline $pipeline_name iniciado para issue #$issue"
    print_connect_hint "$session"
}

# --- Modo BATCH (secuencial) ---
cmd_batch() {
    local pipeline_override=""
    local issues=()

    # Parsear --pipeline de los args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pipeline)
                pipeline_override="$2"
                shift 2
                ;;
            *)
                issues+=("$1")
                shift
                ;;
        esac
    done

    if [ ${#issues[@]} -eq 0 ]; then
        abort "Debes especificar al menos un issue. Uso: --batch 42 43 44"
    fi

    local session
    session=$(safe_session_name "batch-$(date +%H%M%S)")
    local issues_str="${issues[*]}"
    local pipeline_flag=""
    [ -n "$pipeline_override" ] && pipeline_flag="--pipeline $pipeline_override"

    check_tmux
    ensure_events_log

    log "Creando sesion tmux '$session' para batch: issues ${issues_str}..."

    # Crear sesion con ventana unica y panes lado a lado
    tmux new-session -d -s "$session" -n "main" -c "$PROJECT_ROOT"
    tmux set-option -t "$session" remain-on-exit on
    tmux send-keys -t "$session:main" "tail -f '$EVENTS_LOG'" Enter

    # Pane derecho: batch pipeline
    tmux split-window -h -t "$session:main" -c "$PROJECT_ROOT"
    tmux send-keys -t "$session:main.1" "./scripts/batch-pipeline.sh $pipeline_flag $issues_str" Enter

    tmux select-layout -t "$session:main" even-horizontal

    success "Batch pipeline iniciado: issues $issues_str"
    print_connect_hint "$session"
}

# --- Modo PARALELO (un tab por issue) ---
cmd_parallel() {
    local max_parallel=""
    local pipeline_override=""
    local issues=()

    # Parsear args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-parallel)
                max_parallel="$2"
                shift 2
                ;;
            --max-parallel=*)
                max_parallel="${1#*=}"
                shift
                ;;
            --pipeline)
                pipeline_override="$2"
                shift 2
                ;;
            *)
                issues+=("$1")
                shift
                ;;
        esac
    done

    if [ ${#issues[@]} -eq 0 ]; then
        abort "Debes especificar al menos un issue. Uso: --parallel 42 43 44"
    fi

    local session
    session=$(safe_session_name "parallel-$(date +%H%M%S)")
    local issues_str="${issues[*]}"
    local max_flag=""
    [ -n "$max_parallel" ] && max_flag="--max-parallel $max_parallel"

    check_tmux
    ensure_events_log

    log "Creando sesion tmux '$session' para issues paralelos: $issues_str..."

    # Crear sesion con ventana unica y panes lado a lado
    tmux new-session -d -s "$session" -n "main" -c "$PROJECT_ROOT"
    tmux set-option -t "$session" remain-on-exit on
    tmux send-keys -t "$session:main" "tail -f '$EVENTS_LOG'" Enter

    # Pre-resolver pipelines y filtrar issues no enrutables
    local resolved_issues=()
    local resolved_pipelines=()
    for issue in "${issues[@]}"; do
        local resolved
        resolved=$(resolve_pipeline "$issue" "$pipeline_override")
        if [[ "$resolved" == SKIP:* ]]; then
            local reason="${resolved#SKIP:}"
            warn "Issue #$issue saltado ($reason) --- no se abre tab."
            continue
        fi
        resolved_issues+=("$issue")
        resolved_pipelines+=("$resolved")
    done

    if [ ${#resolved_issues[@]} -eq 0 ]; then
        tmux kill-session -t "$session" 2>/dev/null
        abort "No hay issues validos para abrir en paralelo."
    fi

    # Un pane por issue (escalonado para evitar contencion de API)
    for i in "${!resolved_issues[@]}"; do
        tmux split-window -h -t "$session:main" -c "$PROJECT_ROOT"
        tmux send-keys -t "$session:main" "${resolved_pipelines[$i]} ${resolved_issues[$i]}" Enter
        # Escalonar lanzamientos: 30s entre cada uno para evitar que multiples
        # invocaciones de claude -p compitan por recursos de API simultaneamente
        if [ "$i" -lt "$(( ${#resolved_issues[@]} - 1 ))" ]; then
            sleep 30
        fi
    done

    tmux select-layout -t "$session:main" even-horizontal

    success "Pipeline paralelo iniciado: issues ${resolved_issues[*]}"
    print_connect_hint "$session"

    # Nota: el flag --max-parallel se ignora aqui porque cada issue tiene su propio tab
    if [ -n "$max_parallel" ]; then
        warn "--max-parallel no aplica en modo tmux (cada issue tiene su propio tab)."
        warn "Para limitar concurrencia usa: ./scripts/parallel-pipeline.sh $max_flag $issues_str"
    fi
}

# --- Modo TOOLING (un issue, pipeline sin TDD) ---
cmd_tooling() {
    local issue="$1"
    local session
    session=$(safe_session_name "tooling-$issue")

    check_tmux
    ensure_events_log

    if session_exists "$session"; then
        warn "Ya existe una sesion '$session'."
        print_connect_hint "$session"
        exit 0
    fi

    log "Creando sesion tmux '$session' para tooling issue #$issue..."

    tmux new-session -d -s "$session" -n "main" -c "$PROJECT_ROOT"
    tmux set-option -t "$session" remain-on-exit on
    tmux send-keys -t "$session:main" "tail -f '$EVENTS_LOG'" Enter

    tmux split-window -h -t "$session:main" -c "$PROJECT_ROOT"
    tmux send-keys -t "$session:main.1" "./scripts/tooling-pipeline.sh $issue" Enter

    tmux select-layout -t "$session:main" even-horizontal

    success "Pipeline tooling iniciado para issue #$issue"
    print_connect_hint "$session"
}

# --- Modo INFRA (un issue, pipeline IaC) ---
cmd_infra() {
    local issue="$1"
    local session
    session=$(safe_session_name "infra-$issue")

    check_tmux
    ensure_events_log

    if session_exists "$session"; then
        warn "Ya existe una sesion '$session'."
        print_connect_hint "$session"
        exit 0
    fi

    log "Creando sesion tmux '$session' para infra issue #$issue..."

    tmux new-session -d -s "$session" -n "main" -c "$PROJECT_ROOT"
    tmux set-option -t "$session" remain-on-exit on
    tmux send-keys -t "$session:main" "tail -f '$EVENTS_LOG'" Enter

    tmux split-window -h -t "$session:main" -c "$PROJECT_ROOT"
    tmux send-keys -t "$session:main.1" "./scripts/iac-pipeline.sh $issue" Enter

    tmux select-layout -t "$session:main" even-horizontal

    success "Pipeline infra iniciado para issue #$issue"
    print_connect_hint "$session"
}

# --- Modo SCAFFOLD (un dominio) ---
cmd_scaffold() {
    local issue=""
    local domain=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)
                domain="$2"
                shift 2
                ;;
            --domain=*)
                domain="${1#*=}"
                shift
                ;;
            [0-9]*)
                issue="$1"
                shift
                ;;
            *)
                abort "Argumento desconocido para --scaffold: $1"
                ;;
        esac
    done

    [ -n "$domain" ] || abort "Falta --domain para --scaffold. Uso: --scaffold [issue] --domain nombre"

    # Normalizar dominio a kebab-case (acepta PascalCase, camelCase, snake_case)
    domain=$(echo "$domain" \
        | sed 's/_/-/g' \
        | sed 's/\([a-z0-9]\)\([A-Z]\)/\1-\2/g' \
        | tr '[:upper:]' '[:lower:]')

    local session
    session=$(safe_session_name "scaffold-$domain")

    check_tmux
    ensure_events_log

    if session_exists "$session"; then
        warn "Ya existe una sesion '$session'."
        print_connect_hint "$session"
        exit 0
    fi

    local pipeline_args=""
    [ -n "$issue" ] && pipeline_args="$issue "
    pipeline_args="${pipeline_args}--domain $domain"

    log "Creando sesion tmux '$session' para scaffold del dominio '$domain'..."

    tmux new-session -d -s "$session" -n "main" -c "$PROJECT_ROOT"
    tmux set-option -t "$session" remain-on-exit on
    tmux send-keys -t "$session:main" "tail -f '$EVENTS_LOG'" Enter

    tmux split-window -h -t "$session:main" -c "$PROJECT_ROOT"
    tmux send-keys -t "$session:main.1" "./scripts/scaffold-pipeline.sh $pipeline_args" Enter

    tmux select-layout -t "$session:main" even-horizontal

    success "Pipeline de scaffold iniciado para dominio '$domain'"
    print_connect_hint "$session"
}

# --- Mostrar ayuda ---
cmd_help() {
    cat <<EOF

${CYAN}${BOLD}tmux-pipeline.sh${NC} --- Wrapper para pipelines en sesiones tmux

${BOLD}Uso:${NC}
  ./scripts/tmux-pipeline.sh 42                                   Issue unico (enruta por label)
  ./scripts/tmux-pipeline.sh --pipeline tooling 42                Forzar pipeline tooling
  ./scripts/tmux-pipeline.sh --tooling 42                         Issue de tooling (override explicito)
  ./scripts/tmux-pipeline.sh --infra 42                           Issue de infraestructura (IaC)
  ./scripts/tmux-pipeline.sh --scaffold 42 --domain nombre        Scaffold de dominio
  ./scripts/tmux-pipeline.sh --scaffold --domain nombre           Scaffold sin issue
  ./scripts/tmux-pipeline.sh --batch 42 43 44                     Secuencial (enruta por label)
  ./scripts/tmux-pipeline.sh --batch --pipeline tooling 42 43     Secuencial forzando tooling
  ./scripts/tmux-pipeline.sh --parallel 42 43 44                  Paralelo (enruta por label)
  ./scripts/tmux-pipeline.sh --parallel --pipeline tdd 42 43      Paralelo forzando tdd
  ./scripts/tmux-pipeline.sh --attach                             Reconectar sesion tmux activa
  ./scripts/tmux-pipeline.sh --attach tdd-42                      Reconectar sesion especifica

${BOLD}Enrutamiento automatico:${NC}
  Sin --pipeline ni --tooling/--infra, el pipeline se determina por el label tipo:* del issue:
    tipo:feature|refactor       -> tdd-pipeline.sh
    tipo:tooling               -> tooling-pipeline.sh
    tipo:infra                 -> SKIP (usar --infra explicitamente)

${BOLD}En iTerm2 (recomendado):${NC}
  1. Corre el comando anterior desde tu terminal normal
  2. El script crea la sesion en background y te dice como conectarte
  3. Ejecuta: tmux -CC attach -t <nombre-sesion>
  4. iTerm2 muestra los panes lado a lado: 'dashboard' + 'pipeline' (o uno por issue)

${BOLD}Ver sesiones activas:${NC}
  tmux ls

${BOLD}Documentacion completa:${NC}
  docs/tmux-cheatsheet.md

EOF
}

# --- Entrypoint ---
main() {
    if [ $# -eq 0 ]; then
        cmd_help
        exit 0
    fi

    # Pre-parsear --scaffold-domain y --pipeline antes del dispatch de modo
    local scaffold_extra=""
    local pipeline_override=""
    local filtered_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scaffold-domain)
                [ $# -lt 2 ] && abort "Falta el nombre del dominio para --scaffold-domain"
                scaffold_extra="--scaffold-domain $2"
                shift 2
                ;;
            --pipeline)
                [ $# -lt 2 ] && abort "Falta el valor de --pipeline"
                pipeline_override="$2"
                shift 2
                ;;
            *)
                filtered_args+=("$1")
                shift
                ;;
        esac
    done
    set -- "${filtered_args[@]}"

    case "$1" in
        --help|-h)
            cmd_help
            ;;
        --attach)
            shift
            cmd_attach "${1:-}"
            ;;
        --tooling)
            shift
            if [ $# -eq 0 ]; then
                abort "Debes especificar un issue. Uso: --tooling 42"
            fi
            cmd_tooling "$1"
            ;;
        --infra)
            shift
            if [ $# -eq 0 ]; then
                abort "Debes especificar un issue. Uso: --infra 42"
            fi
            cmd_infra "$1"
            ;;
        --scaffold)
            shift
            cmd_scaffold "$@"
            ;;
        --batch)
            shift
            if [ $# -eq 0 ]; then
                abort "Debes especificar al menos un issue. Uso: --batch 42 43 44"
            fi
            # Pasar --pipeline al cmd_batch si se proporciono
            if [ -n "$pipeline_override" ]; then
                cmd_batch --pipeline "$pipeline_override" "$@"
            else
                cmd_batch "$@"
            fi
            ;;
        --parallel)
            shift
            if [ $# -eq 0 ]; then
                abort "Debes especificar al menos un issue. Uso: --parallel 42 43 44"
            fi
            # Pasar --pipeline al cmd_parallel si se proporciono
            if [ -n "$pipeline_override" ]; then
                cmd_parallel --pipeline "$pipeline_override" "$@"
            else
                cmd_parallel "$@"
            fi
            ;;
        [0-9]*)
            # Modo single: argumento directo es un issue
            if [ $# -gt 1 ]; then
                warn "Multiples issues sin modo especificado. Usando --parallel."
                if [ -n "$pipeline_override" ]; then
                    cmd_parallel --pipeline "$pipeline_override" "$@"
                else
                    cmd_parallel "$@"
                fi
            else
                cmd_single "$1" "$scaffold_extra" "$pipeline_override"
            fi
            ;;
        *)
            echo -e "${RED}Argumento desconocido: $1${NC}"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
