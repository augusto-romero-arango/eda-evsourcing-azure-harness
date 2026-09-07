#!/usr/bin/env bash
# mefisto-batch-pipeline.sh -- Procesa issues internos de Mefisto secuencialmente
#
# Implementacion CANONICA (MEF-ADR-0049 decision 2, issue #870). El shim de
# compatibilidad .claude/scripts/mefisto-batch-pipeline.sh reenvia aqui via
# `exec` (plantilla documentada en src/internal/scripts/README.md); invocar
# por cualquiera de las dos rutas es equivalente.
#
# Uso:
#   src/internal/scripts/mefisto-batch-pipeline.sh 42 43 44
#   src/internal/scripts/mefisto-batch-pipeline.sh 42 43 --stop-on-error
#
# El runtime activo (MEFISTO_RUNTIME=claude|opencode) lo hereda del entorno
# (lo antepone el comando generado, issue #867) -- este script no expone un
# flag --runtime propio, solo verifica en la precondicion que el CLI del
# runtime resuelto (lib/mefisto-runtime.sh) este instalado (issue #870).
#
# MEFISTO_AGENT_TIMEOUT_SECONDS (timeout de watchdog por stage, default 1800 --
# issue #946) tambien viaja heredado a cada eslabon: este script no lo lee ni
# lo reenvia, lo valida el pipeline de tooling en cada corrida.
#
# Flujo por issue:
#   1. src/internal/scripts/mefisto-tooling-pipeline.sh <issue>
#   2. Extraer URL del PR del output
#   3. gh pr merge <num> --squash --delete-branch
#   4. Sync VERIFICADO: confirma que el commit de merge del PR llego a
#      origin/main (la base real de la que nace el SIGUIENTE worktree, issue
#      #66) y, aparte, intenta dejar main LOCAL fast-forwardeado para el
#      humano que sigue la corrida.
#
# Sincronizacion entre eslabones (fail-loud, ver issue #46 y #566):
#   Para que una cadena con dependencias funcione, cada eslabon se construye
#   sobre el merge del anterior. La garantia de correccion la da el commit de
#   merge confirmado en origin/main (paso 3 de sync_main_after_merge) MAS que
#   cada worktree del tooling-pipeline nace SIEMPRE de origin/main (issue #66,
#   `git worktree add ... origin/main` en mefisto-tooling-pipeline.sh) -- no de
#   la rama activa del repo. El motor
#   arranca en main/master solo para mantener main LOCAL comodo para el humano
#   entre eslabones, no porque el worktree parta de ahi; por eso el gate de
#   arranque, en vez de exigirlo, se auto-recupera cuando el arbol de trabajo
#   esta limpio y solo aborta cuando no puede (issue #726, ver
#   ensure_repo_on_base_branch).
#
#   Si el commit de merge NO llega a origin/main (paso 3), la cadena ABORTA:
#   el siguiente worktree naceria de un origin/main desactualizado. Si en
#   cambio solo falla dejar main LOCAL sincronizado (pasos 4-5 -- por ejemplo
#   porque otra sesion cambio la rama activa del repo principal mientras el
#   batch corria, una carrera real: ver issue #566), degrada a warning y
#   CONTINUA -- el siguiente worktree sigue naciendo de origin/main, que ya
#   esta al dia. Se elimino el viejo `git pull origin main || warn
#   (continuando)`: era best-effort y silenciaba el fallo de un paso critico;
#   este esquema en cambio distingue cual paso es critico y cual no.
#
# En Mefisto solo existe el pipeline de tooling, asi que no hay flag --pipeline
# ni enrutamiento por label.
#
# Compatible con bash 3.2+ (macOS nativo).

set -euo pipefail

# --- Funciones compartidas ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_mefisto-common.sh"
assert_in_mefisto || exit 1
source "$SCRIPT_DIR/lib/mefisto-runtime.sh"

# --- Colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Logging ---
# Estado neutral a runtime (MEF-ADR-0049, issue #870): la base ya no es la
# ruta legacy bajo .claude/ a secas -- MEFISTO_STATE_DIR (exportada por
# mefisto-state.sh, sourceada arriba via _mefisto-common.sh) resuelve
# ".mefisto/pipeline", el mismo canonico que mefisto_state_path usa para el
# caso sin <root> explicito (mismo criterio que mefisto-tooling-pipeline.sh).
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PIPELINE_DIR="$MEFISTO_STATE_DIR"
LOG_DIR="$PIPELINE_DIR/logs"
LOG_FILE="$LOG_DIR/mefisto-batch-$TIMESTAMP.log"

# events.log del pipeline de tooling (issue #969): un unico archivo,
# compartido por TODAS las corridas lanzadas desde este checkout (lo resuelve
# mefisto-tooling-pipeline.sh contra MEFISTO_STATE_DIR, no contra el worktree
# del issue) -- por eso el reporte de hold de mas abajo se apoya en un
# contador de lineas ya leidas por issue, nunca en descubrir "el" events.log
# de la corrida.
EVENTS_LOG_PATH="$PIPELINE_DIR/events.log"

_strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
_log_file()   { echo -e "$1" | _strip_ansi >> "$LOG_FILE_ABS"; }

log()     { local m="${BLUE}[$(date +%H:%M:%S)]${NC} $1"; echo -e "$m"; _log_file "$m"; }
success() { local m="${GREEN}${BOLD}v${NC} $1"; echo -e "$m"; _log_file "$m"; }
warn()    { local m="${YELLOW}!${NC} $1"; echo -e "$m"; _log_file "$m"; }
header()  { local m="\n${CYAN}${BOLD}-- $1 --${NC}"; echo -e "$m"; _log_file "$m"; }
abort() {
    echo -e "\n${RED}${BOLD}x ERROR FATAL: $1${NC}" | tee -a "$LOG_FILE_ABS"
    echo -e "${YELLOW}Revisa el log: $LOG_FILE_ABS${NC}"
    exit 1
}

