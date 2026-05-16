#!/usr/bin/env bash
# pr-sync.sh — Sincroniza ramas de PRs abiertos con main
#
# Uso:
#   ./scripts/pr-sync.sh 40 41 42               # sincronizar PRs en orden
#   ./scripts/pr-sync.sh 40 41 42 --merge       # sincronizar y mergear cada uno
#   ./scripts/pr-sync.sh --all                   # todos los PRs abiertos
#   ./scripts/pr-sync.sh --all --merge           # sincronizar y mergear todos
#
# Compatible con bash 3.2+ (macOS nativo)

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"
load_harness_config || exit 1

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
PIPELINE_DIR=".claude/pipeline"
LOG_DIR="$PIPELINE_DIR/logs"
LOG_FILE="$LOG_DIR/pr-sync-$TIMESTAMP.log"

_strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
_log_file()   { echo -e "$1" | _strip_ansi >> "$LOG_FILE_ABS"; }

log()     { local m="${BLUE}[$(date +%H:%M:%S)]${NC} $1"; echo -e "$m"; _log_file "$m"; }
success() { local m="${GREEN}${BOLD}✓${NC} $1"; echo -e "$m"; _log_file "$m"; }
warn()    { local m="${YELLOW}⚠${NC} $1"; echo -e "$m"; _log_file "$m"; }
header()  { local m="\n${CYAN}${BOLD}── $1 ──${NC}"; echo -e "$m"; _log_file "$m"; }

# ─── Status tracker (compatible bash 3.2, sin declare -A) ────────────────────
PR_STATUS_NUMS=()
PR_STATUS_VALUES=()
PR_STATUS_BRANCHES=()

set_status() {
    local pr="$1" val="$2"
    local i
    for i in "${!PR_STATUS_NUMS[@]}"; do
        if [ "${PR_STATUS_NUMS[$i]}" = "$pr" ]; then
            PR_STATUS_VALUES[$i]="$val"
            return
        fi
    done
    PR_STATUS_NUMS+=("$pr")
    PR_STATUS_VALUES+=("$val")
}

get_status() {
    local pr="$1" i
    for i in "${!PR_STATUS_NUMS[@]}"; do
        if [ "${PR_STATUS_NUMS[$i]}" = "$pr" ]; then
            echo "${PR_STATUS_VALUES[$i]}"
            return
        fi
    done
    echo "desconocido"
}

set_branch() {
    local pr="$1" branch="$2"
    local i
    for i in "${!PR_STATUS_NUMS[@]}"; do
        if [ "${PR_STATUS_NUMS[$i]}" = "$pr" ]; then
            PR_STATUS_BRANCHES[$i]="$branch"
            return
        fi
    done
    # Si no existe, crear entrada
    PR_STATUS_NUMS+=("$pr")
    PR_STATUS_VALUES+=("pendiente")
    PR_STATUS_BRANCHES+=("$branch")
}

get_branch() {
    local pr="$1" i
    for i in "${!PR_STATUS_NUMS[@]}"; do
        if [ "${PR_STATUS_NUMS[$i]}" = "$pr" ]; then
            echo "${PR_STATUS_BRANCHES[$i]:-"(no disponible)"}"
            return
        fi
    done
    echo "(no disponible)"
}

# ─── Abort de PR individual (no detiene el loop) ─────────────────────────────
CURRENT_WORKTREE=""
HAVE_ERRORS=false

fail_pr() {
    local pr="$1" msg="$2"
    echo -e "\n${RED}${BOLD}✗ PR #$pr: $msg${NC}" | tee -a "$LOG_FILE_ABS"
    set_status "$pr" "ERROR: $msg"
    HAVE_ERRORS=true

    # Limpiar worktree si existe
    if [ -n "${CURRENT_WORKTREE:-}" ] && [ -d "${CURRENT_WORKTREE:-}" ]; then
        warn "Worktree temporal queda en: $CURRENT_WORKTREE (para inspección)"
        git worktree remove --force "$CURRENT_WORKTREE" >>"$LOG_FILE_ABS" 2>&1 || true
    fi
    CURRENT_WORKTREE=""
}

# ─── Parsear argumentos ───────────────────────────────────────────────────────
PR_NUMS=()
DO_MERGE=false
DO_ALL=false

