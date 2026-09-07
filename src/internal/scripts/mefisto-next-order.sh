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
#        quedaron en ciclos y/o con bloqueo externo)
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
# por' y la prosa libre. Dependencia CLOSED/MERGED = satisfecha (no genera
# arista, este dentro o fuera del universo).
#
# Clasificacion de cada issue del universo:
#   (a) Bloqueo externo: declara al menos una dependencia abierta que NO esta
#       en el universo 'estado:listo' -- se excluye del orden y se reporta al
#       tope ('#N bloqueado por #M: fuera de estado:listo, estado OPEN').
#   (b) Candidato: todas sus dependencias abiertas estan dentro del universo
#       -- entra al calculo del orden topologico (Kahn con seleccion golosa
#       del menor numero disponible en cada paso, lo que da el empate
#       resuelto por numero de issue ascendente que pide CA-2).
#   (c) Ciclo: candidato cuya arista nunca se resuelve porque depende
#       (directa o indirectamente) de si mismo -- se excluye del orden y se
#       reporta al tope con sus miembros ('ciclo: #A -> #B -> #A'). Un
#       candidato que solo depende TRANSITIVAMENTE de un ciclo ajeno (no es
#       el mismo parte del ciclo) tampoco entra al orden, pero esa
#       clasificacion de tercer nivel excede el alcance de este issue (ver
#       nota tecnica del issue #936: fuera de los 9 casos de CA-5) y queda
#       fuera del reporte -- no se anuncia como bug, es deuda conocida.
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

if ! ISSUES_JSON=$(gh issue list --label "estado:listo" --state open --limit 100 --json number,title,body 2>/dev/null); then
    echo "ERROR: fallo 'gh issue list --label estado:listo --state open'." >&2
    exit 2
fi

NUMS=$(echo "$ISSUES_JSON" | jq -r '.[].number' | sort -n)

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

# Estado (issue o PR) de una dependencia -- puede fallar si no existe.
dep_state_of() {
    local dep="$1"
    gh issue view "$dep" --json state -q '.state' 2>/dev/null \
        || gh pr view "$dep" --json state -q '.state' 2>/dev/null \
        || echo ""
}

# Cuenta cuantas palabras (numeros separados por espacio) tiene $1. El split
# es intencional (asi se cuenta), no un descuido de comillas.
word_count() {
    # shellcheck disable=SC2086
    set -- $1
    echo "$#"
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

# --- Pase 1: clasificar cada issue del universo -----------------------------
# Bloqueo externo (dependencia abierta fuera del universo) excluye aqui mismo;
# el resto queda como candidato con sus dependencias intra-universo (INSET).

CAND_NUM=()
CAND_TITLE=()
CAND_DEPS=()
BLOCKED_MSGS=""

for ISSUE in $NUMS; do
    TITLE=$(title_of "$ISSUE")
    DEPS=$(body_of "$ISSUE" \
        | awk '/^##[[:space:]]*[Dd]ependencias/{f=1;next} /^##[[:space:]]/{f=0} f' \
        | grep -ioE '(Depende de|Bloqueado por)[[:space:]]+#[0-9]+' \
        | grep -oE '[0-9]+' | sort -u)

    INSET=""
    OUTSET=""
    for DEP in $DEPS; do
        [ "$DEP" = "$ISSUE" ] && continue
        DEP_STATE=$(dep_state_of "$DEP")
        case "$DEP_STATE" in CLOSED|MERGED) continue ;; esac
        if in_universe "$DEP"; then
            INSET="$INSET $DEP"
        else
            OUTSET="$OUTSET $DEP"
            BLOCKED_MSGS="$BLOCKED_MSGS
#$ISSUE bloqueado por #$DEP: fuera de estado:listo, estado OPEN"
        fi
    done

    if [ -z "$OUTSET" ]; then
        CAND_NUM+=("$ISSUE")
        CAND_TITLE+=("$TITLE")
        CAND_DEPS+=("$INSET")
    fi
done

