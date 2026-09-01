#!/usr/bin/env bash
# herdr-pipeline.sh --- Interfaz herdr de los pipelines publicados (issue #690)
#
# Uso (misma superficie de modos que tmux-pipeline.sh):
#   herdr-pipeline.sh 42                          # issue unico (enruta por label)
#   herdr-pipeline.sh 42 --from-stage 3           # retomar desde Stage 3
#   herdr-pipeline.sh --pipeline tooling 42       # forzar pipeline
#   herdr-pipeline.sh --tooling 42                # tooling explicito
#   herdr-pipeline.sh --infra 42                  # IaC explicito
#   herdr-pipeline.sh --scaffold 42 --domain x    # scaffold de dominio
#   herdr-pipeline.sh --batch 42 43 44            # secuencial
#   herdr-pipeline.sh --parallel 42 43            # paralelo: un pane apilado por issue
#   herdr-pipeline.sh --collapse-panes            # poda paneles libres sobrantes sin despachar
#
# En vez de crear una sesion tmux nueva con un pane de `tail -f events.log`
# (que resulto innecesario), esta interfaz trabaja DENTRO del workspace herdr
# actual: reutiliza (o crea con `herdr pane split`) un pane de ejecucion al
# lado del pane que despacha, corre el sub-pipeline en background con su
# reporte a un log, y muestra en el pane el visor en vivo (stream-watch.sh)
# que sigue al agente en curso -- saltando solo de stream en stream a lo
# largo de la secuencia de agentes del issue, siempre en el MISMO pane. Al
# terminar (o si el pipeline muere antes de escribir traza: DoR invalido,
# worktree fallido...) el pane muestra el reporte final.
#
# Concurrencia: si el pane de ejecucion sigue ocupado con otra corrida, se
# abre un pane adicional (la misma concurrencia que daban las sesiones tmux
# separadas); los panes libres se reutilizan en despachos posteriores. La
# deteccion de "libre" es del lado de herdr: un shell interactivo sin comando
# en foreground (`herdr pane process-info`: foreground_process_group_id ==
# shell_pid). Cada visor filtra por sus issues (--issues de stream-watch.sh)
# para que dos corridas concurrentes no se crucen.
#
# Modo paralelo (issue #705): un pane por issue, apilados en la columna del
# pane de ejecucion -- el primer issue reutiliza/crea el pane de la derecha
# (acquire_report_pane, que ademas colapsa los libres sobrantes) y los demas
# son splits hacia abajo con alturas parejas (stack_split_ratio). Cada pane
# corre el runner con el visor de SU issue y un arranque escalonado
# (PARALLEL_STAGGER) que espera DENTRO del pane, no en quien despacha. Un
# lote con dos o mas issues tipo:projection se rechaza: comparten los
# archivos del worker de proyecciones (MEF-ADR-0034) y en modo pane no hay
# scheduler que los serialice (usa /sequential o parallel-pipeline.sh, cuyo
# scheduler si serializa).
#
# Este script requiere correr dentro de un pane herdr (HERDR_ENV=1): la
# autodeteccion vive en tmux-pipeline.sh, que delega aqui cuando aplica y
# sigue con tmux cuando no. Fuera de herdr, usa tmux-pipeline.sh directo.

set -euo pipefail

# --- Funciones compartidas (resolve_pipeline) ---
source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"

# Guard defensivo: este pipeline es del lado publicado y solo aplica al consumidor.
# Si detectamos .claude-plugin/plugin.json en la raiz, estamos en el repo de Mefisto.
_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$_REPO_TOP/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/herdr-pipeline.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Estas en el repo de Mefisto. Para trabajar issues del plugin usa los skills internos /mefisto-tooling o /mefisto-sequential." >&2
    exit 1
fi

# --- Colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# SCRIPT_DIR: ubicacion de ESTE script (el plugin), para invocar sub-scripts.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PROJECT_ROOT: repo objetivo del consumidor (git toplevel del cwd del usuario).
PROJECT_ROOT="$_REPO_TOP"
LOG_DIR_ABS="$PROJECT_ROOT/.claude/pipeline/logs"
# CAFF: prefijo "caffeinate -i" (o vacio fuera de macOS), calculado UNA vez
# por corrida y antepuesto al lanzamiento en background del sub-pipeline
# dentro de cmd_pane_runner -- issue #800. Evita que el Mac entre en
# suspension idle mientras el pane de ejecucion corre.
CAFF="$(caffeinate_prefix)"
# Registro de panes de ejecucion creados por esta interfaz en este repo (uno
# por linea, ids publicos de herdr como "w1:p3"). Vive en .claude/pipeline/
# como el resto del estado runtime: nunca viaja en un commit del consumidor.
PANES_STATE="$PROJECT_ROOT/.claude/pipeline/herdr-report-panes.txt"
# Segundos entre arranques de los issues de un lote --parallel: varios
# `claude -p` arrancando a la vez compiten por la API (mismo motivo que el
# sleep del modo tmux). La espera corre DENTRO de cada pane (--delay del
# runner), asi el despacho devuelve el control de inmediato.
PARALLEL_STAGGER=30

