#!/usr/bin/env bash
# mefisto-validate-batch-deps.sh -- Valida dependencias intra-batch antes de
# lanzar un batch secuencial de mefisto-sequential (paso 1.5, issue #436).
#
# Extraido de .claude/commands/mefisto-sequential.md: ese bloque bash vivia
# incrustado en el markdown del skill, con sintaxis posicional de shell ($1,
# $*, $#) -- y Claude Code expande los placeholders $N del ARCHIVO DEL COMANDO
# antes de que el agente lea su contenido, asi que el agente nunca veia el
# codigo que hay en disco, sino una version corrompida (`local target="437"`
# fijo en vez de `local target="$1"`, con 437 tomado de los argumentos de la
# invocacion real). El sintoma no fallaba: clasificaba mal en silencio, sin
# exit code que lo delatara, en la unica validacion que existe para no lanzar
# un batch mal ordenado. Extraer el bloque a un .sh real elimina la clase
# entera de defecto: un script en disco lo lee `bash`, no el constructor de
# prompts de Claude Code, asi que ningun $N puede corromperse aqui.
#
# Uso:
#   ./.claude/scripts/mefisto-validate-batch-deps.sh <issue1> <issue2> ...
#   (el orden de los argumentos ES el orden del batch)
#
# Exit codes:
#   0 -- el batch se puede lanzar (ver clasificacion abajo)
#   1 -- hay al menos un bloqueo real (tipo b): se aborta, no se muta ningun label
#   2 -- invocado sin argumentos (guarda fail-loud: no se valido nada)
#
# Clasificacion (issue #47, universo de analisis ampliado por issue #466): para
# CADA issue del batch -- ya no solo los que llevan el label 'bloqueado', ver
# nota abajo -- se leen sus dependencias forward ('Depende de #NNN' /
# 'Bloqueado por #NNN', case-insensitive) de la seccion '## Dependencias' de su
# body, ignorando referencias inversas ('Consumido por', 'Bloquea'/'Bloquea a')
# y prosa libre. Cada dependencia ABIERTA se clasifica:
#   (a) Satisfactible por el batch: es otro issue del batch y aparece ANTES en
#       el orden -- no bloquea (el orden + el sync verificado de #46 garantizan
#       que ya estara mergeada cuando arranque este eslabon). Si el issue llevaba
#       puesto el label 'bloqueado' se lo quita; si nunca lo tuvo, no se muta nada.
#   (b) Bloqueo real: esta fuera del batch (y no CLOSED/MERGED), o esta dentro
#       del batch pero DESPUES en el orden (mal ordenada) -- aborta el batch
#       entero y no muta ningun label.
# Las dependencias ya CLOSED/MERGED estan satisfechas y no bloquean (esten o
# no en el batch).
#
# Issue #466 (hueco 2): antes de este cambio, un issue SIN el label 'bloqueado'
# nunca llegaba a leer su body -- si el planner declaraba 'Depende de #X' con #X
# abierto pero olvidaba poner el label, el batch lo dejaba pasar en silencio y
# corria el issue antes que su dependencia. El label 'bloqueado' ahora es
# irrelevante como condicion de ENTRADA al analisis; conserva su rol solo como
# SALIDA (se quita de los issues que lo llevaban puesto cuando el batch resuelve
# sus dependencias, tipo (a) arriba).
#
# No usa 'set -e': tolera que 'gh issue view' falle sobre una dependencia que
# en realidad es un PR (cae a 'gh pr view') o que no existe -- la salida se
# gobierna con 'exit' explicitos, nunca con la propagacion de un comando que
# falla a medio camino.

set -uo pipefail

if [ "$#" -eq 0 ]; then
    echo "ERROR: se invoco sin issues. No se valido NADA (no interpretes esto como OK)." >&2
    echo "Uso: ./.claude/scripts/mefisto-validate-batch-deps.sh <issue1> <issue2> ..." >&2
    exit 2
fi

BATCH="$*"

# Posicion 1-based de un issue en el batch; status != 0 si no esta en el batch.
pos_in_batch() {
    local target="$1" i=0 n
    for n in $BATCH; do
        i=$((i + 1))
        [ "$n" = "$target" ] && { echo "$i"; return 0; }
    done
    return 1
}

