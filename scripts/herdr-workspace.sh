#!/usr/bin/env bash
# herdr-workspace.sh --- Apertura de un proyecto Mefisto en herdr (issue #691)
#
# Uso:
#   <plugin>/scripts/herdr-workspace.sh [ruta-al-repo]
#
# Crea (o enfoca, si ya existe) el workspace herdr del repo indicado
# (default: el repo git del cwd) con los panes principales del flujo
# Mefisto:
#
#   - Pane "planner":   una sesion de agente corriendo el agente de
#     Knowledge Crunching -- `--agent mefisto:planner` en un proyecto
#     consumidor, `--agent mefisto-planner` en el propio repo de Mefisto (los
#     agentes internos llevan prefijo, MEF-ADR-0019).
#   - Pane "ejecucion": una sesion de agente para despachar issues
#     (/implement, /tooling, /infra, /sequential). Dentro de herdr, esos
#     skills abren el tercer pane con el visor en vivo (issue #690).
#
# Filas por runtime en Mefisto (issue #958, MEF-ADR-0049/0050): una invocacion
# monta una fila planner+ejecucion por cada kind. MEFISTO_RUNTIMES (separada
# por comas) tiene precedencia; MEFISTO_RUNTIME selecciona una sola fila si la
# lista no esta definida; sin ambas, el default es `claude,opencode`. El orden
# visual sigue el orden de la lista. Como `pane split` anida bajo quien lo
# pide, al crear el workspace todos los `down` salen del pane raiz ANTES de
# cualquier `right` y recorren la lista al reves: herdr inserta cada pane
# inmediatamente debajo de la raiz. Con tres o mas filas, las inferiores
# pueden quedar anidadas por la geometria de herdr; es un limite conocido y
# aceptado. En consumidores se conserva una fila sin variables de runtime.
#
# Los panes de cada fila de Mefisto arrancan con `--kind <kind>` y llevan
# SIEMPRE `--env MEFISTO_RUNTIME=<kind>` (tambien para los defaults, porque el
# despacho de #928 debe resolver el runtime de su fila), mas
# MEFISTO_MODELS_FILE si esta definida. En un consumidor el runtime es Claude
# Code (el plugin publicado aun no soporta OpenCode): un MEFISTO_RUNTIME
# distinto de "claude" se ignora con un aviso, sin --env -- exactamente el
# comportamiento de hoy. El script nunca fija provider, modelo ni
# credenciales, ni lee opencode.json o un auth store.
#
# Los agentes se lanzan con `herdr agent start` bajo nombres unicos por
# workspace: planner-<slug>, ejecucion-<slug> en un consumidor; en el propio
# repo de Mefisto, planner-<slug>-<kind>, ejecucion-<slug>-<kind> -- el
# sufijo es SIEMPRE el runtime activo de esa fila (issue #930: tambien con
# kind="claude"), para que dos filas no choquen de nombre y el sidebar de
# herdr muestre de un vistazo que runtime corre cada agente. Si un
# lanzamiento falla (p. ej. el nombre ya esta vivo en otro workspace del
# mismo repo), el pane queda con su shell y el script lo avisa: lanzar el
# runtime activo a mano ahi lo resuelve.
#
# Donde correrlo: en cualquier terminal. Dentro de un pane herdr actua sobre
# la sesion actual; fuera de herdr, sobre la sesion default del servidor (las
# sesiones nombradas de herdr son servidores separados: para abrir un
# workspace en una de ellas, corre este script desde un pane de esa sesion).
#
# Idempotencia: en un consumidor, un workspace con el label del repo ya
# montado solo se enfoca -- nunca duplica panes ni agentes. En el repo de
# Mefisto la idempotencia es por (workspace, runtime): una fila con label
# `planner [<kind>]` no se toca. Las faltantes se agregan con `down` desde el
# planner de la ultima fila existente y luego su `right`; ese agregado puede
# quedar anidado y se acepta para no reconstruir filas que ya estan activas.

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

# workspace_slug <label> [max]
#
# Deriva el slug que alimenta el nombre de agente a partir del label del
# workspace: minusculas, todo lo que no sea [a-z0-9] colapsa a '-', sin
# guiones en los extremos, tope de <max> caracteres (default 20 -- el tope de
# un consumidor, que no lleva sufijo de runtime). agent_name_for_role calcula
# el <max> real cuando hay sufijo, para que el nombre completo quepa en los
# 32 caracteres que admiten los nombres de agente de herdr
# ([a-z][a-z0-9_-]{0,31}).
workspace_slug() {
    local max="${2:-20}"
    echo "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9]/-/g' \
        | tr -s '-' \
        | sed 's/^-//; s/-$//' \
        | cut -c1-"$max" \
        | sed 's/-$//'
}