# Los mensajes de progreso van a stderr: varios helpers de este script
# devuelven su resultado por stdout (acquire_report_pane) y un log colado ahi
# corromperia el valor capturado.
log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1" >&2; }
success() { echo -e "${GREEN}${BOLD}v${NC} $1" >&2; }
warn()    { echo -e "${YELLOW}!${NC} $1" >&2; }
abort()   { echo -e "\n${RED}${BOLD}x $1${NC}" >&2; exit 1; }

# Normaliza la ruta de sub-script devuelta por resolve_pipeline a una ruta
# absoluta dentro del plugin (mismo criterio que tmux-pipeline.sh).
plugin_script() {
    echo "$SCRIPT_DIR/$(basename "$1")"
}

# --- Guard de contexto herdr ---
require_herdr_context() {
    command -v herdr &>/dev/null \
        || abort "herdr no esta instalado (https://herdr.dev). Fuera de herdr usa: tmux-pipeline.sh"
    [ "${HERDR_ENV:-}" = "1" ] \
        || abort "No estas dentro de un pane de herdr (HERDR_ENV != 1). Fuera de herdr usa: tmux-pipeline.sh"
    [ -n "${HERDR_PANE_ID:-}" ] && [ -n "${HERDR_WORKSPACE_ID:-}" ] \
        || abort "Faltan HERDR_PANE_ID/HERDR_WORKSPACE_ID en el entorno (los inyecta herdr en cada pane)."
    command -v jq &>/dev/null \
        || abort "La interfaz herdr requiere jq para leer las respuestas del socket API. Instala jq (brew install jq) o usa MEFISTO_UI=tmux."
}

# --- Helpers de panes ---

# pane_exists <pane_id> -- 0 si el pane sigue vivo en el servidor.
pane_exists() {
    herdr pane get "$1" >/dev/null 2>&1
}

# pane_is_free <pane_id>
#
# 0 si el pane esta en su prompt interactivo, sin comando en foreground: el
# process-info de herdr reporta el shell mismo como grupo de foreground
# (foreground_process_group_id == shell_pid). Cualquier fallo de consulta se
# trata como "no libre" (conservador: nunca se teclea sobre una corrida).
pane_is_free() {
    local id="$1"
    local info fg sh
    info=$(herdr pane process-info --pane "$id" 2>/dev/null) || return 1
    fg=$(echo "$info" | jq -r '.result.process_info.foreground_process_group_id // empty' 2>/dev/null)
    sh=$(echo "$info" | jq -r '.result.process_info.shell_pid // empty' 2>/dev/null)
    [ -n "$fg" ] && [ -n "$sh" ] && [ "$fg" = "$sh" ]
}

# prune_report_panes
#
# Poda compartida por acquire_report_pane y --collapse-panes (issue #799):
# recorre PANES_STATE, quita los panes que ya no existen (cerrados a mano) y
# CIERRA los panes libres sobrantes de corridas concurrentes ya terminadas
# del PROPIO workspace, dejando vivo el primero que encuentra libre (no lo
# cierra: queda disponible para reutilizar). Nunca toca panes ocupados ni de
# otro workspace (el mismo repo abierto dos veces). Imprime por stdout dos
# lineas: el pane_id libre que quedo vivo (vacio si no habia ninguno) y la
# cantidad de panes cerrados.
prune_report_panes() {
    mkdir -p "$(dirname "$PANES_STATE")"
    touch "$PANES_STATE"

    local kept="" chosen="" id closed=0
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        pane_exists "$id" || continue
        case "$id" in
            "$HERDR_WORKSPACE_ID:"*) ;;
            *)
                kept="${kept}${id}
"
                continue ;;
        esac
        if pane_is_free "$id"; then
            if [ -z "$chosen" ]; then
                chosen="$id"
                kept="${kept}${id}
"
            elif herdr pane close "$id" >/dev/null 2>&1; then
                log "Pane sobrante de una corrida terminada cerrado: $id"
                closed=$((closed + 1))
            else
                kept="${kept}${id}
"
            fi
        else
            kept="${kept}${id}
"
        fi
    done < "$PANES_STATE"
    printf '%s' "$kept" > "$PANES_STATE"

    printf '%s\n%s\n' "$chosen" "$closed"
}

