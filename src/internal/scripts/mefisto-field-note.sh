#!/usr/bin/env bash
# mefisto-field-note.sh -- Entrega idempotente y recuperable de una field note
# (issues #1295/#1299)
#
# Implementacion CANONICA (MEF-ADR-0049 decision 2). Extrae a un pipeline Bash
# ejecutable y probado la secuencia mecanica de worktree/commit/push/PR que
# hasta ahora vivia como ~200 lineas de prosa shell en el epilogo de
# src/internal/agents/mefisto-planner.md -- una secuencia mecanica expresada
# como texto que el modelo debia reinterpretar al final de una conversacion
# larga, con incidentes reales de rama documental creada en el checkout
# principal o de entrega sin PR.
#
# El issue #1295 solo cubria la PRIMERA entrega (abortaba si la rama ya
# existia). Este script (issue #1299) tolera reintentos y fallos parciales:
# repetir la invocacion con el mismo --agent/--timestamp/--session-id
# recupera la rama, el worktree, el commit y el PR que ya existan de esa
# misma sesion en vez de crear una segunda copia de cada uno (CA-1). Distingue
# ademas los tres estados posibles de un PR de una sesion previa -- abierto
# (se reutiliza), cerrado sin merge (se reabre) y mergeado (se considera
# entregado) -- consultando `gh pr list --state all --json ...,mergedAt` y
# comprobando la LONGITUD del array antes de leer su primer elemento (CA-2):
# `.[0] | [...] | @tsv` sobre una lista vacia emite tabuladores para el
# elemento nulo, y `[ -n "$PR_DATA" ]` los tomaba como PR existente, saltandose
# `gh pr create` -- el defecto concreto que reporta el issue.
#
# Uso:
#   printf '%s\n' "$MARKDOWN" | src/internal/scripts/mefisto-field-note.sh \
#       --agent mefisto-planner --timestamp 2026-09-13-1530 \
#       --session-id 2026-09-13-1530-07-abc123def456-12345
#
# Exit code: 0 si la entrega completo (PR creado, reutilizado, reabierto o ya
# mergeado), 1 en cualquier fallo -- el mensaje de error identifica el ultimo
# checkpoint confirmado (worktree/commit/push/pr) y una accion concreta de
# recuperacion (CA-3).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat >&2 <<'EOF'
Uso: mefisto-field-note.sh --agent <nombre> --timestamp <YYYY-MM-DD-HHMM> --session-id <id-seguro>

Recibe el contenido Markdown de la field note por stdin. Crea (o recupera, si
ya existe de una entrega anterior de la misma sesion) un worktree temporal
aislado del checkout principal y en el commitea, empuja y abre/reabre/reusa
el PR de docs/bitacora/field-notes/<timestamp>-<agente>.md contra la rama
predeterminada del repo.
EOF
}

AGENT=""
TIMESTAMP=""
SESSION_ID=""

while [ $# -gt 0 ]; do
    case "$1" in
        --agent)
            [ $# -ge 2 ] || { echo "ERROR: --agent requiere un valor" >&2; usage; exit 1; }
            AGENT="$2"; shift 2 ;;
        --timestamp)
            [ $# -ge 2 ] || { echo "ERROR: --timestamp requiere un valor" >&2; usage; exit 1; }
            TIMESTAMP="$2"; shift 2 ;;
        --session-id)
            [ $# -ge 2 ] || { echo "ERROR: --session-id requiere un valor" >&2; usage; exit 1; }
            SESSION_ID="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "ERROR: argumento desconocido '$1'" >&2
            usage
            exit 1 ;;
    esac
done

if [ -z "$AGENT" ] || [ -z "$TIMESTAMP" ] || [ -z "$SESSION_ID" ]; then
    echo "ERROR: --agent, --timestamp y --session-id son obligatorios" >&2
    usage
    exit 1
fi

# CA-1: validacion de FORMA antes de tocar Git. AGENT y SESSION_ID componen
# tanto la ruta de la field note (docs/bitacora/field-notes/<ts>-<agente>.md)
# como el nombre de la rama documental (docs/<agente>-field-note-<session>) --
# un valor con '/', '..', espacios o metacaracteres de shell podria escapar
# de ese directorio o inyectar argumentos en `git`/`gh`. El alfabeto permitido
# (letras, digitos, '-', '_') excluye '.' por completo, asi que ni siquiera
# hace falta un chequeo especifico de '..'.
validate_slug() {
    local value="$1" label="$2" max="$3"
    case "$value" in
        -*)
            echo "ERROR: $label '$value' no puede empezar con '-'" >&2
            return 1
            ;;
    esac
    if [[ "$value" =~ [^A-Za-z0-9_-] ]]; then
        echo "ERROR: $label '$value' es invalido: solo se permiten letras, digitos, '-' y '_'" >&2
        return 1
    fi
    if [ "${#value}" -gt "$max" ]; then
        echo "ERROR: $label '$value' supera $max caracteres" >&2
        return 1
    fi
    return 0
}

