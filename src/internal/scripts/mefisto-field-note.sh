#!/usr/bin/env bash
# mefisto-field-note.sh -- Entrega aislada de una field note (issue #1295)
#
# Implementacion CANONICA (MEF-ADR-0049 decision 2). Extrae a un pipeline Bash
# ejecutable y probado la secuencia mecanica de worktree/commit/push/PR que
# hasta ahora vivia como ~200 lineas de prosa shell en el epilogo de
# src/internal/agents/mefisto-planner.md -- una secuencia mecanica expresada
# como texto que el modelo debia reinterpretar al final de una conversacion
# larga, con incidentes reales de rama documental creada en el checkout
# principal o de entrega sin PR. Corrige ademas un defecto verificable del
# camino feliz anterior: `gh pr list --jq '.[0] | [...] | @tsv'` sobre una
# lista vacia emite tabuladores para el elemento nulo, y `[ -n "$PR_DATA" ]`
# lo tomaba como PR existente, saltandose `gh pr create`. Este script evita
# esa clase de bug reusando find_open_pr_for_branch (_mefisto-common.sh), que
# ya normaliza list vacia/"null" a cadena vacia real.
#
# Uso:
#   printf '%s\n' "$MARKDOWN" | src/internal/scripts/mefisto-field-note.sh \
#       --agent mefisto-planner --timestamp 2026-09-13-1530 \
#       --session-id 2026-09-13-1530-07-abc123def456-12345
#
# Entrega SOLO la primera entrega (CA-3 del issue #1295): commit + push + PR
# cuando no existe todavia ni rama ni PR de esta sesion. La idempotencia y
# recuperacion de entregas parciales (rama ya existente, worktree huerfano,
# reapertura de PR cerrado) se endurece en el issue #1299; la delegacion desde
# el agente (que hoy sigue ejecutando su propia prosa shell) se conecta en el
# issue #1298.
#
# Exit code: 0 si la entrega completo (PR creado o reutilizado), 1 en
# cualquier fallo -- el mensaje de error indica el paso exacto.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat >&2 <<'EOF'
Uso: mefisto-field-note.sh --agent <nombre> --timestamp <YYYY-MM-DD-HHMM> --session-id <id-seguro>

Recibe el contenido Markdown de la field note por stdin. Crea un worktree
temporal aislado del checkout principal (nacido de origin/<rama-predeterminada>)
y en el commitea, empuja y abre un PR de
docs/bitacora/field-notes/<timestamp>-<agente>.md contra esa misma rama.
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
# para `git add`/`git commit` -- toda mutacion ocurre en WORKTREE_DIR.
INITIAL_HEAD_REF="$(git -C "$MEFISTO_REPO_ROOT" symbolic-ref -q --short HEAD || true)"
INITIAL_HEAD_SHA="$(git -C "$MEFISTO_REPO_ROOT" rev-parse HEAD)" \
    || { echo "ERROR: no se pudo resolver HEAD del checkout principal" >&2; exit 1; }
INITIAL_STATUS="$(git -C "$MEFISTO_REPO_ROOT" status --porcelain=v1 --untracked-files=all)"

WORKTREE_DIR=""
WORKTREE_REGISTERED=0
CLEANUP_DONE=0

# cleanup_and_verify -- trap EXIT (CA-4)
#
# Corre pase lo que pase (exito o cualquier abort de mas abajo). Limpia el
# worktree SOLO si esta registrado y su status quedo limpio (un commit
# fallido con la field note todavia sin confirmar en DOC_BRANCH se conserva a
# proposito, para no perder la unica copia recuperable). Despues verifica que
# ref, SHA y status del checkout principal coincidan EXACTAMENTE con los
# medidos al arrancar; si no, fuerza exit 1 aunque el resto del script haya
# completado bien -- ese invariante es mas importante que el resultado de la
# entrega.
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

# --- Worktree temporal nacido de origin/<default> (CA-2) --------------------
#
# Este corte entrega solo el camino inicial (issue #1295): si la rama ya
# existe -- local o en origin -- es que una entrega previa de esta misma
# sesion quedo a mitad de camino. Reanudarla es trabajo del issue #1299;
# aqui se aborta con un mensaje explicito en vez de adivinar el estado
# parcial.
git -C "$MEFISTO_REPO_ROOT" fetch origin "$DEFAULT_BRANCH" \
    || { echo "ERROR: 'git fetch origin $DEFAULT_BRANCH' fallo" >&2; exit 1; }

if git -C "$MEFISTO_REPO_ROOT" show-ref --verify --quiet "refs/heads/$DOC_BRANCH"; then
    echo "ERROR: la rama '$DOC_BRANCH' ya existe localmente -- la recuperacion de entregas parciales se endurece en el issue #1299" >&2
    exit 1
