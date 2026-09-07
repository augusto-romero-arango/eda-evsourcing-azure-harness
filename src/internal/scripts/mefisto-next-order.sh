#!/usr/bin/env bash
# mefisto-next-order.sh -- Calcula el orden topologico de lanzamiento de los
# issues 'estado:listo' abiertos del repo de Mefisto (issue #936).
#
# Implementacion CANONICA (MEF-ADR-0049 decision 2 y 6): bash 3.2 + jq + gh +
# git, sin `declare -A`. El shim de compatibilidad en .claude/scripts/ lo
# aporta el issue del comando que lo consume (#939), via `{{mefisto:run}}`
# (plantilla documentada en src/internal/scripts/README.md).
#
# Por que existe: el modo 'orden-de-batch' de mefisto-planner ordena los
# issues A MANO leyendo '## Dependencias', y mefisto-validate-batch-deps.sh
# (paso 1.5 de /mefisto-sequential) solo VALIDA un orden ya dado -- no lo
# calcula, no detecta ciclos y no separa los issues lanzables de los que
# tienen un bloqueo externo abierto. Con 3+ issues 'estado:listo'
# interdependientes el planner razona el grafo cada vez y puede equivocarse
# en silencio. Este script hace ese calculo de forma determinista y solo
# lectura (a diferencia del validador, nunca muta labels ni bodies).
#
# Uso:
#   src/internal/scripts/mefisto-next-order.sh
#   (sin argumentos: opera sobre TODO el universo 'estado:listo' abierto)
#
# Exit codes:
#   0 -- hay al menos un issue lanzable (el orden no quedo vacio)
#   1 -- no hay ningun issue lanzable (universo vacio, o todos los issues
#        quedaron en ciclos y/o bloqueados)
#   2 -- fallo 'gh issue list', o se invoco con argumentos (no acepta ninguno)
#
# Universo de analisis (MEF-ADR-0011, Definition of Ready): exactamente los
# issues 'estado:listo' Y abiertos -- ni borradores ni cerrados. El label
# 'bloqueado' no filtra nada (issue #466): un issue que lo lleva puesto entra
# igual al analisis, y si su dependencia queda resuelta por el orden calculado
# aqui simplemente entra al orden -- este script nunca muta ese label
# (a diferencia de mefisto-validate-batch-deps.sh, que si lo hace).
#
# Extraccion de dependencias (segunda copia del mismo awk|grep de
# mefisto-validate-batch-deps.sh -- MEF-ADR-0018, regla de tres: se extrae a
# _mefisto-common.sh solo cuando aparezca un tercer consumidor): SOLO
# dependencias forward de la seccion '## Dependencias' ('Depende de #N' /
# 'Bloqueado por #N', case-insensitive); se ignoran 'Bloquea', 'Consumido
# por' y la prosa libre. Una dependencia DENTRO del universo esta abierta por
# construccion (el listado es --state open); para las de FUERA se consulta su
# estado, y CLOSED/MERGED = satisfecha (no genera arista ni bloqueo).
#
# Clasificacion de cada issue del universo -- toda exclusion se reporta, ese
# es el punto del script (un issue que no aparece ni en el orden ni en la
# cabecera seria un silencio indistinguible de "no se miro"):
#   (a) Bloqueo externo: declara al menos una dependencia abierta que NO esta
#       en el universo 'estado:listo' -- excluido del orden, reportado como
#       '#N bloqueado por #M: fuera de estado:listo, estado OPEN'.
#   (b) Ciclo: depende directa o indirectamente de si mismo -- excluido del
#       orden, reportado con sus miembros ('ciclo: #A -> #B -> #A').
#   (c) Bloqueo indirecto: sus dependencias son todas intra-universo, pero al
#       menos una quedo excluida por (a), (b) o (c) -- excluido del orden
#       (lanzarlo violaria su dependencia), reportado como '#N bloqueado por
#       #M: excluido del orden'. Sin este caso el script emitiria una linea
#       '/mefisto-sequential' que mefisto-validate-batch-deps.sh rechaza en el
#       paso 1.5: para el validador, una dependencia abierta fuera del batch
#       es un bloqueo real y aborta el batch entero.
#   (d) Lanzable: todas sus dependencias abiertas estan en el orden, antes que
#       el. Entra al orden por Kahn con seleccion golosa del menor numero
#       disponible en cada paso -- de ahi el empate resuelto por numero de
#       issue ascendente que pide CA-2.
#
# La ultima linea de la salida es SIEMPRE la linea de lanzamiento
# ('/mefisto-sequential <orden>', o '/mefisto-sequential (sin issues
# lanzables)' si el orden quedo vacio) -- nunca una salida vacia con exit 0.
#
# No usa 'set -e' (mismo motivo que el validador: 'gh issue view' de una
# dependencia puede ser un PR, y esa falla es esperada -- se cae a 'gh pr
# view' explicitamente, nunca se propaga como abort).

