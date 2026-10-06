#!/usr/bin/env bash
# batch-pipeline.sh --- Ejecuta pipelines para multiples issues secuencialmente
#
# Uso:
#   ./scripts/batch-pipeline.sh 42 43 44                          # enrutamiento automatico por label
#   ./scripts/batch-pipeline.sh --pipeline tooling 60 62 63       # forzar pipeline tooling
#   ./scripts/batch-pipeline.sh --pipeline tdd 42 43              # forzar pipeline tdd
#   ./scripts/batch-pipeline.sh 42 43 --stop-on-error             # abortar en primer fallo
#   MEFISTO_RUNTIME=<id> ./scripts/batch-pipeline.sh 42            # fija el runtime activo cuando hay mas de un CLI instalado (MEF-ADR-0049/0050); sin esta variable, se resuelve por auto-deteccion antes del primer eslabon y se hereda en cada uno
#
# Enrutamiento automatico: sin --pipeline, cada issue se enruta segun su label tipo:*
#   tipo:feature|refactor|projection -> tdd-pipeline.sh
#   tipo:tooling                     -> tooling-pipeline.sh
#   tipo:infra                       -> SKIP (warning, no aborta)
#   sin label tipo:*                 -> SKIP (warning, no aborta)
#
# Flujo por issue: pipeline -> extraer PR -> pr-sync.sh --merge -> siguiente issue
#
# Compatible con bash 3.2+ (macOS nativo)

set -euo pipefail

# ─── Funciones compartidas ───────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"

# ─── Runtime activo (MEF-ADR-0049/0050, issue #1591) ─────────────────────────
# La clausura publicada conserva src/runtime junto a este script -- mismo
# bloque que tooling-pipeline.sh (~20-33). El batch solo necesita el
# discovery (mefisto-runtime.sh): no resuelve modelos, asi que no carga
# mefisto-models.sh como si hace el eslabon.
RUNTIME_DIR="$(cd "$(_pc_script_dir)/../src/runtime" 2>/dev/null && pwd -P)" \
    || { echo "ERROR: no se encontro src/runtime junto al paquete publicado" >&2; exit 1; }
RUNTIME_LIB_DIR="$RUNTIME_DIR/lib"
[ -f "$RUNTIME_LIB_DIR/mefisto-runtime.sh" ] \
    || { echo "ERROR: no se encontro mefisto-runtime.sh en la clausura publicada" >&2; exit 1; }
source "$RUNTIME_LIB_DIR/mefisto-runtime.sh"

# ─── Colores ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Logging ─────────────────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_DIR=""

_strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
_log_file()   { echo -e "$1" | _strip_ansi >> "$LOG_FILE_ABS"; }

log()     { local m="${BLUE}[$(date +%H:%M:%S)]${NC} $1"; echo -e "$m"; _log_file "$m"; }
success() { local m="${GREEN}${BOLD}✓${NC} $1"; echo -e "$m"; _log_file "$m"; }
warn()    { local m="${YELLOW}⚠${NC} $1"; echo -e "$m"; _log_file "$m"; }
header()  { local m="\n${CYAN}${BOLD}── $1 ──${NC}"; echo -e "$m"; _log_file "$m"; }
abort() {
    echo -e "\n${RED}${BOLD}✗ ERROR FATAL: $1${NC}" | tee -a "$LOG_FILE_ABS"
    echo -e "${YELLOW}Revisa el log: $LOG_FILE_ABS${NC}"
    exit 1
}

# ─── Status tracker (compatible bash 3.2, sin declare -A) ────────────────────
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

# ─── Fallo no fatal de un issue (continúa el loop) ───────────────────────────
HAVE_ERRORS=false

fail_issue() {
    local issue="$1" msg="$2"
    echo -e "\n${RED}${BOLD}✗ Issue #$issue: $msg${NC}" | tee -a "$LOG_FILE_ABS"
    set_status "$issue" "ERROR: $msg"
    HAVE_ERRORS=true
}

# ─── Senal de parada suave del batch (issue #974, mismo diseno que el motor ──
# ─── interno #966) ────────────────────────────────────────────────────────────
# Un batch largo no se podia frenar sin matar el pane de tmux/herdr, dejando el
# eslabon en curso a medio pipeline. La senal es un archivo de mera PRESENCIA
# (sin campos que parsear) que /batch-stop escribe desde el checkout principal.
# Vive en pipeline-state/batch-stop -- fuera de .claude/ por construccion
# (MEF-ADR-0017: el runtime intercepta toda escritura bajo .claude/**, incluidas
# redirecciones de Bash) --, misma ubicacion que refactor-signal.md. Que no se
# versione no depende de este script: el bloque de .gitignore que emite
# infra-base-scaffolder lista pipeline-state/ en greenfield (un consumidor ya
# scaffoldeado tiene que anadir la linea a mano, issue #485) y el auto-commit de
# tooling-pipeline.sh la excluye de su `git add` en cualquier caso.
#
# Se consulta en dos momentos (CA-1): antes de arrancar el primer eslabon, y
# despues de cada eslabon completado (pipeline + PR + merge) -- el unico punto
# seguro de la cadena. Un eslabon que fallo nunca llega al segundo chequeo: su
# `continue` lo salta, asi que la senal no interrumpe una cadena que ya estaba
# fallando por otra razon -- solo el camino de exito la consulta.
BATCH_STOP_SIGNAL="pipeline-state/batch-stop"