fi
if git -C "$MEFISTO_REPO_ROOT" ls-remote --exit-code --heads origin "$DOC_BRANCH" >/dev/null 2>&1; then
    echo "ERROR: la rama '$DOC_BRANCH' ya existe en origin -- la recuperacion de entregas parciales se endurece en el issue #1299" >&2
    exit 1
fi

SUMMARIES_DIR="$MEFISTO_REPO_ROOT/.mefisto/pipeline/summaries"
mkdir -p "$SUMMARIES_DIR"
WORKTREE_DIR="$(mktemp -d "$SUMMARIES_DIR/field-note-${SESSION_ID}.XXXXXX")" \
    || { echo "ERROR: no se pudo crear el directorio temporal del worktree" >&2; exit 1; }

git -C "$MEFISTO_REPO_ROOT" worktree add -b "$DOC_BRANCH" "$WORKTREE_DIR" "origin/$DEFAULT_BRANCH" \
    || { echo "ERROR: 'git worktree add' fallo para la rama '$DOC_BRANCH'" >&2; exit 1; }
WORKTREE_REGISTERED=1

# --- Escribir y validar exclusivamente la field note (CA-2) -----------------
FIELD_NOTE_ABS="$WORKTREE_DIR/$FIELD_NOTE_REL"
mkdir -p "$(dirname "$FIELD_NOTE_ABS")"
printf '%s\n' "$FIELD_NOTE_CONTENT" > "$FIELD_NOTE_ABS"

git -C "$WORKTREE_DIR" add -- "$FIELD_NOTE_REL" \
    || { echo "ERROR: 'git add' del worktree documental fallo" >&2; exit 1; }

WORKTREE_STATUS="$(git -C "$WORKTREE_DIR" status --porcelain=v1 --untracked-files=all)"
# `-x` (linea completa, no subcadena): sin el, cualquier entrada de status que
# CONTENGA el path esperado -- un rename hacia el, un path mas largo con el
# mismo prefijo -- se filtraria como si fuera la field note.
OTHER_PATHS="$(printf '%s\n' "$WORKTREE_STATUS" | grep -vxF "A  $FIELD_NOTE_REL" | grep -v '^$' || true)"
if [ -n "$OTHER_PATHS" ]; then
    echo "ERROR: el worktree documental contiene cambios fuera de '$FIELD_NOTE_REL':" >&2
    printf '%s\n' "$OTHER_PATHS" >&2
    exit 1
fi

# --- Commit, push y PR (CA-3) ------------------------------------------------
git -C "$WORKTREE_DIR" commit -m "docs(bitacora): agregar field note de $AGENT" \
    || { echo "ERROR: 'git commit' del worktree documental fallo" >&2; exit 1; }
COMMIT_SHA="$(git -C "$WORKTREE_DIR" rev-parse HEAD)"

git -C "$WORKTREE_DIR" push -u origin "$DOC_BRANCH" \
    || { echo "ERROR: 'git push' de la rama '$DOC_BRANCH' fallo; el commit $COMMIT_SHA sigue disponible localmente para reintentar" >&2; exit 1; }

# find_open_pr_for_branch (_mefisto-common.sh) trata una lista vacia o un
# "null" de `gh pr list` como ausencia real de PR -- exactamente el defecto
# que este issue corrige (el `@tsv` original emitia tabuladores para el
# elemento nulo, y `[ -n "$PR_DATA" ]` los tomaba como PR existente).
EXISTING_PR_URL="$(find_open_pr_for_branch "$DOC_BRANCH" "$MEFISTO_REPO_SLUG" "$DEFAULT_BRANCH")"
if [ -n "$EXISTING_PR_URL" ]; then
    PR_URL="$EXISTING_PR_URL"
    echo "PR ya existente reutilizado (no se llamo a 'gh pr create')"
else
    # Sin `2>&1` por la misma razon que arriba, y aqui es aun mas visible:
    # `gh pr create` escribe su progreso ("Creating pull request for <head>
    # into <base> in <repo>") en stderr y SOLO la URL en stdout. Fusionarlos
    # dejaria PR_URL multilinea -- una "URL" que ni el reporte final ni quien
    # consuma este script (issue #1298) podrian usar.
    PR_URL="$(gh pr create --repo "$MEFISTO_REPO_SLUG" --base "$DEFAULT_BRANCH" --head "$DOC_BRANCH" \
        --title "docs(bitacora): field note de $AGENT ${TIMESTAMP}" \
        --body "Entrega aislada de la field note de la sesion $AGENT ${SESSION_ID}.")" \
        || { echo "ERROR: 'gh pr create' fallo; la rama '$DOC_BRANCH' ya esta empujada, el PR queda pendiente" >&2; exit 1; }
fi

echo "Field note: $FIELD_NOTE_REL"
echo "Rama: $DOC_BRANCH"
echo "Commit: $COMMIT_SHA"
echo "PR: $PR_URL"
