#!/usr/bin/env bash
# mefisto-tmux-pipeline.sh -- Wrapper tmux para los pipelines INTERNOS de Mefisto
#
# Uso:
#   ./.claude/scripts/mefisto-tmux-pipeline.sh --tooling 42
#   ./.claude/scripts/mefisto-tmux-pipeline.sh --tooling 42 --verbose
#   ./.claude/scripts/mefisto-tmux-pipeline.sh --batch 42 43 44   # secuencial
#   ./.claude/scripts/mefisto-tmux-pipeline.sh --batch 42 43 44 --verbose
#   ./.claude/scripts/mefisto-tmux-pipeline.sh --attach            # reconectar
#   ./.claude/scripts/mefisto-tmux-pipeline.sh --attach mefisto-tooling-42
#
# --verbose (issue #435, en cualquier posicion de los argumentos) suma un
# tercer pane con el visor en vivo mefisto-stream-watch.sh (#434). Es opt-in:
# sin el flag, la sesion queda byte por byte igual que siempre (dos panes).
# El visor tambien se puede lanzar a mano en cualquier momento sobre una
# corrida en curso -- con o sin este flag -- corriendo en otra terminal:
#   ./.claude/scripts/mefisto-stream-watch.sh
#
# Caveat del arranque con --verbose: el visor descubre el *.stream.jsonl mas
# reciente de .claude/pipeline/logs/ y el pane se abre ANTES de que el pipeline
# haya escrito el suyo (la traza del stage 1 nace recien cuando arranca el
# agente, tras crear el worktree y validar el DoR). Hasta entonces el visor
# muestra la traza de la corrida ANTERIOR -- su encabezado dice a que issue y
# stage pertenece -- y salta sola a la nueva en cuanto empieza a crecer.
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

# Extrae --verbose de "$@" (en cualquier posicion) y lo consume: nunca debe
# propagarse al pipeline invocado por send-keys (CA-2) -- critico en
# cmd_batch, que parsea issues_str posicionalmente. Deja el flag en la
# global VERBOSE (el literal true/false, que los call-sites comparan con
# `[ "$VERBOSE" = true ]` -- la convencion de booleanos del resto de los
# pipelines) y el resto de argumentos, en orden, en el array global
# REMAINING_ARGS.
VERBOSE=false
REMAINING_ARGS=()
extract_verbose_flag() {
    VERBOSE=false
    REMAINING_ARGS=()
    local arg
    for arg in "$@"; do
        if [ "$arg" = "--verbose" ]; then
            VERBOSE=true
        else
            REMAINING_ARGS+=("$arg")
        fi
    done
}