set -uo pipefail

if [ "$#" -gt 0 ]; then
    echo "ERROR: argumento desconocido: $*. Este script no acepta argumentos." >&2
    echo "Uso: src/internal/scripts/mefisto-next-order.sh" >&2
    exit 2
fi

ISSUE_LIMIT=200

if ! ISSUES_JSON=$(gh issue list --label "estado:listo" --state open --limit "$ISSUE_LIMIT" --json number,title,body 2>/dev/null); then
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

# Pertenece un numero de issue al universo (lista NUMS)? Mismo patron que
# pos_in_batch de mefisto-validate-batch-deps.sh, pero solo de pertenencia.
in_universe() {
    local target="$1" n
    for n in $NUMS; do
        [ "$n" = "$target" ] && return 0
    done
    return 1
}

# Estado (issue o PR) de una dependencia -- puede fallar si no existe. Solo se
# consulta para dependencias FUERA del universo: las de dentro estan abiertas
# por construccion, y preguntarlo de nuevo seria un round-trip a gh por arista
# cuyo fallo transitorio degradaria a "satisfecha" una dependencia real.
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
# Los arrays cubren TODOS los issues del universo (no solo los lanzables): un
# issue excluido sigue siendo nodo del grafo, y sus dependientes necesitan
# poder apuntarle para clasificarse como caso (c).

NUM=()
TITLE=()
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
    DEPS_IN+=("$INSET")
    EXCLUDED+=("$IS_BLOCKED")
done

COUNT=${#NUM[@]}

# Indice (0-based) de un numero de issue dentro del universo; status != 0 si
# ese numero no esta en el universo.
index_of() {
    local target="$1" i
    for ((i = 0; i < COUNT; i++)); do
        [ "${NUM[i]}" = "$target" ] && { echo "$i"; return 0; }
    done
    return 1
}

# --- Pase 2: Kahn sobre los nodos no excluidos -------------------------------
# Un nodo excluido nunca se elige y nunca decrementa a sus dependientes: por
# eso sus dependientes se quedan sin resolver y caen al caso (c) del reporte,
# en vez de colarse al orden con su dependencia incumplida.

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
# DFS blanco/gris/negro clasico sobre las aristas "depende de" (u -> v si u
# depende de v). Un nodo gris re-visitado es un ancestro en la pila actual: el
# segmento de la pila desde ese ancestro hasta el tope ES el ciclo. Un nodo que
# solo depende TRANSITIVAMENTE de un ciclo queda antes de ese ancestro en la
# pila, nunca aparece en el ciclo reportado, y se reporta en el pase 4.

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
# Todo lo que quedo sin resolver y no tiene ya un reporte propio -- ni bloqueo
# externo (a) ni miembro de ciclo (b) -- esta detras de algo que si lo tiene.

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
        echo "$pos. #${NUM[idx]} ${TITLE[idx]} -- $JUST"
        LAUNCH_NUMS="$LAUNCH_NUMS ${NUM[idx]}"
        pos=$((pos + 1))
    done
    echo "/mefisto-sequential$LAUNCH_NUMS"
    exit 0
fi

echo "/mefisto-sequential (sin issues lanzables)"
exit 1