validate_slug "$AGENT" "--agent" 60 || exit 1
validate_slug "$SESSION_ID" "--session-id" 120 || exit 1

if ! [[ "$TIMESTAMP" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$ ]]; then
    echo "ERROR: --timestamp '$TIMESTAMP' es invalido: se espera el formato YYYY-MM-DD-HHMM" >&2
    exit 1
fi

for dep in git gh jq; do
    command -v "$dep" >/dev/null 2>&1 || { echo "ERROR: '$dep' no esta disponible en PATH" >&2; exit 1; }
done

source "$SCRIPT_DIR/lib/_mefisto-common.sh"
assert_in_mefisto || exit 1

if [ -z "${MEFISTO_REPO_SLUG:-}" ]; then
    echo "ERROR: no se pudo resolver el repo remoto (gh repo view --json nameWithOwner); revisa 'gh auth status'" >&2
    exit 1
fi

FIELD_NOTE_CONTENT="$(cat)"
if [ -z "$FIELD_NOTE_CONTENT" ]; then
    echo "ERROR: no se recibio contenido por stdin para la field note" >&2
    exit 1
fi

# --- Custodia del checkout principal (CA-4) ---------------------------------
#
# Estos tres valores se vuelven a medir en cleanup_and_verify, al final: deben
# coincidir exactamente. El checkout principal nunca se usa para escribir ni
# para `git add`/`git commit` -- toda mutacion ocurre en WORKTREE_DIR, tanto en
# una entrega nueva como en una reanudada.
INITIAL_HEAD_REF="$(git -C "$MEFISTO_REPO_ROOT" symbolic-ref -q --short HEAD || true)"
INITIAL_HEAD_SHA="$(git -C "$MEFISTO_REPO_ROOT" rev-parse HEAD)" \
    || { echo "ERROR: no se pudo resolver HEAD del checkout principal" >&2; exit 1; }
INITIAL_STATUS="$(git -C "$MEFISTO_REPO_ROOT" status --porcelain=v1 --untracked-files=all)"

WORKTREE_DIR=""
WORKTREE_REGISTERED=0
CLEANUP_DONE=0

# LAST_CHECKPOINT -- el ultimo paso CONFIRMADO de la entrega (CA-3): "inicio"
# hasta que el worktree queda listo, luego "worktree" -> "commit" -> "push" ->
# "pr". recovery_abort() lo imprime tal cual quedo antes del paso que fallo,
# para que quien retoma la sesion sepa exactamente cuanto se alcanzo a hacer.
LAST_CHECKPOINT="inicio"

# recovery_abort <paso> <accion>
#
# Aborta identificando el PASO que fallo (no el checkpoint confirmado --
# LAST_CHECKPOINT es lo ultimo que SI se completo) y una ACCION concreta de
# recuperacion (CA-3): nunca un mensaje generico de "goto retry", siempre algo
# que la sesion que retoma pueda ejecutar o verificar.
recovery_abort() {
    local paso="$1" accion="$2"
    echo "ERROR: fallo en el paso '$paso' de la entrega de la field note (sesion '$SESSION_ID')" >&2
    echo "Ultimo checkpoint confirmado: $LAST_CHECKPOINT" >&2
    echo "Accion de recuperacion: $accion" >&2
    exit 1
}

