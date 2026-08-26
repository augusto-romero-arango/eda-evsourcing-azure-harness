#!/usr/bin/env bash
# mefisto-herdr-pipeline.sh --- Interfaz herdr de los pipelines INTERNOS de
# Mefisto (porte del publicado scripts/herdr-pipeline.sh, issue #690)
#
# Uso (misma superficie de modos que mefisto-tmux-pipeline.sh):
#   ./.claude/scripts/mefisto-herdr-pipeline.sh --tooling 42 [--from-stage N]
#   ./.claude/scripts/mefisto-herdr-pipeline.sh --batch 42 43 44
#
# En vez de crear una sesion tmux nueva con un pane de `tail -f events.log`,
# esta interfaz trabaja DENTRO del workspace herdr actual: reutiliza (o crea
# con `herdr pane split`) un pane de ejecucion al lado del pane que despacha,
# corre el sub-pipeline en background con su reporte a un log, y muestra en
# el pane el visor en vivo (mefisto-stream-watch.sh, #434) que sigue al
# agente en curso -- un solo pane para toda la secuencia de agentes del
# issue. Al terminar (o si el pipeline muere antes de escribir traza) el
# pane muestra el reporte final.
#
# --verbose se acepta y se consume sin efecto: en herdr el visor es siempre
# visible (era el opt-in del modo tmux, issue #435). --if-exists tampoco
# aplica (era de las sesiones tmux): una corrida concurrente abre un pane
# adicional y los panes libres se reutilizan, con la misma deteccion que el
# publicado (`herdr pane process-info`: foreground_process_group_id ==
# shell_pid).
#
# Requiere correr dentro de un pane herdr (HERDR_ENV=1): la autodeteccion
# vive en mefisto-tmux-pipeline.sh, que delega aqui cuando aplica y sigue
# con tmux cuando no (escape hatch: MEFISTO_UI=tmux).
#
# Solo se ejecuta dentro del repo de Mefisto (assert_in_mefisto).

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
LOG_DIR_ABS="$PROJECT_ROOT/.claude/pipeline/logs"
# Registro de panes de ejecucion creados por esta interfaz (uno por linea,
# ids publicos de herdr como "w1:p3"). Vive en .claude/pipeline/ como el
# resto del estado runtime.
PANES_STATE="$PROJECT_ROOT/.claude/pipeline/herdr-report-panes.txt"

# Los mensajes de progreso van a stderr: acquire_report_pane devuelve su
# resultado por stdout y un log colado ahi corromperia el valor capturado.
log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1" >&2; }
success() { echo -e "${GREEN}${BOLD}v${NC} $1" >&2; }
warn()    { echo -e "${YELLOW}!${NC} $1" >&2; }
abort()   { echo -e "\n${RED}${BOLD}x $1${NC}" >&2; exit 1; }

# --- Guard de contexto herdr ---
require_herdr_context() {
    command -v herdr &>/dev/null \
        || abort "herdr no esta instalado (https://herdr.dev). Fuera de herdr usa: mefisto-tmux-pipeline.sh"
    [ "${HERDR_ENV:-}" = "1" ] \
        || abort "No estas dentro de un pane de herdr (HERDR_ENV != 1). Fuera de herdr usa: mefisto-tmux-pipeline.sh"
    [ -n "${HERDR_PANE_ID:-}" ] && [ -n "${HERDR_WORKSPACE_ID:-}" ] \
        || abort "Faltan HERDR_PANE_ID/HERDR_WORKSPACE_ID en el entorno (los inyecta herdr en cada pane)."
    command -v jq &>/dev/null \
        || abort "La interfaz herdr requiere jq para leer las respuestas del socket API. Instala jq o usa MEFISTO_UI=tmux."
}

# --- Helpers de panes (mismo contrato que scripts/herdr-pipeline.sh) ---

pane_exists() {
    herdr pane get "$1" >/dev/null 2>&1
}