# --- Status tracker (compatible bash 3.2, sin declare -A) ---
ISSUE_STATUS_NUMS=()
ISSUE_STATUS_VALUES=()
ISSUE_STATUS_PRS=()

set_status() {
    local issue="$1" val="$2"
    local i
    for i in "${!ISSUE_STATUS_NUMS[@]}"; do
        if [ "${ISSUE_STATUS_NUMS[$i]}" = "$issue" ]; then
            ISSUE_STATUS_VALUES[$i]="$val"
            return
        fi
    done
    ISSUE_STATUS_NUMS+=("$issue")
    ISSUE_STATUS_VALUES+=("$val")
    ISSUE_STATUS_PRS+=("")
}

get_status() {
    local issue="$1" i
    for i in "${!ISSUE_STATUS_NUMS[@]}"; do
        if [ "${ISSUE_STATUS_NUMS[$i]}" = "$issue" ]; then
            echo "${ISSUE_STATUS_VALUES[$i]}"
            return
        fi
    done
    echo "desconocido"
}

set_pr() {
    local issue="$1" pr="$2"
    local i
    for i in "${!ISSUE_STATUS_NUMS[@]}"; do
        if [ "${ISSUE_STATUS_NUMS[$i]}" = "$issue" ]; then
            ISSUE_STATUS_PRS[$i]="$pr"
            return
        fi
    done
    ISSUE_STATUS_NUMS+=("$issue")
    ISSUE_STATUS_VALUES+=("pendiente")
    ISSUE_STATUS_PRS+=("$pr")
}

get_pr() {
    local issue="$1" i
    for i in "${!ISSUE_STATUS_NUMS[@]}"; do
        if [ "${ISSUE_STATUS_NUMS[$i]}" = "$issue" ]; then
            echo "${ISSUE_STATUS_PRS[$i]:-""}"
            return
        fi
    done
    echo ""
}

# --- Fallo no fatal de un issue (continua el loop) ---
HAVE_ERRORS=false

# Condiciones que NO son un fallo del batch pero que el humano debe conocer al
# terminar (issue #566): hoy la unica es "el merge llego a origin/main pero main
# LOCAL quedo sin sincronizar". Se reporta aparte de HAVE_ERRORS para no
# contradecir la propia degradacion a warning con un exit 1 y un resumen que
# afirme que "algunos issues tuvieron errores" cuando ninguno lo tuvo.
HAVE_WARNINGS=false

# Tiempo total en espera (hold) de todo el batch (issue #969, CA-3): una
# espera por RATE_LIMIT/PROVIDER_UNAVAILABLE (issue #967) NUNCA suma aqui como
# fallo -- este contador es puramente informativo, nunca se lee en la logica
# de HAVE_ERRORS/FAILED/--stop-on-error (CA-1/CA-5).
BATCH_TOTAL_HOLD_SECONDS=0

# fmt_hold_duration <segundos>
#
# "Xm Ys" a partir de segundos enteros. Mismo formato que usa
# mefisto-tooling-pipeline.sh para su propio reporte de hold (issue #967),
# para que el numero se lea igual en el log del eslabon y en el resumen del
# batch.
fmt_hold_duration() {
    local secs="${1:-0}"
    echo "$((secs / 60))m $((secs % 60))s"
}