ABORT_MSGS=""        # bloqueos reales (tipo b) acumulados de todo el batch
LABELS_TO_CLEAR=""   # issues tipo (a) a los que se les quitara 'bloqueado'

for ISSUE in $BATCH; do
    ISSUE_POS=$(pos_in_batch "$ISSUE")

    # El label 'bloqueado' ya NO filtra la entrada al analisis (issue #466):
    # se sigue leyendo para saber si hay que QUITARLO al final (rol de salida).
    LABELS=$(gh issue view "$ISSUE" --json labels -q '[.labels[].name] | join(",")')
    HAS_LABEL=""
    case ",$LABELS," in *",bloqueado,"*) HAS_LABEL=1 ;; esac

    # Extraer dependencias SOLO de la seccion '## Dependencias' y SOLO tras un
    # marcador forward canonico ('Depende de' / 'Bloqueado por'), ignorando
    # refs inversas/notas ('Consumido por', 'Bloquea'/'Bloquea a', 'se traslada
    # a', 'Relacionado con', prosa). Se leen de TODOS los issues del batch, no
    # solo de los que llevan 'bloqueado'.
    DEPS=$(gh issue view "$ISSUE" --json body -q '.body' \
        | awk '/^##[[:space:]]*[Dd]ependencias/{f=1;next} /^##[[:space:]]/{f=0} f' \
        | grep -ioE '(Depende de|Bloqueado por)[[:space:]]+#[0-9]+' \
        | grep -oE '[0-9]+' | sort -u)

    ISSUE_REAL=""    # bloqueos reales de ESTE issue
    for DEP in $DEPS; do
        [ "$DEP" = "$ISSUE" ] && continue
        # Estado de la dependencia (puede ser issue o PR).
        DEP_STATE=$(gh issue view "$DEP" --json state -q '.state' 2>/dev/null \
                 || gh pr view "$DEP" --json state -q '.state' 2>/dev/null || echo "")
        # CLOSED/MERGED -> dependencia ya satisfecha (caso ortogonal previo).
        case "$DEP_STATE" in CLOSED|MERGED) continue ;; esac
        # Abierta (o desconocida) -> clasificar por posicion en el batch.
        if DEP_POS=$(pos_in_batch "$DEP"); then
            if [ "$DEP_POS" -lt "$ISSUE_POS" ]; then
                : # (a) satisfactible: en el batch y ANTES en el orden -> no bloquea
            else
                # (b) mal ordenada: en el batch pero DESPUES de este issue.
                ISSUE_REAL="$ISSUE_REAL
  - #$DEP esta en el batch pero DESPUES de #$ISSUE (mal ordenada). Mueve #$DEP antes de #$ISSUE."
            fi
        else
            # (b) fuera del batch y no esta cerrada/mergeada.
            ISSUE_REAL="$ISSUE_REAL
  - #$DEP esta fuera del batch y no esta CLOSED/MERGED (bloqueo real)."
        fi
    done

    if [ -n "$ISSUE_REAL" ]; then
        ABORT_MSGS="$ABORT_MSGS
#$ISSUE no se puede lanzar:$ISSUE_REAL"
    elif [ -n "$HAS_LABEL" ]; then
        # Sin bloqueos reales: si el issue llevaba 'bloqueado' puesto, se resolvio
        # por el orden del batch (o por deps ya cerradas) y hay que quitarselo.
        # Si nunca lo tuvo, no hay nada que mutar.
        LABELS_TO_CLEAR="$LABELS_TO_CLEAR $ISSUE"
    fi
done

if [ -n "$ABORT_MSGS" ]; then
    echo "ABORTAR el batch. Bloqueos reales detectados:"
    echo "$ABORT_MSGS"
    echo
    echo "Reordena el batch (dependencias antes que sus dependientes) o cierra las"
    echo "dependencias externas antes de relanzar."
    exit 1
fi

# Solo si TODO el batch paso la validacion mutamos estado (no tocar labels si abortamos).
for ISSUE in $LABELS_TO_CLEAR; do
    gh issue edit "$ISSUE" --remove-label "bloqueado"
    echo "Quitado 'bloqueado' de #$ISSUE: sus dependencias abiertas se resuelven por el"
    echo "orden del batch + sync verificado (#46); las cerradas ya estan satisfechas."
done
echo "Validacion 1.5 OK: el batch se puede lanzar."
exit 0