CAND_COUNT=${#CAND_NUM[@]}

# Posicion (indice de array, 0-based) de un numero de issue dentro de los
# candidatos; status != 0 si ese numero no es candidato (quedo excluido por
# bloqueo externo en el pase 1).
candidate_index_of() {
    local target="$1" i
    for ((i = 0; i < CAND_COUNT; i++)); do
        [ "${CAND_NUM[i]}" = "$target" ] && { echo "$i"; return 0; }
    done
    return 1
}

# --- Pase 2: filtrar aristas a solo-candidatos y correr Kahn ----------------
# Una dependencia intra-universo que en el pase 1 quedo excluida (era
# candidata pero otra de SUS dependencias esta fuera del universo) se
# descarta aqui como arista: no hay nodo candidato al que apuntar.

RESOLVED=()
INDEG=()
for ((i = 0; i < CAND_COUNT; i++)); do
    RESOLVED[i]=0
    FILTERED=""
    for DEP in ${CAND_DEPS[i]}; do
        if candidate_index_of "$DEP" >/dev/null; then
            FILTERED="$FILTERED $DEP"
        fi
    done
    CAND_DEPS[i]="$FILTERED"
    INDEG[i]=$(word_count "$FILTERED")
done

ORDER=()
progress=1
while [ "$progress" -eq 1 ]; do
    progress=0
    best=-1
    for ((i = 0; i < CAND_COUNT; i++)); do
        if [ "${RESOLVED[i]}" -eq 0 ] && [ "${INDEG[i]}" -eq 0 ]; then
            if [ "$best" -eq -1 ] || [ "${CAND_NUM[i]}" -lt "${CAND_NUM[best]}" ]; then
                best=$i
            fi
        fi
    done
    if [ "$best" -ge 0 ]; then
        RESOLVED[best]=1
        ORDER+=("$best")
        progress=1
        BEST_NUM=${CAND_NUM[best]}
        for ((j = 0; j < CAND_COUNT; j++)); do
            if [ "${RESOLVED[j]}" -eq 0 ]; then
                case " ${CAND_DEPS[j]} " in
                    *" $BEST_NUM "*) INDEG[j]=$((INDEG[j] - 1)) ;;
                esac
            fi
        done
    fi
done

# --- Deteccion de ciclos entre los candidatos que quedaron sin resolver -----
# DFS blanco/gris/negro clasico sobre las aristas "depende de" (u -> v si u
# depende de v). Un nodo gris re-visitado es un ancestro en la pila actual:
# el segmento de la pila desde ese ancestro hasta el tope ES el ciclo (un
# candidato que solo depende TRANSITIVAMENTE de un ciclo ajeno queda antes de
# ese ancestro en la pila y por eso NUNCA aparece en el ciclo reportado --
# ver nota tecnica de la cabecera).

CYCLE_MSGS=""
COLOR=()
STACK=()
for ((i = 0; i < CAND_COUNT; i++)); do COLOR[i]="white"; done

stack_index_of() {
    local target="$1" k
    for ((k = 0; k < ${#STACK[@]}; k++)); do
        [ "${STACK[k]}" -eq "$target" ] && { echo "$k"; return 0; }
    done
    return 1
}

emit_cycle() {
    local anchor="$1" pos path n k
    pos=$(stack_index_of "$anchor")
    path=""
    for ((k = pos; k < ${#STACK[@]}; k++)); do
        n=${CAND_NUM[${STACK[k]}]}
        if [ -z "$path" ]; then path="#$n"; else path="$path -> #$n"; fi
    done
    path="$path -> #${CAND_NUM[anchor]}"
    CYCLE_MSGS="$CYCLE_MSGS
ciclo: $path"
}

dfs_visit() {
    local u="$1" dep v
    COLOR[u]="gray"
    STACK+=("$u")
    for dep in ${CAND_DEPS[u]}; do
        v=$(candidate_index_of "$dep") || continue
        [ "${RESOLVED[v]}" -eq 1 ] && continue
        case "${COLOR[v]}" in
            gray) emit_cycle "$v" ;;
            white) dfs_visit "$v" ;;
        esac
    done
    COLOR[u]="black"
    unset 'STACK[${#STACK[@]}-1]'
}

for ((i = 0; i < CAND_COUNT; i++)); do
    if [ "${RESOLVED[i]}" -eq 0 ] && [ "${COLOR[i]}" = "white" ]; then
        dfs_visit "$i"
    fi
done

# --- Salida ------------------------------------------------------------------

if [ -z "$CYCLE_MSGS" ] && [ -z "$BLOCKED_MSGS" ]; then
    echo "Sin ciclos ni bloqueos externos."
else
    [ -n "$CYCLE_MSGS" ] && echo "$CYCLE_MSGS"
    [ -n "$BLOCKED_MSGS" ] && echo "$BLOCKED_MSGS"
fi
echo

if [ "${#ORDER[@]}" -gt 0 ]; then
    pos=1
    LAUNCH_NUMS=""
    for idx in "${ORDER[@]}"; do
        NUM=${CAND_NUM[idx]}
        TITLE=${CAND_TITLE[idx]}
        DEPS=${CAND_DEPS[idx]}
        if [ -z "$DEPS" ]; then
            JUST="sin dependencias abiertas"
        else
            # Split intencional: format_dep_list espera args separados, no un unico string.
            # shellcheck disable=SC2086
            JUST="tras $(format_dep_list $DEPS)"
        fi
        echo "$pos. #$NUM $TITLE -- $JUST"
        LAUNCH_NUMS="$LAUNCH_NUMS $NUM"
        pos=$((pos + 1))
    done
    echo "/mefisto-sequential$LAUNCH_NUMS"
    exit 0
fi

echo "/mefisto-sequential (sin issues lanzables)"
exit 1