batch_stop_requested() {
    [ -f "$BATCH_STOP_SIGNAL" ]
}

# defer_from_index <indice-0-based>
#
# Consume la senal (CA-5: se borra para no envenenar la corrida siguiente) y
# marca "aplazado" (CA-2) todos los issues de ISSUE_NUMS desde <indice> en
# adelante. Nunca toca HAVE_ERRORS/FAILED/--stop-on-error (CA-5: una parada
# solicitada no es un fallo del batch).
defer_from_index() {
    local from="$1" i
    rm -f "$BATCH_STOP_SIGNAL"
    for ((i = from; i < ${#ISSUE_NUMS[@]}; i++)); do
        set_status "${ISSUE_NUMS[$i]}" "aplazado (parada solicitada; no se proceso en esta corrida)"
    done
}

# ─── Preflight de autonomia (issue #1826, MEF-ADR-0055) ──────────────────────
# Gate de CONSULTA antes de lanzar: delega en autonomy-preflight.sh (#1870) un plan
# cerrado launchKind:sequential. No adquiere ni libera la lease de la cadena, no pide
# aprobacion, no repara perfil/permisos y no certifica la sesion futura: ready-to-dispatch
# deja sus checks `deferred` al guard por instancia del stage (#1858/#1860). `legacy`
# (sin perfil / runtime sin contexto) conserva exactamente el flujo anterior; cualquier
# otra salida (blocked, incomplete, 75 busy, salida invalida, consulta caida) impide el
# lanzamiento y NUNCA se sustituye por legacy.
BATCH_PREFLIGHT_BLOCKED=false
PREFLIGHT_STATUS=""
PREFLIGHT_DIAG=""
PREFLIGHT_DEFERRED=""
BATCH_PLAN_NUMS=()
BATCH_PLAN_KINDS=()

# batch_plan_kind_for <issue>: pipelineKind del plan inicial ("" si no esta).
batch_plan_kind_for() {
    local i
    for ((i = 0; i < ${#BATCH_PLAN_NUMS[@]}; i++)); do
        if [ "${BATCH_PLAN_NUMS[$i]}" = "$1" ]; then echo "${BATCH_PLAN_KINDS[$i]}"; return 0; fi
    done
    return 0
}

# batch_autonomy_preflight <numero:pipelineKind>...
# 0 = legacy|ready-to-dispatch; 1 = no se puede lanzar (PREFLIGHT_STATUS/DIAG con codigos).
batch_autonomy_preflight() {
    local bin plan out rc=0 src=direct args
    PREFLIGHT_STATUS=""; PREFLIGHT_DIAG=""; PREFLIGHT_DEFERRED=""
    bin="$(_pc_script_dir)/autonomy-preflight.sh"
    args=(--project-root "$REPO_ROOT" --runtime "$BATCH_RUNTIME")
    src="$(pipeline_preflight_source)"
    if [ "$src" != direct ]; then
        args+=(--context "$MEFISTO_EXECUTION_CONTEXT")
    fi
    if [ ! -x "$bin" ]; then
        PREFLIGHT_STATUS="unavailable"; PREFLIGHT_DIAG="PREFLIGHT_UNAVAILABLE"
        return 1
    fi
    plan=$(jq -cn --arg s "$src" '{schemaVersion:1,launchKind:"sequential",source:$s,requestedOperations:[],
        issues:[$ARGS.positional[] | split(":") | {number:(.[0]|tonumber),pipelineKind:.[1]}]}' --args "$@" 2>/dev/null) \
        || { PREFLIGHT_STATUS="unavailable"; PREFLIGHT_DIAG="PREFLIGHT_PLAN_INVALID"; return 1; }
    out=$(printf '%s' "$plan" | "$bin" "${args[@]}" 2>/dev/null) || rc=$?
    PREFLIGHT_STATUS=$(printf '%s' "$out" | jq -r '.status // empty' 2>/dev/null) || PREFLIGHT_STATUS=""
    PREFLIGHT_DIAG=$(printf '%s' "$out" | jq -r '[.diagnostics[]? | select(type == "string" and test("^[A-Za-z0-9_#:.-]+$"))] | join(",")' 2>/dev/null) || PREFLIGHT_DIAG=""
    PREFLIGHT_DEFERRED=$(printf '%s' "$out" | jq -r '[.checks[]? | select(.state == "deferred" and (.code|type) == "string" and (.owner|type) == "string") | "\(.code)@\(.owner)"] | map(select(test("^[A-Za-z0-9_#:./@-]+$"))) | join(",")' 2>/dev/null) || PREFLIGHT_DEFERRED=""
    if [ "$rc" -eq 0 ]; then
        case "$PREFLIGHT_STATUS" in
            legacy)
                # Un contexto transportado nunca degrada a legacy (CA-5).
                [ "$src" = command ] || return 0
                PREFLIGHT_STATUS="invalid"; PREFLIGHT_DIAG="PREFLIGHT_LEGACY_WITH_CONTEXT"; return 1 ;;
            ready-to-dispatch)
                # Fail-closed (CA-3): todo check clasificado; deferred solo con propietario;
                # ningun block ni estado desconocido presentado como admision.
                if printf '%s' "$out" | jq -e '(.checks | type == "array") and all(.checks[];
                        (.state | IN("pass","deferred","not-applicable"))
                        and (.state != "deferred" or ((.owner | type) == "string" and (.owner | length) > 0)))' >/dev/null 2>&1; then
                    return 0
                fi
                PREFLIGHT_STATUS="invalid"; PREFLIGHT_DIAG="PREFLIGHT_CHECKS_INCONSISTENT"; return 1 ;;
        esac
    fi
    if [ "$rc" -eq 75 ]; then
        PREFLIGHT_STATUS="busy"; PREFLIGHT_DIAG="${PREFLIGHT_DIAG:-PREFLIGHT_BUSY}"
    else
        case "$PREFLIGHT_STATUS" in
            blocked|incomplete) ;;
            *) PREFLIGHT_STATUS="invalid"; PREFLIGHT_DIAG="${PREFLIGHT_DIAG:-PREFLIGHT_RC_$rc}" ;;
        esac
    fi
    return 1
}

# batch_preflight_block_from <indice-0-based> <momento>
# Termina el lanzamiento de la cola restante: estado explicito, sin worktree/PR/merge, y
# exit != 0 al final. No consume batch-stop, no mata procesos ni revierte merges.
batch_preflight_block_from() {
    local from="$1" when="$2" i
    BATCH_PREFLIGHT_BLOCKED=true
    for ((i = from; i < ${#ISSUE_NUMS[@]}; i++)); do
        set_status "${ISSUE_NUMS[$i]}" "no iniciado por preflight (${PREFLIGHT_STATUS}: ${PREFLIGHT_DIAG:-sin-detalle})"
    done
    echo -e "\n${RED}${BOLD}✗ Preflight de autonomia ${when}: ${PREFLIGHT_STATUS} [${PREFLIGHT_DIAG:-sin-detalle}]. No se lanza la cola restante.${NC}" | tee -a "$LOG_FILE_ABS"
}

# ─── Parsear argumentos ───────────────────────────────────────────────────────
ISSUE_NUMS=()
STOP_ON_ERROR=false
PIPELINE_OVERRIDE=""  # vacio = enrutamiento automatico por label

if [ $# -eq 0 ]; then
    echo "Uso: $0 [--pipeline tdd|tooling] <issue1> <issue2> ... [--stop-on-error]"
    echo "  --pipeline TYPE    Forzar pipeline: 'tdd' o 'tooling' (sin flag: enruta por label tipo:*)"
    echo "  issue1 ...         Numeros de issues a procesar (en orden)"
    echo "  --stop-on-error    Abortar en el primer fallo (por defecto: continuar)"
    exit 1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --pipeline)
            [ $# -lt 2 ] && { echo "Falta el valor de --pipeline"; exit 1; }
            case "$2" in
                tdd|tooling) PIPELINE_OVERRIDE="$2" ;;
                *)           echo "Pipeline desconocido: $2. Usa 'tdd' o 'tooling'"; exit 1 ;;
            esac
            shift 2
            ;;
        --stop-on-error) STOP_ON_ERROR=true; shift ;;
        [0-9]*)          ISSUE_NUMS+=("$1"); shift ;;
        *)
            echo "Argumento desconocido: $1"
            exit 1
            ;;
    esac