# pane_is_free <pane_id>
#
# 0 si el pane esta en su prompt interactivo, sin comando en foreground.
# Cualquier fallo de consulta se trata como "no libre" (conservador: nunca
# se teclea sobre una corrida).
pane_is_free() {
    local id="$1"
    local info fg sh
    info=$(herdr pane process-info --pane "$id" 2>/dev/null) || return 1
    fg=$(echo "$info" | jq -r '.result.process_info.foreground_process_group_id // empty' 2>/dev/null)
    sh=$(echo "$info" | jq -r '.result.process_info.shell_pid // empty' 2>/dev/null)
    [ -n "$fg" ] && [ -n "$sh" ] && [ "$fg" = "$sh" ]
}

# acquire_report_pane
#
# Imprime por stdout el pane_id donde correr el proximo pipeline: el primer
# pane registrado que siga vivo, pertenezca a ESTE workspace y este libre; o
# uno nuevo (split a la derecha del pane que despacha, sin robar el foco).
# De paso poda del registro los panes que ya no existen.
acquire_report_pane() {
    mkdir -p "$(dirname "$PANES_STATE")"
    touch "$PANES_STATE"

    local kept="" chosen="" id
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        pane_exists "$id" || continue
        kept="${kept}${id}
"
        [ -n "$chosen" ] && continue
        case "$id" in
            "$HERDR_WORKSPACE_ID:"*) ;;
            *) continue ;;
        esac
        if pane_is_free "$id"; then
            chosen="$id"
        fi
    done < "$PANES_STATE"
    printf '%s' "$kept" > "$PANES_STATE"

    if [ -z "$chosen" ]; then
        local resp
        resp=$(herdr pane split --pane "$HERDR_PANE_ID" --direction right --cwd "$PROJECT_ROOT" --no-focus 2>&1) \
            || abort "No se pudo crear el pane de ejecucion (herdr pane split): $resp"
        chosen=$(echo "$resp" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
        [ -n "$chosen" ] || abort "herdr pane split no devolvio pane_id. Respuesta: $resp"
        echo "$chosen" >> "$PANES_STATE"
        log "Pane de ejecucion nuevo: $chosen"
    else
        log "Reusando el pane de ejecucion libre: $chosen"
    fi

    echo "$chosen"
}

# dispatch_to_pane <titulo> <issues_csv> <cmd> [args...]
#
# Consigue un pane libre y le teclea (herdr pane run) la invocacion del
# runner interno (--_pane-runner). Todo argumento va quoteado con printf %q:
# el pane run literalmente escribe la linea en el shell del pane.
dispatch_to_pane() {
    local title="$1" issues_csv="$2"
    shift 2

    local pane
    pane=$(acquire_report_pane)

    local cmdline
    cmdline="cd $(printf '%q' "$PROJECT_ROOT") && $(printf '%q' "$SCRIPT_DIR/mefisto-herdr-pipeline.sh") --_pane-runner --title $(printf '%q' "$title")"
    if [ -n "$issues_csv" ]; then
        cmdline="$cmdline --issues $(printf '%q' "$issues_csv")"
    fi
    cmdline="$cmdline --"
    local a
    for a in "$@"; do
        cmdline="$cmdline $(printf '%q' "$a")"
    done

    herdr pane run "$pane" "$cmdline" >/dev/null 2>&1 \
        || abort "No se pudo lanzar el pipeline en el pane $pane (herdr pane run fallo)."

    success "Pipeline '$title' corriendo en el pane $pane de este workspace."
    log "El pane muestra el visor en vivo del agente; el reporte completo queda en $LOG_DIR_ABS/."
    log "No hay sesion que adjuntar: el pane ya esta visible en el workspace (barra lateral de herdr)."
}