# Ayuda del wrapper (CA-6). Es la misma que ya se imprimia al invocar sin
# argumentos, extraida a una funcion para que --help/-h la muestre en vez de
# caer en "Argumento no reconocido" (mismo patron que cmd_help del wrapper
# publicado, scripts/tmux-pipeline.sh).
print_usage() {
    echo "Uso: $0 --tooling <issue> [--verbose] | --batch <issue1> <issue2> ... [--verbose] | --attach [sesion]"
    echo ""
    echo "  --verbose   Suma un pane con el visor en vivo (mefisto-stream-watch.sh,"
    echo "              issue #434). Opt-in: sin el flag la sesion no cambia."
    echo "              Al abrirse muestra la traza de la corrida ANTERIOR (con su"
    echo "              encabezado de issue/stage) hasta que la nueva empieza a"
    echo "              escribirse, y salta sola a ella."
    echo "              Es un flag de ESTE wrapper: /mefisto-tooling y"
    echo "              /mefisto-sequential todavia no lo reenvian, asi que para"
    echo "              usarlo hay que invocar el script a mano."
    echo "              El visor tambien se puede lanzar suelto, en cualquier"
    echo "              momento y sin este flag, sobre una corrida ya en curso:"
    echo "                ./.claude/scripts/mefisto-stream-watch.sh"
}

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
    extract_verbose_flag "$@"
    # Guarda de bash 3.2 (macOS): "${arr[@]}" con un array vacio revienta con
    # "unbound variable" bajo `set -u` -- de ahi el chequeo de longitud previo
    # en vez de expandir REMAINING_ARGS directo cuando podria estar vacio.
    if [ ${#REMAINING_ARGS[@]} -gt 0 ]; then
        set -- "${REMAINING_ARGS[@]}"
    else
        set --
    fi
    [ $# -lt 1 ] && abort "Falta el numero de issue. Uso: --tooling <issue> [--verbose]"
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
    local tail_pane script_pane watch_pane
    tmux new-session -d -s "$session" -n "main" -c "$PROJECT_ROOT"
    tail_pane=$(tmux list-panes -t "$session:main" -F '#{pane_id}' | head -n1)
    tmux set-option -t "$session" remain-on-exit on
    tmux send-keys -t "$tail_pane" "tail -f '$EVENTS_LOG'" Enter

    # El split -v (issue #435) se hace ANTES del -h, mientras tail_pane todavia
    # ocupa toda la ventana: asi el visor queda a lo ancho completo (abajo),
    # y tail_pane conserva el ancho completo para partirse en tail/script (arriba).
    if [ "$VERBOSE" = true ]; then
        watch_pane=$(tmux split-window -v -t "$tail_pane" -c "$PROJECT_ROOT" -P -F '#{pane_id}')
        tmux send-keys -t "$watch_pane" "./.claude/scripts/mefisto-stream-watch.sh" Enter
    fi

    script_pane=$(tmux split-window -h -t "$tail_pane" -c "$PROJECT_ROOT" -P -F '#{pane_id}')
    tmux send-keys -t "$script_pane" "./.claude/scripts/mefisto-tooling-pipeline.sh $issue" Enter

    # even-horizontal deshace el split -v de arriba (lo aplana a 3 columnas):
    # solo se aplica sin --verbose, donde nunca hubo split -v que preservar.
    if [ "$VERBOSE" != true ]; then
        tmux select-layout -t "$session:main" even-horizontal
    fi

    success "Pipeline mefisto-tooling iniciado para issue #$issue"
    print_connect_hint "$session"
}

cmd_batch() {
    # --verbose se extrae ANTES de construir issues_str (CA-2): cmd_batch lo
    # manda sin comillas por send-keys a mefisto-batch-pipeline.sh, que lo
    # parsea posicionalmente -- un --verbose colado ahi rompe ese parseo.
    extract_verbose_flag "$@"
    # Misma guarda de bash 3.2 que en cmd_tooling: no expandir REMAINING_ARGS
    # vacio directo, revienta con "unbound variable" bajo `set -u`.
    local issues=()
    if [ ${#REMAINING_ARGS[@]} -gt 0 ]; then
        issues=("${REMAINING_ARGS[@]}")
    fi

    if [ ${#issues[@]} -eq 0 ]; then
        abort "Debes especificar al menos un issue. Uso: --batch 42 43 44 [--verbose]"
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
    local tail_pane script_pane watch_pane
    tmux new-session -d -s "$session" -n "main" -c "$PROJECT_ROOT"
    tail_pane=$(tmux list-panes -t "$session:main" -F '#{pane_id}' | head -n1)
    tmux set-option -t "$session" remain-on-exit on
    tmux send-keys -t "$tail_pane" "tail -f '$EVENTS_LOG'" Enter

    # El split -v (issue #435) se hace ANTES del -h, mientras tail_pane todavia
    # ocupa toda la ventana: asi el visor queda a lo ancho completo (abajo),
    # y tail_pane conserva el ancho completo para partirse en tail/script (arriba).
    if [ "$VERBOSE" = true ]; then
        watch_pane=$(tmux split-window -v -t "$tail_pane" -c "$PROJECT_ROOT" -P -F '#{pane_id}')
        tmux send-keys -t "$watch_pane" "./.claude/scripts/mefisto-stream-watch.sh" Enter
    fi

    script_pane=$(tmux split-window -h -t "$tail_pane" -c "$PROJECT_ROOT" -P -F '#{pane_id}')
    tmux send-keys -t "$script_pane" "./.claude/scripts/mefisto-batch-pipeline.sh $issues_str" Enter

    # even-horizontal deshace el split -v de arriba (lo aplana a 3 columnas):
    # solo se aplica sin --verbose, donde nunca hubo split -v que preservar.
    if [ "$VERBOSE" != true ]; then
        tmux select-layout -t "$session:main" even-horizontal
    fi

    success "Batch pipeline interno iniciado: issues $issues_str"
    print_connect_hint "$session"
}

# --- Dispatcher ---
if [ $# -eq 0 ]; then
    print_usage
    exit 1
fi

case "$1" in
    --help|-h)
        print_usage
        ;;
    --tooling)
        shift
        cmd_tooling "$@"
        ;;
    --batch)
        shift
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