# acquire_report_pane
#
# Imprime por stdout el pane_id donde correr el proximo pipeline: el primer
# pane registrado que siga vivo, pertenezca a ESTE workspace y este libre (via
# prune_report_panes, que de paso cierra los libres sobrantes); o uno nuevo
# (split a la derecha del pane que despacha, sin robar el foco). El layout
# colapsa naturalmente de vuelta a UN solo pane de seguimiento, y despachar un
# issue nuevo "reemplaza" al pane del que termino en vez de acumular ventanas
# (el reporte de cada corrida pasada sigue en su .report.log).
acquire_report_pane() {
    local result chosen
    result=$(prune_report_panes)
    chosen=$(printf '%s' "$result" | sed -n '1p')

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

# stack_split_ratio <total> <k>
#
# Ratio del k-esimo split (1-indexado) al apilar <total> panes de alturas
# parejas en una columna partiendo siempre el pane inferior: 1/(total-k+1).
# En herdr el ratio de un split es la fraccion que conserva el pane ORIGINAL
# (el nodo `first` del arbol BSP, el de arriba en un split down; verificado
# en split_at/split_rect de src/layout.rs de herdr 0.8.2), asi que el pane
# que queda arriba conserva 1/total y el resto se sigue partiendo parejo.
# herdr acota el ratio a [0.1, 0.9] (valid_split_ratio): con 10+ issues los
# primeros panes quedan algo mas altos que 1/total -- cosmetico, sin manejo
# especial. Pura (sin herdr, sin estado) para poder testearla sola.
stack_split_ratio() {
    local total="$1" k="$2"
    awk -v t="$total" -v k="$k" 'BEGIN { printf "%.4f", 1 / (t - k + 1) }'
}

# build_pane_runner_cmdline <titulo> <issues_csv> <delay_s> <cmd> [args...]
#
# Imprime por stdout la linea que un pane debe ejecutar para correr el runner
# interno (--_pane-runner) con <cmd args...>. Todo argumento va quoteado con
# printf %q: el pane run literalmente escribe la linea en el shell del pane.
build_pane_runner_cmdline() {
    local title="$1" issues_csv="$2" delay="$3"
    shift 3

    local cmdline
    cmdline="cd $(printf '%q' "$PROJECT_ROOT") && $(printf '%q' "$SCRIPT_DIR/herdr-pipeline.sh") --_pane-runner --title $(printf '%q' "$title")"
    if [ -n "$issues_csv" ]; then
        cmdline="$cmdline --issues $(printf '%q' "$issues_csv")"
    fi
    if [ "$delay" -gt 0 ]; then
        cmdline="$cmdline --delay $delay"
    fi
    cmdline="$cmdline --"
    local a
    for a in "$@"; do
        cmdline="$cmdline $(printf '%q' "$a")"
    done
    echo "$cmdline"
}

# dispatch_to_pane <titulo> <issues_csv> <cmd> [args...]
#
# Consigue un pane libre y le teclea (herdr pane run) la invocacion del
# runner interno (--_pane-runner), que corre <cmd args...> en background con
# su reporte a un log y muestra el visor en primer plano.
dispatch_to_pane() {
    local title="$1" issues_csv="$2"
    shift 2

    local pane
    pane=$(acquire_report_pane)

    local cmdline
    cmdline=$(build_pane_runner_cmdline "$title" "$issues_csv" 0 "$@")

    herdr pane run "$pane" "$cmdline" >/dev/null 2>&1 \
        || abort "No se pudo lanzar el pipeline en el pane $pane (herdr pane run fallo)."

    success "Pipeline '$title' corriendo en el pane $pane de este workspace."
    log "El pane muestra el visor en vivo del agente; el reporte completo queda en $LOG_DIR_ABS/."
    log "No hay sesion que adjuntar: el pane ya esta visible en el workspace (barra lateral de herdr)."
}

# --- Runner interno (corre DENTRO del pane de ejecucion) ---
#
# herdr-pipeline.sh --_pane-runner --title <t> [--issues <csv>] [--delay <s>] -- <cmd> [args...]
#
# 1. Renombra el pane con el titulo de la corrida (visible en el borde/sidebar).
#    Con --delay (lotes --parallel) espera esos segundos, visible en el pane,
#    antes de lanzar: el escalonado no bloquea a quien despacha.
# 2. Lanza <cmd> en background con stdout+stderr al reporte (.report.log).
# 3. Muestra el visor en vivo filtrado a los issues de ESTA corrida y a
#    streams nacidos despues de ahora (--newer-than): sin traza previa ajena.
# 4. Cuando el pipeline termina, corta el visor e imprime el reporte final
#    (completo si es corto, la cola si es largo). Si el pipeline murio antes
#    de escribir traza alguna, ese reporte es lo primero util que se ve.
# 5. Renombra el pane a "[ok] ..."/"[fallo] ..." y devuelve el exit code del
#    pipeline; el shell del pane queda en su prompt, listo para reutilizarse.
cmd_pane_runner() {
    local title="" issues_csv="" delay=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --title)
                [ $# -lt 2 ] && abort "Falta el valor de --title"
                title="$2"; shift 2 ;;
            --issues)
                [ $# -lt 2 ] && abort "Falta el valor de --issues"
                issues_csv="$2"; shift 2 ;;
            --delay)
                [ $# -lt 2 ] && abort "Falta el valor de --delay"
                [[ "$2" =~ ^[0-9]+$ ]] || abort "--delay debe ser un entero de segundos (recibido: '$2')"
                delay="$2"; shift 2 ;;
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
    report_log="$LOG_DIR_ABS/herdr-run-$ts-$$.report.log"

    if [ -n "${HERDR_PANE_ID:-}" ]; then
        herdr pane rename "$HERDR_PANE_ID" "$title" >/dev/null 2>&1 || true
    fi

    # Reemplazo natural del pane reutilizado: limpia pantalla y scrollback de
    # la corrida anterior antes del banner (2J pantalla, 3J scrollback, H
    # cursor a origen). El reporte de la corrida vieja sigue en su .report.log.
    printf '\033[2J\033[3J\033[H'

    echo -e "${CYAN}${BOLD}=== $title ===${NC}"
    echo -e "${CYAN}Comando: $*${NC}"
    echo -e "${CYAN}Reporte: $report_log${NC}"
    echo ""

    # Arranque escalonado de los lotes --parallel. Espera ANTES de start_epoch
    # para que el visor (--newer-than) siga viendo el stream propio.
    if [ "$delay" -gt 0 ]; then
        echo -e "${YELLOW}Arranque escalonado: esperando ${delay}s antes de lanzar...${NC}"
        sleep "$delay"
    fi

    local start_epoch
    start_epoch=$(date +%s)

    # El pipeline y TODOS sus descendientes (agentes claude -p, gates que
    # corren los tests del repo) arrancan con las variables HERDR_* removidas:
    # con HERDR_ENV=1 heredado del pane, cualquier invocacion de
    # tmux-pipeline.sh a lo largo de la corrida (p. ej. las fixtures de
    # test-tmux-preparse.sh) autodetectaria herdr y crearia panes REALES en
    # el workspace del humano (visto en vivo: explosion de panes "[fallo]").
    # El runner conserva su propio entorno -- el rename final usa
    # HERDR_PANE_ID -- solo el hijo corre aislado. El array arranca con un
    # -u fijo para nunca expandirse vacio (bash 3.2 revienta con "unbound
    # variable" al expandir un array vacio bajo `set -u`).
    local env_unset=(-u HERDR_ENV)
    local v
    while IFS='=' read -r v _; do
        case "$v" in
            HERDR_*) env_unset+=(-u "$v") ;;
        esac
    done < <(env)

    # $CAFF se expande sin comillas a proposito (0 o 2 palabras, "caffeinate -i"):
    # antepone caffeinate como proceso padre del pipeline sin agregar una rama
    # if/else duplicada por cada valor posible del prefijo (issue #800).
    # shellcheck disable=SC2086
    $CAFF env "${env_unset[@]}" "$@" >"$report_log" 2>&1 &
    local pipe_pid=$!

    local viewer_pid=""
    if [ -n "$issues_csv" ]; then
        "$SCRIPT_DIR/stream-watch.sh" --issues "$issues_csv" --newer-than "$start_epoch" &
    else
        "$SCRIPT_DIR/stream-watch.sh" --newer-than "$start_epoch" &
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

# --- Modos (misma superficie que tmux-pipeline.sh) ---

cmd_single() {
    local issue="$1"
    local extra_args="${2:-}"
    local pipeline_override="${3:-}"
    # models: idem al parametro homonimo de cmd_tooling (issue #712) -- argumento
    # propio y entrecomillado, NO concatenado a extra_args, porque extra_args se
    # expande sin comillas mas abajo y un id de modelo completo como
    # 'claude-opus-5[1m]' es un patron glob valido que la pathname expansion
    # podria alterar. resolve_pipeline() solo devuelve tdd-pipeline.sh o
    # tooling-pipeline.sh aqui (los unicos overrides validos son "tdd"/"tooling";
    # tipo:infra ya aborto como SKIP arriba), y ambos implementan --models.
    local models="${4:-}"
    # variant: label crudo de --variant (issue #713), mismo criterio que
    # 'models' -- argumento propio, no concatenado a extra_args. resolve_pipeline()
    # solo devuelve tdd-pipeline.sh o tooling-pipeline.sh aqui, y desde este issue
    # ambos implementan --variant.
    local variant="${5:-}"

    local resolved
    resolved=$(resolve_pipeline "$issue" "$pipeline_override")
    if [[ "$resolved" == SKIP:* ]]; then
        local reason="${resolved#SKIP:}"
        abort "Issue #$issue no se puede enrutar a un pipeline ($reason)."
    fi
    resolved="$(plugin_script "$resolved")"

    local pipeline_name
    pipeline_name=$(basename "$resolved" .sh)
    local title="${pipeline_name%-pipeline} #$issue"
    [ -n "$variant" ] && title="${pipeline_name%-pipeline} #$issue ($variant)"

    if [ -n "$models" ] && [ -n "$variant" ]; then
        # shellcheck disable=SC2086
        dispatch_to_pane "$title" "$issue" "$resolved" "$issue" $extra_args --models "$models" --variant "$variant"
    elif [ -n "$models" ]; then
        # shellcheck disable=SC2086
        dispatch_to_pane "$title" "$issue" "$resolved" "$issue" $extra_args --models "$models"
    elif [ -n "$variant" ]; then
        # shellcheck disable=SC2086
        dispatch_to_pane "$title" "$issue" "$resolved" "$issue" $extra_args --variant "$variant"
    else
        # shellcheck disable=SC2086 -- extra_args es una lista de flags simples
        dispatch_to_pane "$title" "$issue" "$resolved" "$issue" $extra_args
    fi
}

cmd_tooling() {
    local issue="$1"
    local extra_args="${2:-}"
    # models: el valor crudo de --models (issue #708), como argumento propio y
    # entrecomillado -- NO concatenado a extra_args. extra_args se expande sin
    # comillas (lista de flags simples, p. ej. "--from-stage 2") y ahi un id de
    # modelo completo como 'claude-opus-5[1m]' es un patron glob valido que la
    # pathname expansion podria alterar. Como argumento propio llega intacto a
    # build_pane_runner_cmdline, que lo quotea con printf %q hacia el pane.
    local models="${3:-}"
    # variant: label crudo de --variant (issue #710), mismo criterio que
    # 'models' -- argumento propio, no concatenado a extra_args. Ademas
    # distingue el titulo del pane cuando hay variante (dos corridas del mismo
    # issue en panes separados, cada una identificable en la barra lateral).
    local variant="${4:-}"
    local title="tooling #$issue"
    [ -n "$variant" ] && title="tooling #$issue ($variant)"
    if [ -n "$models" ] && [ -n "$variant" ]; then
        # shellcheck disable=SC2086
        dispatch_to_pane "$title" "$issue" "$SCRIPT_DIR/tooling-pipeline.sh" "$issue" $extra_args --models "$models" --variant "$variant"
    elif [ -n "$models" ]; then
        # shellcheck disable=SC2086
        dispatch_to_pane "$title" "$issue" "$SCRIPT_DIR/tooling-pipeline.sh" "$issue" $extra_args --models "$models"
    elif [ -n "$variant" ]; then
        # shellcheck disable=SC2086
        dispatch_to_pane "$title" "$issue" "$SCRIPT_DIR/tooling-pipeline.sh" "$issue" $extra_args --variant "$variant"
    else
        # shellcheck disable=SC2086
        dispatch_to_pane "$title" "$issue" "$SCRIPT_DIR/tooling-pipeline.sh" "$issue" $extra_args
    fi
}

cmd_infra() {
    local issue="$1"
    local extra_args="${2:-}"
    # shellcheck disable=SC2086
    dispatch_to_pane "infra #$issue" "$issue" "$SCRIPT_DIR/iac-pipeline.sh" "$issue" $extra_args
}

cmd_scaffold() {
    local issue=""
    local domain=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)
                domain="$2"; shift 2 ;;
            --domain=*)
                domain="${1#*=}"; shift ;;
            [0-9]*)
                issue="$1"; shift ;;
            *)
                abort "Argumento desconocido para --scaffold: $1" ;;
        esac
    done

    [ -n "$domain" ] || abort "Falta --domain para --scaffold. Uso: --scaffold [issue] --domain nombre"

    # Normalizar dominio a kebab-case (acepta PascalCase, camelCase, snake_case)
    domain=$(echo "$domain" \
        | sed 's/_/-/g' \
        | sed 's/\([a-z0-9]\)\([A-Z]\)/\1-\2/g' \
        | tr '[:upper:]' '[:lower:]')

    local args=()
    [ -n "$issue" ] && args+=("$issue")
    args+=(--domain "$domain")

    dispatch_to_pane "scaffold $domain" "${issue:-}" "$SCRIPT_DIR/scaffold-pipeline.sh" "${args[@]}"
}