# --- Runner interno (corre DENTRO del pane de ejecucion) ---
#
# mefisto-herdr-pipeline.sh --_pane-runner --title <t> [--issues <csv>] -- <cmd> [args...]
#
# Mismo ciclo que el runner publicado: renombra el pane, lanza <cmd> en
# background con stdout+stderr al reporte, muestra el visor filtrado a los
# issues de ESTA corrida y a streams nacidos despues de ahora, y al terminar
# corta el visor, imprime el reporte y renombra el pane [ok]/[fallo].
cmd_pane_runner() {
    local title="" issues_csv=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --title)
                [ $# -lt 2 ] && abort "Falta el valor de --title"
                title="$2"; shift 2 ;;
            --issues)
                [ $# -lt 2 ] && abort "Falta el valor de --issues"
                issues_csv="$2"; shift 2 ;;
            --)
                shift; break ;;
            *)
                abort "Argumento no reconocido para --_pane-runner: $1" ;;
        esac
    done
    [ -n "$title" ] || abort "--_pane-runner requiere --title"
    [ $# -gt 0 ] || abort "--_pane-runner requiere un comando tras --"

    mkdir -p "$LOG_DIR_ABS"
    local ts report_log
    ts=$(date +%Y%m%d-%H%M%S)
    report_log="$LOG_DIR_ABS/mefisto-herdr-run-$ts-$$.report.log"

    if [ -n "${HERDR_PANE_ID:-}" ]; then
        herdr pane rename "$HERDR_PANE_ID" "$title" >/dev/null 2>&1 || true
    fi

    echo -e "${CYAN}${BOLD}=== $title ===${NC}"
    echo -e "${CYAN}Comando: $*${NC}"
    echo -e "${CYAN}Reporte: $report_log${NC}"
    echo ""

    local start_epoch
    start_epoch=$(date +%s)

    "$@" >"$report_log" 2>&1 &
    local pipe_pid=$!

    local viewer_pid=""
    if [ -n "$issues_csv" ]; then
        "$SCRIPT_DIR/mefisto-stream-watch.sh" --issues "$issues_csv" --newer-than "$start_epoch" &
    else
        "$SCRIPT_DIR/mefisto-stream-watch.sh" --newer-than "$start_epoch" &
    fi
    viewer_pid=$!

    # Ctrl+C en el pane ya llega a pipeline y visor (comparten el grupo de
    # foreground); el trap solo asegura la limpieza y deja constancia.
    trap '
        kill '"$pipe_pid"' 2>/dev/null || true
        kill '"$viewer_pid"' 2>/dev/null || true
        [ -n "${HERDR_PANE_ID:-}" ] && herdr pane rename "$HERDR_PANE_ID" "[cortado] '"$title"'" >/dev/null 2>&1 || true
        echo ""
        echo "Corrida interrumpida. Reporte parcial: '"$report_log"'"
        exit 130
    ' INT TERM

    local rc=0
    wait "$pipe_pid" || rc=$?
    trap - INT TERM

    kill "$viewer_pid" 2>/dev/null || true
    wait "$viewer_pid" 2>/dev/null || true

    echo ""
    if [ "$rc" -eq 0 ]; then
        echo -e "${GREEN}${BOLD}=== $title: pipeline terminado OK ===${NC}"
    else
        echo -e "${RED}${BOLD}=== $title: pipeline FALLO (exit $rc) ===${NC}"
    fi
    echo ""

    if [ -f "$report_log" ]; then
        local total_lines
        total_lines=$(wc -l < "$report_log" | tr -d ' ')
        if [ "$total_lines" -le 60 ]; then
            cat "$report_log"
        else
            echo -e "${YELLOW}(ultimas 40 lineas del reporte; completo en $report_log)${NC}"
            echo ""
            tail -n 40 "$report_log"
        fi
    else
        echo "(el pipeline no llego a escribir reporte)"
    fi

    if [ -n "${HERDR_PANE_ID:-}" ]; then
        if [ "$rc" -eq 0 ]; then
            herdr pane rename "$HERDR_PANE_ID" "[ok] $title" >/dev/null 2>&1 || true
        else
            herdr pane rename "$HERDR_PANE_ID" "[fallo] $title" >/dev/null 2>&1 || true
        fi
    fi

    return "$rc"
}

# --- Modos ---

cmd_tooling() {
    local issue="$1"
    local extra_args="${2:-}"
    # shellcheck disable=SC2086 -- extra_args es una lista de flags simples
    dispatch_to_pane "mefisto-tooling #$issue" "$issue" "$SCRIPT_DIR/mefisto-tooling-pipeline.sh" "$issue" $extra_args
}

