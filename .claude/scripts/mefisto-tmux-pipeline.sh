#!/usr/bin/env bash
# mefisto-tmux-pipeline.sh -- Wrapper tmux para los pipelines INTERNOS de Mefisto
#
# Uso:
#   ./.claude/scripts/mefisto-tmux-pipeline.sh --tooling 42
#   ./.claude/scripts/mefisto-tmux-pipeline.sh --batch 42 43 44   # secuencial
#   ./.claude/scripts/mefisto-tmux-pipeline.sh --attach            # reconectar
#   ./.claude/scripts/mefisto-tmux-pipeline.sh --attach mefisto-tooling-42
#
# Solo se ejecuta dentro del repo de Mefisto (assert_in_mefisto en _mefisto-common.sh).

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$MEFISTO_REPO_ROOT"
EVENTS_LOG="$PROJECT_ROOT/.claude/pipeline/events.log"

log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
success() { echo -e "${GREEN}${BOLD}v${NC} $1"; }
warn()    { echo -e "${YELLOW}!${NC} $1"; }
abort()   { echo -e "\n${RED}${BOLD}x $1${NC}" >&2; exit 1; }

check_tmux() {
    command -v tmux &>/dev/null || abort "tmux no esta instalado. Instala con: brew install tmux"
}

ensure_events_log() {
    mkdir -p "$(dirname "$EVENTS_LOG")"
    touch "$EVENTS_LOG"
}

safe_session_name() { echo "$1" | tr ' /:' '-' | tr -cd 'a-zA-Z0-9-'; }
session_exists()    { tmux has-session -t "$1" 2>/dev/null; }

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
}

cmd_attach() {
    local target="${1:-}"
    check_tmux
    if [ -n "$target" ]; then
        if ! session_exists "$target"; then
            echo -e "${YELLOW}Sesion '$target' no existe. Sesiones disponibles:${NC}"
            tmux ls 2>/dev/null || echo "  (ninguna)"
            exit 1
        fi
        exec tmux attach -t "$target"
    else
        tmux ls &>/dev/null || abort "No hay sesiones tmux activas."
        exec tmux attach
    fi
}

cmd_tooling() {
    local issue="$1"
    local session
    session=$(safe_session_name "mefisto-tooling-$issue")

    check_tmux
    ensure_events_log

    if session_exists "$session"; then
        warn "Ya existe una sesion '$session'."
        print_connect_hint "$session"
        exit 0
    fi

    log "Creando sesion tmux '$session' para mefisto-tooling issue #$issue..."

    # Captura el pane_id del shell creado por new-session (formato %N).
    # Usar pane_id en vez de "$session:main.X" evita depender de pane-base-index,
    # que en muchas configuraciones (incluida la de macOS por defecto al usar
    # iTerm2) es 1 en vez de 0 y rompe la indexacion implicita.
    local tail_pane script_pane
    tmux new-session -d -s "$session" -n "main" -c "$PROJECT_ROOT"
    tail_pane=$(tmux list-panes -t "$session:main" -F '#{pane_id}' | head -n1)
    tmux set-option -t "$session" remain-on-exit on
    tmux send-keys -t "$tail_pane" "tail -f '$EVENTS_LOG'" Enter

    script_pane=$(tmux split-window -h -t "$tail_pane" -c "$PROJECT_ROOT" -P -F '#{pane_id}')
    tmux send-keys -t "$script_pane" "./.claude/scripts/mefisto-tooling-pipeline.sh $issue" Enter

    tmux select-layout -t "$session:main" even-horizontal

    success "Pipeline mefisto-tooling iniciado para issue #$issue"
    print_connect_hint "$session"
}

cmd_batch() {
    local issues=("$@")

    if [ ${#issues[@]} -eq 0 ]; then
        abort "Debes especificar al menos un issue. Uso: --batch 42 43 44"
    fi

    local session
    session=$(safe_session_name "mefisto-batch-$(date +%H%M%S)")
    local issues_str="${issues[*]}"

    check_tmux
    ensure_events_log

    if session_exists "$session"; then
        warn "Ya existe una sesion '$session'."
        print_connect_hint "$session"
        exit 0
    fi

    log "Creando sesion tmux '$session' para batch interno: issues ${issues_str}..."

    # Patron pane_id (no indices implicitos) para evitar el bug de pane-base-index
    # que motivo el commit 6a6b978.
    local tail_pane script_pane
    tmux new-session -d -s "$session" -n "main" -c "$PROJECT_ROOT"
    tail_pane=$(tmux list-panes -t "$session:main" -F '#{pane_id}' | head -n1)
    tmux set-option -t "$session" remain-on-exit on
    tmux send-keys -t "$tail_pane" "tail -f '$EVENTS_LOG'" Enter

    script_pane=$(tmux split-window -h -t "$tail_pane" -c "$PROJECT_ROOT" -P -F '#{pane_id}')
    tmux send-keys -t "$script_pane" "./.claude/scripts/mefisto-batch-pipeline.sh $issues_str" Enter

    tmux select-layout -t "$session:main" even-horizontal

    success "Batch pipeline interno iniciado: issues $issues_str"
    print_connect_hint "$session"
}

# --- Dispatcher ---
if [ $# -eq 0 ]; then
    echo "Uso: $0 --tooling <issue> | --batch <issue1> <issue2> ... | --attach [sesion]"
    exit 1
fi

case "$1" in
    --tooling)
        shift
        [ $# -lt 1 ] && abort "Falta el numero de issue"
        cmd_tooling "$1"
        ;;
    --batch)
        shift
        [ $# -lt 1 ] && abort "Debes especificar al menos un issue. Uso: --batch 42 43 44"
        cmd_batch "$@"
        ;;
    --attach)
        shift
        cmd_attach "${1:-}"
        ;;
    *)
        abort "Argumento no reconocido: $1"
        ;;
esac
