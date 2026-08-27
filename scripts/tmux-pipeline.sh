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
#   ./scripts/tmux-pipeline.sh 42 --from-stage 3         # retomar issue #42 desde Stage 3
#   ./scripts/tmux-pipeline.sh 42 --if-exists replace    # matar la sesion existente y arrancar limpio
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
# Nota: NO se descarta _REPO_TOP; se reusa mas abajo como PROJECT_ROOT (el repo
# objetivo del consumidor), distinto de SCRIPT_DIR (la ubicacion del plugin).

# --- Colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --if-exists (reuse|replace|abort), seteado en el pre-parseo de main() antes del
# dispatch de modo (CA-3/CA-4). Vacio = sin flag explicito: la decision se
# pregunta interactivamente si hay TTY, o se toma por un default seguro segun
# la sesion este viva o muerta si no lo hay (ver handle_session_conflict).
SESSION_IF_EXISTS=""

# SCRIPT_DIR: ubicacion de ESTE script (el plugin). Sirve para invocar otros
# sub-scripts del plugin (tdd/tooling/batch/parallel/iac/scaffold-pipeline.sh).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PROJECT_ROOT: repo objetivo del consumidor (git toplevel del cwd del usuario),
# donde se crean las sesiones tmux, los logs y events.log. NO se deriva de
# SCRIPT_DIR porque el plugin ya no vive dentro del repo del consumidor.
PROJECT_ROOT="$_REPO_TOP"
EVENTS_LOG="$PROJECT_ROOT/.claude/pipeline/events.log"

# Normaliza la ruta de sub-script devuelta por resolve_pipeline a una ruta
# absoluta dentro del plugin, para que el pane tmux la encuentre aunque su cwd
# sea el repo del consumidor. Usa basename, asi que es indiferente a si el
# resolver ya devuelve ruta absoluta (issue #289) o, en llamadores futuros,
# relativa.
plugin_script() {
    echo "$SCRIPT_DIR/$(basename "$1")"
}

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

# should_delegate_to_herdr <args...>
#
# 0 si esta invocacion debe correr por la interfaz herdr (issue #690):
# estamos dentro de un pane herdr (HERDR_ENV=1 + HERDR_PANE_ID inyectado),
# el binario esta en PATH, y el modo pedido tiene equivalente herdr --
# desde el issue #705 eso incluye --parallel (panes apilados por issue);
# solo --attach/--help son tmux-especificos. MEFISTO_UI=tmux es el escape
# hatch para forzar tmux desde dentro de herdr (y lo exporta
# herdr-pipeline.sh al delegar de vuelta, cortando el ciclo).
should_delegate_to_herdr() {
    [ "${MEFISTO_UI:-}" = "tmux" ] && return 1
    [ "${HERDR_ENV:-}" = "1" ] || return 1
    [ -n "${HERDR_PANE_ID:-}" ] || return 1
    command -v herdr &>/dev/null || return 1
    local a
    for a in "$@"; do
        case "$a" in
            --attach|--help|-h) return 1 ;;
        esac
    done
    return 0
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

# session_is_alive <session>
#
# Retorna 0 (verdadero) si al menos un pane de la sesion sigue con su proceso
# vivo. Retorna 1 (falso) si TODOS los panes estan "dead" -- remain-on-exit
# (activado en los seis modos) los mantiene abiertos tras terminar, asi que un
# pane muerto no es una corrida en curso (CA-4). Si no se puede consultar tmux
# se asume viva (conservador: nunca se reemplaza por error de consulta).
session_is_alive() {
    local session="$1"
    local dead_flags
    dead_flags=$(tmux list-panes -s -t "$session" -F '#{pane_dead}' 2>/dev/null)
    [ -n "$dead_flags" ] || return 0
    echo "$dead_flags" | grep -q '^0$'
}

# prompt_session_conflict <session> <alive:true|false>
#
# Pregunta interactivamente que hacer ante una sesion existente. El default
# (Enter sin escribir nada) depende de si la sesion esta viva o muerta (CA-4):
# reusar (attach) si esta viva, reemplazar si esta muerta -- son las decisiones
# opuestas correctas para cada caso. Solo se llama con stdin/stdout en TTY.
prompt_session_conflict() {
    local session="$1" alive="$2"
    local default_action="replace" default_label="reemplazar"
    local estado="terminada"
    if [ "$alive" = true ]; then
        default_action="reuse"
        default_label="reusar (attach)"
        estado="activa"
    fi
    echo "" >&2
    warn "Ya existe una sesion '$session' ($estado)." >&2
    echo -e "  ${BOLD}[r]${NC}eusar   -- attach a la sesion existente" >&2
    echo -e "  ${BOLD}[e]${NC}liminar -- kill-session y arrancar limpio" >&2
    echo -e "  ${BOLD}[a]${NC}bortar" >&2
    # `|| true`: sin el, un EOF (Ctrl+D) hace fallar a read y, bajo `set -e`,
    # mata el subshell de la sustitucion de comandos -- el script moriria sin
    # mensaje. Con el, un EOF cae en el default igual que un Enter vacio.
    local answer=""
    read -r -p "Elegi una opcion [r/e/a] (Enter = $default_label): " answer || true
    case "$answer" in
        r|R) echo "reuse" ;;
        e|E) echo "replace" ;;
        a|A) echo "abort" ;;
        *)   echo "$default_action" ;;
    esac
}