if [ $# -eq 0 ]; then
    echo "Uso: $0 [PR_NUM...] [--all] [--merge]"
    echo "  PR_NUM...   Números de PRs a sincronizar (en orden)"
    echo "  --all       Sincronizar todos los PRs abiertos"
    echo "  --merge     Mergear a main después de sincronizar"
    exit 1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --merge) DO_MERGE=true; shift ;;
        --all)   DO_ALL=true; shift ;;
        [0-9]*)  PR_NUMS+=("$1"); shift ;;
        *)
            echo "Argumento desconocido: $1"
            exit 1
            ;;
    esac
done

# ─── Verificar que estamos en el repo correcto ────────────────────────────────
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
    || { echo "No estás en un repositorio git"; exit 1; }

# Guard defensivo: este script es del lado publicado y solo aplica al consumidor.
# Para mergear PRs del repo de Mefisto, usa /mefisto-merge.
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/pr-sync.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Estás en el repo de Mefisto. Para mergear PRs del plugin, usa /mefisto-merge." >&2
    exit 1
fi

cd "$REPO_ROOT"

# ─── Inicializar log ──────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
LOG_FILE_ABS="$REPO_ROOT/$LOG_FILE"
touch "$LOG_FILE_ABS"

header "pr-sync — Sincronización de PRs con main"
log "Log: $LOG_FILE_ABS"

# ─── Verificar dependencias ───────────────────────────────────────────────────
MISSING_DEPS=""
for dep in claude gh git dotnet; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        MISSING_DEPS="$MISSING_DEPS $dep"
    fi
done
if [ -n "$MISSING_DEPS" ]; then
    echo -e "${RED}${BOLD}✗ Dependencias faltantes:${MISSING_DEPS}${NC}"
    exit 1
fi

# ─── Resolver lista de PRs (compatible bash 3.2, sin mapfile) ─────────────────
if [ "$DO_ALL" = true ]; then
    log "Obteniendo todos los PRs abiertos..."
    PR_NUMS=()
    while IFS= read -r num; do
        [ -n "$num" ] && PR_NUMS+=("$num")
    done < <(gh pr list --state open --json number -q '.[].number' | sort -n)
    if [ ${#PR_NUMS[@]} -eq 0 ]; then
        log "No hay PRs abiertos."
        exit 0
    fi
fi

if [ ${#PR_NUMS[@]} -eq 0 ]; then
    echo -e "${RED}${BOLD}✗ No se especificaron PRs. Usa --all o proporciona números de PR.${NC}"
    exit 1
fi

log "PRs a procesar (en orden): ${PR_NUMS[*]}"
if [ "$DO_MERGE" = true ]; then
    warn "Modo --merge activado: cada PR será mergeado a main después de sincronizar"
fi

# ─── Función: invocar agente ──────────────────────────────────────────────────
LOG_DIR_ABS="$REPO_ROOT/$LOG_DIR"
mkdir -p "$LOG_DIR_ABS"

run_agent() {
    local label="$1"
    local agent="$2"
    local prompt="$3"
    local worktree="$4"
    local log_file="$LOG_DIR_ABS/pr-sync-${label}-${TIMESTAMP}.log"
    local start_ts
    start_ts=$(date +%s)

    log "Invocando $agent ($label)..."

    (cd "$worktree" && claude -p "$prompt" \
        --agent "$agent" \
        --permission-mode bypassPermissions \
        --output-format text \
        >"$log_file" 2>&1) || {
        local elapsed=$(( $(date +%s) - start_ts ))
        warn "$agent falló después de ${elapsed}s"
        echo -e "\n${RED}── Últimas líneas del log de $agent:${NC}"
        tail -20 "$log_file"
        return 1
    }

    local elapsed=$(( $(date +%s) - start_ts ))
    log "$agent completado en ${elapsed}s"
}

# ─── Función: validar tests post-merge ────────────────────────────────────────
validate_tests() {
    local worktree="$1"
    local test_output


    # Build explícito: dotnet test con compilación implícita falla en worktrees
    # por FileNotFoundException en assemblies de proyecto (Contracts).
    local build_output
    build_output=$(dotnet build "$worktree/${HARNESS_SOLUTION_FILE}" 2>&1)
    local build_rc=$?
    echo "$build_output" >> "$LOG_FILE_ABS"
    if [ "$build_rc" -ne 0 ]; then
        echo "$build_output"
        return 2  # error de compilación
    fi

    local test_rc=0
    test_output=$(dotnet test --solution "$worktree/${HARNESS_SOLUTION_FILE}" --no-build 2>&1) || test_rc=$?
    echo "$test_output" >> "$LOG_FILE_ABS"

    # Exit codes de Microsoft.Testing.Platform:
    #   0 = todos pasan, 2 = tests fallando, 8 = sin tests
    # Errores de compilación producen exit code 1 con "error CS/MSB" en la salida
    case "$test_rc" in
        0) ;;  # todo bien, continuar
        2)
            echo "$test_output"
            return 1  # tests fallidos
            ;;
        8)
            echo "$test_output"
            return 3  # no se ejecutaron tests
            ;;
        *)
            # Exit code 1 u otro: verificar si es error de compilación
            if echo "$test_output" | grep -qE "error CS[0-9]+:|error MSB[0-9]+:|Build FAILED"; then
                echo "$test_output"
                return 2  # error de compilación
            fi
            echo "$test_output"
            return 1  # otro error de tests
            ;;
    esac

    echo "$test_output"
    return 0
}