# cleanup_and_verify -- trap EXIT (CA-4)
#
# Corre pase lo que pase (exito o cualquier abort de mas abajo). Limpia el
# worktree SOLO si esta registrado y su status quedo limpio (un commit
# fallido, o una field note todavia sin confirmar en DOC_BRANCH, se conserva a
# proposito, para no perder la unica copia recuperable -- CA-3). Un worktree
# ya commiteado y limpio se puede borrar sin perder nada: el commit sigue vivo
# en la rama del repo principal, que comparte el mismo object store; una
# entrega que reanude esta misma sesion vuelve a montarlo con
# `git worktree add` sobre esa misma rama. Despues verifica que ref, SHA y
# status del checkout principal coincidan EXACTAMENTE con los medidos al
# arrancar; si no, fuerza exit 1 aunque el resto del script haya completado
# bien -- ese invariante es mas importante que el resultado de la entrega.
cleanup_and_verify() {
    local exit_code=$?
    [ "$CLEANUP_DONE" -eq 1 ] && return "$exit_code"
    CLEANUP_DONE=1

    if [ -n "$WORKTREE_DIR" ] && [ "$WORKTREE_REGISTERED" -eq 1 ] && [ -d "$WORKTREE_DIR" ]; then
        local wt_status
        wt_status="$(git -C "$WORKTREE_DIR" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)"
        if [ -z "$wt_status" ]; then
            git -C "$MEFISTO_REPO_ROOT" worktree remove "$WORKTREE_DIR" >/dev/null 2>&1 || true
        else
            echo "AVISO: el worktree '$WORKTREE_DIR' conserva cambios sin commitear; no se elimina. Status:" >&2
            printf '%s\n' "$wt_status" >&2
        fi
    elif [ -n "$WORKTREE_DIR" ] && [ -d "$WORKTREE_DIR" ]; then
        rmdir "$WORKTREE_DIR" 2>/dev/null || true
    fi

    local current_ref current_sha current_status
    current_ref="$(git -C "$MEFISTO_REPO_ROOT" symbolic-ref -q --short HEAD || true)"
    current_sha="$(git -C "$MEFISTO_REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
    current_status="$(git -C "$MEFISTO_REPO_ROOT" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)"

    if [ "$current_ref" != "$INITIAL_HEAD_REF" ] || [ "$current_sha" != "$INITIAL_HEAD_SHA" ] || [ "$current_status" != "$INITIAL_STATUS" ]; then
        echo "ERROR: el checkout principal cambio durante la entrega de la field note (invariante CA-4 violado)" >&2
        echo "  ref:    inicial='$INITIAL_HEAD_REF' actual='$current_ref'" >&2
        echo "  sha:    inicial='$INITIAL_HEAD_SHA' actual='$current_sha'" >&2
        echo "  status: inicial='$INITIAL_STATUS' actual='$current_status'" >&2
        exit_code=1
    fi

    exit "$exit_code"
}
trap cleanup_and_verify EXIT

# --- Resolver la rama predeterminada (CA-2) ---------------------------------
#
# Sin `2>&1`: la salida de `gh` se usa como VALOR (nombre de rama que alimenta
# `git fetch`, `git worktree add origin/<rama>` y `gh pr create --base`), asi
# que fusionar su stderr la corromperia en cuanto gh emita cualquier aviso en
# un exito (token por expirar, version nueva disponible). El stderr de gh cae
# directo al stderr de este script -- el diagnostico no se pierde, solo deja de
# contaminar el valor. Misma convencion que mefisto-release.sh y
# mefisto-tooling-pipeline.sh.
DEFAULT_BRANCH="$(gh repo view --repo "$MEFISTO_REPO_SLUG" --json defaultBranchRef --jq '.defaultBranchRef.name')"
GH_REPO_VIEW_RC=$?
if [ "$GH_REPO_VIEW_RC" -ne 0 ] || [ -z "$DEFAULT_BRANCH" ] || [ "$DEFAULT_BRANCH" = "null" ]; then
    echo "ERROR: no se pudo resolver la rama predeterminada del repo via 'gh repo view' (rc=$GH_REPO_VIEW_RC); revisa 'gh auth status'" >&2
    exit 1
