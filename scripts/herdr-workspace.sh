#!/usr/bin/env bash
# herdr-workspace.sh --- Apertura de un proyecto Mefisto en herdr (issue #691)
#
# Uso:
#   <plugin>/scripts/herdr-workspace.sh [ruta-al-repo]
#
# Crea (o enfoca, si ya existe uno con el mismo nombre) el workspace herdr
# del repo indicado (default: el repo git del cwd) con los dos panes
# principales del flujo Mefisto:
#
#   - Pane izquierdo  "planner":   una sesion de Claude Code corriendo el
#     agente de Knowledge Crunching -- `claude --agent mefisto:planner` en un
#     proyecto consumidor, `claude --agent mefisto-planner` en el propio repo
#     de Mefisto (los agentes internos llevan prefijo, MEF-ADR-0019).
#   - Pane derecho    "ejecucion": una sesion de Claude Code para despachar
#     issues (/implement, /tooling, /infra, /sequential). Dentro de herdr,
#     esos skills abren el tercer pane con el visor en vivo (issue #690).
#
# Los agentes se lanzan con `herdr agent start` bajo nombres unicos por
# workspace (planner-<slug>, ejecucion-<slug>) para que el sidebar de herdr
# muestre su estado (working/blocked/done). Si un lanzamiento falla (p. ej.
# el nombre ya esta vivo en otro workspace del mismo repo), el pane queda
# con su shell y el script lo avisa: lanzar `claude` a mano ahi lo resuelve.
#
# Donde correrlo: en cualquier terminal. Dentro de un pane herdr actua sobre
# la sesion actual; fuera de herdr, sobre la sesion default del servidor (las
# sesiones nombradas de herdr son servidores separados: para abrir un
# workspace en una de ellas, corre este script desde un pane de esa sesion).
#
# Idempotencia: si ya existe un workspace con el label del repo, solo lo
# enfoca -- nunca duplica panes ni agentes.

set -euo pipefail

# --- Colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
success() { echo -e "${GREEN}${BOLD}v${NC} $1"; }
warn()    { echo -e "${YELLOW}!${NC} $1"; }
abort()   { echo -e "\n${RED}${BOLD}x $1${NC}" >&2; exit 1; }

# workspace_slug <label>
#
# Deriva el sufijo de los nombres de agente (planner-<slug>, ejecucion-<slug>)
# a partir del label del workspace: minusculas, todo lo que no sea [a-z0-9]
# colapsa a '-', sin guiones en los extremos, maximo 20 caracteres -- los
# nombres de agente de herdr admiten [a-z][a-z0-9_-]{0,31} y el prefijo mas
# largo ("ejecucion-") ocupa 10.
workspace_slug() {
    echo "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9]/-/g' \
        | tr -s '-' \
        | sed 's/^-//; s/-$//' \
        | cut -c1-20 \
        | sed 's/-$//'
}

# planner_agent_for_repo <repo_root>
#
# Imprime el argumento de `claude --agent` que corresponde al planner de ese
# repo: el agente interno "mefisto-planner" en el propio repo de Mefisto
# (detectado por .claude-plugin/plugin.json), el publicado "mefisto:planner"
# (calificado por plugin) en un consumidor.
planner_agent_for_repo() {
    local root="$1"
    if [ -f "$root/.claude-plugin/plugin.json" ]; then
        echo "mefisto-planner"
    else
        echo "mefisto:planner"
    fi
}

# pane_shell_is_free <pane_id>
#
# 0 si el pane esta en su prompt interactivo, sin comando en foreground
# (mismo criterio que herdr-pipeline.sh: foreground_process_group_id ==
# shell_pid). `herdr agent start` exige un shell disponible; recien creado el
# pane, el shell puede tardar un instante en llegar al prompt.
pane_shell_is_free() {
    local id="$1"
    local info fg sh
    info=$(herdr pane process-info --pane "$id" 2>/dev/null) || return 1
    fg=$(echo "$info" | jq -r '.result.process_info.foreground_process_group_id // empty' 2>/dev/null)
    sh=$(echo "$info" | jq -r '.result.process_info.shell_pid // empty' 2>/dev/null)
    [ -n "$fg" ] && [ -n "$sh" ] && [ "$fg" = "$sh" ]
}

# wait_for_free_shell <pane_id>
#
# Espera hasta ~6s a que el shell del pane llegue a su prompt. Devuelve 0 si
# llego, 1 si no (el llamador degrada a un aviso, nunca aborta por esto).
wait_for_free_shell() {
    local id="$1"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        pane_shell_is_free "$id" && return 0
        sleep 0.5
    done
    return 1
}