# agent_name_for_role <rol> <label> <kind>
#
# Imprime el nombre de agente herdr para <rol> ("planner" o "ejecucion") a
# partir del label del workspace y el sufijo de runtime <kind> (issue #930;
# vacio = sin sufijo, comportamiento de un consumidor -- CA-3). Con <kind> no
# vacio el slug se recorta al tope que deja espacio para el prefijo MAS LARGO
# ("ejecucion-", 10 caracteres) + "-<kind>", para que planner y ejecucion
# compartan el mismo slug pase lo que pase con <rol>. Los nombres de agente
# de herdr admiten [a-z][a-z0-9_-]{0,31} (32 caracteres).
agent_name_for_role() {
    local rol="$1" label="$2" kind="$3"
    local max=20
    [ -n "$kind" ] && max=$((32 - 10 - 1 - ${#kind}))
    # MEFISTO_RUNTIME es texto libre: un kind absurdamente largo dejaria
    # max <= 0, y `cut -c1-0` abortaria el script entero (set -e + pipefail).
    # Con el piso el nombre queda largo y degrada por la via de siempre:
    # `herdr agent start` falla y el pane conserva su shell.
    [ "$max" -lt 1 ] && max=1
    local slug
    slug=$(workspace_slug "$label" "$max")
    echo "${rol}-${slug}${kind:+-$kind}"
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

# runtimes_for_repo <planner_agent>
#
# Imprime un kind por linea. En Mefisto normaliza la lista, elimina vacios y
# duplicados conservando la primera aparicion. En consumidores siempre
# devuelve `claude`, sin leer las variables.
runtimes_for_repo() {
    local planner_agent="$1"
    if [ "$planner_agent" != "mefisto-planner" ]; then
        echo "claude"
        return
    fi

    local configured
    if [ "${MEFISTO_RUNTIMES+x}" = "x" ]; then
        configured="$MEFISTO_RUNTIMES"
    elif [ -n "${MEFISTO_RUNTIME:-}" ]; then
        configured="$MEFISTO_RUNTIME"
    else
        configured="claude,opencode"
    fi
    printf '%s\n' "$configured" | awk -F, '
        {
            for (i = 1; i <= NF; i++) {
                value = $i
                sub(/^[[:space:]]+/, "", value)
                sub(/[[:space:]]+$/, "", value)
                if (value != "" && !seen[value]++) print value
            }
        }
    '
}

# pane_label_lookup <workspace_id> <label>
#
# Imprime el pane_id del primer pane de <workspace_id> cuyo label sea
# exactamente <label> (vacio si ninguno calza). Base de la deteccion de
# filas por (workspace, runtime) (issue #958 CA-4):
# SIEMPRE por label, nunca por si el agente del pane llego a arrancar (un
# `herdr agent start` fallido no debe hacer creer que la fila no existe).
# Un `herdr pane list` que falla (o devuelve algo que jq no puede leer) es
# "no encontre el pane", no un error fatal: sin el `|| true` final, pipefail
# haria fallar la asignacion del llamador y `set -e` mataria el script en
# silencio -- justo tragandose el aviso accionable de CA-4.
pane_label_lookup() {
    local ws="$1" label="$2"
    herdr pane list --workspace "$ws" 2>/dev/null \
        | jq -r --arg l "$label" '.result.panes[]? | select(.label == $l) | .pane_id' 2>/dev/null \
        | head -1 || true
}

# last_runtime_planner_lookup <workspace_id>
#
# Imprime el ultimo planner de runtime listado por herdr. Es el fallback para
# agregar una fila cuando el workspace solo contiene runtimes que no forman
# parte de la configuracion actual (por ejemplo, al pasar de una lista de un
# elemento a otra lista disjunta). No renombra ni reinicia esa fila existente.
last_runtime_planner_lookup() {
    local ws="$1"
    herdr pane list --workspace "$ws" 2>/dev/null \
        | jq -r '[.result.panes[]? | select((.label? // "") | startswith("planner [")) | .pane_id] | last // empty' 2>/dev/null \
        || true
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

# start_agent_in_pane <nombre> <pane_id> <arg-de---agent (vacio = runtime pelado)> [<kind>]
#
# Lanza una sesion del runtime activo (<kind>, default "claude") en el pane
# via `herdr agent start` (asi el sidebar muestra su estado de vida). El
# arranque tiene una carrera conocida: recien creado el pane, el primer
# intento puede fallar aunque el shell ya reporte su prompt (visto en vivo:
# el mismo comando reintentado a mano funciona) -- por eso un fallo se
# reintenta UNA vez tras una pausa, pasando antes por `herdr agent get`: un
# primer intento que fallo con agent_not_ready puede haber dejado al runtime
# levantando con el nombre ya reservado, y ahi el get lo confirma sin un
# segundo start que chocaria con el nombre. Los errores del CLI (JSON por
# stderr) se muestran en el aviso en vez de tragarse: sin eso el fallo real
# es indiagnosticable. Si ambos intentos fallan, degrada a un aviso: el pane
# queda con su shell y el humano puede lanzar el runtime a mano.
#
# MEFISTO_AGENT_START_RETRY_PAUSE (segundos, default 3) es la pausa entre el
# start fallido y el `agent get` que lo confirma; existe para que los tests no
# paguen esa espera de reloj cuatro veces (mismo criterio que
# MEFISTO_AGENT_MAX_ATTEMPTS en el pipeline de tooling). En produccion nadie
# la fija: el default es el comportamiento de siempre.
start_agent_in_pane() {
    local name="$1" pane="$2" agent_arg="$3" kind="${4:-claude}"
    if ! wait_for_free_shell "$pane"; then
        warn "El shell del pane $pane no llego a su prompt; lanza el agente a mano ahi."
        return 0
    fi

    local intento err="" rc=0
    for intento in 1 2; do
        rc=0
        if [ -n "$agent_arg" ]; then
            err=$(herdr agent start "$name" --kind "$kind" --pane "$pane" --timeout 90000 -- --agent "$agent_arg" 2>&1 >/dev/null) || rc=$?
        else
            err=$(herdr agent start "$name" --kind "$kind" --pane "$pane" --timeout 90000 2>&1 >/dev/null) || rc=$?
        fi
        if [ "$rc" -eq 0 ]; then
            success "Agente '$name' corriendo en el pane $pane${agent_arg:+ ($kind --agent $agent_arg)}"
            return 0
        fi
        sleep "${MEFISTO_AGENT_START_RETRY_PAUSE:-3}"
        if herdr agent get "$name" >/dev/null 2>&1; then
            success "Agente '$name' corriendo en el pane $pane (levanto tras el primer intento)${agent_arg:+ ($kind --agent $agent_arg)}"
            return 0
        fi
        if [ "$intento" -eq 1 ]; then
            warn "herdr agent start fallo para '$name' (rc=$rc); reintentando una vez...${err:+ Detalle: $(echo "$err" | head -c 200)}"
        fi
    done

    warn "No se pudo lanzar '$name' en el pane $pane tras 2 intentos (rc=$rc).${err:+ Detalle: $(echo "$err" | head -c 200)}"
    warn "El pane quedo con su shell: lanza ahi '$kind${agent_arg:+ --agent $agent_arg}' a mano."
    return 0
}

# mount_first_row <repo_root> <label> <planner_agent>
#
# Monta la unica fila de un consumidor, con el contrato previo intacto.
mount_first_row() {
    local repo_root="$1" label="$2" planner_agent="$3"

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

    local planner_name ejecucion_name
    planner_name=$(agent_name_for_role "planner" "$label" "")
    ejecucion_name=$(agent_name_for_role "ejecucion" "$label" "")

    start_agent_in_pane "$planner_name" "$p1" "$planner_agent" "claude"
    [ -n "$p2" ] && start_agent_in_pane "$ejecucion_name" "$p2" "" "claude"

    echo ""
    success "Workspace '$label' listo ($ws): planner ($p1) + ejecucion (${p2:-no creado})."
    log "Desde el pane de ejecucion despacha issues con /implement, /tooling, /infra o /sequential:"
    log "dentro de herdr cada corrida abre su pane con el visor en vivo (issue #690)."
}

# mount_runtime_row <repo_root> <base_pane> <label> <planner_agent> <kind>
#
# Agrega una fila faltante debajo de <base_pane>. Publica el planner nuevo en
# MOUNTED_RUNTIME_PLANNER para que el llamador pueda encadenar otra faltante.
mount_runtime_row() {
    local repo_root="$1" base_pane="$2" label="$3" planner_agent="$4" runtime_kind="$5"
    local env_args=(--env "MEFISTO_RUNTIME=$runtime_kind")
    [ -n "${MEFISTO_MODELS_FILE:-}" ] && env_args+=(--env "MEFISTO_MODELS_FILE=$MEFISTO_MODELS_FILE")
    log "Montando la fila de '$runtime_kind' en el workspace '$label' ..."
    local resp p_planner="" p_ejecucion=""
    resp=$(herdr pane split --pane "$base_pane" --direction down --cwd "$repo_root" --no-focus "${env_args[@]}" 2>&1) \
        && p_planner=$(echo "$resp" | jq -r '.result.pane.pane_id // empty')
    if [ -z "$p_planner" ]; then
        warn "No se pudo crear el pane del planner de la fila '$runtime_kind': $resp"
        return 0
    fi

    resp=$(herdr pane split --pane "$p_planner" --direction right --cwd "$repo_root" --no-focus "${env_args[@]+"${env_args[@]}"}" 2>&1) \
        && p_ejecucion=$(echo "$resp" | jq -r '.result.pane.pane_id // empty')
    if [ -z "$p_ejecucion" ]; then
        warn "No se pudo crear el pane de ejecucion de la fila '$runtime_kind' (split fallo): la fila queda con el pane del planner."
    fi

    herdr pane rename "$p_planner" "planner [$runtime_kind]" >/dev/null 2>&1 || true
    [ -n "$p_ejecucion" ] && herdr pane rename "$p_ejecucion" "ejecucion [$runtime_kind]" >/dev/null 2>&1 || true

    local planner_name ejecucion_name
    planner_name=$(agent_name_for_role "planner" "$label" "$runtime_kind")
    ejecucion_name=$(agent_name_for_role "ejecucion" "$label" "$runtime_kind")

    start_agent_in_pane "$planner_name" "$p_planner" "$planner_agent" "$runtime_kind"
    [ -n "$p_ejecucion" ] && start_agent_in_pane "$ejecucion_name" "$p_ejecucion" "" "$runtime_kind"

    echo ""
    success "Fila de '$runtime_kind' lista en '$label': planner ($p_planner) + ejecucion (${p_ejecucion:-no creado})."
    log "Desde el pane de ejecucion despacha issues con /mefisto-tooling, /mefisto-sequential, etc."
    MOUNTED_RUNTIME_PLANNER="$p_planner"
}

# mount_runtime_rows <repo_root> <label> <planner_agent> <runtime...>
#
# Crea todas las filas: primero los `down` inversos, despues todos los `right`.
mount_runtime_rows() {
    local repo_root="$1" label="$2" planner_agent="$3"
    shift 3
    local runtimes=("$@")
    local first_kind="${runtimes[0]}"
    local first_env=(--env "MEFISTO_RUNTIME=$first_kind")
    [ -n "${MEFISTO_MODELS_FILE:-}" ] && first_env+=(--env "MEFISTO_MODELS_FILE=$MEFISTO_MODELS_FILE")
    local resp ws root i kind pane

    log "Creando el workspace '$label' para $repo_root ..."
    resp=$(herdr workspace create --cwd "$repo_root" --label "$label" "${first_env[@]}" 2>&1) \
        || abort "No se pudo crear el workspace: $resp"
    ws=$(echo "$resp" | jq -r '.result.workspace.workspace_id // empty')
    root=$(echo "$resp" | jq -r '.result.root_pane.pane_id // empty')
    [ -n "$ws" ] && [ -n "$root" ] || abort "herdr workspace create no devolvio ids. Respuesta: $resp"

    local planners=("$root") ejecuciones=()
    for ((i=${#runtimes[@]}-1; i>=1; i--)); do
        kind="${runtimes[$i]}"
        local env_args=(--env "MEFISTO_RUNTIME=$kind")
        [ -n "${MEFISTO_MODELS_FILE:-}" ] && env_args+=(--env "MEFISTO_MODELS_FILE=$MEFISTO_MODELS_FILE")
        pane=""
        resp=$(herdr pane split --pane "$root" --direction down --cwd "$repo_root" --no-focus "${env_args[@]}" 2>&1) \
            && pane=$(echo "$resp" | jq -r '.result.pane.pane_id // empty')
        [ -n "$pane" ] || warn "No se pudo crear el planner de la fila '$kind': $resp"
        planners[$i]="$pane"
    done

    for ((i=0; i<${#runtimes[@]}; i++)); do
        kind="${runtimes[$i]}"
        pane="${planners[$i]:-}"
        [ -n "$pane" ] || continue
        local row_env=(--env "MEFISTO_RUNTIME=$kind")
        [ -n "${MEFISTO_MODELS_FILE:-}" ] && row_env+=(--env "MEFISTO_MODELS_FILE=$MEFISTO_MODELS_FILE")
        local execution=""
        resp=$(herdr pane split --pane "$pane" --direction right --cwd "$repo_root" --no-focus "${row_env[@]}" 2>&1) \
            && execution=$(echo "$resp" | jq -r '.result.pane.pane_id // empty')
        [ -n "$execution" ] || warn "No se pudo crear el pane de ejecucion de la fila '$kind'."
        ejecuciones[$i]="$execution"
    done

    for ((i=0; i<${#runtimes[@]}; i++)); do
        kind="${runtimes[$i]}"
        pane="${planners[$i]:-}"
        [ -n "$pane" ] || continue
        herdr pane rename "$pane" "planner [$kind]" >/dev/null 2>&1 || true
        [ -n "${ejecuciones[$i]:-}" ] && herdr pane rename "${ejecuciones[$i]}" "ejecucion [$kind]" >/dev/null 2>&1 || true
        start_agent_in_pane "$(agent_name_for_role planner "$label" "$kind")" "$pane" "$planner_agent" "$kind"
        [ -n "${ejecuciones[$i]:-}" ] && start_agent_in_pane "$(agent_name_for_role ejecucion "$label" "$kind")" "${ejecuciones[$i]}" "" "$kind"
    done

    echo ""
    success "Workspace '$label' listo ($ws): ${#runtimes[@]} fila(s) de runtime."
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

    local label
    label=$(basename "$repo_root")

    # Idempotencia de primer nivel: sin workspace con este label todavia, no
    # hay nada que enfocar en ninguna rama.
    local existing
    existing=$(herdr workspace list 2>/dev/null \
        | jq -r --arg l "$label" '.result.workspaces[]? | select(.label == $l) | .workspace_id' \
        | head -1)

    if [ "$planner_agent" != "mefisto-planner" ]; then
        # --- Rama consumidor: layout de hoy, sin cambios (issue #931 CA-5) ---
        # El aviso va ANTES de la rama de idempotencia (comportamiento de
        # #875): un MEFISTO_RUNTIME ignorado hay que decirlo tambien al
        # reenfocar un workspace ya montado, no solo al crearlo.
        if [ -n "${MEFISTO_RUNTIME:-}" ] && [ "$MEFISTO_RUNTIME" != "claude" ]; then
            warn "El plugin publicado aun no soporta OpenCode (MEFISTO_RUNTIME=$MEFISTO_RUNTIME); se usa 'claude'."
        fi
        if [ -n "$existing" ]; then
            herdr workspace focus "$existing" >/dev/null 2>&1 || true
            success "El workspace '$label' ya existe ($existing): enfocado, sin duplicar panes ni agentes."
            exit 0
        fi
        mount_first_row "$repo_root" "$label" "$planner_agent"
        return
    fi

    # --- Rama Mefisto: una fila por runtime configurado (issue #958) ---
    local runtimes=() runtime_kind
    while IFS= read -r runtime_kind; do
        [ -n "$runtime_kind" ] && runtimes+=("$runtime_kind")
    done < <(runtimes_for_repo "$planner_agent")
    [ "${#runtimes[@]}" -gt 0 ] || abort "La lista de runtimes quedo vacia."

    if [ -z "$existing" ]; then
        mount_runtime_rows "$repo_root" "$label" "$planner_agent" "${runtimes[@]}"
        return
    fi

    local ws="$existing"
    herdr workspace focus "$ws" >/dev/null 2>&1 || true
    local row_panes=() last_existing="" i
    for ((i=0; i<${#runtimes[@]}; i++)); do
        row_panes[$i]=$(pane_label_lookup "$ws" "planner [${runtimes[$i]}]")
        [ -n "${row_panes[$i]}" ] && last_existing="${row_panes[$i]}"
    done

    [ -n "$last_existing" ] || last_existing=$(last_runtime_planner_lookup "$ws")
    if [ -z "$last_existing" ]; then
        warn "El workspace '$label' ($ws) no contiene ningun planner de runtime desde el cual montar las filas faltantes; se enfoco sin modificar el layout."
        return
    fi

    local mounted=0
    for ((i=0; i<${#runtimes[@]}; i++)); do
        [ -n "${row_panes[$i]}" ] && continue
        MOUNTED_RUNTIME_PLANNER=""
        mount_runtime_row "$repo_root" "$last_existing" "$label" "$planner_agent" "${runtimes[$i]}"
        if [ -n "$MOUNTED_RUNTIME_PLANNER" ]; then
            last_existing="$MOUNTED_RUNTIME_PLANNER"
            mounted=$((mounted + 1))
        fi
    done
    [ "$mounted" -gt 0 ] \
        && success "Workspace '$label' enfocado; se montaron $mounted fila(s) faltante(s)." \
        || success "El workspace '$label' ya tiene todas las filas pedidas ($ws): enfocado sin duplicar panes ni agentes."
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