done

if [ ${#ISSUE_NUMS[@]} -eq 0 ]; then
    echo -e "${RED}${BOLD}✗ No se especificaron issues.${NC}"
    exit 1
fi

# ─── Verificar que estamos en el repo correcto ────────────────────────────────
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
    || { echo "No estás en un repositorio git"; exit 1; }

# Guard defensivo: este pipeline es del lado publicado y solo aplica al consumidor.
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: batch-pipeline.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Estás en el repo de Mefisto. Trabaja los issues internos secuencialmente con /mefisto-tooling." >&2
    exit 1
fi

cd "$REPO_ROOT"

# Validación de homogeneidad: igual que en parallel-pipeline.sh, todos los issues
# del batch se asumen del repo actual; gh issue view N consulta el repo del cwd.

# ─── Inicializar log ──────────────────────────────────────────────────────────
LOG_DIR="$(dirname "$(mefisto_state_path 'logs/.state')")"
LOG_FILE_ABS="$(mefisto_state_path "logs/batch-$TIMESTAMP.log")"
touch "$LOG_FILE_ABS"

# events.log del checkout (issue #973): el MISMO archivo que tdd-pipeline.sh/
# tooling-pipeline.sh/iac-pipeline.sh escriben, uno solo para todas las
# corridas lanzadas desde aqui (lo resuelven contra este cwd, no contra el
# worktree del issue). Este orquestador ya hereda gratis CA-1/CA-5: mientras
# el stage esta en hold, el pipeline invocado abajo sigue bloqueado en su
# propio sleep, sin devolver el control con exit != 0, asi que una espera no
# incrementa FAILED, no dispara --stop-on-error y no cambia el exit code.
#
# Reparto del reporte de espera (mismo que el homologo interno, issue #969):
#   - EN VIVO, mientras el eslabon espera: la linea la emite el propio
#     eslabon ("... en espera (hold), ...", issue #971) y llega a este pane
#     por el `tee` de mas abajo; en paralelo /work-status la lee de este mismo
#     events.log y renderiza "EN ESPERA" con causa y hora de sonda (CA-2/CA-4).
#     El batch no la duplica: mientras el eslabon corre esta bloqueado en el `tee`.
#   - AL CERRAR el eslabon: este script anota cuanto se espero, como nota
#     ANEXA al desenlace real -- nunca como fallo (CA-1).
EVENTS_LOG_ABS="$(mefisto_state_path 'events.log')"
EVENTS_LOG_LEGACY_ABS="$MEFISTO_LEGACY_STATE_DIR/events.log"
touch "$EVENTS_LOG_ABS"

# Tiempo total en espera (hold) de todo el batch: contador puramente
# informativo, nunca leido en la logica de HAVE_ERRORS/FAILED/--stop-on-error
# (CA-1/CA-5).
BATCH_TOTAL_HOLD_SECONDS=0

# hold_seconds_in_all_events_logs <issue> <canonical_from_line> <legacy_from_line>
#
# Las dos raices pueden contener sesiones activas distintas durante la
# transicion. La legacy es solo lectura y puede aparecer despues de arrancar.
hold_seconds_in_all_events_logs() {
    local issue="$1" canonical_from_line="$2" legacy_from_line="$3" total
    total=$(hold_seconds_in_range "$EVENTS_LOG_ABS" "$canonical_from_line" "$issue")
    if [ -f "$EVENTS_LOG_LEGACY_ABS" ]; then
        total=$(( total + $(hold_seconds_in_range "$EVENTS_LOG_LEGACY_ABS" "$legacy_from_line" "$issue") ))
    fi
    echo "$total"
}

# Inicializar status tracker
for issue in "${ISSUE_NUMS[@]}"; do
    set_status "$issue" "pendiente"
done

# ─── Verificar dependencias ───────────────────────────────────────────────────
MISSING_DEPS=""
for dep in gh git dotnet; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        MISSING_DEPS="$MISSING_DEPS $dep"
    fi
done
if [ -n "$MISSING_DEPS" ]; then
    echo -e "${RED}${BOLD}✗ Dependencias faltantes:${MISSING_DEPS}${NC}"
    exit 1
fi

# ─── Resolver runtime activo (CA-2/CA-3, issue #1591) ────────────────────────
# Mismo criterio que los pipelines hijos (tooling-pipeline.sh ~324-333): sin
# herencia implicita. Si falla (ningun CLI detectado, o varios sin
# MEFISTO_RUNTIME para desambiguar) el batch aborta ANTES de tocar ningun
# issue -- no recien dentro del primer eslabon, que es donde fallaria hoy.
if ! mefisto_resolve_runtime >/dev/null; then
    echo -e "${RED}${BOLD}✗ No se pudo resolver el runtime activo: ${MEFISTO_RUNTIME_ERROR:-motivo desconocido}${NC}"
    exit 1
fi
BATCH_RUNTIME="$MEFISTO_RESOLVED_RUNTIME"

# CA-3: cuando MEFISTO_RUNTIME llega explicito (env o ya resuelto arriba),
# mefisto_resolve_runtime no comprueba que el CLI exista -- solo que haya
# adaptador. Se verifica aqui para fallar temprano, como ya hacia el chequeo
# de dependencias de arriba, en vez de descubrirlo recien dentro del primer
# eslabon.
if ! runtime_cli_available "$BATCH_RUNTIME"; then
    echo -e "${RED}${BOLD}✗ Dependencias faltantes: CLI del runtime '$BATCH_RUNTIME'${NC}"
    exit 1
fi

# CA-4: cada eslabon (tdd-pipeline.sh/tooling-pipeline.sh) y pr-sync.sh
# heredan este mismo runtime ya resuelto; sin el export, cada uno volveria a
# auto-detectar por su cuenta y podria divergir del batch.
export MEFISTO_RUNTIME="$BATCH_RUNTIME"

# Referencia de ejecucion de TODA la cadena (issue #1861, MEF-ADR-0055): se abre una
# vez, antes del primer eslabon, y sobrevive a huecos, hold, sync de main, espera de
# cuota y reintentos hasta el cierre del batch. Sin contexto transportado ni perfil
# autorizado (o con runtime Claude) conserva el camino previo, sin servicio ni lease.
_BATCH_PKG_ROOT="$(cd "$(_pc_script_dir)/.." && pwd -P)"
orchestrator_execution_open sequential "$REPO_ROOT" "$_BATCH_PKG_ROOT" "$RUNTIME_LIB_DIR" "$(_pc_script_dir)/run-published-agent.sh" \
    || abort "No se pudo abrir la ejecucion preparada del batch (contexto invalido, ocupado o revocado)"
orchestrator_install_exit_trap

# ─── Cabecera ─────────────────────────────────────────────────────────────────
header "batch-pipeline --- Procesamiento secuencial de issues"
log "Runtime: $MEFISTO_RUNTIME"
log "Pipeline: $([ -n "$PIPELINE_OVERRIDE" ] && echo "$PIPELINE_OVERRIDE (override)" || echo 'automatico por label')"
log "Issues a procesar: ${ISSUE_NUMS[*]}"
log "Modo en error: $([ "$STOP_ON_ERROR" = true ] && echo 'detener' || echo 'continuar')"
log "Log: $LOG_FILE_ABS"
log "Parada suave: /batch-stop detiene el batch tras el eslabon en curso (issue #974)"

# ─── Loop principal ───────────────────────────────────────────────────────────
COMPLETED=0
FAILED=0
TOTAL=${#ISSUE_NUMS[@]}

# Cola efectiva de esta corrida (issue #974): ISSUE_NUMS conserva el orden
# pedido -- es lo que recorre el resumen final --, mientras BATCH_QUEUE es lo
# que el loop realmente procesa. Vaciarla es como se salta el loop completo sin
# envolverlo en un `if` (que forzaria a reindentar todo su cuerpo).
BATCH_QUEUE=("${ISSUE_NUMS[@]}")
BATCH_PREFLIGHT_LAUNCHED=false

# Parada suave, momento 1 (CA-1): la senal ya estaba puesta antes de arrancar
# el primer eslabon, asi que ningun issue se procesa en esta corrida.
if batch_stop_requested; then
    warn "Parada solicitada ($BATCH_STOP_SIGNAL) antes de arrancar el primer eslabon: ningun issue se procesa en esta corrida."
    defer_from_index 0
    BATCH_QUEUE=()
fi

# Preflight de autonomia, plan inicial (issue #1826): tras consultar batch-stop, para que
# no se imponga sobre trabajo que no se ejecutara. Mismo resolutor y orden que el loop;
# cerrados/sin tipo/SKIP no entran al plan (conservan su semantica). Sin issues ruteables
# no se exige ninguna capacidad.
if [ ${#BATCH_QUEUE[@]} -gt 0 ]; then
    PLAN_ITEMS=()
    for PLAN_ISSUE in "${BATCH_QUEUE[@]}"; do
        PLAN_FACTS=$(resolve_pipeline_with_state "$PLAN_ISSUE" "$PIPELINE_OVERRIDE") || continue
        [ "${PLAN_FACTS%%|*}" = "OPEN" ] || continue
        PLAN_SCRIPT="${PLAN_FACTS#*|}"
        [[ "$PLAN_SCRIPT" == SKIP:* ]] && continue
        PLAN_KIND=$(orchestrator_kind_for_script "$PLAN_SCRIPT")
        [ -n "$PLAN_KIND" ] || continue
        [ -z "$(batch_plan_kind_for "$PLAN_ISSUE")" ] || continue
        BATCH_PLAN_NUMS+=("$PLAN_ISSUE")
        BATCH_PLAN_KINDS+=("$PLAN_KIND")
        PLAN_ITEMS+=("$PLAN_ISSUE:$PLAN_KIND")
    done
    if [ ${#PLAN_ITEMS[@]} -gt 0 ]; then
        if batch_autonomy_preflight "${PLAN_ITEMS[@]}"; then
            log "Preflight de autonomia: $PREFLIGHT_STATUS"
            if [ "$PREFLIGHT_STATUS" = "ready-to-dispatch" ] && [ -n "$PREFLIGHT_DEFERRED" ]; then
                log "Verificaciones diferidas al stage (no es permiso efectivo futuro): $PREFLIGHT_DEFERRED"
            fi
        else
            batch_preflight_block_from 0 "antes del primer issue"
            BATCH_QUEUE=()
        fi
    fi
fi

# ${a[@]+"${a[@]}"}: bash 3.2 aborta con "unbound variable" al expandir un array
# vacio bajo `set -u` (este script corre con `set -euo pipefail`), y la cola
# queda vacia justamente cuando la parada se pidio antes del primer eslabon.
for ISSUE_NUM in ${BATCH_QUEUE[@]+"${BATCH_QUEUE[@]}"}; do
    CURRENT=$((COMPLETED + FAILED + 1))
    header "Issue #$ISSUE_NUM ($CURRENT/$TOTAL)"

    # ── Pre-validacion y resolucion de pipeline (una sola llamada API) ──────
    STATE_AND_PIPELINE=$(resolve_pipeline_with_state "$ISSUE_NUM" "$PIPELINE_OVERRIDE")
    ISSUE_STATE="${STATE_AND_PIPELINE%%|*}"
    PIPELINE_SCRIPT="${STATE_AND_PIPELINE#*|}"

    if [ "$ISSUE_STATE" != "OPEN" ]; then
        log "Issue #$ISSUE_NUM esta $ISSUE_STATE --- saltando."
        FAILED=$((FAILED + 1))
        continue
    fi

    if [[ "$PIPELINE_SCRIPT" == SKIP:* ]]; then
        local_reason="${PIPELINE_SCRIPT#SKIP:}"
        warn "Issue #$ISSUE_NUM saltado ($local_reason) --- no se puede enrutar a un pipeline."
        FAILED=$((FAILED + 1))
        continue
    fi

    PIPELINE_NAME=$(basename "$PIPELINE_SCRIPT")

    # ── Preflight de autonomia antes de cada eslabon posterior al primero (#1826) ─
    # Reconsulta facts del issue que sigue (ya resueltos arriba), runtime, perfil/contexto
    # y plan restante: ninguna admision previa sobrevive por estar en memoria. Un bloqueo
    # nuevo termina el lanzamiento de la cola restante; el eslabon anterior ya concluyo.
    if [ "$BATCH_PREFLIGHT_LAUNCHED" = true ]; then
        REST_ITEMS=("$ISSUE_NUM:$(orchestrator_kind_for_script "$PIPELINE_SCRIPT")")
        for ((REST_I = CURRENT; REST_I < ${#ISSUE_NUMS[@]}; REST_I++)); do
            REST_KIND=$(batch_plan_kind_for "${ISSUE_NUMS[$REST_I]}")
            [ -z "$REST_KIND" ] || REST_ITEMS+=("${ISSUE_NUMS[$REST_I]}:$REST_KIND")
        done
        if ! batch_autonomy_preflight "${REST_ITEMS[@]}"; then
            batch_preflight_block_from $((CURRENT - 1)) "antes del issue #$ISSUE_NUM"
            break
        fi
    fi
    BATCH_PREFLIGHT_LAUNCHED=true

    # ── Stage 1: Ejecutar pipeline ────────────────────────────────────────────
    log "Ejecutando $PIPELINE_NAME para issue #$ISSUE_NUM..."

    ISSUE_LOG="$LOG_DIR/batch-issue-${ISSUE_NUM}-${TIMESTAMP}.log"
    touch "$ISSUE_LOG"

    # Marca de arranque para el reporte de hold de este eslabon (issue #973):
    # hold_seconds_in_range solo cuenta desde aqui, y ademas atribuye por
    # cabecera de sesion (tercer argumento) -- con el numero de linea solo,
    # otra corrida del mismo checkout intercalada en el mismo events.log le
    # regalaria sus esperas a este eslabon.
    HOLD_LINE_START=$(wc -l < "$EVENTS_LOG_ABS" 2>/dev/null | tr -d ' ')
    [ -z "$HOLD_LINE_START" ] && HOLD_LINE_START=0
    HOLD_LINE_START_LEGACY=0
    if [ -f "$EVENTS_LOG_LEGACY_ABS" ]; then
        HOLD_LINE_START_LEGACY=$(wc -l < "$EVENTS_LOG_LEGACY_ABS" 2>/dev/null | tr -d ' ')
        [ -z "$HOLD_LINE_START_LEGACY" ] && HOLD_LINE_START_LEGACY=0
    fi

    # Reserva del contexto hijo ANTES del spawn (issue #1861): si no se puede reservar
    # el eslabon no arranca y no se reporta como ejecutado.
    if ! orchestrator_reserve_child "$(orchestrator_kind_for_script "$PIPELINE_SCRIPT")" "$REPO_ROOT"; then
        fail_issue "$ISSUE_NUM" "no se pudo reservar el contexto de ejecucion del eslabon; el pipeline no se lanzo"
        FAILED=$((FAILED + 1))
        if [ "$STOP_ON_ERROR" = true ]; then
            abort "Detenido por --stop-on-error en issue #$ISSUE_NUM"
        fi
        continue
    fi

    PIPELINE_EXIT=0
    if [ -n "$ORCH_CHILD_ID" ]; then
        MEFISTO_EXECUTION_CONTEXT="$ORCH_CHILD_CONTEXT" MEFISTO_EXECUTION_DIGEST="$ORCH_CHILD_DIGEST" \
            "$PIPELINE_SCRIPT" "$ISSUE_NUM" 2>&1 | tee "$ISSUE_LOG" || PIPELINE_EXIT=$?
        orchestrator_finish_child "$(orchestrator_outcome_for "$PIPELINE_EXIT")" || true
    else
        "$PIPELINE_SCRIPT" "$ISSUE_NUM" 2>&1 | tee "$ISSUE_LOG" || PIPELINE_EXIT=$?
    fi

    # Agregar el log del issue al log general
    cat "$ISSUE_LOG" | _strip_ansi >> "$LOG_FILE_ABS"

    # Segundos en espera (hold) durante ESTE eslabon (issue #973): se anotan
    # como nota ANEXA a cualquier desenlace -- completado o fallido -- porque
    # un eslabon puede haber esperado horas y fallar igual al agotar el techo
    # de espera, y ese tiempo explica su reloj. Nunca cambia
    # FAILED/HAVE_ERRORS/--stop-on-error ni el exit code (CA-1/CA-5).
    ISSUE_HOLD_SECONDS=$(hold_seconds_in_all_events_logs "$ISSUE_NUM" "$HOLD_LINE_START" "$HOLD_LINE_START_LEGACY")
    ISSUE_HELD_NOTE="$(hold_note_suffix "$ISSUE_HOLD_SECONDS")"
    if [ "$ISSUE_HOLD_SECONDS" -gt 0 ]; then
        BATCH_TOTAL_HOLD_SECONDS=$(( BATCH_TOTAL_HOLD_SECONDS + ISSUE_HOLD_SECONDS ))
        log "Issue #$ISSUE_NUM: $(fmt_hold_duration "$ISSUE_HOLD_SECONDS") en espera (hold) durante este eslabon -- no cuenta como fallo"
    fi

    if [ "$PIPELINE_EXIT" -ne 0 ]; then
        fail_issue "$ISSUE_NUM" "pipeline fallo (exit $PIPELINE_EXIT). Log: $ISSUE_LOG$ISSUE_HELD_NOTE"
        FAILED=$((FAILED + 1))
        if [ "$STOP_ON_ERROR" = true ]; then
            abort "Detenido por --stop-on-error en issue #$ISSUE_NUM"
        fi
        continue
    fi

    # ── Stage 2: Extraer número de PR ────────────────────────────────────────
    # tdd-pipeline.sh imprime: "PR creado: https://github.com/owner/repo/pull/NNN"
    # y también: "  PR:      https://github.com/owner/repo/pull/NNN"
    PR_URL=$(cat "$ISSUE_LOG" \
        | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' \
        | head -1)

    if [ -z "$PR_URL" ]; then
        fail_issue "$ISSUE_NUM" "no se pudo extraer la URL del PR del output. Log: $ISSUE_LOG$ISSUE_HELD_NOTE"
        FAILED=$((FAILED + 1))
        if [ "$STOP_ON_ERROR" = true ]; then
            abort "Detenido por --stop-on-error en issue #$ISSUE_NUM"
        fi
        continue
    fi

    PR_NUM=$(echo "$PR_URL" | grep -oE '[0-9]+$')
    set_pr "$ISSUE_NUM" "$PR_NUM"
    success "Pipeline completado → PR #$PR_NUM ($PR_URL)"

    # ── Stage 3: Merge del PR ─────────────────────────────────────────────────
    log "Mergeando PR #$PR_NUM a main..."

    SYNC_EXIT=0
    "$(_pc_script_dir)/pr-sync.sh" "$PR_NUM" --merge 2>&1 | tee -a "$ISSUE_LOG" || SYNC_EXIT=$?

    cat "$ISSUE_LOG" | _strip_ansi >> "$LOG_FILE_ABS"

    if [ "$SYNC_EXIT" -ne 0 ]; then
        fail_issue "$ISSUE_NUM" "merge del PR #$PR_NUM falló (exit $SYNC_EXIT). Log: $ISSUE_LOG$ISSUE_HELD_NOTE"
        FAILED=$((FAILED + 1))
        if [ "$STOP_ON_ERROR" = true ]; then
            abort "Detenido por --stop-on-error en issue #$ISSUE_NUM"
        fi
        continue
    fi

    # ── Stage 4: Actualizar main local para el siguiente issue ────────────────
    log "Actualizando main local..."
    git pull origin main >>"$LOG_FILE_ABS" 2>&1 || warn "git pull origin main falló (continuando)"

    set_status "$ISSUE_NUM" "completado (PR #$PR_NUM mergeado)$ISSUE_HELD_NOTE"
    COMPLETED=$((COMPLETED + 1))
    success "Issue #$ISSUE_NUM completado y mergeado$ISSUE_HELD_NOTE"

    # Parada suave, momento 2 (CA-1): el unico punto seguro de la cadena -- el
    # PR ya esta mergeado. Un eslabon fallido (pipeline/PR/merge) nunca llega
    # aqui: sus `continue` de arriba lo saltan.
    if batch_stop_requested; then
        if [ "$CURRENT" -lt "$TOTAL" ]; then
            warn "Parada solicitada ($BATCH_STOP_SIGNAL) tras completar #$ISSUE_NUM: los eslabones restantes quedan aplazados, sin arrancar ningun worktree."
        else
            warn "Parada solicitada ($BATCH_STOP_SIGNAL) tras completar #$ISSUE_NUM, que era el ultimo eslabon del batch: no quedaba ninguno por arrancar. La senal se consumio igual, para no afectar la corrida siguiente."
        fi
        defer_from_index "$CURRENT"
        break
    fi
done

# ─── Resumen final ────────────────────────────────────────────────────────────
header "Resumen"
echo -e ""
printf "${BOLD}%-10s %-8s %-45s${NC}\n" "Issue" "PR" "Estado"
printf "%s\n" "─────────────────────────────────────────────────────────────────"

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

# Issues aplazados (issue #974, CA-4): en el mismo orden en que quedaron en
# ISSUE_NUMS, para que la linea de relanzamiento respete el orden del batch.
DEFERRED_NUMS=()
for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
    case "$(get_status "$ISSUE_NUM")" in
        aplazado*) DEFERRED_NUMS+=("$ISSUE_NUM") ;;
    esac
done
DEFERRED=${#DEFERRED_NUMS[@]}
NOT_STARTED=0
for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
    case "$(get_status "$ISSUE_NUM")" in
        "no iniciado por preflight"*) NOT_STARTED=$((NOT_STARTED + 1)) ;;
    esac
done

echo ""
echo -e "  Total: $TOTAL  |  ${GREEN}Completados: $COMPLETED${NC}  |  ${RED}Fallidos: $FAILED${NC}  |  ${YELLOW}Aplazados: $DEFERRED${NC}"
if [ "$NOT_STARTED" -gt 0 ]; then
    echo -e "  ${RED}No iniciados por preflight: $NOT_STARTED${NC}"
fi
echo -e "  Log: $LOG_FILE_ABS"
# Tiempo total en espera (issue #973): informativo, aparte del recuento de
# desenlaces -- una espera nunca es un fallo ni un aplazado.
if [ "$BATCH_TOTAL_HOLD_SECONDS" -gt 0 ]; then
    echo -e "  ${YELLOW}En espera (hold) durante el batch: $(fmt_hold_duration "$BATCH_TOTAL_HOLD_SECONDS")${NC} -- por limite de uso o caida del proveedor, no cuenta como fallo"
fi
echo ""

if [ "$DEFERRED" -gt 0 ]; then
    warn "Parada solicitada: $DEFERRED issue(s) quedaron aplazados en esta corrida. No es un fallo del batch: el exit code no cambia por esto y nada quedo a medio pipeline."
    echo -e "  Relanza los aplazados, en el mismo orden: ${BOLD}/sequential ${DEFERRED_NUMS[*]}${NC}"
    echo ""
fi

if [ "$BATCH_PREFLIGHT_BLOCKED" = true ]; then
    warn "Preflight de autonomia: $NOT_STARTED issue(s) no iniciados por preflight. No se reintento ni se amplio ningun permiso. Log: $LOG_FILE_ABS"
    exit 1
fi

if [ "$HAVE_ERRORS" = true ]; then
    warn "Algunos issues tuvieron errores. Revisa el log: $LOG_FILE_ABS"
    exit 1
fi
success "batch-pipeline completado. Log: $LOG_FILE_ABS"
