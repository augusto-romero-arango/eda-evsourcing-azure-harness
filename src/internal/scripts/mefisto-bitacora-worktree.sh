#!/usr/bin/env bash
# mefisto-bitacora-worktree.sh -- Aisla en un worktree la integracion de la
# bitacora interna (issue #2105).
#
# Implementacion CANONICA (MEF-ADR-0049 decision 2). El historiador interno
# antes cambiaba la rama del checkout compartido (git switch -c) y commiteaba
# desde ahi; otra sesion que compartia ese checkout podia terminar commiteando
# y empujando sobre una rama que no era la suya. Este script mueve toda la
# mutacion a un worktree propio bajo .mefisto/pipeline/summaries/ (misma
# estructura que mefisto-field-note.sh): el checkout principal nunca cambia de
# rama, de HEAD ni de status.
#
# Uso:
#   mefisto-bitacora-worktree.sh prepare --fecha <YYYY-MM-DD>
#       Crea o reutiliza el worktree de la rama docs/bitacora-hasta-<fecha>
#       desde origin/main e imprime su ruta absoluta (unica linea de stdout).
#   mefisto-bitacora-worktree.sh deliver --worktree <ruta>
#       Valida que solo cambian rutas bajo docs/bitacora/, commitea, empuja,
#       crea o reutiliza el PR contra main, imprime "PR #<n>" y elimina el
#       worktree solo si quedo limpio. Reintentar es idempotente.
#
# Exit code: 0 en exito, 1 en cualquier fallo (el mensaje indica la accion de
# recuperacion).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_BRANCH="main"
ALLOWED_PREFIX="docs/bitacora/"

usage() {
    cat >&2 <<'EOF'
Uso:
  mefisto-bitacora-worktree.sh prepare --fecha <YYYY-MM-DD>
  mefisto-bitacora-worktree.sh deliver --worktree <ruta>
EOF
}

