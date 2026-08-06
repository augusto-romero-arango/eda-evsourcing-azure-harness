#!/usr/bin/env bash
# mefisto-batch-pipeline.sh -- Procesa issues internos de Mefisto secuencialmente
#
# Uso:
#   ./.claude/scripts/mefisto-batch-pipeline.sh 42 43 44
#   ./.claude/scripts/mefisto-batch-pipeline.sh 42 43 --stop-on-error
#
# Flujo por issue:
#   1. ./.claude/scripts/mefisto-tooling-pipeline.sh <issue>
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
#   mefisto-tooling-pipeline.sh:269) -- no de la rama activa del repo. El motor
#   exige arrancar en main/master solo para mantener main LOCAL comodo para el
#   humano entre eslabones, no porque el worktree parta de ahi.
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

# --- Logging ---
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PIPELINE_DIR=".claude/pipeline"
LOG_DIR="$PIPELINE_DIR/logs"
LOG_FILE="$LOG_DIR/mefisto-batch-$TIMESTAMP.log"

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

fail_issue() {
    local issue="$1" msg="$2"
    echo -e "\n${RED}${BOLD}x Issue #$issue: $msg${NC}" | tee -a "$LOG_FILE_ABS"
    set_status "$issue" "ERROR: $msg"
    HAVE_ERRORS=true
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
# Lee:    MAIN_BRANCH (rama activa del repo AL ARRANQUE, validada como main/master)
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
mkdir -p "$LOG_DIR"
LOG_FILE_ABS="$REPO_ROOT/$LOG_FILE"
touch "$LOG_FILE_ABS"

# Inicializar status tracker
for issue in "${ISSUE_NUMS[@]}"; do
    set_status "$issue" "pendiente"
done

# --- Verificar dependencias ---
MISSING_DEPS=""
for dep in claude gh git; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        MISSING_DEPS="$MISSING_DEPS $dep"
    fi
done
if [ -n "$MISSING_DEPS" ]; then
    echo -e "${RED}${BOLD}x Dependencias faltantes:${MISSING_DEPS}${NC}"
    exit 1
fi

# --- Verificar que el repo principal arranca en main/master ---
# Cada worktree del tooling-pipeline nace SIEMPRE de origin/main, sea cual sea
# la rama activa del repo principal (issue #66, mefisto-tooling-pipeline.sh:
# 249-270); ese invariante no depende de este gate. La razon real de exigir
# main/master aqui es mantener main LOCAL sincronizado entre eslabones para el
# humano que sigue la corrida (issue #566) -- arrancar en otra rama generaria
# sorpresas ahi, aunque la cadena en si seguiria siendo correcta. Fail-loud:
# abortamos con un mensaje claro en vez de seguir (issue #46, robustez).
MAIN_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$MAIN_BRANCH" != "main" ] && [ "$MAIN_BRANCH" != "master" ]; then
    abort "El repo principal esta en la rama '$MAIN_BRANCH', no en main/master. Cada worktree del tooling-pipeline nace de origin/main sin importar la rama activa (issue #66), pero el batch tambien mantiene main LOCAL sincronizado entre eslabones para el humano que sigue la corrida -- arrancar fuera de main/master genera sorpresas ahi. Haz 'git switch main' antes de lanzar el batch."
fi

# --- Cabecera ---
header "mefisto-batch-pipeline --- Procesamiento secuencial de issues internos"
log "Pipeline: mefisto-tooling (unico pipeline interno de Mefisto)"
log "Issues a procesar: ${ISSUE_NUMS[*]}"
log "Rama base: $MAIN_BRANCH (el batch la mantiene sincronizada con origin/main entre eslabones; cada worktree nace de origin/main, issue #66)"
log "Modo en error: $([ "$STOP_ON_ERROR" = true ] && echo 'detener' || echo 'continuar')"
log "Log: $LOG_FILE_ABS"

PIPELINE_SCRIPT="./.claude/scripts/mefisto-tooling-pipeline.sh"
if [ ! -x "$PIPELINE_SCRIPT" ]; then
    abort "No se encontro el pipeline interno: $PIPELINE_SCRIPT"
fi

# --- Loop principal ---
COMPLETED=0
FAILED=0
TOTAL=${#ISSUE_NUMS[@]}

for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
    CURRENT=$((COMPLETED + FAILED + 1))
    header "Issue #$ISSUE_NUM ($CURRENT/$TOTAL)"

    # -- Stage 1: Ejecutar pipeline interno --
    # El propio pipeline interno valida que el issue exista y este OPEN.
    # Aqui solo capturamos el exit code y lo registramos como error del issue.
    log "Ejecutando mefisto-tooling-pipeline.sh para issue #$ISSUE_NUM..."

    ISSUE_LOG="$REPO_ROOT/$LOG_DIR/mefisto-batch-issue-${ISSUE_NUM}-${TIMESTAMP}.log"
    touch "$ISSUE_LOG"

    PIPELINE_EXIT=0
    "$PIPELINE_SCRIPT" "$ISSUE_NUM" 2>&1 | tee "$ISSUE_LOG" || PIPELINE_EXIT=$?

    # Agregar el log del issue al log general (sin codigos ANSI)
    _strip_ansi < "$ISSUE_LOG" >> "$LOG_FILE_ABS"

    if [ "$PIPELINE_EXIT" -ne 0 ]; then
        fail_issue "$ISSUE_NUM" "pipeline fallo (exit $PIPELINE_EXIT). Log: $ISSUE_LOG"
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
        fail_issue "$ISSUE_NUM" "no se pudo extraer la URL del PR del output. Log: $ISSUE_LOG"
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
    # .claude/commands/mefisto-merge.md).
    log "Mergeando PR #$PR_NUM a main (squash + delete-branch)..."

    MERGE_EXIT=0
    gh pr merge "$PR_NUM" --squash --delete-branch 2>&1 | tee -a "$ISSUE_LOG" || MERGE_EXIT=$?

    _strip_ansi < "$ISSUE_LOG" >> "$LOG_FILE_ABS"

    if [ "$MERGE_EXIT" -ne 0 ]; then
        fail_issue "$ISSUE_NUM" "merge del PR #$PR_NUM fallo (exit $MERGE_EXIT). Log: $ISSUE_LOG"
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
    # nace de origin/main (mefisto-tooling-pipeline.sh:269), que ya esta al dia.
    IS_LAST_ISSUE=false
    [ "$CURRENT" -eq "$TOTAL" ] && IS_LAST_ISSUE=true

    log "Sincronizando $MAIN_BRANCH con origin (verificado)..."
    SYNC_RC=0
    sync_main_after_merge "$PR_NUM" || SYNC_RC=$?

    if [ "$SYNC_RC" -eq 0 ]; then
        success "$MAIN_BRANCH local incluye el merge del PR #$PR_NUM (commit ${MERGE_SHA_SYNCED:0:12})"
        set_status "$ISSUE_NUM" "completado (PR #$PR_NUM mergeado)"
        COMPLETED=$((COMPLETED + 1))
        success "Issue #$ISSUE_NUM completado y mergeado"
    elif [ "$SYNC_RC" -eq 1 ]; then
        # origin/main SI tiene el merge confirmado (paso 3 exitoso): la correccion
        # de la cadena esta garantizada aunque main LOCAL no haya quedado
        # sincronizado. No fatal (CA-3): degrada a warning y continua.
        set_status "$ISSUE_NUM" "completado (PR #$PR_NUM mergeado; sync de $MAIN_BRANCH LOCAL fallido, no fatal)"
        COMPLETED=$((COMPLETED + 1))
        HAVE_WARNINGS=true
        success "Issue #$ISSUE_NUM completado y mergeado"
        warn "El commit de merge ${MERGE_SHA_SYNCED:0:12} del PR #$PR_NUM ya esta confirmado en origin/main; solo fallo dejar $MAIN_BRANCH LOCAL sincronizado. No bloquea la cadena: el siguiente worktree nace de origin/main. Para ponerte al dia: 'git switch $MAIN_BRANCH && git pull --ff-only'."
    else
        # SYNC_RC = 2: el merge commit no llego a origin/main. El PR ya quedo
        # mergeado (el issue en si esta resuelto), pero el siguiente worktree
        # naceria de una base desactualizada. Esto SI rompe la cadena.
        set_status "$ISSUE_NUM" "completado (PR #$PR_NUM mergeado; sync de origin/main FALLIDO)"
        COMPLETED=$((COMPLETED + 1))
        HAVE_ERRORS=true
        if [ "$IS_LAST_ISSUE" = true ]; then
            warn "El sync verificado de origin/main fallo, pero #$ISSUE_NUM era el ultimo eslabon: ningun issue posterior depende de este merge."
        else
            abort "Sync verificado de origin/main tras el PR #$PR_NUM fallo: el commit de merge no quedo confirmado en origin/main. El siguiente eslabon naceria de una base desactualizada, asi que la cadena se aborta. Revisa el log: $LOG_FILE_ABS"
        fi
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

echo ""
echo -e "  Total: $TOTAL  |  ${GREEN}Completados: $COMPLETED${NC}  |  ${RED}Fallidos: $FAILED${NC}"
echo -e "  Log: $LOG_FILE_ABS"
echo ""

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