# handle_session_conflict <session>
#
# Si la sesion NO existe, no hace nada (retorna 0: el llamador crea una nueva).
# Si existe, resuelve la accion (reuse/replace/abort) por flag explicito
# (--if-exists), por prompt interactivo (con default segun CA-4), o por el
# default seguro sin TTY (CA-4: nunca destruir una corrida viva) -- y actua:
#   reuse   -> se conecta a la sesion si hay terminal (exec, no retorna): con
#              switch-client si ya estamos dentro de tmux, con attach si no. Sin
#              terminal (headless: un stage corriendo bajo claude -p) imprime el
#              hint de conexion y sale con exit 0, el mismo comportamiento que
#              antes de este issue -- nunca secuestra la vista de otra corrida.
#   replace -> mata la sesion existente y retorna 0 para que el llamador cree
#              la nueva limpia.
#   abort   -> termina con abort() (exit 1).
# Solo retorna (0) cuando el llamador debe proceder a crear la sesion.
handle_session_conflict() {
    local session="$1"
    session_exists "$session" || return 0

    local alive=false
    session_is_alive "$session" && alive=true

    local action="$SESSION_IF_EXISTS"
    if [ -z "$action" ]; then
        if [ -t 0 ] && [ -t 1 ]; then
            action=$(prompt_session_conflict "$session" "$alive")
        elif [ "$alive" = true ]; then
            action="reuse"
        else
            action="replace"
        fi
    fi

    case "$action" in
        reuse)
            if [ -t 1 ]; then
                # Ya dentro de tmux, `attach` falla ("sessions should be nested
                # with care, unset $TMUX to force"): switch-client es el comando
                # que mueve el cliente actual a otra sesion (man tmux,
                # switch-client). Sin esta rama, reusar una sesion desde el
                # propio tmux -CC de iTerm2 -- el flujo que recomienda
                # docs/tmux-cheatsheet.md -- terminaria en error.
                if inside_tmux; then
                    log "Reusando la sesion '$session' (switch-client)..."
                    exec tmux switch-client -t "$session"
                fi
                log "Reusando la sesion '$session' (attach)..."
                exec tmux attach -t "$session"
            fi
            warn "Ya existe una sesion '$session'."
            print_connect_hint "$session"
            exit 0
            ;;
        replace)
            log "Sesion '$session' se reemplaza ($([ "$alive" = true ] && echo "estaba activa" || echo "estaba terminada"))..."
            tmux kill-session -t "$session" 2>/dev/null || true
            return 0
            ;;
        abort)
            abort "Sesion '$session' ya existe. Usa --if-exists reuse (attach), --if-exists replace (recrear), o gestionala a mano: tmux attach -t $session / tmux kill-session -t $session"
            ;;
        *)
            abort "Valor invalido para --if-exists: '$action' (valores validos: reuse, replace, abort)"
            ;;
    esac
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
    # Ruta absoluta al sub-script del plugin (el pane corre con cwd=consumidor).
    resolved="$(plugin_script "$resolved")"

    local pipeline_name
    pipeline_name=$(basename "$resolved" .sh)
    local session
    session=$(safe_session_name "$pipeline_name-$issue")

    check_tmux
    ensure_events_log

    handle_session_conflict "$session"

    log "Creando sesion tmux '$session' para issue #$issue ($pipeline_name)..."

    # Crear sesion con ventana unica y panes lado a lado.
    # Se capturan los pane_id (formato %N) en vez de referenciar los panes por
    # indice implicito ("$session:main.1"): ese indice depende de pane-base-index,
    # que en muchas configuraciones de ~/.tmux.conf es 1 en vez de 0 y haria que
    # el sub-script se teclee dentro del pane del 'tail' (que ignora stdin) en
    # lugar de arrancar. El pane_id es estable e independiente de base-index.
    local tail_pane pipe_pane
    tmux new-session -d -s "$session" -n "main" -c "$PROJECT_ROOT"
    tail_pane=$(tmux list-panes -t "$session:main" -F '#{pane_id}' | head -n1)
    tmux set-option -t "$session" remain-on-exit on
    tmux send-keys -t "$tail_pane" "tail -f '$EVENTS_LOG'" Enter

    # Pane derecho: pipeline. La ruta del sub-script va entre comillas simples
    # por si el plugin esta instalado bajo una ruta con espacios (mismo criterio
    # que '$EVENTS_LOG').
    pipe_pane=$(tmux split-window -h -t "$tail_pane" -c "$PROJECT_ROOT" -P -F '#{pane_id}')
    tmux send-keys -t "$pipe_pane" "'$resolved' $issue $extra_args" Enter

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
    handle_session_conflict "$session"

    log "Creando sesion tmux '$session' para batch: issues ${issues_str}..."

    # Crear sesion con ventana unica y panes lado a lado.
    # Captura de pane_id (ver nota en cmd_single): el indice implicito
    # "$session:main.1" depende de pane-base-index y rompe el arranque cuando
    # esa opcion vale 1 en ~/.tmux.conf.
    local tail_pane pipe_pane
    tmux new-session -d -s "$session" -n "main" -c "$PROJECT_ROOT"
    tail_pane=$(tmux list-panes -t "$session:main" -F '#{pane_id}' | head -n1)
    tmux set-option -t "$session" remain-on-exit on
    tmux send-keys -t "$tail_pane" "tail -f '$EVENTS_LOG'" Enter

    # Pane derecho: batch pipeline
    pipe_pane=$(tmux split-window -h -t "$tail_pane" -c "$PROJECT_ROOT" -P -F '#{pane_id}')
    tmux send-keys -t "$pipe_pane" "'$SCRIPT_DIR/batch-pipeline.sh' $pipeline_flag $issues_str" Enter

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
    handle_session_conflict "$session"

    log "Creando sesion tmux '$session' para issues paralelos: $issues_str..."

    # Crear sesion con ventana unica y panes lado a lado.
    # Captura de pane_id (ver nota en cmd_single) para no depender de
    # pane-base-index al direccionar el pane del 'tail'.
    local tail_pane
    tmux new-session -d -s "$session" -n "main" -c "$PROJECT_ROOT"
    tail_pane=$(tmux list-panes -t "$session:main" -F '#{pane_id}' | head -n1)
    tmux set-option -t "$session" remain-on-exit on
    tmux send-keys -t "$tail_pane" "tail -f '$EVENTS_LOG'" Enter

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
        # Ruta absoluta al sub-script del plugin (el pane corre con cwd=consumidor).
        resolved_pipelines+=("$(plugin_script "$resolved")")
    done

    if [ ${#resolved_issues[@]} -eq 0 ]; then
        tmux kill-session -t "$session" 2>/dev/null
        abort "No hay issues validos para abrir en paralelo."
    fi

    # Un pane por issue (escalonado para evitar contencion de API).
    # Cada split-window devuelve su propio pane_id (-P -F '#{pane_id}') y el
    # sub-script se envia a ESE pane. Antes los send-keys apuntaban siempre a
    # "$session:main" (el pane del 'tail'), por lo que ningun pipeline paralelo
    # arrancaba, con cualquier valor de pane-base-index.
    local pipe_pane
    for i in "${!resolved_issues[@]}"; do
        pipe_pane=$(tmux split-window -h -t "$session:main" -c "$PROJECT_ROOT" -P -F '#{pane_id}')
        tmux send-keys -t "$pipe_pane" "'${resolved_pipelines[$i]}' ${resolved_issues[$i]}" Enter
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
        warn "Para limitar concurrencia usa: $SCRIPT_DIR/parallel-pipeline.sh $max_flag $issues_str"
    fi
}

# --- Modo TOOLING (un issue, pipeline sin TDD) ---
cmd_tooling() {
    local issue="$1"
    # extra_args: lo que se propaga al sub-script ("--from-stage N", "--models
    # 'agente=modelo[,...]'" y/o "--variant '<label>'", compuestos por el
    # dispatch de --tooling en main()). tooling-pipeline.sh acepta --from-stage
    # (rango 1-2, que valida el propio sub-script), --models (issue #708,
    # validado por parse_stage_models antes de crear el worktree) y --variant
    # (issue #710, validado por validate_variant_label antes de crear el
    # worktree): tragarselos aqui en silencio arrancaria de Stage 1 sobre un
    # worktree que ya tiene commits, o correria sin avisar que el override se
    # perdio.
    local extra_args="${2:-}"
    # variant_label: label crudo de --variant (issue #710, tercer argumento,
    # SEPARADO de extra_args): a diferencia de --from-stage/--models, este
    # nombre de sesion lo necesita para el sufijo -<label> (CA-2) sin volver a
    # parsear extra_args.
    local variant_label="${3:-}"
    local session
    session=$(safe_session_name "tooling-$issue")
    [ -n "$variant_label" ] && session=$(safe_session_name "tooling-$issue-$variant_label")

    check_tmux
    ensure_events_log

    handle_session_conflict "$session"

    log "Creando sesion tmux '$session' para tooling issue #$issue..."

    # Captura de pane_id (ver nota en cmd_single) para no depender de
    # pane-base-index al direccionar los panes.
    local tail_pane pipe_pane
    tmux new-session -d -s "$session" -n "main" -c "$PROJECT_ROOT"
    tail_pane=$(tmux list-panes -t "$session:main" -F '#{pane_id}' | head -n1)
    tmux set-option -t "$session" remain-on-exit on
    tmux send-keys -t "$tail_pane" "tail -f '$EVENTS_LOG'" Enter

    pipe_pane=$(tmux split-window -h -t "$tail_pane" -c "$PROJECT_ROOT" -P -F '#{pane_id}')
    tmux send-keys -t "$pipe_pane" "'$SCRIPT_DIR/tooling-pipeline.sh' $issue $extra_args" Enter

    tmux select-layout -t "$session:main" even-horizontal

    success "Pipeline tooling iniciado para issue #$issue"
    print_connect_hint "$session"
}

# --- Modo INFRA (un issue, pipeline IaC) ---
cmd_infra() {
    local issue="$1"
    # extra_args: idem cmd_tooling -- iac-pipeline.sh tambien acepta
    # --from-stage (rango 1-2 validado por el sub-script).
    local extra_args="${2:-}"
    local session
    session=$(safe_session_name "infra-$issue")

    check_tmux
    ensure_events_log

    handle_session_conflict "$session"

    log "Creando sesion tmux '$session' para infra issue #$issue..."

    # Captura de pane_id (ver nota en cmd_single) para no depender de
    # pane-base-index al direccionar los panes.
    local tail_pane pipe_pane
    tmux new-session -d -s "$session" -n "main" -c "$PROJECT_ROOT"
    tail_pane=$(tmux list-panes -t "$session:main" -F '#{pane_id}' | head -n1)
    tmux set-option -t "$session" remain-on-exit on
    tmux send-keys -t "$tail_pane" "tail -f '$EVENTS_LOG'" Enter

    pipe_pane=$(tmux split-window -h -t "$tail_pane" -c "$PROJECT_ROOT" -P -F '#{pane_id}')
    tmux send-keys -t "$pipe_pane" "'$SCRIPT_DIR/iac-pipeline.sh' $issue $extra_args" Enter

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

    handle_session_conflict "$session"

    local pipeline_args=""
    [ -n "$issue" ] && pipeline_args="$issue "
    pipeline_args="${pipeline_args}--domain $domain"

    log "Creando sesion tmux '$session' para scaffold del dominio '$domain'..."

    # Captura de pane_id (ver nota en cmd_single) para no depender de
    # pane-base-index al direccionar los panes.
    local tail_pane pipe_pane
    tmux new-session -d -s "$session" -n "main" -c "$PROJECT_ROOT"
    tail_pane=$(tmux list-panes -t "$session:main" -F '#{pane_id}' | head -n1)
    tmux set-option -t "$session" remain-on-exit on
    tmux send-keys -t "$tail_pane" "tail -f '$EVENTS_LOG'" Enter

    pipe_pane=$(tmux split-window -h -t "$tail_pane" -c "$PROJECT_ROOT" -P -F '#{pane_id}')
    tmux send-keys -t "$pipe_pane" "'$SCRIPT_DIR/scaffold-pipeline.sh' $pipeline_args" Enter

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
  ./scripts/tmux-pipeline.sh 42 --from-stage 3                    Retomar issue #42 desde Stage 3
  ./scripts/tmux-pipeline.sh --pipeline tooling 42                Forzar pipeline tooling
  ./scripts/tmux-pipeline.sh --tooling 42                         Issue de tooling (override explicito)
  ./scripts/tmux-pipeline.sh --tooling 42 --models 'reviewer=opus,writer=sonnet'  Modelo por stage (experimentos)
  ./scripts/tmux-pipeline.sh 42 --models 'reviewer=opus,test-writer=sonnet'      Idem, enrutando por label a tdd-pipeline.sh
  ./scripts/tmux-pipeline.sh --tooling 42 --variant experimento-a                Corrida paralela del mismo issue (sin PR, rama local)
  ./scripts/tmux-pipeline.sh --tooling 42 --variant a                           Dos variantes del mismo issue, cada una en su sesion tmux
  ./scripts/tmux-pipeline.sh --tooling 42 --variant b                           (lanzar ambos comandos, cada uno arranca en background)
  ./scripts/tmux-pipeline.sh --infra 42                           Issue de infraestructura (IaC)
  ./scripts/tmux-pipeline.sh --scaffold 42 --domain nombre        Scaffold de dominio
  ./scripts/tmux-pipeline.sh --scaffold --domain nombre           Scaffold sin issue
  ./scripts/tmux-pipeline.sh --batch 42 43 44                     Secuencial (enruta por label)
  ./scripts/tmux-pipeline.sh --batch --pipeline tooling 42 43     Secuencial forzando tooling
  ./scripts/tmux-pipeline.sh --parallel 42 43 44                  Paralelo (enruta por label)
  ./scripts/tmux-pipeline.sh --parallel --pipeline tdd 42 43      Paralelo forzando tdd
  ./scripts/tmux-pipeline.sh --attach                             Reconectar sesion tmux activa
  ./scripts/tmux-pipeline.sh --attach tdd-42                      Reconectar sesion especifica

${BOLD}Retomar una corrida caida (--from-stage):${NC}
  Valido en los modos de un unico issue: <issue> suelto, --tooling y --infra.
  Se rechaza (mensaje explicito, nunca silencio) en --batch, --parallel, varios
  issues sueltos --- un unico --from-stage sobre un lote seria ambiguo --- y en
  --scaffold/--attach, que no tienen stages retomables. El wrapper NO valida el
  rango: lo valida el sub-script destino (tdd-pipeline.sh acepta 1-4;
  tooling-pipeline.sh e iac-pipeline.sh, 1-2), para no desincronizarse con el
  la primera vez que un pipeline sume una fase.

${BOLD}Modelo por stage (--models, experimentos A/B de desempeno):${NC}
  Valido con --tooling y con el enrutamiento automatico de un unico issue
  (sea por label o por '--pipeline tdd|tooling <issue>' -- ambos overrides de
  resolve_pipeline() resuelven siempre a tdd-pipeline.sh o tooling-pipeline.sh):
  --models 'agente=modelo[,agente=modelo...]' sobreescribe el modelo de un
  stage puntual. La clave es el nombre de agente que recibe run_agent() en el
  sub-script destino:
    tooling-pipeline.sh: 'writer' (cubre Stage 1 y la etapa de merge, ambos
      invocados con ese mismo nombre) y 'reviewer' (Stage 2).
    tdd-pipeline.sh: 'test-writer'/'projection-test-writer' (Stage 1),
      'implementer'/'projection-implementer' (Stage 2, y la etapa de merge que
      SIEMPRE usa la clave 'implementer'), 'smoke-test-writer' (Stage 2b) y
      'reviewer' (Stage 3). Los dos sub-stages de remediacion del coverage gate
      (Stage 4) no pasan por run_agent, pero honran el mismo mapa con una clave
      fina propia -- 'patch-test-writer'/'patch-implementer' -- que, si no esta
      en el mapa, cae a la del agente que realmente relanzan (el del Stage 1 y
      el del Stage 2): asi '--models test-writer=X' cubre tambien su
      remediacion, y la clave fina existe solo para diferenciarla a proposito.
      El scaffold de dominio (Stage 0, domain-scaffolder) queda fuera del mapa
      -- no es un stage TDD.
  Sin entrada en el mapa, el stage usa su default de siempre (el frontmatter
  `model:` del agente en tdd-pipeline.sh; sonnet/opus hardcodeado en
  tooling-pipeline.sh). Se rechaza (mensaje explicito, nunca silencio) en
  --infra, --scaffold, --batch, --parallel y --attach, porque sus sub-scripts
  no implementan el flag o serian ambiguos sobre varios issues. Un --models
  malformado aborta ANTES de crear el worktree. Dentro de un pane herdr, esta
  invocacion delega en herdr-pipeline.sh, que reenvia --models con la misma
  superficie.

${BOLD}Corridas paralelas del mismo issue (--variant <label>):${NC}
  Solo valido con --tooling (tooling-pipeline.sh implementa el flag; --infra,
  --scaffold, --batch, --parallel, --attach y el enrutamiento automatico de un
  unico issue lo rechazan con mensaje explicito -- el ultimo porque podria
  resolver a tdd-pipeline.sh, que no lo implementa). Corre el MISMO issue N
  veces en paralelo, cada corrida en su propio worktree/rama/sesion tmux con el
  sufijo -<label> (slug [a-z0-9-], hasta 40 caracteres): dos corridas
  simultaneas del mismo issue sin --variant colisionarian worktree y rama.
  En modo variante el pipeline NO hace push, NO abre PR y NO comenta el issue
  -- la rama queda LOCAL. Se combina con --models para comparar modelo por
  variante (una variante sin --models es la corrida de control):
    tmux-pipeline.sh --tooling 42 --variant a --models 'writer=sonnet'
    tmux-pipeline.sh --tooling 42 --variant b --models 'writer=opus'
  Si una variante gana la comparacion, se promueve a mano (push + gh pr create
  sobre esa rama) o relanzando el pipeline sin --variant.

${BOLD}Sesion existente (--if-exists reuse|replace|abort):${NC}
  Si ya existe una sesion con ese nombre, el wrapper distingue si sigue viva o
  ya termino (remain-on-exit deja el pane abierto tras un crash, pero el
  proceso ya no corre) y ofrece reusarla (attach), reemplazarla (kill-session y
  arrancar limpio) o abortar. Con terminal interactiva se pregunta (default:
  reusar si esta viva, reemplazar si esta muerta); sin terminal la decision se
  toma por --if-exists, o por ese mismo default si no se paso el flag -- nunca
  se destruye una sesion viva sin pedirlo explicitamente.

${BOLD}Enrutamiento automatico:${NC}
  Sin --pipeline ni --tooling/--infra, el pipeline se determina por el label tipo:* del issue:
    tipo:feature|refactor|projection -> tdd-pipeline.sh
    tipo:tooling                     -> tooling-pipeline.sh
    tipo:infra                       -> SKIP (usar --infra explicitamente)

  Con --parallel, dos issues tipo:projection nunca corren a la vez: comparten los
  archivos del worker de proyecciones del BC, asi que se serializan entre si.

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

    # Autodeteccion herdr (issue #690): dentro de un pane herdr, los modos
    # con equivalente se despachan a la interfaz herdr (pane de ejecucion en
    # el workspace actual, sin sesion tmux); fuera de herdr, o para
    # --attach, todo sigue igual que siempre.
    if should_delegate_to_herdr "$@"; then
        exec "$SCRIPT_DIR/herdr-pipeline.sh" "$@"
    fi

    # Pre-parsear --scaffold-domain, --pipeline, --from-stage y --if-exists
    # antes del dispatch de modo. --from-stage y --if-exists se sacan de
    # filtered_args igual que los otros dos: si quedaran, "253 --from-stage 4"
    # se veria como 3 argumentos posicionales y el caso [0-9]* (mas abajo)
    # desviaria a cmd_parallel (issue #449, causa 2).
    local scaffold_extra=""
    local pipeline_override=""
    local from_stage_extra=""
    local models_extra=""
    local variant_extra=""
    local variant_label_raw=""
    SESSION_IF_EXISTS=""
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
            --from-stage)
                [ $# -lt 2 ] && abort "Falta el valor de --from-stage"
                [[ "$2" =~ ^[0-9]+$ ]] || abort "--from-stage debe ser un numero entero (recibido: '$2')"
                from_stage_extra="--from-stage $2"
                shift 2
                ;;
            --models)
                # Sin pre-parsear aqui, --models caeria en filtered_args y el
                # dispatch de --tooling (que solo reenvia "$1" + from_stage_extra
                # a cmd_tooling) lo descartaria en silencio (issue #708). Las
                # comillas simples protegen el valor (puede traer '[' / ']' de un
                # id de modelo completo, p. ej. claude-opus-5[1m]) de que el shell
                # que interpreta el send-keys de tmux lo tome como un glob.
                [ $# -lt 2 ] && abort "Falta el valor de --models"
                models_extra="--models '$2'"
                shift 2
                ;;
            --variant)
                # Mismo criterio que --models arriba: sin pre-parsear aqui,
                # --variant caeria en filtered_args y el dispatch de --tooling
                # (que solo reenvia "$1" + extras conocidos) lo descartaria en
                # silencio (issue #710). variant_label_raw (sin comillas) es
                # lo que usa cmd_tooling para el sufijo del nombre de sesion
                # (CA-2); variant_extra (con comillas) es lo que viaja al
                # send-keys, igual que models_extra.
                [ $# -lt 2 ] && abort "Falta el valor de --variant"
                variant_label_raw="$2"
                variant_extra="--variant '$2'"
                shift 2
                ;;
            --if-exists)
                [ $# -lt 2 ] && abort "Falta el valor de --if-exists (reuse|replace|abort)"
                case "$2" in
                    reuse|replace|abort) SESSION_IF_EXISTS="$2" ;;
                    *) abort "--if-exists debe ser reuse, replace o abort (recibido: '$2')" ;;
                esac
                shift 2
                ;;
            *)
                filtered_args+=("$1")
                shift
                ;;
        esac
    done
    # Guarda de bash 3.2 (macOS): "${arr[@]}" con un array vacio revienta con
    # "unbound variable" bajo `set -u`. Sin ella, invocar solo flags
    # ("--from-stage 4" sin numero de issue) moria con un error interno de bash
    # en vez de con el mensaje de uso.
    if [ ${#filtered_args[@]} -gt 0 ]; then
        set -- "${filtered_args[@]}"
    else
        abort "Faltan argumentos posicionales (numero de issue o modo). Corre '$0 --help' para ver el uso."
    fi

    case "$1" in
        --help|-h)
            cmd_help
            ;;
        --attach)
            shift
            # --attach solo reconecta a una sesion ya creada: no lanza pipeline,
            # asi que no hay a quien propagarle --from-stage/--models.
            [ -n "$from_stage_extra" ] && abort "--from-stage no aplica a --attach (no lanza un pipeline, solo reconecta). Para retomar: tmux-pipeline.sh <issue> --from-stage N"
            [ -n "$models_extra" ] && abort "--models no aplica a --attach (no lanza un pipeline, solo reconecta). Para usarlo: tmux-pipeline.sh --tooling <issue> --models 'agente=modelo'"
            [ -n "$variant_extra" ] && abort "--variant no aplica a --attach (no lanza un pipeline, solo reconecta). Para usarlo: tmux-pipeline.sh --tooling <issue> --variant <label>"
            cmd_attach "${1:-}"
            ;;
        --tooling)
            shift
            if [ $# -eq 0 ]; then
                abort "Debes especificar un issue. Uso: --tooling 42"
            fi
            # Compone from_stage_extra + models_extra + variant_extra sin arrays
            # (bash 3.2 de macOS revienta con "unbound variable" al expandir un
            # array vacio bajo `set -u`) -- mismo patron que combined_extra mas
            # abajo.
            local tooling_extra="$from_stage_extra"
            if [ -n "$models_extra" ]; then
                if [ -n "$tooling_extra" ]; then
                    tooling_extra="$tooling_extra $models_extra"
                else
                    tooling_extra="$models_extra"
                fi
            fi
            if [ -n "$variant_extra" ]; then
                if [ -n "$tooling_extra" ]; then
                    tooling_extra="$tooling_extra $variant_extra"
                else
                    tooling_extra="$variant_extra"
                fi
            fi
            cmd_tooling "$1" "$tooling_extra" "$variant_label_raw"
            ;;
        --infra)
            shift
            if [ $# -eq 0 ]; then
                abort "Debes especificar un issue. Uso: --infra 42"
            fi
            # iac-pipeline.sh todavia no implementa --models ni --variant
            # (issues #708/#712 cubren tooling-pipeline.sh y tdd-pipeline.sh; el
            # #710 solo tooling-pipeline.sh, ninguno toca iac-pipeline.sh):
            # rechazar en vez de tragarselo en silencio.
            [ -n "$models_extra" ] && abort "--models todavia no es valido con --infra (iac-pipeline.sh no implementa el flag). Usalo con --tooling o un issue TDD: tmux-pipeline.sh --tooling <issue> --models 'agente=modelo'"
            [ -n "$variant_extra" ] && abort "--variant todavia no es valido con --infra (iac-pipeline.sh no implementa el flag). Usalo con --tooling: tmux-pipeline.sh --tooling <issue> --variant <label>"
            cmd_infra "$1" "$from_stage_extra"
            ;;
        --scaffold)
            shift
            # scaffold-pipeline.sh no acepta --from-stage ni --models (verificado):
            # no tiene stages retomables. Rechazar en vez de tragarselo en silencio.
            [ -n "$from_stage_extra" ] && abort "--from-stage no es valido con --scaffold (scaffold-pipeline.sh no tiene stages retomables)."
            [ -n "$models_extra" ] && abort "--models no es valido con --scaffold (scaffold-pipeline.sh no implementa el flag)."
            [ -n "$variant_extra" ] && abort "--variant no es valido con --scaffold (scaffold-pipeline.sh no implementa el flag)."
            cmd_scaffold "$@"
            ;;
        --batch)
            shift
            if [ $# -eq 0 ]; then
                abort "Debes especificar al menos un issue. Uso: --batch 42 43 44"
            fi
            # --from-stage sobre un lote de issues es ambiguo (Notas tecnicas del
            # issue #449): rechazar es la opcion segura.
            [ -n "$from_stage_extra" ] && abort "--from-stage no es valido con --batch (seria ambiguo sobre varios issues). Usalo con un unico issue: tmux-pipeline.sh <issue> --from-stage N"
            # Mismo criterio: --models por issue sobre un lote tambien seria
            # ambiguo, y hoy solo lo implementa tooling-pipeline.sh (issue #708).
            [ -n "$models_extra" ] && abort "--models no es valido con --batch (seria ambiguo sobre varios issues). Usalo con un unico issue: tmux-pipeline.sh --tooling <issue> --models 'agente=modelo'"
            # --variant es una corrida DE UN issue, N veces: tambien seria
            # ambiguo sobre un lote de issues distintos (issue #710).
            [ -n "$variant_extra" ] && abort "--variant no es valido con --batch (seria ambiguo sobre varios issues). Usalo con un unico issue: tmux-pipeline.sh --tooling <issue> --variant <label>"
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
            # Mismo rechazo que --batch: --from-stage no tiene sentido sobre
            # varios issues a la vez.
            [ -n "$from_stage_extra" ] && abort "--from-stage no es valido con --parallel (seria ambiguo sobre varios issues). Usalo con un unico issue: tmux-pipeline.sh <issue> --from-stage N"
            [ -n "$models_extra" ] && abort "--models no es valido con --parallel (seria ambiguo sobre varios issues). Usalo con un unico issue: tmux-pipeline.sh --tooling <issue> --models 'agente=modelo'"
            [ -n "$variant_extra" ] && abort "--variant no es valido con --parallel (seria ambiguo sobre varios issues). Usalo con un unico issue: tmux-pipeline.sh --tooling <issue> --variant <label>"
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
                # Multiples issues sin modo especificado: idem --batch/--parallel,
                # --from-stage/--models seria ambiguo sobre el lote resultante.
                [ -n "$from_stage_extra" ] && abort "--from-stage no es valido con multiples issues (se interpretaria como --parallel). Especifica un unico issue: tmux-pipeline.sh <issue> --from-stage N"
                [ -n "$models_extra" ] && abort "--models no es valido con multiples issues (se interpretaria como --parallel). Usa: tmux-pipeline.sh --tooling <issue> --models 'agente=modelo'"
                [ -n "$variant_extra" ] && abort "--variant no es valido con multiples issues (se interpretaria como --parallel). Usa: tmux-pipeline.sh --tooling <issue> --variant <label>"
                warn "Multiples issues sin modo especificado. Usando --parallel."
                if [ -n "$pipeline_override" ]; then
                    cmd_parallel --pipeline "$pipeline_override" "$@"
                else
                    cmd_parallel "$@"
                fi
            else
                # El enrutamiento automatico (sin --tooling explicito) resuelve
                # a tdd-pipeline.sh o tooling-pipeline.sh (los unicos overrides
                # validos de resolve_pipeline son "tdd"/"tooling"; tipo:infra
                # retorna SKIP antes de llegar a un sub-script) -- issue #712:
                # ambos ya implementan --models, asi que se reenvia sin rechazar.
                # Compone scaffold_extra + from_stage_extra + models_extra sin
                # arrays (bash 3.2 de macOS revienta con "unbound variable" al
                # expandir un array vacio incluso con "${arr[*]}" bajo `set -u`).
                local combined_extra="$scaffold_extra"
                if [ -n "$from_stage_extra" ]; then
                    if [ -n "$combined_extra" ]; then
                        combined_extra="$combined_extra $from_stage_extra"
                    else
                        combined_extra="$from_stage_extra"
                    fi
                fi
                if [ -n "$models_extra" ]; then
                    if [ -n "$combined_extra" ]; then
                        combined_extra="$combined_extra $models_extra"
                    else
                        combined_extra="$models_extra"
                    fi
                fi
                # --variant (issue #710) solo lo implementa tooling-pipeline.sh,
                # a diferencia de --models (que ya cubren ambos sub-scripts
                # desde el #712): el enrutamiento automatico podria resolver a
                # tdd-pipeline.sh, que no lo soporta. Rechazar en vez de
                # reenviarlo con el riesgo de que ahi se trague en silencio.
                [ -n "$variant_extra" ] && abort "--variant solo es valido con --tooling explicito (tooling-pipeline.sh implementa el flag; el enrutamiento automatico podria resolver a tdd-pipeline.sh, que no). Usa: tmux-pipeline.sh --tooling <issue> --variant <label>"
                cmd_single "$1" "$combined_extra" "$pipeline_override"
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