SUBCMD="${1:-}"
[ $# -ge 1 ] && shift
FECHA=""
WORKTREE_ARG=""

case "$SUBCMD" in
    prepare|deliver) ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: subcomando '$SUBCMD' desconocido (prepare|deliver)" >&2; usage; exit 1 ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --fecha)
            [ $# -ge 2 ] || { echo "ERROR: --fecha requiere un valor" >&2; exit 1; }
            FECHA="$2"; shift 2 ;;
        --worktree)
            [ $# -ge 2 ] || { echo "ERROR: --worktree requiere un valor" >&2; exit 1; }
            WORKTREE_ARG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: argumento desconocido '$1'" >&2; usage; exit 1 ;;
    esac
done

if [ "$SUBCMD" = "prepare" ]; then
    if ! [[ "$FECHA" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "ERROR: --fecha es obligatoria y debe tener el formato YYYY-MM-DD" >&2
        exit 1
    fi
else
    [ -n "$WORKTREE_ARG" ] || { echo "ERROR: --worktree es obligatorio" >&2; exit 1; }
fi

for dep in git gh jq; do
    command -v "$dep" >/dev/null 2>&1 || { echo "ERROR: '$dep' no esta disponible en PATH" >&2; exit 1; }
done

source "$SCRIPT_DIR/lib/_mefisto-common.sh"
assert_in_mefisto || exit 1

SUMMARIES_DIR="$MEFISTO_REPO_ROOT/.mefisto/pipeline/summaries"

find_worktree_path_for_branch() {
    local branch="$1"
    git -C "$MEFISTO_REPO_ROOT" worktree list --porcelain | awk -v want="refs/heads/$branch" '
        /^worktree / { wt = substr($0, 10) }
        /^branch / { if ($2 == want) { print wt; exit } }
    '
}

# --- prepare ----------------------------------------------------------------
do_prepare() {
    local branch="docs/bitacora-hasta-${FECHA}"
    local wt_dir="$SUMMARIES_DIR/bitacora-${FECHA}"
    local current_ref existing

    git -C "$MEFISTO_REPO_ROOT" fetch origin "$BASE_BRANCH" >&2 \
        || { echo "ERROR: 'git fetch origin $BASE_BRANCH' fallo; verifica red y credenciales y reintenta 'prepare --fecha $FECHA'." >&2; return 1; }

    current_ref="$(git -C "$MEFISTO_REPO_ROOT" symbolic-ref -q --short HEAD || true)"
    if [ "$current_ref" = "$branch" ]; then
        echo "ERROR: la rama '$branch' esta checkouteada en el checkout principal; muevelo a su rama de trabajo habitual y reintenta." >&2
        return 1
    fi

    existing="$(find_worktree_path_for_branch "$branch")"
    if [ -n "$existing" ] && [ ! -d "$existing" ]; then
        git -C "$MEFISTO_REPO_ROOT" worktree prune >&2 || true
        existing=""
    fi
    if [ -n "$existing" ]; then
        echo "Worktree existente reutilizado: $existing" >&2
        printf '%s\n' "$existing"
        return 0
    fi

    mkdir -p "$SUMMARIES_DIR"
    if git -C "$MEFISTO_REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$MEFISTO_REPO_ROOT" worktree add "$wt_dir" "$branch" >&2 \
            || { echo "ERROR: 'git worktree add' fallo sobre la rama local '$branch'; revisa 'git worktree list', corre 'git worktree prune' y reintenta." >&2; return 1; }
    elif git -C "$MEFISTO_REPO_ROOT" fetch origin "refs/heads/$branch:refs/remotes/origin/$branch" >/dev/null 2>&1; then
        git -C "$MEFISTO_REPO_ROOT" worktree add -b "$branch" "$wt_dir" "origin/$branch" >&2 \
            || { echo "ERROR: 'git worktree add' fallo desde origin/$branch; reintenta." >&2; return 1; }
    else
        git -C "$MEFISTO_REPO_ROOT" update-ref -d "refs/remotes/origin/$branch" >/dev/null 2>&1 || true
        git -C "$MEFISTO_REPO_ROOT" worktree add -b "$branch" "$wt_dir" "origin/$BASE_BRANCH" >&2 \
            || { echo "ERROR: 'git worktree add' fallo desde origin/$BASE_BRANCH; reintenta 'prepare --fecha $FECHA'." >&2; return 1; }
    fi
    (cd "$wt_dir" && pwd -P)
}

# --- deliver ----------------------------------------------------------------
LAST_CHECKPOINT="inicio"
recovery_abort() {
    echo "ERROR: fallo en el paso '$1' de la entrega de la bitacora" >&2
    echo "Ultimo checkpoint confirmado: $LAST_CHECKPOINT" >&2
    echo "Accion de recuperacion: $2" >&2
    exit 1
}

do_deliver() {
    local wt="$WORKTREE_ARG" branch fecha commit_sha others pr_json pr_info pr_state pr_url pr_num

    if [ ! -d "$wt" ]; then
        # Reintento tras una entrega exitosa: el worktree ya se elimino, pero
        # la ruta canonica identifica la rama; si su PR existe, se reporta.
        fecha="$(basename "$wt")"; fecha="${fecha#bitacora-}"
        if [[ "$fecha" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            branch="docs/bitacora-hasta-${fecha}"
            pr_num="$(gh pr list --head "$branch" --base "$BASE_BRANCH" --repo "$MEFISTO_REPO_SLUG" \
                --state all --json number,state,createdAt 2>/dev/null \
                | jq -r '[.[] | select(.state != "CLOSED")] | sort_by(.createdAt // "", .number) | last | .number // empty' 2>/dev/null)"
            if [ -n "$pr_num" ]; then
                echo "El worktree '$wt' ya no existe; la rama '$branch' ya fue entregada." >&2
                echo "PR #${pr_num}"
                return 0
            fi
        fi
        echo "ERROR: el worktree '$wt' no existe; corre 'prepare' de nuevo." >&2
        return 1
    fi
    wt="$(cd "$wt" && pwd -P)"
    if [ "$wt" = "$(cd "$MEFISTO_REPO_ROOT" && pwd -P)" ]; then
        echo "ERROR: --worktree apunta al checkout principal; la entrega solo opera en un worktree aislado." >&2
        return 1
    fi
    branch="$(git -C "$wt" symbolic-ref -q --short HEAD || true)"
    case "$branch" in
        docs/bitacora-hasta-*) ;;
        *) echo "ERROR: la rama del worktree ('$branch') no es docs/bitacora-hasta-<fecha>." >&2; return 1 ;;
    esac
    fecha="${branch#docs/bitacora-hasta-}"

    # Validar scope: cualquier ruta cambiada (staged, unstaged, untracked)
    # debe vivir bajo docs/bitacora/.
    others="$( {
        git -C "$wt" diff --cached --name-only --no-renames
        git -C "$wt" diff --name-only --no-renames
        git -C "$wt" ls-files -o --exclude-standard
    } | sort -u | grep -v '^$' | grep -v "^${ALLOWED_PREFIX}" || true)"
    if [ -n "$others" ]; then
        echo "ERROR: el worktree contiene cambios fuera de '$ALLOWED_PREFIX':" >&2
        printf '%s\n' "$others" >&2
        return 1
    fi

    git -C "$wt" add -A -- "$ALLOWED_PREFIX" \
        || recovery_abort "commit" "'git add' fallo en '$wt'; revisa 'git -C $wt status' y reintenta."

    if ! git -C "$wt" diff --cached --quiet; then
        git -C "$wt" commit -q -m "docs(bitacora): entradas hasta el ${fecha}" \
            || recovery_abort "commit" "'git commit' fallo en '$wt'; los cambios siguen staged; revisa 'git -C $wt status' y reintenta."
    elif git -C "$wt" merge-base --is-ancestor HEAD "origin/$BASE_BRANCH" 2>/dev/null; then
        echo "ERROR: no hay cambios que entregar en '$wt' (HEAD ya esta en origin/$BASE_BRANCH)." >&2
        return 1
    else
        echo "Commit existente reutilizado (sin cambios nuevos)" >&2
    fi
    commit_sha="$(git -C "$wt" rev-parse HEAD)"
    LAST_CHECKPOINT="commit"

    git -C "$MEFISTO_REPO_ROOT" fetch origin "refs/heads/$branch:refs/remotes/origin/$branch" >/dev/null 2>&1 \
        || git -C "$MEFISTO_REPO_ROOT" update-ref -d "refs/remotes/origin/$branch" >/dev/null 2>&1 || true
    git -C "$wt" push -q --force-with-lease -u origin "$branch" >&2 \
        || recovery_abort "push" "'git push' de '$branch' fallo; el commit $commit_sha sigue en '$wt'. Revisa red/permisos y reintenta 'deliver --worktree $wt'."
    LAST_CHECKPOINT="push"

    pr_json="$(gh pr list --head "$branch" --base "$BASE_BRANCH" --repo "$MEFISTO_REPO_SLUG" \
        --state all --json number,url,state,mergedAt,createdAt)" \
        || recovery_abort "consulta-pr" "'gh pr list' fallo; revisa 'gh auth status' y reintenta."
    pr_info="$(printf '%s' "$pr_json" | jq -c 'if length > 0 then sort_by(.createdAt // "", .number) | last else empty end' 2>/dev/null)"

    if [ -n "$pr_info" ]; then
        pr_state="$(printf '%s' "$pr_info" | jq -r '.state')"
        pr_url="$(printf '%s' "$pr_info" | jq -r '.url')"
        pr_num="$(printf '%s' "$pr_info" | jq -r '.number')"
        if [ "$pr_state" = "CLOSED" ]; then
            gh pr reopen --repo "$MEFISTO_REPO_SLUG" "$pr_url" >&2 \
                || recovery_abort "reapertura-pr" "El PR $pr_url esta cerrado sin merge y 'gh pr reopen' fallo; reabrelo a mano y reintenta."
        fi
        echo "PR existente reutilizado: $pr_url" >&2
    else
        pr_url="$(gh pr create --repo "$MEFISTO_REPO_SLUG" --base "$BASE_BRANCH" --head "$branch" \
            --title "docs(bitacora): entradas hasta el ${fecha}" \
            --body "Pone al dia la bitacora del harness (entrega aislada en worktree, hasta el ${fecha}).")" \
            || recovery_abort "creacion-pr" "'gh pr create' fallo; la rama '$branch' ya esta empujada. Reintenta 'deliver --worktree $wt'."
        pr_num="${pr_url##*/}"
    fi
    LAST_CHECKPOINT="pr"

    if [ -z "$(git -C "$wt" status --porcelain=v1 --untracked-files=all)" ]; then
        git -C "$MEFISTO_REPO_ROOT" worktree remove "$wt" >/dev/null 2>&1 || true
    else
        echo "AVISO: el worktree '$wt' conserva cambios sin commitear; no se elimina." >&2
    fi

    echo "PR #${pr_num}"
}

case "$SUBCMD" in
    prepare) do_prepare; exit $? ;;
    deliver) do_deliver; exit $? ;;
esac