# hold_seconds_in_range <events_log> <from_line>
#
# Suma los segundos en espera (hold) registrados en <events_log> desde la
# linea <from_line>+1 hasta EOF. Cada linea "[hold]" (formato fijo por el
# issue #967: "[HH:MM:SS][hold] <FAMILIA>: esperando, proxima sonda HH:MM:SS
# (techo HH:MM)") ya trae, en su propio texto, la hora en que empezo esa
# siesta y la hora en que se reanudara -- la diferencia ES la duracion de ese
# ciclo de espera, sin necesidad de acceso al proceso del sub-pipeline (que ya
# termino cuando el batch llega a invocar esta funcion). Las lineas
# "[hold][resume]" (issue #968, mismo prefijo pero otro formato, sin "proxima
# sonda") no matchean el patron y se ignoran -- no representan tiempo de
# espera adicional, son eventos de la reanudacion de sesion DENTRO de un
# ciclo ya contado.
#
# Ambas horas son HH:MM:SS del MISMO dia (un solo ciclo nunca excede
# MEFISTO_HOLD_MAX_SECONDS, tipicamente minutos); si la resta da negativa
# (el ciclo cruzo medianoche) se suma un dia completo. Imprime el total en
# segundos por stdout; 0 si <events_log> no existe o no hay lineas "[hold]"
# en el rango. Nunca aborta (los tests corren esta funcion sola, sin `set -e`
# heredado del script completo).
hold_seconds_in_range() {
    local events_log="$1" from_line="$2"
    [ -f "$events_log" ] || { echo 0; return 0; }

    local total=0 line start_hms probe_hms start_epoch probe_epoch delta
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [[ "$line" =~ ^\[([0-9]{2}:[0-9]{2}:[0-9]{2})\]\[hold\]\ [^:]+:\ esperando,\ proxima\ sonda\ ([0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
            start_hms="${BASH_REMATCH[1]}"
            probe_hms="${BASH_REMATCH[2]}"
            start_epoch=$(date -j -f '%H:%M:%S' "$start_hms" +%s 2>/dev/null || date -d "$start_hms" +%s 2>/dev/null || echo "")
            probe_epoch=$(date -j -f '%H:%M:%S' "$probe_hms" +%s 2>/dev/null || date -d "$probe_hms" +%s 2>/dev/null || echo "")
            [ -z "$start_epoch" ] && continue
            [ -z "$probe_epoch" ] && continue
            delta=$(( probe_epoch - start_epoch ))
            [ "$delta" -lt 0 ] && delta=$(( delta + 86400 ))
            total=$(( total + delta ))
        fi
    done < <(tail -n "+$((from_line + 1))" "$events_log" 2>/dev/null)

    echo "$total"
}

# hold_note_suffix <segundos>
#
# " (espero Xm Ys en hold)" si <segundos> > 0, cadena vacia si no -- listo
# para concatenar al final de un mensaje de set_status/fail_issue sin alterar
# su prefijo ("completado"/"ERROR:"): CA-1 exige que una espera nunca convierta
# un desenlace real en fallo ni viceversa, asi que esto es siempre una nota
# ANEXA, nunca lo que decide el prefijo.
hold_note_suffix() {
    local secs="${1:-0}"
    [ "$secs" -gt 0 ] && echo " (espero $(fmt_hold_duration "$secs") en hold)"
    return 0
}

fail_issue() {
    local issue="$1" msg="$2"
    echo -e "\n${RED}${BOLD}x Issue #$issue: $msg${NC}" | tee -a "$LOG_FILE_ABS"
    set_status "$issue" "ERROR: $msg"
    HAVE_ERRORS=true
}

# --- Senal de parada suave del batch (issue #966) ---------------------------
# Un batch largo no se podia frenar sin matar el pane de tmux/herdr, dejando el
# eslabon en curso a medio pipeline (worktree colgado, PR sin abrir o sin
# mergear). La senal es un archivo de mera PRESENCIA (sin campos que parsear)
# que /mefisto-batch-stop escribe desde el checkout principal. Vive en
# .mefisto/pipeline/batch-stop -- fuera de .claude/ por construccion (MEF-ADR-0017:
# el estado interno ya vive ahi, MEF-ADR-0049) -- y nunca se commitea (.mefisto/
# esta en .gitignore).
#
# Se consulta en dos momentos (CA-1): antes de arrancar el primer eslabon, y
# despues del sync verificado de cada eslabon -- el unico punto seguro de la
# cadena, porque ahi el PR ya esta mergeado y origin/main ya incluye el merge.
# Un eslabon que fallo (pipeline/PR/merge) nunca llega a este segundo chequeo:
# su `continue` lo salta, asi que la senal no interrumpe una cadena que ya
# estaba fallando por otra razon -- solo el camino de exito la consulta.
BATCH_STOP_SIGNAL="$MEFISTO_STATE_DIR/batch-stop"

batch_stop_requested() {
    [ -f "$BATCH_STOP_SIGNAL" ]
}

# defer_from_index <indice-0-based>
#
# Consume la senal (CA-4: se borra para no envenenar la corrida siguiente) y
# marca "aplazado" (CA-2/CA-3) todos los issues de ISSUE_NUMS desde <indice> en
# adelante. Nunca toca HAVE_ERRORS/FAILED/--stop-on-error (CA-5: una parada
# solicitada no es un fallo del batch).
defer_from_index() {
    local from="$1" i
    rm -f "$BATCH_STOP_SIGNAL"
    for ((i = from; i < ${#ISSUE_NUMS[@]}; i++)); do
        set_status "${ISSUE_NUMS[$i]}" "aplazado (parada solicitada; no se proceso en esta corrida)"
    done
}

# --- Sync VERIFICADO de main entre eslabones (issue #46, corregido en #566) ---
# Tras mergear el PR de un eslabon, confirma que el commit de merge llego a
# origin/main (la base real del siguiente worktree, issue #66) y, aparte,
# intenta dejar main LOCAL fast-forwardeado para el humano que sigue la
# corrida. Reemplaza el viejo `git pull origin main || warn (continuando)`,
# que era best-effort y silenciaba el fallo de un paso critico.
#
# Los pasos 4 y 5 operan sobre la referencia $MAIN_BRANCH por NOMBRE, nunca
# sobre el HEAD del momento (issue #566, CA-1): si otra sesion cambio la rama
# activa del repo principal mientras el batch corria (carrera real -- ver
# notas tecnicas del issue), el resultado tiene que ser identico este HEAD
# donde este. `git merge --ff-only` solo es seguro cuando $MAIN_BRANCH sigue
# siendo la rama activa (mueve HEAD, que en ese caso ES $MAIN_BRANCH); si ya
# no lo es, usamos `git fetch origin main:$MAIN_BRANCH`, que git permite
# precisamente porque $MAIN_BRANCH NO esta checked out (git solo rechaza ese
# refspec cuando el destino es la rama activa -- por eso no sirve como
# reemplazo universal del merge, solo como alternativa para este caso).
#
# Args:   $1 = numero de PR ya mergeado
# Lee:    MAIN_BRANCH (rama base fijada por ensure_repo_on_base_branch AL ARRANQUE:
#         la activa si ya era main/master, o la auto-recuperada -- issue #726)
# Set:    MERGE_SHA_SYNCED = SHA del commit de merge, fijado en cuanto queda
#         confirmado en origin/main (paso 3). Queda vacio SOLO en el caso fatal
#         (return 2), de modo que el llamador pueda nombrar el commit tambien
#         cuando degrada a warning por el fallo de los pasos 4-5.
# Return: 0 si el sync (origin + main local) se completo.
#         1 si solo fallo dejar main LOCAL sincronizado (origin/main SI tiene
#           el merge -- no fatal para la cadena, issue #566 CA-3).
#         2 si el merge commit no se pudo confirmar en origin/main (fatal: el
#           siguiente worktree naceria de una base desactualizada).
sync_main_after_merge() {
    local pr_num="$1"
    local merge_sha="" attempt present=false
    local active_branch="" observed_branch=""
    MERGE_SHA_SYNCED=""

    # 1. SHA del commit de merge del PR (puede tardar en propagarse tras el merge).
    for attempt in 1 2 3; do
        merge_sha=$(gh pr view "$pr_num" --json mergeCommit -q '.mergeCommit.oid' 2>/dev/null || true)
        if [ -n "$merge_sha" ] && [ "$merge_sha" != "null" ]; then
            break
        fi
        sleep 2
    done
    if [ -z "$merge_sha" ] || [ "$merge_sha" = "null" ]; then
        warn "sync: no se pudo determinar el commit de merge del PR #$pr_num"
        return 2
    fi

    # 2. Traer origin/main (verificado).
    if ! git fetch origin main >>"$LOG_FILE_ABS" 2>&1; then
        warn "sync: git fetch origin main fallo"
        return 2
    fi

    # 3. Confirmar que el merge commit llego a origin/main (reintenta por lag
    #    del remoto). Esta es la garantia real de la cadena (issue #566): el
    #    siguiente worktree nace de origin/main, no de main local. Si esto
    #    falla, la cadena SI debe abortar (return 2 = fatal).
    for attempt in 1 2 3; do
        if git merge-base --is-ancestor "$merge_sha" origin/main 2>/dev/null; then
            present=true
            break
        fi
        sleep 2
        git fetch origin main >>"$LOG_FILE_ABS" 2>&1 || true
    done
    if [ "$present" != true ]; then
        warn "sync: el commit de merge $merge_sha del PR #$pr_num no aparece en origin/main"
        return 2
    fi

    # Desde aqui la correccion de la cadena ya esta garantizada: el siguiente
    # worktree nace de origin/main, que ya incluye este commit. Lo publicamos
    # ahora (no al final) para que el llamador pueda nombrarlo tambien en el
    # camino degradado (return 1), donde lo unico pendiente es main LOCAL.
    MERGE_SHA_SYNCED="$merge_sha"

    # 4. Fast-forward de $MAIN_BRANCH (por NOMBRE -- CA-1) a origin/main. Si la
    #    rama activa del repo ya no es $MAIN_BRANCH, lo detectamos y lo
    #    nombramos (CA-2) en vez de operar a ciegas sobre el HEAD del momento
    #    o culpar a una "divergencia" de main que no existe.
    active_branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$active_branch" != "$MAIN_BRANCH" ]; then
        warn "sync: la rama activa del repo cambio a '$active_branch' (se esperaba '$MAIN_BRANCH'); se actualiza '$MAIN_BRANCH' por nombre sin tocar la rama activa"
        if ! git fetch origin "main:$MAIN_BRANCH" >>"$LOG_FILE_ABS" 2>&1; then
            observed_branch=$(git rev-parse --abbrev-ref HEAD)
            warn "sync: no se pudo fast-forwardear '$MAIN_BRANCH' por nombre a origin/main (rama activa observada: '$observed_branch')"
            return 1
        fi
    elif ! git merge --ff-only origin/main >>"$LOG_FILE_ABS" 2>&1; then
        observed_branch=$(git rev-parse --abbrev-ref HEAD)
        warn "sync: no se pudo fast-forwardear '$observed_branch' local a origin/main (posible divergencia local)"
        return 1
    fi

    # 5. Confirmar que el merge commit quedo en $MAIN_BRANCH (por NOMBRE --
    #    CA-1), nunca en HEAD: si la rama activa cambio, HEAD ya no es una
    #    senal valida de donde vive $MAIN_BRANCH.
    if ! git merge-base --is-ancestor "$merge_sha" "$MAIN_BRANCH" 2>/dev/null; then
        observed_branch=$(git rev-parse --abbrev-ref HEAD)
        warn "sync: el commit de merge $merge_sha no quedo en '$MAIN_BRANCH' tras el sync (rama activa observada: '$observed_branch')"
        return 1
    fi

    return 0
}

# --- Parsear argumentos ---
ISSUE_NUMS=()
STOP_ON_ERROR=false

if [ $# -eq 0 ]; then
    echo "Uso: $0 <issue1> <issue2> ... [--stop-on-error]"
    echo "  issue1 ...         Numeros de issues a procesar (en orden)"
    echo "  --stop-on-error    Abortar en el primer fallo (por defecto: continuar)"
    exit 1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --stop-on-error) STOP_ON_ERROR=true; shift ;;
        [0-9]*)          ISSUE_NUMS+=("$1"); shift ;;
        *)
            echo "Argumento desconocido: $1"
            exit 1
            ;;
    esac
done

if [ ${#ISSUE_NUMS[@]} -eq 0 ]; then
    echo -e "${RED}${BOLD}x No se especificaron issues.${NC}"
    exit 1
fi

# --- Repo root (validado por assert_in_mefisto) ---
REPO_ROOT="$MEFISTO_REPO_ROOT"
cd "$REPO_ROOT"

# --- Inicializar log ---
# LOG_FILE ya es absoluto (PIPELINE_DIR viene de MEFISTO_STATE_DIR, issue
# #870): 'realpath' solo normaliza (symlinks tipo /var -> /private/var en
# macOS), nunca compone contra REPO_ROOT -- concatenar "$REPO_ROOT/$LOG_FILE"
# duplicaria la ruta absoluta. Se toca el archivo ANTES de resolverlo (mismo
# orden que mefisto-tooling-pipeline.sh): realpath no garantiza resolver un
# componente final que todavia no existe.
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
LOG_FILE_ABS="$(realpath "$LOG_FILE")"

# Inicializar status tracker
for issue in "${ISSUE_NUMS[@]}"; do
    set_status "$issue" "pendiente"
done

# --- Verificar dependencias ---
MISSING_DEPS=""
for dep in git gh jq; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        MISSING_DEPS="$MISSING_DEPS $dep"
    fi
done
if [ -n "$MISSING_DEPS" ]; then
    echo -e "${RED}${BOLD}x Dependencias faltantes:${MISSING_DEPS}${NC}"
    exit 1
fi

# El CLI del runtime activo (issue #870): ya no "claude" a secas -- el runtime
# lo decide mefisto_resolve_runtime (precedencia explicito > MEFISTO_RUNTIME >
# autodeteccion, lib/mefisto-runtime.sh); este eslabon hereda MEFISTO_RUNTIME
# del entorno (lo antepone el comando generado, issue #867), sin flag --runtime
# propio. mefisto_resolve_runtime NO valida que el CLI este instalado cuando
# el runtime llega explicito o por entorno (solo al autodetectar) -- el
# 'command -v "$BATCH_RUNTIME"' de abajo es la unica verificacion real de que
# el binario existe.
if ! BATCH_RUNTIME="$(mefisto_resolve_runtime)"; then
    echo -e "${RED}${BOLD}x No se pudo resolver el runtime activo: $MEFISTO_RUNTIME_ERROR${NC}"
    echo -e "${YELLOW}Fija MEFISTO_RUNTIME=claude|opencode para desambiguar.${NC}"
    exit 1
fi
if ! command -v "$BATCH_RUNTIME" >/dev/null 2>&1; then
    echo -e "${RED}${BOLD}x Falta el CLI del runtime resuelto ('$BATCH_RUNTIME').${NC}"
    echo -e "${YELLOW}Fija MEFISTO_RUNTIME=claude|opencode con un runtime instalado.${NC}"
    exit 1
fi

# Se re-exporta YA RESUELTO (CA-3): sin esto, cuando el runtime llego por
# autodeteccion (MEFISTO_RUNTIME vacio en el entorno) cada eslabon volveria a
# autodetectar por su cuenta, y el batch estaria anunciando en su cabecera un
# runtime que ningun hijo llego a ver. Con el export, "el eslabon hereda el
# runtime del entorno" es literal para las tres vias de resolucion, y el que
# hereda es exactamente el que esta precondicion verifico instalado. El resto
# del entorno (MEFISTO_MODELS_FILE, ...) viaja solo, sin que este script lo
# toque.
export MEFISTO_RUNTIME="$BATCH_RUNTIME"

# ensure_repo_on_base_branch
#
# Gate de arranque del batch (issue #46, auto-recuperacion agregada en el
# issue #726). Cada worktree del tooling-pipeline nace SIEMPRE de origin/main,
# sea cual sea la rama activa del repo principal (issue #66, `git worktree add
# ... origin/main` en mefisto-tooling-pipeline.sh) -- ese invariante no depende
# de este gate. La razon real de exigir main/master aqui es puramente higienica:
# mantener main LOCAL sincronizado entre eslabones para el humano que sigue
# la corrida (issue #566).
#
# Si la rama activa ya es main/master, no hace nada. Si no lo es:
#   - Arbol de trabajo LIMPIO (`git status --porcelain` vacio): la rama
#     abandonada no pierde nada (sus commits ya estan en su ref, tipicamente
#     tambien en origin) -- el gate se AUTO-RECUPERA en vez de abortar:
#     cambia a la rama base (preferida 'main' si existe localmente, si no
#     'master') y la deja al dia con origin (`git pull --ff-only`), dejando
#     un warning que nombra la rama original (mismo tono que los warnings de
#     sync del issue #566).
#   - Arbol SUCIO (cambios sin commitear o staged): la auto-recuperacion no
#     aplica -- switchear arrastraria o descartaria ese trabajo. Aborta
#     fail-loud, igual que el gate original (issue #46, robustez).
#   - El `git pull --ff-only` posterior al switch falla (la rama base LOCAL
#     diverge de origin): aborta fail-loud -- la premisa de higiene de este
#     gate no se puede cumplir sin que el humano resuelva la divergencia a
#     mano.
#
# Deja MAIN_BRANCH con la rama base efectiva (la activa al entrar si ya era
# main/master, o la rama a la que se auto-recupero).
ensure_repo_on_base_branch() {
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)

    if [ "$current_branch" = "main" ] || [ "$current_branch" = "master" ]; then
        MAIN_BRANCH="$current_branch"
        return 0
    fi

    if [ -n "$(git status --porcelain)" ]; then
        abort "El repo principal esta en la rama '$current_branch', no en main/master, y el arbol de trabajo no esta limpio (cambios sin commitear, staged o archivos sin trackear). Cada worktree del tooling-pipeline nace de origin/main sin importar la rama activa (issue #66), pero el batch tambien mantiene main LOCAL sincronizado entre eslabones para el humano que sigue la corrida -- arrancar fuera de main/master genera sorpresas ahi. La auto-recuperacion del gate (issue #726) solo aplica con el arbol de trabajo LIMPIO; con cambios pendientes, resuelvelos o descartalos y haz 'git switch main' a mano antes de lanzar el batch."
    fi

    local base_branch
    if git rev-parse --verify -q refs/heads/main >/dev/null 2>&1; then
        base_branch="main"
    elif git rev-parse --verify -q refs/heads/master >/dev/null 2>&1; then
        base_branch="master"
    else
        abort "El repo principal esta en la rama '$current_branch' y no existe ni 'main' ni 'master' local para auto-recuperar el gate. Crea o rescata una de las dos antes de lanzar el batch."
    fi

    git switch -q "$base_branch" || abort "El repo principal esta en la rama '$current_branch' (arbol limpio), pero 'git switch $base_branch' fallo. Resuelve a mano antes de lanzar el batch."

    local pull_output
    if ! pull_output=$(git pull --ff-only 2>&1); then
        abort "El repo principal estaba en la rama '$current_branch' (arbol limpio); el gate lo auto-recupero a '$base_branch' (issue #726), pero 'git pull --ff-only' fallo ahi -- tipicamente porque '$base_branch' LOCAL divergio de origin/$base_branch (tambien cae aqui una base sin upstream configurado). La premisa de higiene de este gate no se puede cumplir asi: resuelve la divergencia a mano (el repo quedo en '$base_branch') antes de relanzar el batch. Salida de git: $(printf '%s' "$pull_output" | tr '\n' ' ')"
    fi

    warn "El repo principal estaba en la rama '$current_branch' (arbol limpio) al arrancar el batch; el gate se auto-recupero a '$base_branch' y lo sincronizo con origin/$base_branch (issue #726). Los commits de '$current_branch' siguen intactos en su rama."
    MAIN_BRANCH="$base_branch"
}

ensure_repo_on_base_branch

# --- Cabecera ---
header "mefisto-batch-pipeline --- Procesamiento secuencial de issues internos"
log "Pipeline: mefisto-tooling (unico pipeline interno de Mefisto)"
log "Runtime activo: $BATCH_RUNTIME"
log "Issues a procesar: ${ISSUE_NUMS[*]}"
log "Rama base: $MAIN_BRANCH (el batch la mantiene sincronizada con origin/main entre eslabones; cada worktree nace de origin/main, issue #66)"
log "Modo en error: $([ "$STOP_ON_ERROR" = true ] && echo 'detener' || echo 'continuar')"
log "Log: $LOG_FILE_ABS"
log "Parada suave: /mefisto-batch-stop detiene el batch tras el eslabon en curso (issue #966)"
log "Espera automatica: ante RATE_LIMIT/PROVIDER_UNAVAILABLE el eslabon en curso espera (hold) en vez de fallar (issue #967) -- mientras espera, /mefisto-work-status lo reporta 'en espera' (issue #969)"

# Eslabon canonico (issue #870): se invoca directo, sin pasar por el shim de
# compatibilidad. Ruta absoluta derivada de SCRIPT_DIR (donde vive este mismo
# archivo, ya en src/internal/scripts/), indiferente al cwd del invocador.
PIPELINE_SCRIPT="$SCRIPT_DIR/mefisto-tooling-pipeline.sh"
if [ ! -x "$PIPELINE_SCRIPT" ]; then
    abort "No se encontro el pipeline interno: $PIPELINE_SCRIPT"
fi

# --- Loop principal ---
COMPLETED=0
FAILED=0
TOTAL=${#ISSUE_NUMS[@]}

# Cola efectiva de esta corrida (issue #966): ISSUE_NUMS conserva el orden
# pedido -- es lo que recorre el resumen final --, mientras BATCH_QUEUE es lo
# que el loop realmente procesa. Vaciarla es como se salta el loop completo sin
# envolverlo en un `if` (que forzaria a reindentar todo su cuerpo).
BATCH_QUEUE=("${ISSUE_NUMS[@]}")

# Parada suave, momento 1 (issue #966, CA-1): la senal ya estaba puesta antes de
# arrancar el primer eslabon, asi que ningun issue se procesa en esta corrida.
if batch_stop_requested; then
    warn "Parada solicitada ($BATCH_STOP_SIGNAL) antes de arrancar el primer eslabon: ningun issue se procesa en esta corrida."
    defer_from_index 0
    BATCH_QUEUE=()
fi

# ${a[@]+"${a[@]}"}: bash 3.2 aborta con "unbound variable" al expandir un array
# vacio bajo `set -u` (mismo idioma que generate-internal-adapters.sh), y la cola
# queda vacia justamente cuando la parada se pidio antes del primer eslabon.
for ISSUE_NUM in ${BATCH_QUEUE[@]+"${BATCH_QUEUE[@]}"}; do
    CURRENT=$((COMPLETED + FAILED + 1))
    header "Issue #$ISSUE_NUM ($CURRENT/$TOTAL)"

    # -- Stage 1: Ejecutar pipeline interno --
    # El propio pipeline interno valida que el issue exista y este OPEN.
    # Aqui solo capturamos el exit code y lo registramos como error del issue.
    log "Ejecutando mefisto-tooling-pipeline.sh para issue #$ISSUE_NUM..."

    # LOG_DIR ya es absoluto (MEFISTO_STATE_DIR, issue #870): sin REPO_ROOT/ al frente.
    ISSUE_LOG="$LOG_DIR/mefisto-batch-issue-${ISSUE_NUM}-${TIMESTAMP}.log"
    touch "$ISSUE_LOG"

    # Marca de arranque para el reporte de hold de este eslabon (issue #969,
    # CA-3): cuantas lineas tenia EVENTS_LOG_PATH antes de invocar el
    # pipeline. Con jq/wc ausentes o el archivo todavia inexistente
    # (primera corrida del checkout), hold_seconds_in_range degrada a 0 --
    # nunca aborta el batch por esto.
    HOLD_LINE_START=0
    [ -f "$EVENTS_LOG_PATH" ] && HOLD_LINE_START=$(wc -l < "$EVENTS_LOG_PATH" 2>/dev/null | tr -d ' ')
    [ -z "$HOLD_LINE_START" ] && HOLD_LINE_START=0

    PIPELINE_EXIT=0
    "$PIPELINE_SCRIPT" "$ISSUE_NUM" 2>&1 | tee "$ISSUE_LOG" || PIPELINE_EXIT=$?

    # Agregar el log del issue al log general (sin codigos ANSI)
    _strip_ansi < "$ISSUE_LOG" >> "$LOG_FILE_ABS"

    # Segundos en espera (hold) durante ESTE eslabon (issue #969, CA-3): se
    # calcula pase lo que pase con PIPELINE_EXIT -- un eslabon puede haber
    # esperado horas y fallar igual al agotar el techo de espera, y ese tiempo
    # tambien cuenta para el total del batch. Nunca decide FAILED/HAVE_ERRORS
    # (CA-1): es una nota informativa que se concatena a los mensajes de abajo.
    ISSUE_HOLD_SECONDS=$(hold_seconds_in_range "$EVENTS_LOG_PATH" "$HOLD_LINE_START")
    if [ "$ISSUE_HOLD_SECONDS" -gt 0 ]; then
        BATCH_TOTAL_HOLD_SECONDS=$((BATCH_TOTAL_HOLD_SECONDS + ISSUE_HOLD_SECONDS))
        log "Issue #$ISSUE_NUM: $(fmt_hold_duration "$ISSUE_HOLD_SECONDS") en espera (hold) durante este eslabon"
    fi

    if [ "$PIPELINE_EXIT" -ne 0 ]; then
        fail_issue "$ISSUE_NUM" "pipeline fallo (exit $PIPELINE_EXIT). Log: $ISSUE_LOG$(hold_note_suffix "$ISSUE_HOLD_SECONDS")"
        FAILED=$((FAILED + 1))
        if [ "$STOP_ON_ERROR" = true ]; then
            abort "Detenido por --stop-on-error en issue #$ISSUE_NUM"
        fi
        continue
    fi

    # -- Stage 2: Extraer numero de PR del output --
    # mefisto-tooling-pipeline.sh imprime entre otras lineas:
    #   "v PR creado: https://github.com/owner/repo/pull/NNN"
    #   "  PR:      https://github.com/owner/repo/pull/NNN"
    PR_URL=$(_strip_ansi < "$ISSUE_LOG" \
        | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' \
        | head -1)

    if [ -z "$PR_URL" ]; then
        fail_issue "$ISSUE_NUM" "no se pudo extraer la URL del PR del output. Log: $ISSUE_LOG$(hold_note_suffix "$ISSUE_HOLD_SECONDS")"
        FAILED=$((FAILED + 1))
        if [ "$STOP_ON_ERROR" = true ]; then
            abort "Detenido por --stop-on-error en issue #$ISSUE_NUM"
        fi
        continue
    fi

    PR_NUM=$(echo "$PR_URL" | grep -oE '[0-9]+$')
    set_pr "$ISSUE_NUM" "$PR_NUM"
    success "Pipeline completado -> PR #$PR_NUM ($PR_URL)"

    # -- Stage 3: Merge del PR --
    # En Mefisto no usamos pr-sync.sh (es del lado publicado). Mergeamos con
    # gh pr merge directo, con squash + delete-branch (consistente con
    # src/internal/commands/mefisto-merge.md).
    log "Mergeando PR #$PR_NUM a main (squash + delete-branch)..."

    MERGE_EXIT=0
    gh pr merge "$PR_NUM" --squash --delete-branch 2>&1 | tee -a "$ISSUE_LOG" || MERGE_EXIT=$?

    _strip_ansi < "$ISSUE_LOG" >> "$LOG_FILE_ABS"

    if [ "$MERGE_EXIT" -ne 0 ]; then
        fail_issue "$ISSUE_NUM" "merge del PR #$PR_NUM fallo (exit $MERGE_EXIT). Log: $ISSUE_LOG$(hold_note_suffix "$ISSUE_HOLD_SECONDS")"
        FAILED=$((FAILED + 1))
        if [ "$STOP_ON_ERROR" = true ]; then
            abort "Detenido por --stop-on-error en issue #$ISSUE_NUM"
        fi
        continue
    fi

    # -- Stage 4: Sincronizar main de forma VERIFICADA para el siguiente issue --
    # Critico para cadenas con dependencias (issue #46): el siguiente eslabon DEBE
    # partir de un origin/main que ya incluye el merge de este. La severidad
    # distingue DONDE fallo el sync (issue #566, CA-3): si origin/main no tiene
    # el merge confirmado (return 2), SI abortamos -- el siguiente worktree
    # naceria de una base vieja. Si solo fallo dejar main LOCAL sincronizado
    # (return 1), degradamos a warning y continuamos: el siguiente worktree
    # nace de origin/main, que ya esta al dia.
    IS_LAST_ISSUE=false
    [ "$CURRENT" -eq "$TOTAL" ] && IS_LAST_ISSUE=true

    log "Sincronizando $MAIN_BRANCH con origin (verificado)..."
    SYNC_RC=0
    sync_main_after_merge "$PR_NUM" || SYNC_RC=$?

    if [ "$SYNC_RC" -eq 0 ]; then
        success "$MAIN_BRANCH local incluye el merge del PR #$PR_NUM (commit ${MERGE_SHA_SYNCED:0:12})"
        set_status "$ISSUE_NUM" "completado (PR #$PR_NUM mergeado)$(hold_note_suffix "$ISSUE_HOLD_SECONDS")"
        COMPLETED=$((COMPLETED + 1))
        success "Issue #$ISSUE_NUM completado y mergeado"
    elif [ "$SYNC_RC" -eq 1 ]; then
        # origin/main SI tiene el merge confirmado (paso 3 exitoso): la correccion
        # de la cadena esta garantizada aunque main LOCAL no haya quedado
        # sincronizado. No fatal (CA-3): degrada a warning y continua.
        set_status "$ISSUE_NUM" "completado (PR #$PR_NUM mergeado; sync de $MAIN_BRANCH LOCAL fallido, no fatal)$(hold_note_suffix "$ISSUE_HOLD_SECONDS")"
        COMPLETED=$((COMPLETED + 1))
        HAVE_WARNINGS=true
        success "Issue #$ISSUE_NUM completado y mergeado"
        warn "El commit de merge ${MERGE_SHA_SYNCED:0:12} del PR #$PR_NUM ya esta confirmado en origin/main; solo fallo dejar $MAIN_BRANCH LOCAL sincronizado. No bloquea la cadena: el siguiente worktree nace de origin/main. Para ponerte al dia: 'git switch $MAIN_BRANCH && git pull --ff-only'."
    else
        # SYNC_RC = 2: el merge commit no llego a origin/main. El PR ya quedo
        # mergeado (el issue en si esta resuelto), pero el siguiente worktree
        # naceria de una base desactualizada. Esto SI rompe la cadena.
        set_status "$ISSUE_NUM" "completado (PR #$PR_NUM mergeado; sync de origin/main FALLIDO)$(hold_note_suffix "$ISSUE_HOLD_SECONDS")"
        COMPLETED=$((COMPLETED + 1))
        HAVE_ERRORS=true
        if [ "$IS_LAST_ISSUE" = true ]; then
            warn "El sync verificado de origin/main fallo, pero #$ISSUE_NUM era el ultimo eslabon: ningun issue posterior depende de este merge."
        else
            abort "Sync verificado de origin/main tras el PR #$PR_NUM fallo: el commit de merge no quedo confirmado en origin/main. El siguiente eslabon naceria de una base desactualizada, asi que la cadena se aborta. Revisa el log: $LOG_FILE_ABS"
        fi
    fi

    # CA-1 (momento 2): despues del sync verificado de este eslabon -- el
    # unico punto seguro de la cadena (el PR ya esta mergeado y origin/main ya
    # incluye el merge). Un eslabon fallido (pipeline/PR/merge) nunca llega
    # aqui: sus `continue` de arriba lo saltan.
    if batch_stop_requested; then
        if [ "$CURRENT" -lt "$TOTAL" ]; then
            warn "Parada solicitada ($BATCH_STOP_SIGNAL) tras el sync verificado de #$ISSUE_NUM: los eslabones restantes quedan aplazados, sin arrancar ningun worktree."
        else
            # La senal llego mientras corria el ULTIMO eslabon: no queda nada
            # que aplazar, pero igual hay que consumirla (CA-4) para no
            # envenenar la corrida siguiente. Decirlo evita que el humano
            # busque en el resumen unos aplazados que nunca existieron.
            warn "Parada solicitada ($BATCH_STOP_SIGNAL) tras el sync verificado de #$ISSUE_NUM, que era el ultimo eslabon del batch: no quedaba ninguno por arrancar. La senal se consumio igual, para no afectar la corrida siguiente."
        fi
        defer_from_index "$CURRENT"
        break
    fi
done

# --- Resumen final ---
header "Resumen"
echo -e ""
printf "${BOLD}%-10s %-8s %-45s${NC}\n" "Issue" "PR" "Estado"
printf "%s\n" "-----------------------------------------------------------------"

for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
    PR=$(get_pr "$ISSUE_NUM")
    STATUS=$(get_status "$ISSUE_NUM")
    if echo "$STATUS" | grep -q "^completado"; then
        COLOR="$GREEN"
    elif echo "$STATUS" | grep -q "^ERROR"; then
        COLOR="$RED"
    else
        COLOR="$YELLOW"
    fi
    printf "${COLOR}%-10s %-8s %-45s${NC}\n" "#$ISSUE_NUM" "${PR:-(n/a)}" "$STATUS"
done

# Issues aplazados (issue #966, CA-3): en el mismo orden en que quedaron en
# ISSUE_NUMS, para que la linea de relanzamiento respete el orden del batch.
DEFERRED_NUMS=()
for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
    case "$(get_status "$ISSUE_NUM")" in
        aplazado*) DEFERRED_NUMS+=("$ISSUE_NUM") ;;
    esac
done
DEFERRED=${#DEFERRED_NUMS[@]}

echo ""
echo -e "  Total: $TOTAL  |  ${GREEN}Completados: $COMPLETED${NC}  |  ${RED}Fallidos: $FAILED${NC}  |  ${YELLOW}Aplazados: $DEFERRED${NC}"
echo -e "  Log: $LOG_FILE_ABS"
echo ""

# Tiempo total en espera del batch (issue #969, CA-3): informativo, nunca
# afecta FAILED/HAVE_ERRORS/el exit code (CA-1/CA-5) -- por eso se imprime
# aparte, despues de la fila de totales, y solo cuando hubo alguna espera.
if [ "$BATCH_TOTAL_HOLD_SECONDS" -gt 0 ]; then
    echo -e "  Tiempo total en espera (hold): $(fmt_hold_duration "$BATCH_TOTAL_HOLD_SECONDS")"
    echo ""
fi

if [ "$DEFERRED" -gt 0 ]; then
    warn "Parada solicitada: $DEFERRED issue(s) quedaron aplazados en esta corrida. No es un fallo del batch: el exit code es 0 y nada quedo a medio pipeline."
    echo -e "  Relanza los aplazados, en el mismo orden: ${BOLD}/mefisto-sequential ${DEFERRED_NUMS[*]}${NC}"
    echo ""
fi

if [ "$HAVE_ERRORS" = true ]; then
    warn "Algunos issues tuvieron errores. Revisa el log: $LOG_FILE_ABS"
    exit 1
fi
if [ "$HAVE_WARNINGS" = true ]; then
    # Todos los eslabones se completaron y mergearon: no es un fallo del batch
    # (issue #566), asi que el exit es 0. Pero main LOCAL quedo atrasado y el
    # humano tiene que saberlo antes de seguir trabajando sobre este repo.
    warn "Todos los issues se completaron, pero $MAIN_BRANCH LOCAL quedo sin sincronizar en algun eslabon (ver el detalle arriba). Ponte al dia con 'git switch $MAIN_BRANCH && git pull --ff-only'. Log: $LOG_FILE_ABS"
fi
success "mefisto-batch-pipeline completado. Log: $LOG_FILE_ABS"