# ─── Función: mergear PR con retry (P2) ──────────────────────────────────────
merge_pr_with_retry() {
    local pr_num="$1"
    local max_retries=5
    local wait_seconds=3
    local attempt

    for attempt in $(seq 1 "$max_retries"); do
        # Consultar estado de mergeabilidad en GitHub
        local status
        status=$(gh pr view "$pr_num" --json mergeStateStatus -q '.mergeStateStatus' 2>/dev/null || echo "UNKNOWN")

        if [ "$status" = "CLEAN" ] || [ "$status" = "UNSTABLE" ] || [ "$status" = "HAS_HOOKS" ]; then
            if gh pr merge "$pr_num" --merge --delete-branch >>"$LOG_FILE_ABS" 2>&1; then
                return 0
            fi
        fi

        if [ "$attempt" -lt "$max_retries" ]; then
            log "GitHub aún no reporta PR #$pr_num como mergeable (estado: $status). Reintentando en ${wait_seconds}s... ($attempt/$max_retries)"
            sleep "$wait_seconds"
            wait_seconds=$((wait_seconds * 2))
        fi
    done

    warn "PR #$pr_num no fue mergeable después de $max_retries intentos (último estado: $status)"
    return 1
}

# ─── Función: desbloquear issues dependientes tras merge ─────────────────
desbloquear_issues_dependientes() {
    local pr_num="$1"

    # Obtener body del PR para extraer "Closes #N"
    local pr_body
    pr_body=$(gh pr view "$pr_num" --json body -q '.body' 2>/dev/null || echo "")
    if [ -z "$pr_body" ]; then
        return 0
    fi

    # Extraer todos los issue numbers cerrados por este PR
    local closed_issues=()
    local match
    while IFS= read -r match; do
        [ -n "$match" ] && closed_issues+=("$match")
    done < <(echo "$pr_body" | grep -ioE 'Closes #[0-9]+' | grep -oE '[0-9]+')

    if [ ${#closed_issues[@]} -eq 0 ]; then
        return 0
    fi

    log "PR #$pr_num cierra issue(s): ${closed_issues[*]}. Buscando issues bloqueados dependientes..."

    # Obtener todos los issues abiertos con label "bloqueado"
    local bloqueados_json
    bloqueados_json=$(gh issue list --state open --label "bloqueado" --json number,body,title 2>/dev/null || echo "[]")

    if [ "$bloqueados_json" = "[]" ] || [ -z "$bloqueados_json" ]; then
        log "No hay issues con label 'bloqueado'."
        return 0
    fi

    # Para cada issue bloqueado, verificar si depende de alguno de los issues cerrados
    local bloqueado_count
    bloqueado_count=$(echo "$bloqueados_json" | jq 'length')

    local idx=0
    while [ "$idx" -lt "$bloqueado_count" ]; do
        local bloqueado_num
        bloqueado_num=$(echo "$bloqueados_json" | jq -r ".[$idx].number")
        local bloqueado_body
        bloqueado_body=$(echo "$bloqueados_json" | jq -r ".[$idx].body // \"\"")
        local bloqueado_title
        bloqueado_title=$(echo "$bloqueados_json" | jq -r ".[$idx].title // \"\"")

        # Extraer seccion ## Dependencias del body
        # Usa awk para compatibilidad con macOS (head -n -1 no funciona en BSD)
        local deps_section
        deps_section=$(echo "$bloqueado_body" | awk '/^## Dependencias/{found=1; next} /^## /{found=0} found{print}')

        # Verificar si este issue bloqueado referencia alguno de los issues cerrados
        local referencia_cerrado=false
        local closed_num
        for closed_num in "${closed_issues[@]}"; do
            if echo "$deps_section" | grep -qE "#${closed_num}([^0-9]|$)"; then
                referencia_cerrado=true
                break
            fi
        done

        if [ "$referencia_cerrado" = true ]; then
            # Extraer TODAS las dependencias del issue bloqueado
            local all_deps=()
            local dep_num
            while IFS= read -r dep_num; do
                [ -n "$dep_num" ] && all_deps+=("$dep_num")
            done < <(echo "$deps_section" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -u)

            # Verificar si TODAS las dependencias estan cerradas/mergeadas
            local todas_cerradas=true
            local dep_abierta=""
            for dep_num in "${all_deps[@]}"; do
                local dep_state
                # Intentar como issue primero
                dep_state=$(gh issue view "$dep_num" --json state -q '.state' 2>/dev/null || echo "")
                if [ "$dep_state" = "CLOSED" ]; then
                    continue
                fi
                # Intentar como PR
                dep_state=$(gh pr view "$dep_num" --json state -q '.state' 2>/dev/null || echo "")
                if [ "$dep_state" = "MERGED" ] || [ "$dep_state" = "CLOSED" ]; then
                    continue
                fi
                # Si llegamos aqui, la dependencia sigue abierta
                todas_cerradas=false
                dep_abierta="$dep_num"
                break
            done

            if [ "$todas_cerradas" = true ]; then
                log "Desbloqueando issue #$bloqueado_num: $bloqueado_title"
                if gh issue edit "$bloqueado_num" --remove-label "bloqueado" >>"$LOG_FILE_ABS" 2>&1; then
                    success "Issue #$bloqueado_num desbloqueado: $bloqueado_title"
                else
                    warn "No se pudo quitar el label 'bloqueado' del issue #$bloqueado_num"
                fi
            else
                log "Issue #$bloqueado_num sigue bloqueado (dependencia #$dep_abierta aun abierta)"
            fi
        fi

        idx=$((idx + 1))
    done
}

# ─── Loop principal ───────────────────────────────────────────────────────────
for PR_NUM in "${PR_NUMS[@]}"; do
    header "PR #$PR_NUM"
    CURRENT_WORKTREE=""

    # Verificar que el PR sigue abierto
    PR_STATE=$(gh pr view "$PR_NUM" --json state -q '.state' 2>/dev/null || echo "NOT_FOUND")
    if [ "$PR_STATE" != "OPEN" ]; then
        warn "PR #$PR_NUM no está abierto (estado: $PR_STATE). Saltando."
        set_status "$PR_NUM" "omitido ($PR_STATE)"
        set_branch "$PR_NUM" "(n/a)"
        continue
    fi

    # Obtener rama del PR
    BRANCH_NAME=$(gh pr view "$PR_NUM" --json headRefName -q '.headRefName')
    log "Rama: $BRANCH_NAME"
    set_branch "$PR_NUM" "$BRANCH_NAME"

    # Actualizar referencias remotas
    log "Actualizando referencias remotas..."
    if ! git fetch origin main >>"$LOG_FILE_ABS" 2>&1; then
        fail_pr "$PR_NUM" "No se pudo hacer fetch de origin/main"
        continue
    fi
    if ! git fetch origin "$BRANCH_NAME" >>"$LOG_FILE_ABS" 2>&1; then
        fail_pr "$PR_NUM" "No se pudo hacer fetch de origin/$BRANCH_NAME"
        continue
    fi

    # Calcular si la rama está detrás de main
    BEHIND=$(git rev-list "origin/$BRANCH_NAME..origin/main" --count)

    if [ "$BEHIND" -eq 0 ]; then
        success "PR #$PR_NUM ya está al día con main. Nada que hacer."
        set_status "$PR_NUM" "al día"

        if [ "$DO_MERGE" = true ]; then
            log "Mergeando PR #$PR_NUM a main..."
            if merge_pr_with_retry "$PR_NUM"; then
                success "PR #$PR_NUM mergeado a main"
                set_status "$PR_NUM" "mergeado"
                desbloquear_issues_dependientes "$PR_NUM"
                git fetch origin main >>"$LOG_FILE_ABS" 2>&1 || true
            else
                fail_pr "$PR_NUM" "No se pudo mergear después de reintentos"
            fi
        fi
        continue
    fi

    log "main tiene $BEHIND commit(s) nuevos respecto a la rama."

    # Crear worktree temporal (realpath evita el symlink /tmp→/private/tmp en macOS
    # que confunde a dotnet con rutas duplicadas para el mismo proyecto)
    TEMP_WORKTREE="$(realpath /tmp)/pr-sync-${PR_NUM}-$(date +%s)"
    CURRENT_WORKTREE="$TEMP_WORKTREE"

    log "Creando worktree temporal en $TEMP_WORKTREE..."
    if ! git worktree add "$TEMP_WORKTREE" --detach "origin/$BRANCH_NAME" >>"$LOG_FILE_ABS" 2>&1; then
        fail_pr "$PR_NUM" "No se pudo crear el worktree temporal"
        continue
    fi

    # Establecer rama local con el nombre correcto
    if ! git -C "$TEMP_WORKTREE" checkout -B "$BRANCH_NAME" "origin/$BRANCH_NAME" >>"$LOG_FILE_ABS" 2>&1; then
        fail_pr "$PR_NUM" "No se pudo hacer checkout de la rama $BRANCH_NAME"
        continue
    fi

    # Copiar settings.json con rutas absolutas (igual que tdd-pipeline.sh)
    if [ -f "$REPO_ROOT/.claude/settings.json" ]; then
        mkdir -p "$TEMP_WORKTREE/.claude"
        sed "s|\.claude/pipeline/events\.log|$REPO_ROOT/.claude/pipeline/events.log|g" \
            "$REPO_ROOT/.claude/settings.json" > "$TEMP_WORKTREE/.claude/settings.json"
    fi

    # Merge de main
    log "Haciendo merge de origin/main..."
    if git -C "$TEMP_WORKTREE" merge origin/main --no-edit >>"$LOG_FILE_ABS" 2>&1; then
        success "Merge automático exitoso"
    else
        warn "Merge con conflictos. Invocando implementer para resolverlos..."

        CONFLICT_FILES=$(git -C "$TEMP_WORKTREE" diff --name-only --diff-filter=U)
        log "Archivos en conflicto: $CONFLICT_FILES"

        MERGE_PROMPT="Estás en el directorio raíz del proyecto ${HARNESS_PROJECT_NAME}.

Hay conflictos de merge con la rama main en los siguientes archivos:
$CONFLICT_FILES

Resuelve los conflictos manteniendo tanto la funcionalidad nueva (de esta rama) como la existente (de main).
Después de resolver cada archivo, haz git add del archivo.
Cuando todos estén resueltos, haz git commit para completar el merge.
NO elimines código de ninguna de las dos ramas — integra ambos cambios."

        if ! run_agent "merge-pr${PR_NUM}" "implementer" "$MERGE_PROMPT" "$TEMP_WORKTREE"; then
            fail_pr "$PR_NUM" "El agente implementer falló al resolver conflictos"
            continue
        fi

        REMAINING=$(git -C "$TEMP_WORKTREE" diff --name-only --diff-filter=U 2>/dev/null || true)
        if [ -n "$REMAINING" ]; then
            fail_pr "$PR_NUM" "Aún quedan conflictos después del agente: $REMAINING"
            continue
        fi
        success "Conflictos resueltos"
    fi

    # Verificar tests post-merge (P3: validación robusta)
    log "Verificando tests después del merge..."
    TEST_EXIT=0
    TEST_OUTPUT=$(validate_tests "$TEMP_WORKTREE") || TEST_EXIT=$?

    # Reintentar si falla: solo para código 1 (tests fallidos)
    if [ "${TEST_EXIT:-0}" -eq 2 ]; then
        fail_pr "$PR_NUM" "Error de compilación post-merge"
        continue
    elif [ "${TEST_EXIT:-0}" -eq 3 ]; then
        fail_pr "$PR_NUM" "No se ejecutaron tests (posible fallo silencioso)"
        continue
    elif [ "${TEST_EXIT:-0}" -eq 1 ]; then
        warn "Tests fallan post-merge. Invocando implementer para arreglar..."

        FAILED_TESTS=$(echo "$TEST_OUTPUT" | grep -E "Failed|Con error" | head -10)
        FIX_PROMPT="Estás en el directorio raíz del proyecto ${HARNESS_PROJECT_NAME}.

Después de hacer merge con main, los siguientes tests fallan:
$FAILED_TESTS

Arregla el código en src/ para que todos los tests pasen.
NO modifiques los tests.
Cuando termines, haz commit de los cambios."

        if ! run_agent "fix-pr${PR_NUM}" "implementer" "$FIX_PROMPT" "$TEMP_WORKTREE"; then
            fail_pr "$PR_NUM" "El agente implementer falló al arreglar tests"
            continue
        fi

        TEST_EXIT2=0
        TEST_OUTPUT2=$(validate_tests "$TEMP_WORKTREE") || TEST_EXIT2=$?

        if [ "${TEST_EXIT2:-0}" -ne 0 ]; then
            fail_pr "$PR_NUM" "Tests siguen fallando después del segundo intento"
            continue
        fi
    fi

    success "Todos los tests pasan"

    # Push de la rama actualizada
    log "Haciendo push de la rama actualizada..."
    if ! git -C "$TEMP_WORKTREE" push origin "$BRANCH_NAME" --force-with-lease >>"$LOG_FILE_ABS" 2>&1; then
        fail_pr "$PR_NUM" "No se pudo hacer push de $BRANCH_NAME"
        continue
    fi
    success "Rama $BRANCH_NAME actualizada en origin"

    # Limpiar worktree temporal
    git worktree remove --force "$TEMP_WORKTREE" >>"$LOG_FILE_ABS" 2>&1 || true
    git branch -D "$BRANCH_NAME" >>"$LOG_FILE_ABS" 2>&1 || true
    CURRENT_WORKTREE=""
    success "Worktree temporal limpiado"

    set_status "$PR_NUM" "sincronizado"

    # Merge a main (si se pidió) — con retry (P2)
    if [ "$DO_MERGE" = true ]; then
        log "Mergeando PR #$PR_NUM a main..."
        if merge_pr_with_retry "$PR_NUM"; then
            success "PR #$PR_NUM mergeado a main"
            set_status "$PR_NUM" "mergeado"
            desbloquear_issues_dependientes "$PR_NUM"
            git fetch origin main >>"$LOG_FILE_ABS" 2>&1 || true
        else
            fail_pr "$PR_NUM" "No se pudo mergear después de reintentos"
        fi
    fi
done

# ─── Resumen final (P6: siempre se muestra) ──────────────────────────────────
header "Resumen"
echo -e ""
printf "${BOLD}%-8s %-50s %-15s${NC}\n" "PR" "Rama" "Estado"
printf "%s\n" "─────────────────────────────────────────────────────────────────────────────"

for PR_NUM in "${PR_NUMS[@]}"; do
    BRANCH=$(get_branch "$PR_NUM")
    STATUS=$(get_status "$PR_NUM")
    if [ "$STATUS" = "mergeado" ]; then
        COLOR="$GREEN"
    elif [ "$STATUS" = "sincronizado" ] || [ "$STATUS" = "al día" ]; then
        COLOR="$BLUE"
    else
        COLOR="$YELLOW"
    fi
    printf "${COLOR}%-8s %-50s %-15s${NC}\n" "#$PR_NUM" "$BRANCH" "$STATUS"
done

echo ""
if [ "$HAVE_ERRORS" = true ]; then
    warn "Algunos PRs tuvieron errores. Revisa el log: $LOG_FILE_ABS"
    exit 1
else
    success "pr-sync completado. Log: $LOG_FILE_ABS"
fi
