#!/usr/bin/env bash
# next-order.sh -- Calcula el orden topologico de lanzamiento de los issues
# 'estado:listo' abiertos del repo consumidor (issue #940).
#
# Copia hermana deliberada de src/internal/scripts/mefisto-next-order.sh
# (issue #936), MEF-ADR-0018 regla de tres: el lado publicado no puede
# depender de src/internal/ (MEF-ADR-0019), asi que el algoritmo se duplica en
# vez de compartirse via source. Cualquier fix al calculo del orden (Kahn,
# deteccion de ciclos, bloqueos externos/indirectos) debe aplicarse a AMBAS
# copias.
#
# Diferencia con la copia interna: la ultima linea de la salida es la linea de
# lanzamiento de un comando de secuenciamiento, y ese comando depende del
# runtime del consumidor (MEF-ADR-0050): hoy el unico adaptador publicado es
# Claude Code Plugin y el comando se invoca '/mefisto:sequential'; bajo
# OpenCode (#874) el namespace puede diferir. Este script NUNCA hardcodea esa
# decision: la recibe por '--launch-command "<texto>"' (el wrapper de cada
# runtime la pasa), y sin el flag cae al default '/mefisto:sequential' -- el
# unico adaptador publicado hoy.
#
# Uso:
#   scripts/next-order.sh
#   scripts/next-order.sh --launch-command "/mefisto:sequential"
#   (sin mas argumentos: opera sobre TODO el universo 'estado:listo' abierto
#   del repo consumidor)
#
# Cada linea del orden incluye el label 'tipo:' del issue ('N. #123
# [tipo:feature] Titulo -- tras #A'): el consumidor lo necesita para decidir
# si un tramo va a /mefisto:sequential o podria ir a /mefisto:parallel en su
# lugar. Este script NO propone oleadas paralelas -- calcula un unico orden
# lineal; agrupar issues sin dependencia mutua en oleadas sigue siendo el modo
# 'oleadas' del planner publicado.
#
# Exit codes:
#   0 -- hay al menos un issue lanzable (el orden no quedo vacio)
#   1 -- no hay ningun issue lanzable (universo vacio, o todos los issues
#        quedaron en ciclos y/o bloqueados)
#   2 -- fallo 'gh issue list', o se invoco con argumentos invalidos
#
# Universo de analisis (MEF-ADR-0011, Definition of Ready): exactamente los
# issues 'estado:listo' Y abiertos del repo consumidor -- ni borradores ni
# cerrados. El label 'bloqueado' no filtra nada: un issue que lo lleva puesto
# entra igual al analisis, y si su dependencia queda resuelta por el orden
# calculado aqui simplemente entra al orden -- este script nunca muta labels.
#
# Extraccion de dependencias: SOLO dependencias forward de la seccion
# '## Dependencias' ('Depende de #N' / 'Bloqueado por #N', case-insensitive);
# se ignoran 'Bloquea', 'Consumido por' y la prosa libre. Una dependencia
# DENTRO del universo esta abierta por construccion (el listado es --state
# open); para las de FUERA se consulta su estado, y CLOSED/MERGED = satisfecha
# (no genera arista ni bloqueo).
#
# Clasificacion de cada issue del universo -- toda exclusion se reporta:
#   (a) Bloqueo externo: declara al menos una dependencia abierta que NO esta
#       en el universo 'estado:listo' -- excluido del orden, reportado como
#       '#N bloqueado por #M: fuera de estado:listo, estado OPEN'.
#   (b) Ciclo: depende directa o indirectamente de si mismo -- excluido del
#       orden, reportado con sus miembros ('ciclo: #A -> #B -> #A').
#   (c) Bloqueo indirecto: sus dependencias son todas intra-universo, pero al
#       menos una quedo excluida por (a), (b) o (c) -- excluido del orden,
#       reportado como '#N bloqueado por #M: excluido del orden'.
#   (d) Lanzable: todas sus dependencias abiertas estan en el orden, antes que
#       el. Entra al orden por Kahn con seleccion golosa del menor numero
#       disponible en cada paso (empate resuelto por numero de issue
#       ascendente).
#
# No usa 'set -e': 'gh issue view' de una dependencia puede ser un PR, y esa
# falla es esperada -- se cae a 'gh pr view' explicitamente, nunca se propaga
# como abort.

set -uo pipefail

# Guard defensivo: este script es del lado publicado y solo aplica al
# consumidor. No sourcea _pipeline-common.sh (solo hace falta el guard, y
# arrastrar ese archivo aqui sumaria dependencias -- dotnet, colores -- que
# este script no usa).
_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$_REPO_TOP/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/next-order.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Estas en el repo de Mefisto. Usa src/internal/scripts/mefisto-next-order.sh en su lugar." >&2
    exit 1
fi
unset _REPO_TOP

LAUNCH_COMMAND="/mefisto:sequential"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --launch-command)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --launch-command requiere un argumento." >&2
                echo 'Uso: scripts/next-order.sh [--launch-command "<texto>"]' >&2
                exit 2
            fi
            LAUNCH_COMMAND="$2"
            shift 2
            ;;
        *)
            echo "ERROR: argumento desconocido: $1." >&2
            echo 'Uso: scripts/next-order.sh [--launch-command "<texto>"]' >&2
            exit 2
            ;;
    esac