cmd_batch() {
    local pipeline_override=""
    local issues=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pipeline)
                pipeline_override="$2"; shift 2 ;;
            *)
                issues+=("$1"); shift ;;
        esac
    done

    if [ ${#issues[@]} -eq 0 ]; then
        abort "Debes especificar al menos un issue. Uso: --batch 42 43 44"
    fi

    local issues_csv
    issues_csv=$(IFS=','; echo "${issues[*]}")

    local args=()
    [ -n "$pipeline_override" ] && args+=(--pipeline "$pipeline_override")
    args+=("${issues[@]}")

    dispatch_to_pane "batch ${issues_csv}" "$issues_csv" "$SCRIPT_DIR/batch-pipeline.sh" "${args[@]}"
}

# --- Modo PARALELO (issue #705): un pane apilado por issue ---
#
# El primer issue reutiliza/crea el pane de ejecucion de la derecha; los demas
# se apilan con splits hacia abajo de alturas parejas. Cada pane corre el
# runner con el visor de SU issue; el escalonado (PARALLEL_STAGGER) espera
# dentro del pane via --delay, asi este despacho retorna de inmediato.
cmd_parallel() {
    local pipeline_override=""
    local issues=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pipeline)
                pipeline_override="$2"; shift 2 ;;
            --max-parallel)
                warn "--max-parallel no aplica en modo herdr (cada issue corre en su propio pane). Para limitar concurrencia usa parallel-pipeline.sh directo."
                shift 2 ;;
            --max-parallel=*)
                warn "--max-parallel no aplica en modo herdr (cada issue corre en su propio pane). Para limitar concurrencia usa parallel-pipeline.sh directo."
                shift ;;
            *)
                issues+=("$1"); shift ;;
        esac
    done

    if [ ${#issues[@]} -eq 0 ]; then
        abort "Debes especificar al menos un issue. Uso: --parallel 42 43 44"
    fi

    # Pre-resolver cada issue: estado + tipo:projection + pipeline en UNA sola
    # llamada gh (resolve_issue_facts). Los no OPEN o sin pipeline se saltan
    # con aviso, igual que el modo tmux y parallel-pipeline.sh.
    local resolved_issues=()
    local resolved_pipelines=()
    local projection_count=0
    local issue facts state rest is_projection resolved
    for issue in "${issues[@]}"; do
        if ! facts=$(resolve_issue_facts "$issue" "$pipeline_override"); then
            abort "Override de pipeline invalido: '$pipeline_override' (usa tdd|tooling)."
        fi
        state="${facts%%|*}"
        rest="${facts#*|}"
        is_projection="${rest%%|*}"
        resolved="${rest#*|}"

        if [ "$state" != "OPEN" ]; then
            warn "Issue #$issue esta $state --- saltando."
            continue
        fi
        if [[ "$resolved" == SKIP:* ]]; then
            warn "Issue #$issue saltado (${resolved#SKIP:}) --- no se abre pane."
            continue
        fi

        resolved_issues+=("$issue")
        resolved_pipelines+=("$(plugin_script "$resolved")")
        if [ "$is_projection" = "true" ]; then
            projection_count=$((projection_count + 1))
        fi
    done

    if [ ${#resolved_issues[@]} -eq 0 ]; then
        abort "No hay issues validos para procesar en paralelo."
    fi

    # Gate de projections: en modo pane no hay scheduler que las serialice y
    # todas comparten los archivos del worker de proyecciones del BC
    # (MEF-ADR-0034) -- dos a la vez producirian PRs pisandose entre si.
    if [ "$projection_count" -gt 1 ]; then
        abort "$projection_count issues tipo:projection en el lote: comparten el worker de proyecciones (MEF-ADR-0034) y en modo pane no se serializan entre si. Usa /sequential, o parallel-pipeline.sh directo (su scheduler si los serializa)."
    fi

    # Pane 1: el pane de ejecucion de la derecha (reutilizado o creado; los
    # libres sobrantes se colapsan ahi mismo, asi el apilado arranca de UNO).
    local panes=() prev
    prev=$(acquire_report_pane)
    panes+=("$prev")

    # Panes 2..N: apilados hacia abajo bajo el pane anterior, registrados en
    # PANES_STATE para heredar la reutilizacion/colapso post-corrida.
    local total=${#resolved_issues[@]}
    local k ratio resp pane
    for ((k = 1; k < total; k++)); do
        ratio=$(stack_split_ratio "$total" "$k")
        resp=$(herdr pane split --pane "$prev" --direction down --ratio "$ratio" --cwd "$PROJECT_ROOT" --no-focus 2>&1) \
            || abort "No se pudo crear el pane apilado $((k + 1))/$total (herdr pane split): $resp"
        pane=$(echo "$resp" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
        [ -n "$pane" ] || abort "herdr pane split no devolvio pane_id. Respuesta: $resp"
        echo "$pane" >> "$PANES_STATE"
        panes+=("$pane")
        prev="$pane"
    done

    local i pipeline_name title delay cmdline
    for i in "${!resolved_issues[@]}"; do
        issue="${resolved_issues[$i]}"
        pipeline_name=$(basename "${resolved_pipelines[$i]}" .sh)
        title="${pipeline_name%-pipeline} #$issue"
        delay=$((i * PARALLEL_STAGGER))

        cmdline=$(build_pane_runner_cmdline "$title" "$issue" "$delay" "${resolved_pipelines[$i]}" "$issue")
        herdr pane run "${panes[$i]}" "$cmdline" >/dev/null 2>&1 \
            || abort "No se pudo lanzar el issue #$issue en el pane ${panes[$i]} (herdr pane run fallo)."

        if [ "$delay" -gt 0 ]; then
            log "Issue #$issue -> pane ${panes[$i]} ($title, arranca en ${delay}s)"
        else
            log "Issue #$issue -> pane ${panes[$i]} ($title)"
        fi
    done

    success "Pipeline paralelo corriendo: $total pane(s) apilados en este workspace, uno por issue."
    log "Cada pane muestra el visor en vivo de su issue; los reportes quedan en $LOG_DIR_ABS/."
    log "Los PRs NO se mergean automaticamente: usa /merge <PR_NUM> al terminar."
}

# cmd_collapse_panes (issue #799)
#
# Poda del registro los paneles muertos y CIERRA los libres sobrantes del
# propio workspace (dejando uno vivo) sin despachar ni crear ningun pane --
# la mitad de acquire_report_pane que no crea pane nuevo, compartida via
# prune_report_panes (CA-4). Pensado para que /merge lo invoque al terminar
# un lote --parallel: deja los paneles del lote mergeado colapsados de vuelta
# a uno, igual que ocurriria al despachar el proximo issue.
#
# Imprime por stdout SOLO la cantidad de paneles cerrados (entero, "0" si no
# hubo ninguno). Seguro fuera de contexto (CA-2): sin herdr/jq instalados, sin
# HERDR_ENV=1, sin HERDR_PANE_ID/HERDR_WORKSPACE_ID o sin PANES_STATE previo,
# es un no-op que imprime "0" y sale 0 -- nunca aborta.
cmd_collapse_panes() {
    if [ "${HERDR_ENV:-}" != "1" ] \
        || [ -z "${HERDR_PANE_ID:-}" ] || [ -z "${HERDR_WORKSPACE_ID:-}" ] \
        || ! command -v herdr &>/dev/null || ! command -v jq &>/dev/null \
        || [ ! -f "$PANES_STATE" ]; then
        echo "0"
        return 0
    fi

    local result closed
    result=$(prune_report_panes)
    closed=$(printf '%s' "$result" | sed -n '2p')
    echo "${closed:-0}"
}

cmd_help() {
    cat <<EOF

${CYAN}${BOLD}herdr-pipeline.sh${NC} --- Interfaz herdr de los pipelines publicados

${BOLD}Uso (misma superficie que tmux-pipeline.sh):${NC}
  herdr-pipeline.sh 42                                   Issue unico (enruta por label)
  herdr-pipeline.sh 42 --from-stage 3                    Retomar issue #42 desde Stage 3
  herdr-pipeline.sh --pipeline tooling 42                Forzar pipeline tooling
  herdr-pipeline.sh --tooling 42                         Issue de tooling
  herdr-pipeline.sh --tooling 42 --models 'reviewer=opus'  Modelo por stage (experimentos)
  herdr-pipeline.sh 42 --models 'reviewer=opus,test-writer=sonnet'  Idem, enrutando por label a tdd-pipeline.sh
  herdr-pipeline.sh --tooling 42 --variant experimento-a Corrida paralela del mismo issue (sin PR, rama local)
  herdr-pipeline.sh 42 --variant a --models 'test-writer=sonnet'  Idem, enrutando por label a tdd-pipeline.sh
  herdr-pipeline.sh --infra 42                           Issue de infraestructura (IaC)
  herdr-pipeline.sh --scaffold 42 --domain nombre        Scaffold de dominio
  herdr-pipeline.sh --batch 42 43 44                     Secuencial
  herdr-pipeline.sh --parallel 42 43                     Paralelo: un pane apilado por issue
  herdr-pipeline.sh --collapse-panes                     Poda paneles libres sobrantes sin despachar (usado por /merge)

${BOLD}Que hace distinto de tmux-pipeline.sh:${NC}
  No crea sesiones tmux ni el pane de 'tail -f events.log'. Reutiliza (o
  crea) un pane de ejecucion en el workspace herdr actual: el pipeline corre
  en background con su reporte a un log y el pane muestra el visor en vivo
  (stream-watch.sh) del agente en curso, un solo pane para toda la secuencia
  de agentes del issue. Si el pane sigue ocupado con otra corrida, se abre
  un pane adicional; los libres se reutilizan.

  Con --parallel, cada issue corre en su propio pane apilado bajo el pane de
  ejecucion (alturas parejas, visor por issue, arranques escalonados de 30s
  dentro de cada pane). Un lote con dos o mas issues tipo:projection se
  rechaza: usa /sequential o parallel-pipeline.sh, que si los serializa.

${BOLD}Requisitos:${NC} correr dentro de un pane herdr (HERDR_ENV=1) y jq.
  Fuera de herdr usa tmux-pipeline.sh, que ademas autodetecta herdr y delega
  aqui solo cuando aplica (escape hatch: MEFISTO_UI=tmux).

EOF
}

# --- Entrypoint ---
main() {
    if [ $# -eq 0 ]; then
        cmd_help
        exit 0
    fi

    # El runner interno se despacha antes del pre-parseo: sus argumentos
    # (--title, el comando tras --) no deben pasar por los filtros de modos.
    if [ "$1" = "--_pane-runner" ]; then
        shift
        cmd_pane_runner "$@"
        exit $?
    fi

    # --collapse-panes (issue #799) tampoco pasa por el pre-parseo: no toma
    # argumentos posicionales y el pre-parseo aborta si no queda ninguno.
    if [ "$1" = "--collapse-panes" ]; then
        shift
        cmd_collapse_panes
        exit $?
    fi

    # Pre-parseo identico a tmux-pipeline.sh: --scaffold-domain, --pipeline,
    # --from-stage y --models se extraen de cualquier posicion; --if-exists (que
    # en tmux decide sobre la sesion existente) no tiene equivalente aqui -- el
    # conflicto de "ya hay una corrida" se resuelve con un pane adicional --
    # asi que se consume con un aviso en vez de romper la invocacion.
    local scaffold_extra=""
    local pipeline_override=""
    local from_stage_extra=""
    local models_spec=""
    local variant_spec=""
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
                # Sin este caso, --models caeria en filtered_args y el dispatch
                # de --tooling (que solo reenvia "$1") lo descartaria EN
                # SILENCIO: la corrida usaria los modelos default mientras el
                # operador cree que el override del experimento se aplico
                # (issue #708). A diferencia de tmux-pipeline.sh, aqui el valor
                # se guarda crudo: el pane no lo re-parsea con un shell, viaja
                # como argv quoteado con printf %q.
                [ $# -lt 2 ] && abort "Falta el valor de --models"
                models_spec="$2"
                shift 2
                ;;
            --variant)
                # Mismo criterio que --models arriba: sin este caso, --variant
                # caeria en filtered_args y el dispatch de --tooling (que solo
                # reenvia "$1" + los extras conocidos) lo descartaria EN
                # SILENCIO (issue #710).
                [ $# -lt 2 ] && abort "Falta el valor de --variant"
                variant_spec="$2"
                shift 2
                ;;
            --if-exists)
                [ $# -lt 2 ] && abort "Falta el valor de --if-exists"
                warn "--if-exists es de las sesiones tmux y no aplica en herdr (una corrida concurrente abre un pane adicional); se ignora."
                shift 2
                ;;
            *)
                filtered_args+=("$1")
                shift
                ;;
        esac
    done
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
            abort "En herdr no hay attach: los panes de ejecucion viven en el workspace del proyecto. Abrilo desde la barra lateral de herdr (o corre 'herdr' para adjuntar al servidor)."
            ;;
        --parallel)
            shift
            [ $# -eq 0 ] && abort "Debes especificar al menos un issue. Uso: --parallel 42 43 44"
            [ -n "$from_stage_extra" ] && abort "--from-stage no es valido con --parallel (seria ambiguo sobre varios issues). Usalo con un unico issue."
            [ -n "$models_spec" ] && abort "--models no es valido con --parallel (seria ambiguo sobre varios issues). Usalo con un unico issue: herdr-pipeline.sh --tooling <issue> --models 'agente=modelo'"
            [ -n "$variant_spec" ] && abort "--variant no es valido con --parallel (seria ambiguo sobre varios issues). Usalo con un unico issue: herdr-pipeline.sh --tooling <issue> --variant <label>"
            require_herdr_context
            if [ -n "$pipeline_override" ]; then
                cmd_parallel --pipeline "$pipeline_override" "$@"
            else
                cmd_parallel "$@"
            fi
            ;;
        --tooling)
            shift
            require_herdr_context
            [ $# -eq 0 ] && abort "Debes especificar un issue. Uso: --tooling 42"
            cmd_tooling "$1" "$from_stage_extra" "$models_spec" "$variant_spec"
            ;;
        --infra)
            shift
            [ -n "$models_spec" ] && abort "--models todavia no es valido con --infra (iac-pipeline.sh no implementa el flag). Usalo con --tooling: herdr-pipeline.sh --tooling <issue> --models 'agente=modelo'"
            [ -n "$variant_spec" ] && abort "--variant todavia no es valido con --infra (iac-pipeline.sh no implementa el flag). Usalo con --tooling: herdr-pipeline.sh --tooling <issue> --variant <label>"
            require_herdr_context
            [ $# -eq 0 ] && abort "Debes especificar un issue. Uso: --infra 42"
            cmd_infra "$1" "$from_stage_extra"
            ;;
        --scaffold)
            shift
            [ -n "$from_stage_extra" ] && abort "--from-stage no es valido con --scaffold (scaffold-pipeline.sh no tiene stages retomables)."
            [ -n "$models_spec" ] && abort "--models no es valido con --scaffold (scaffold-pipeline.sh no implementa el flag)."
            [ -n "$variant_spec" ] && abort "--variant no es valido con --scaffold (scaffold-pipeline.sh no implementa el flag)."
            require_herdr_context
            cmd_scaffold "$@"
            ;;
        --batch)
            shift
            [ $# -eq 0 ] && abort "Debes especificar al menos un issue. Uso: --batch 42 43 44"
            [ -n "$from_stage_extra" ] && abort "--from-stage no es valido con --batch (seria ambiguo sobre varios issues). Usalo con un unico issue."
            [ -n "$models_spec" ] && abort "--models no es valido con --batch (seria ambiguo sobre varios issues). Usalo con un unico issue: herdr-pipeline.sh --tooling <issue> --models 'agente=modelo'"
            [ -n "$variant_spec" ] && abort "--variant no es valido con --batch (seria ambiguo sobre varios issues). Usalo con un unico issue: herdr-pipeline.sh --tooling <issue> --variant <label>"
            require_herdr_context
            if [ -n "$pipeline_override" ]; then
                cmd_batch --pipeline "$pipeline_override" "$@"
            else
                cmd_batch "$@"
            fi
            ;;
        [0-9]*)
            if [ $# -gt 1 ]; then
                [ -n "$from_stage_extra" ] && abort "--from-stage no es valido con multiples issues (se interpretaria como --parallel). Especifica un unico issue."
                [ -n "$models_spec" ] && abort "--models no es valido con multiples issues (se interpretaria como --parallel). Usa: herdr-pipeline.sh --tooling <issue> --models 'agente=modelo'"
                [ -n "$variant_spec" ] && abort "--variant no es valido con multiples issues (se interpretaria como --parallel). Usa: herdr-pipeline.sh --tooling <issue> --variant <label>"
                warn "Multiples issues sin modo especificado. Usando --parallel."
                require_herdr_context
                if [ -n "$pipeline_override" ]; then
                    cmd_parallel --pipeline "$pipeline_override" "$@"
                else
                    cmd_parallel "$@"
                fi
            else
                # El enrutamiento automatico (sin --tooling explicito) resuelve
                # a tdd-pipeline.sh o tooling-pipeline.sh (issues #712/#713:
                # ambos ya implementan --models y --variant) -- mismo criterio
                # que tmux-pipeline.sh.
                require_herdr_context
                local combined_extra="$scaffold_extra"
                if [ -n "$from_stage_extra" ]; then
                    if [ -n "$combined_extra" ]; then
                        combined_extra="$combined_extra $from_stage_extra"
                    else
                        combined_extra="$from_stage_extra"
                    fi
                fi
                cmd_single "$1" "$combined_extra" "$pipeline_override" "$models_spec" "$variant_spec"
            fi
            ;;
        *)
            echo -e "${RED}Argumento desconocido: $1${NC}" >&2
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