fi

FIELD_NOTE_REL="docs/bitacora/field-notes/${TIMESTAMP}-${AGENT}.md"
DOC_BRANCH="docs/${AGENT}-field-note-${SESSION_ID}"

git -C "$MEFISTO_REPO_ROOT" fetch origin "$DEFAULT_BRANCH" \
    || recovery_abort "worktree" "'git fetch origin $DEFAULT_BRANCH' fallo; verifica conectividad de red y credenciales de git, luego reintenta con los mismos --agent/--timestamp/--session-id."

# --- Localizar rama/worktree preexistentes de esta sesion (CA-1/CA-2) -------
#
# Tres fuentes posibles de una entrega previa parcial: (a) ya hay un worktree
# REGISTRADO para DOC_BRANCH (la corrida anterior no llego a limpiarlo, p. ej.
# un proceso matado a la fuerza); (b) DOC_BRANCH existe LOCAL pero sin
# worktree activo (el worktree si se limpio, pero la rama -- que vive en el
# object store compartido, no en el worktree -- sobrevivio); (c) DOC_BRANCH
# solo existe en origin (el push de una corrida anterior tuvo exito pero el
# proceso murio antes de limpiar localmente, o la rama local se perdio por
# otra via). Se resuelven en ese orden porque cada una es mas barata/directa
# de reanudar que la siguiente.
find_worktree_path_for_branch() {
    local branch="$1"
    git -C "$MEFISTO_REPO_ROOT" worktree list --porcelain | awk -v want="refs/heads/$branch" '
        /^worktree / { wt = substr($0, 10) }
        /^branch / { if ($2 == want) { print wt; exit } }
    '
}

EXISTING_WT_PATH="$(find_worktree_path_for_branch "$DOC_BRANCH")"
if [ -n "$EXISTING_WT_PATH" ] && [ ! -d "$EXISTING_WT_PATH" ]; then
    # git todavia registra el worktree pero su directorio ya no esta (borrado
    # a mano o por el SO): purga la entrada huerfana y cae al camino (b).
    git -C "$MEFISTO_REPO_ROOT" worktree prune >/dev/null 2>&1 || true
    EXISTING_WT_PATH=""
fi

BRANCH_EXISTS_LOCAL=0
git -C "$MEFISTO_REPO_ROOT" show-ref --verify --quiet "refs/heads/$DOC_BRANCH" && BRANCH_EXISTS_LOCAL=1

# refspec EXPLICITO: sin el, `git fetch origin <rama>` solo actualiza
# FETCH_HEAD y no crea/actualiza `refs/remotes/origin/<rama>` a menos que el
# remote tenga configurado ese refspec de antemano -- y el `git worktree add`
# de la rama (c), mas abajo, necesita ese ref remoto resuelto por nombre.
REMOTE_DOC_BRANCH_EXISTS=0
git -C "$MEFISTO_REPO_ROOT" fetch origin "refs/heads/$DOC_BRANCH:refs/remotes/origin/$DOC_BRANCH" >/dev/null 2>&1 \
    && REMOTE_DOC_BRANCH_EXISTS=1

SUMMARIES_DIR="$MEFISTO_REPO_ROOT/.mefisto/pipeline/summaries"
mkdir -p "$SUMMARIES_DIR"

if [ -n "$EXISTING_WT_PATH" ]; then
    WORKTREE_DIR="$EXISTING_WT_PATH"
    echo "Worktree existente de una entrega previa de esta sesion reutilizado: $WORKTREE_DIR"