done

ISSUE_LIMIT=200

if ! ISSUES_JSON=$(gh issue list --label "estado:listo" --state open --limit "$ISSUE_LIMIT" --json number,title,body,labels 2>/dev/null); then
    echo "ERROR: fallo 'gh issue list --label estado:listo --state open'." >&2
    exit 2
fi

NUMS=$(echo "$ISSUES_JSON" | jq -r '.[].number' | sort -n)

# Truncar el universo en silencio daria un orden correcto sobre un grafo
# incompleto: el peor resultado posible aqui, porque parece bueno.
UNIVERSE_COUNT=$(echo "$ISSUES_JSON" | jq -r 'length')
if [ "$UNIVERSE_COUNT" -ge "$ISSUE_LIMIT" ]; then
    echo "ADVERTENCIA: 'gh issue list' devolvio $UNIVERSE_COUNT issues (--limit $ISSUE_LIMIT):" >&2
    echo "el universo puede estar truncado y el orden calculado sobre un grafo incompleto." >&2
fi

title_of() {
    echo "$ISSUES_JSON" | jq -r --argjson n "$1" '.[] | select(.number==$n) | .title'
}

body_of() {
    echo "$ISSUES_JSON" | jq -r --argjson n "$1" '.[] | select(.number==$n) | .body'
}

# Label 'tipo:X' de un issue del universo (CA-3): el consumidor lo necesita
# para decidir si un tramo va a /mefisto:sequential o /mefisto:parallel. Si el
# issue no lleva ningun label 'tipo:*' (no deberia pasar, es obligatorio por
# convencion), imprime "tipo:desconocido" en vez de dejar la linea sin
# clasificar en silencio.
tipo_of() {
    local t
    t=$(echo "$ISSUES_JSON" | jq -r --argjson n "$1" \
        '.[] | select(.number==$n) | [.labels[]?.name] | map(select(startswith("tipo:"))) | first // "tipo:desconocido"')
    echo "$t"
}

# Pertenece un numero de issue al universo (lista NUMS)?
in_universe() {
    local target="$1" n
    for n in $NUMS; do
        [ "$n" = "$target" ] && return 0
    done
    return 1
}

# Estado (issue o PR) de una dependencia -- solo se consulta para
# dependencias FUERA del universo.
dep_state_of() {
    local dep="$1"
    gh issue view "$dep" --json state -q '.state' 2>/dev/null \
        || gh pr view "$dep" --json state -q '.state' 2>/dev/null \
        || echo ""
}

# Formatea una lista de numeros (args separados) como "#A, #B, #C" ascendente.
format_dep_list() {
    local n out=""
    for n in $(printf '%s\n' "$@" | sort -n); do
        [ -z "$n" ] && continue
        if [ -z "$out" ]; then out="#$n"; else out="$out, #$n"; fi
    done
    echo "$out"
}

# --- Pase 1: leer el grafo del universo entero -------------------------------

NUM=()
TITLE=()
TIPO=()
DEPS_IN=()      # dependencias abiertas intra-universo
EXCLUDED=()     # 1 si ya se sabe que no puede entrar al orden
BLOCKED_MSGS=""

for ISSUE in $NUMS; do
    DEPS=$(body_of "$ISSUE" \
        | awk '/^##[[:space:]]*[Dd]ependencias/{f=1;next} /^##[[:space:]]/{f=0} f' \
        | grep -ioE '(Depende de|Bloqueado por)[[:space:]]+#[0-9]+' \
        | grep -oE '[0-9]+' | sort -u)

    INSET=""
    IS_BLOCKED=0
    for DEP in $DEPS; do
        [ "$DEP" = "$ISSUE" ] && continue
        if in_universe "$DEP"; then
            INSET="$INSET $DEP"
            continue
        fi
        case "$(dep_state_of "$DEP")" in CLOSED|MERGED) continue ;; esac
        IS_BLOCKED=1
        BLOCKED_MSGS="${BLOCKED_MSGS}#$ISSUE bloqueado por #$DEP: fuera de estado:listo, estado OPEN"$'\n'
    done

    NUM+=("$ISSUE")
    TITLE+=("$(title_of "$ISSUE")")
    TIPO+=("$(tipo_of "$ISSUE")")
    DEPS_IN+=("$INSET")
    EXCLUDED+=("$IS_BLOCKED")
done