cmd_batch() {
    local issues=("$@")
    local issues_csv
    issues_csv=$(IFS=','; echo "${issues[*]}")
    dispatch_to_pane "mefisto-batch ${issues_csv}" "$issues_csv" "$SCRIPT_DIR/mefisto-batch-pipeline.sh" "${issues[@]}"
}

print_usage() {
    echo "Uso: $0 --tooling <issue> [--from-stage N]"
    echo "     $0 --batch <issue1> <issue2> ..."
    echo ""
    echo "Interfaz herdr de los pipelines internos: en vez de una sesion tmux,"
    echo "reutiliza (o crea) un pane de ejecucion en el workspace herdr actual"
    echo "con el visor en vivo (mefisto-stream-watch.sh) del agente en curso."
    echo "--verbose se acepta sin efecto (el visor es siempre visible aqui);"
    echo "--if-exists no aplica (una corrida concurrente abre un pane adicional)."
    echo "Fuera de herdr usa mefisto-tmux-pipeline.sh, que autodetecta y delega"
    echo "aqui solo cuando aplica (escape hatch: MEFISTO_UI=tmux)."
}

# --- Dispatcher ---
if [ $# -eq 0 ]; then
    print_usage
    exit 1
fi

# El runner interno se despacha antes del pre-parseo: sus argumentos (--title,
# el comando tras --) no deben pasar por los filtros de flags de modos.
if [ "$1" = "--_pane-runner" ]; then
    shift
    cmd_pane_runner "$@"
    exit $?
fi

# Pre-parseo con el mismo contrato que extract_wrapper_flags del wrapper tmux:
# --verbose, --from-stage e --if-exists se consumen de cualquier posicion.
FROM_STAGE_EXTRA=""
REMAINING_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --verbose)
            # En herdr el visor es siempre visible: el flag del modo tmux
            # (issue #435) se consume sin efecto para que /mefisto-tooling-verbose
            # siga funcionando tal cual dentro de herdr.
            shift
            ;;
        --from-stage)
            [ $# -lt 2 ] && abort "Falta el valor de --from-stage"
            [[ "$2" =~ ^[0-9]+$ ]] || abort "--from-stage debe ser un numero entero (recibido: '$2')"
            FROM_STAGE_EXTRA="--from-stage $2"
            shift 2
            ;;
        --if-exists)
            [ $# -lt 2 ] && abort "Falta el valor de --if-exists"
            echo -e "${YELLOW}!${NC} --if-exists es de las sesiones tmux y no aplica en herdr (una corrida concurrente abre un pane adicional); se ignora." >&2
            shift 2
            ;;
        *)
            REMAINING_ARGS+=("$1")
            shift
            ;;
    esac
done
if [ ${#REMAINING_ARGS[@]} -gt 0 ]; then
    set -- "${REMAINING_ARGS[@]}"
else
    set --
fi

case "${1:-}" in
    --help|-h)
        print_usage
        ;;
    --attach)
        abort "En herdr no hay attach: los panes de ejecucion viven en el workspace de Mefisto. Abrilo desde la barra lateral de herdr (o corre 'herdr' para adjuntar al servidor)."
        ;;
    --tooling)
        shift
        require_herdr_context
        [ $# -lt 1 ] && abort "Falta el numero de issue. Uso: --tooling <issue> [--from-stage N]"
        cmd_tooling "$1" "$FROM_STAGE_EXTRA"
        ;;
    --batch)
        shift
        [ $# -lt 1 ] && abort "Debes especificar al menos un issue. Uso: --batch 42 43 44"
        [ -n "$FROM_STAGE_EXTRA" ] && abort "--from-stage no es valido con --batch (seria ambiguo sobre varios issues). Usa --tooling <issue> --from-stage N para un unico issue."
        require_herdr_context
        cmd_batch "$@"
        ;;
    "")
        print_usage
        exit 1
        ;;
    *)
        abort "Argumento no reconocido: $1"
        ;;
esac