elif [ "$BRANCH_EXISTS_LOCAL" -eq 1 ]; then
    WORKTREE_DIR="$(mktemp -d "$SUMMARIES_DIR/field-note-${SESSION_ID}.XXXXXX")" \
        || { echo "ERROR: no se pudo crear el directorio temporal del worktree" >&2; exit 1; }
    git -C "$MEFISTO_REPO_ROOT" worktree add "$WORKTREE_DIR" "$DOC_BRANCH" \
        || recovery_abort "worktree" "La rama '$DOC_BRANCH' ya existe localmente pero 'git worktree add' fallo; revisa 'git -C $MEFISTO_REPO_ROOT worktree list' y 'git -C $MEFISTO_REPO_ROOT branch -vv', corre 'git -C $MEFISTO_REPO_ROOT worktree prune' si hay entradas huerfanas y reintenta con los mismos flags."
elif [ "$REMOTE_DOC_BRANCH_EXISTS" -eq 1 ]; then
    WORKTREE_DIR="$(mktemp -d "$SUMMARIES_DIR/field-note-${SESSION_ID}.XXXXXX")" \
        || { echo "ERROR: no se pudo crear el directorio temporal del worktree" >&2; exit 1; }
    git -C "$MEFISTO_REPO_ROOT" worktree add -b "$DOC_BRANCH" "$WORKTREE_DIR" "origin/$DOC_BRANCH" \
        || recovery_abort "worktree" "La rama '$DOC_BRANCH' existe en origin pero no localmente y 'git worktree add' fallo; verifica conectividad de red y reintenta con los mismos flags."
else
    WORKTREE_DIR="$(mktemp -d "$SUMMARIES_DIR/field-note-${SESSION_ID}.XXXXXX")" \
        || { echo "ERROR: no se pudo crear el directorio temporal del worktree" >&2; exit 1; }
    git -C "$MEFISTO_REPO_ROOT" worktree add -b "$DOC_BRANCH" "$WORKTREE_DIR" "origin/$DEFAULT_BRANCH" \
        || recovery_abort "worktree" "Esta es la primera entrega de la sesion y 'git worktree add' fallo; revisa que 'origin/$DEFAULT_BRANCH' exista (git -C $MEFISTO_REPO_ROOT fetch origin $DEFAULT_BRANCH) y reintenta."
fi
WORKTREE_REGISTERED=1
LAST_CHECKPOINT="worktree"

# --- Escribir y validar exclusivamente la field note (CA-2/CA-4) -----------
#
# Se (re)escribe el mismo contenido siempre, incluso al reanudar: si ya estaba
# commiteado identico, `git add` no deja nada staged (ver mas abajo, no genera
# un commit vacio); si el contenido cambio entre reintentos, queda staged para
# que el siguiente bloque lo AMENDe en vez de crear un segundo commit (CA-1).
FIELD_NOTE_ABS="$WORKTREE_DIR/$FIELD_NOTE_REL"
mkdir -p "$(dirname "$FIELD_NOTE_ABS")" \
    || recovery_abort "worktree" "No se pudo crear el directorio de '$FIELD_NOTE_REL' dentro de '$WORKTREE_DIR'; revisa permisos de disco y reintenta."
printf '%s\n' "$FIELD_NOTE_CONTENT" > "$FIELD_NOTE_ABS" \
    || recovery_abort "worktree" "No se pudo escribir '$FIELD_NOTE_ABS'; revisa espacio/permisos de disco y reintenta."

git -C "$WORKTREE_DIR" add -- "$FIELD_NOTE_REL" \
    || recovery_abort "worktree" "'git add' del worktree documental fallo en '$WORKTREE_DIR'; revisa 'git -C $WORKTREE_DIR status' y reintenta."

# `-x` (linea completa, no subcadena): sin el, cualquier entrada de status que
# CONTENGA el path esperado -- un rename hacia el, un path mas largo con el
# mismo prefijo -- se filtraria como si fuera la field note. Se acepta tanto
# "A  " (primer commit de la rama) como "M  " (contenido distinto al de un
# commit previo de esta misma sesion, camino de amend). Nunca se stagea, borra
# ni fuerza limpieza de ninguna otra ruta (CA-4): cualquier otra cosa aborta.
WORKTREE_STATUS="$(git -C "$WORKTREE_DIR" status --porcelain=v1 --untracked-files=all)"
OTHER_PATHS="$(printf '%s\n' "$WORKTREE_STATUS" \
    | grep -vxF "A  $FIELD_NOTE_REL" \
    | grep -vxF "M  $FIELD_NOTE_REL" \
    | grep -v '^$' || true)"