COUNT=${#NUM[@]}

# Indice (0-based) de un numero de issue dentro del universo.
index_of() {
    local target="$1" i
    for ((i = 0; i < COUNT; i++)); do
        [ "${NUM[i]}" = "$target" ] && { echo "$i"; return 0; }
    done
    return 1
}

# --- Pase 2: Kahn sobre los nodos no excluidos -------------------------------

RESOLVED=()
INDEG=()
for ((i = 0; i < COUNT; i++)); do
    RESOLVED[i]=0
    n=0
    for DEP in ${DEPS_IN[i]}; do
        n=$((n + 1))
    done
    INDEG[i]=$n
done

ORDER=()
progress=1
while [ "$progress" -eq 1 ]; do
    progress=0
    best=-1
    for ((i = 0; i < COUNT; i++)); do
        if [ "${RESOLVED[i]}" -eq 0 ] && [ "${EXCLUDED[i]}" -eq 0 ] && [ "${INDEG[i]}" -eq 0 ]; then
            if [ "$best" -eq -1 ] || [ "${NUM[i]}" -lt "${NUM[best]}" ]; then
                best=$i
            fi
        fi
    done
    if [ "$best" -ge 0 ]; then
        RESOLVED[best]=1
        ORDER+=("$best")
        progress=1
        BEST_NUM=${NUM[best]}
        for ((j = 0; j < COUNT; j++)); do
            if [ "${RESOLVED[j]}" -eq 0 ]; then
                case " ${DEPS_IN[j]} " in
                    *" $BEST_NUM "*) INDEG[j]=$((INDEG[j] - 1)) ;;
                esac
            fi
        done
    fi
done

# --- Pase 3: ciclos entre los nodos que quedaron sin resolver ----------------

CYCLE_MSGS=""
CYCLE_NUMS=""   # numeros de issue que son miembros de algun ciclo
COLOR=()
STACK=()
for ((i = 0; i < COUNT; i++)); do COLOR[i]="white"; done

stack_index_of() {
    local target="$1" k
    for ((k = 0; k < ${#STACK[@]}; k++)); do
        [ "${STACK[k]}" -eq "$target" ] && { echo "$k"; return 0; }
    done
    return 1
}

emit_cycle() {
    local anchor="$1" pos path n k
    pos=$(stack_index_of "$anchor") || return 0
    path=""
    for ((k = pos; k < ${#STACK[@]}; k++)); do
        n=${NUM[${STACK[k]}]}
        case " $CYCLE_NUMS " in *" $n "*) ;; *) CYCLE_NUMS="$CYCLE_NUMS $n" ;; esac
        if [ -z "$path" ]; then path="#$n"; else path="$path -> #$n"; fi
    done
    path="$path -> #${NUM[anchor]}"
    CYCLE_MSGS="${CYCLE_MSGS}ciclo: $path"$'\n'
}

dfs_visit() {
    local u="$1" dep v
    COLOR[u]="gray"
    STACK+=("$u")
    for dep in ${DEPS_IN[u]}; do
        v=$(index_of "$dep") || continue
        [ "${RESOLVED[v]}" -eq 1 ] && continue
        case "${COLOR[v]}" in
            gray) emit_cycle "$v" ;;
            white) dfs_visit "$v" ;;
        esac
    done
    COLOR[u]="black"
    unset 'STACK[${#STACK[@]}-1]'
}

for ((i = 0; i < COUNT; i++)); do
    if [ "${RESOLVED[i]}" -eq 0 ] && [ "${COLOR[i]}" = "white" ]; then
        dfs_visit "$i"
    fi
done

# --- Pase 4: bloqueos indirectos (caso c) ------------------------------------

INDIRECT_MSGS=""
for ((i = 0; i < COUNT; i++)); do
    [ "${RESOLVED[i]}" -eq 1 ] && continue
    [ "${EXCLUDED[i]}" -eq 1 ] && continue
    case " $CYCLE_NUMS " in *" ${NUM[i]} "*) continue ;; esac
    for DEP in ${DEPS_IN[i]}; do
        DEP_IDX=$(index_of "$DEP") || continue
        [ "${RESOLVED[DEP_IDX]}" -eq 1 ] && continue
        INDIRECT_MSGS="${INDIRECT_MSGS}#${NUM[i]} bloqueado por #$DEP: excluido del orden"$'\n'
    done
done

# --- Salida ------------------------------------------------------------------

if [ -z "$CYCLE_MSGS" ] && [ -z "$BLOCKED_MSGS" ] && [ -z "$INDIRECT_MSGS" ]; then
    echo "Sin ciclos ni bloqueos externos."
else
    printf '%s' "$CYCLE_MSGS" "$BLOCKED_MSGS" "$INDIRECT_MSGS"
fi
echo

if [ "${#ORDER[@]}" -gt 0 ]; then
    pos=1
    LAUNCH_NUMS=""
    for idx in "${ORDER[@]}"; do
        if [ -z "${DEPS_IN[idx]}" ]; then
            JUST="sin dependencias abiertas"
        else
            # Split intencional: format_dep_list espera args separados, no un unico string.
            # shellcheck disable=SC2086
            JUST="tras $(format_dep_list ${DEPS_IN[idx]})"
        fi
        echo "$pos. #${NUM[idx]} [${TIPO[idx]}] ${TITLE[idx]} -- $JUST"
        LAUNCH_NUMS="$LAUNCH_NUMS ${NUM[idx]}"
        pos=$((pos + 1))
    done
    echo "$LAUNCH_COMMAND$LAUNCH_NUMS"
    exit 0
fi

echo "$LAUNCH_COMMAND (sin issues lanzables)"
exit 1