# start_agent_in_pane <nombre> <pane_id> <arg-de---agent (vacio = claude pelado)>
#
# Lanza una sesion de Claude Code en el pane via `herdr agent start` (asi el
# sidebar muestra su estado de vida). Degrada a un aviso si falla: el pane
# queda con su shell y el humano puede lanzar `claude` a mano.
start_agent_in_pane() {
    local name="$1" pane="$2" agent_arg="$3"
    if ! wait_for_free_shell "$pane"; then
        warn "El shell del pane $pane no llego a su prompt; lanza el agente a mano ahi."
        return 0
    fi
    local rc=0
    if [ -n "$agent_arg" ]; then
        herdr agent start "$name" --kind claude --pane "$pane" --timeout 90000 -- --agent "$agent_arg" >/dev/null 2>&1 || rc=$?
    else
        herdr agent start "$name" --kind claude --pane "$pane" --timeout 90000 >/dev/null 2>&1 || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        success "Agente '$name' corriendo en el pane $pane${agent_arg:+ (claude --agent $agent_arg)}"
    else
        warn "No se pudo lanzar '$name' en el pane $pane (herdr agent start fallo, rc=$rc)."
        warn "El pane quedo con su shell: lanza ahi 'claude${agent_arg:+ --agent $agent_arg}' a mano."
    fi
    return 0
}

main() {
    local target="${1:-.}"

    command -v herdr &>/dev/null || abort "herdr no esta instalado (https://herdr.dev)."
    command -v jq &>/dev/null || abort "Este script requiere jq (brew install jq)."
    herdr status server >/dev/null 2>&1 || abort "El servidor de herdr no responde. Corre 'herdr' para arrancarlo."

    local repo_root
    repo_root=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null) \
        || abort "'$target' no esta dentro de un repositorio git."

    local planner_agent
    planner_agent=$(planner_agent_for_repo "$repo_root")
    if [ "$planner_agent" = "mefisto:planner" ] && [ ! -f "$repo_root/.claude/harness.config.json" ]; then
        warn "El repo no tiene .claude/harness.config.json: parece no estar onboardeado a Mefisto (/onboard)."
        warn "El workspace se abre igual, pero los pipelines fallaran hasta completar el onboarding."
    fi

    local label slug
    label=$(basename "$repo_root")
    slug=$(workspace_slug "$label")

    # Idempotencia: un workspace con este label ya montado solo se enfoca.
    local existing
    existing=$(herdr workspace list 2>/dev/null \
        | jq -r --arg l "$label" '.result.workspaces[]? | select(.label == $l) | .workspace_id' \
        | head -1)
    if [ -n "$existing" ]; then
        herdr workspace focus "$existing" >/dev/null 2>&1 || true
        success "El workspace '$label' ya existe ($existing): enfocado, sin duplicar panes ni agentes."
        exit 0
    fi

    log "Creando el workspace '$label' para $repo_root ..."
    local resp ws p1
    resp=$(herdr workspace create --cwd "$repo_root" --label "$label" 2>&1) \
        || abort "No se pudo crear el workspace: $resp"
    ws=$(echo "$resp" | jq -r '.result.workspace.workspace_id // empty')
    p1=$(echo "$resp" | jq -r '.result.root_pane.pane_id // empty')
    [ -n "$ws" ] && [ -n "$p1" ] || abort "herdr workspace create no devolvio ids. Respuesta: $resp"

    local p2=""
    resp=$(herdr pane split --pane "$p1" --direction right --cwd "$repo_root" --no-focus 2>&1) \
        && p2=$(echo "$resp" | jq -r '.result.pane.pane_id // empty')
    if [ -z "$p2" ]; then
        warn "No se pudo crear el pane de ejecucion (split fallo): el workspace queda con el pane del planner."
    fi

    herdr pane rename "$p1" "planner" >/dev/null 2>&1 || true
    [ -n "$p2" ] && herdr pane rename "$p2" "ejecucion" >/dev/null 2>&1 || true

    start_agent_in_pane "planner-$slug" "$p1" "$planner_agent"
    [ -n "$p2" ] && start_agent_in_pane "ejecucion-$slug" "$p2" ""

    echo ""
    success "Workspace '$label' listo ($ws): planner ($p1) + ejecucion (${p2:-no creado})."
    log "Desde el pane de ejecucion despacha issues con /implement, /tooling, /infra o /sequential:"
    log "dentro de herdr cada corrida abre su pane con el visor en vivo (issue #690)."
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