if [ -n "$OTHER_PATHS" ]; then
    echo "ERROR: el worktree documental contiene cambios fuera de '$FIELD_NOTE_REL':" >&2
    printf '%s\n' "$OTHER_PATHS" >&2
    exit 1
fi

# --- Commit: crear, reusar o amend (CA-1/CA-3) ------------------------------
HEAD_HAS_NOTE=0
git -C "$WORKTREE_DIR" cat-file -e "HEAD:$FIELD_NOTE_REL" 2>/dev/null && HEAD_HAS_NOTE=1

if git -C "$WORKTREE_DIR" diff --cached --quiet -- "$FIELD_NOTE_REL"; then
    # Nada staged distinto de HEAD: si HEAD ya traia la nota, es un commit de
    # una entrega previa de esta misma sesion -- se reusa sin commitear de
    # nuevo. FIELD_NOTE_CONTENT ya se valido no vacio, asi que HEAD_HAS_NOTE=0
    # aqui no deberia ocurrir salvo un estado corrupto del worktree.
    if [ "$HEAD_HAS_NOTE" -eq 1 ]; then
        echo "Commit ya existente de esta sesion reutilizado (contenido identico, no se creo uno nuevo)"
    else
        recovery_abort "commit" "El worktree en '$WORKTREE_DIR' quedo sin cambios staged pero HEAD tampoco tiene '$FIELD_NOTE_REL' -- estado inconsistente. Inspecciona 'git -C $WORKTREE_DIR log --oneline' y 'git -C $WORKTREE_DIR status' a mano antes de reintentar."
    fi
else
    if [ "$HEAD_HAS_NOTE" -eq 1 ]; then
        git -C "$WORKTREE_DIR" commit --amend --no-edit \
            || recovery_abort "commit" "'git commit --amend' fallo en '$WORKTREE_DIR' al actualizar el contenido de la field note de una entrega previa; revisa 'git -C $WORKTREE_DIR status' (el commit anterior sigue intacto) y reintenta."
        echo "Commit existente de esta sesion actualizado via --amend (el contenido de la field note cambio respecto al intento anterior)"
    else
        git -C "$WORKTREE_DIR" commit -m "docs(bitacora): agregar field note de $AGENT" \
            || recovery_abort "commit" "'git commit' del worktree documental fallo en '$WORKTREE_DIR'; revisa 'git -C $WORKTREE_DIR status' (la field note sigue staged) y reintenta."
    fi
fi
COMMIT_SHA="$(git -C "$WORKTREE_DIR" rev-parse HEAD)"
LAST_CHECKPOINT="commit"

# --- Push (CA-1/CA-3) --------------------------------------------------------
#
# `--force-with-lease`: idempotente en el camino feliz (si origin ya tiene
# exactamente este commit, es un no-op -- "Everything up-to-date") y necesario
# en el camino de amend (el SHA local cambio respecto al que ya se habia
# empujado en un intento previo). Es seguro porque DOC_BRANCH es una rama
# documental de un solo dueno (esta sesion): nadie mas le hace push, y
# --force-with-lease igual aborta si origin diverge de lo que este fetch ya
# observo (el de "Localizar rama/worktree preexistentes", arriba).
git -C "$WORKTREE_DIR" push --force-with-lease -u origin "$DOC_BRANCH" \
    || recovery_abort "push" "'git push --force-with-lease' de '$DOC_BRANCH' fallo; el commit $COMMIT_SHA sigue disponible localmente en '$WORKTREE_DIR' (o reanudable con los mismos --agent/--timestamp/--session-id). Revisa conectividad de red, permisos del remoto y reintenta."
LAST_CHECKPOINT="push"

# --- Consultar y resolver el PR (CA-2/CA-3) ---------------------------------
#
# query_pr_for_branch imprime el PR mas reciente de DOC_BRANCH->DEFAULT_BRANCH
# EN CUALQUIER ESTADO ('--state all'), o cadena vacia si no hay ninguno.
# Deliberadamente NO usa `.[0] | [...] | @tsv` como unica condicion de
# existencia (el defecto que reporta el issue: sobre `[]` esa expresion emite
# tabuladores para el elemento nulo, indistinguibles en bash de "hay datos").
# En su lugar, jq evalua la LONGITUD del array antes de indexar: `empty` no
# imprime nada en absoluto cuando no hay PR.
query_pr_for_branch() {
    gh pr list --head "$DOC_BRANCH" --base "$DEFAULT_BRANCH" --repo "$MEFISTO_REPO_SLUG" \
        --state all --json number,url,state,mergedAt
}

PR_LIST_JSON="$(query_pr_for_branch)"
PR_LIST_RC=$?
if [ "$PR_LIST_RC" -ne 0 ]; then
    recovery_abort "consulta-pr" "'gh pr list' fallo para '$DOC_BRANCH'; la rama y el commit $COMMIT_SHA ya estan en origin (no se perdio nada). Revisa 'gh auth status' y reintenta con los mismos flags."
fi

PR_INFO="$(printf '%s' "$PR_LIST_JSON" | jq -c 'if length > 0 then .[0] else empty end' 2>/dev/null)"

if [ -z "$PR_INFO" ]; then
    # Sin `2>&1` por la misma razon que arriba, y aqui es aun mas visible:
    # `gh pr create` escribe su progreso ("Creating pull request for <head>
    # into <base> in <repo>") en stderr y SOLO la URL en stdout. Fusionarlos
    # dejaria PR_URL multilinea -- una "URL" que ni el reporte final ni quien
    # consuma este script (issue #1298) podrian usar.
    PR_URL="$(gh pr create --repo "$MEFISTO_REPO_SLUG" --base "$DEFAULT_BRANCH" --head "$DOC_BRANCH" \
        --title "docs(bitacora): field note de $AGENT ${TIMESTAMP}" \
        --body "Entrega aislada de la field note de la sesion $AGENT ${SESSION_ID}.")" \
        || recovery_abort "creacion-pr" "'gh pr create' fallo; la rama '$DOC_BRANCH' con el commit $COMMIT_SHA ya esta empujada a origin. Revisa 'gh auth status' y reintenta con los mismos flags -- la proxima corrida encontrara la rama ya lista y solo reintentara el PR."
    echo "PR creado (no existia ninguno para '$DOC_BRANCH')"
else
    PR_STATE="$(printf '%s' "$PR_INFO" | jq -r '.state')"
    PR_MERGED_AT="$(printf '%s' "$PR_INFO" | jq -r '.mergedAt')"
    PR_URL="$(printf '%s' "$PR_INFO" | jq -r '.url')"

    # `state == "MERGED"` ya deberia bastar (asi lo modela `gh`), pero
    # `mergedAt` no nulo es la evidencia de respaldo que pide el issue: un
    # `state: CLOSED` por si solo no distingue cierre sin merge de entrega
    # completada.
    if [ "$PR_STATE" = "MERGED" ] || { [ -n "$PR_MERGED_AT" ] && [ "$PR_MERGED_AT" != "null" ]; }; then
        echo "PR ya mergeado: la field note de esta sesion ya fue entregada ($PR_URL)"
    elif [ "$PR_STATE" = "OPEN" ]; then
        echo "PR ya existente reutilizado (no se llamo a 'gh pr create')"
    else
        gh pr reopen --repo "$MEFISTO_REPO_SLUG" "$PR_URL" \
            || recovery_abort "reapertura-pr" "El PR $PR_URL de '$DOC_BRANCH' esta cerrado sin merge y 'gh pr reopen' fallo; la rama y el commit $COMMIT_SHA siguen intactos en origin. Reabrelo a mano en GitHub, o revisa 'gh auth status' y reintenta."
        echo "PR cerrado sin merge fue reabierto: $PR_URL"
    fi
fi
LAST_CHECKPOINT="pr"

echo "Field note: $FIELD_NOTE_REL"
echo "Rama: $DOC_BRANCH"
echo "Commit: $COMMIT_SHA"
echo "PR: $PR_URL"
