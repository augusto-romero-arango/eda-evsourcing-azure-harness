#!/usr/bin/env bash
# mefisto-worktree.sh -- Worktree propio para sesiones de trabajo directo (issue #2108)
#
# Implementacion CANONICA (MEF-ADR-0049 decision 2). Ninguna sesion de trabajo
# directo edita ni commitea en el checkout principal: cada una trabaja en un
# worktree bajo .mefisto/worktrees/<slug> (dentro del repo, ignorado por Git),
# asi el HEAD compartido nunca se mueve. Bash + git puros: vale para cualquier
# runtime (MEF-ADR-0050).
#
# Uso:
#   mefisto-worktree.sh new <slug>   crea (o reutiliza) el worktree desde
#                                    origin/main e imprime su ruta absoluta
#   mefisto-worktree.sh clean        elimina los worktrees cuya rama ya esta en
#                                    origin/main y con status limpio
#
# Exit code: 0 en exito, 1 en cualquier fallo.

set -uo pipefail

usage() {
    cat >&2 <<'EOF'
Uso: mefisto-worktree.sh new <slug>
     mefisto-worktree.sh clean
EOF
}

command -v git >/dev/null 2>&1 || { echo "ERROR: 'git' no esta disponible en PATH" >&2; exit 1; }

COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || { echo "ERROR: no se esta dentro de un repositorio git" >&2; exit 1; }
MAIN_ROOT="$(dirname "$COMMON_DIR")"
WT_BASE="$MAIN_ROOT/.mefisto/worktrees"
BASE_BRANCH="main"

cmd_new() {
    local slug="${1:-}"
    if [ -z "$slug" ]; then
        echo "ERROR: 'new' requiere un <slug>" >&2; usage; return 1
    fi
    case "$slug" in
        -*) echo "ERROR: slug '$slug' no puede empezar con '-'" >&2; return 1 ;;
    esac
    if [[ "$slug" =~ [^A-Za-z0-9_-] ]]; then
        echo "ERROR: slug '$slug' es invalido: solo se permiten letras, digitos, '-' y '_'" >&2
        return 1
    fi

    local wt="$WT_BASE/$slug"

    if git -C "$MAIN_ROOT" worktree list --porcelain | grep -qxF "worktree $wt" && [ -d "$wt" ]; then
        echo "$wt"
        return 0
    fi

    git -C "$MAIN_ROOT" fetch origin "$BASE_BRANCH" >&2 \
        || { echo "ERROR: 'git fetch origin $BASE_BRANCH' fallo; verifica la red y las credenciales" >&2; return 1; }

    git -C "$MAIN_ROOT" worktree prune >/dev/null 2>&1 || true
    mkdir -p "$WT_BASE" || { echo "ERROR: no se pudo crear '$WT_BASE'" >&2; return 1; }

    if git -C "$MAIN_ROOT" show-ref --verify --quiet "refs/heads/$slug"; then
        git -C "$MAIN_ROOT" worktree add "$wt" "$slug" >&2 \
            || { echo "ERROR: la rama '$slug' existe pero 'git worktree add' fallo (puede estar checkouteada en otro worktree)" >&2; return 1; }
    else
        git -C "$MAIN_ROOT" worktree add --no-track -b "$slug" "$wt" "origin/$BASE_BRANCH" >&2 \
            || { echo "ERROR: 'git worktree add' fallo; revisa que 'origin/$BASE_BRANCH' exista" >&2; return 1; }
    fi
    echo "$wt"
}

# Una rama cuenta como mergeada si su punta esta en origin/main habiendo tenido
# commits propios (una rama recien creada, sin trabajo, tambien es ancestro de
# origin/main y no debe borrarse), o si su upstream desaparecio del remoto
# (rama borrada al mergear, p. ej. squash).
branch_is_merged() {
    local branch="$1" n track
    n="$(git -C "$MAIN_ROOT" reflog show "refs/heads/$branch" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${n:-0}" -gt 1 ] && git -C "$MAIN_ROOT" merge-base --is-ancestor "refs/heads/$branch" "origin/$BASE_BRANCH" 2>/dev/null; then
        return 0
    fi
    track="$(git -C "$MAIN_ROOT" for-each-ref --format='%(upstream:track)' "refs/heads/$branch")"
    [ "$track" = "[gone]" ]
}

cmd_clean() {
    [ -d "$WT_BASE" ] || { echo "Sin worktrees en '$WT_BASE'"; return 0; }

    # Sin refspec: con 'origin main', --prune solo poda origin/main y una rama
    # mergeada por squash nunca quedaria con upstream [gone].
    git -C "$MAIN_ROOT" fetch --prune origin >&2 \
        || { echo "ERROR: 'git fetch --prune origin' fallo; verifica la red y las credenciales" >&2; return 1; }
    git -C "$MAIN_ROOT" worktree prune >/dev/null 2>&1 || true

    local dir branch status removed=0 kept=0
    for dir in "$WT_BASE"/*/; do
        [ -d "$dir" ] || continue
        dir="${dir%/}"
        branch="$(git -C "$dir" symbolic-ref -q --short HEAD 2>/dev/null || true)"
        if [ -z "$branch" ]; then
            echo "AVISO: '$dir' sin rama (HEAD desacoplado); se conserva" >&2
            kept=$((kept + 1)); continue
        fi
        if ! branch_is_merged "$branch"; then
            echo "Conservado (rama '$branch' aun no mergeada en origin/$BASE_BRANCH): $dir"
            kept=$((kept + 1)); continue
        fi
        status="$(git -C "$dir" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)"
        if [ -n "$status" ]; then
            echo "AVISO: '$dir' (rama '$branch' mergeada) tiene cambios sin commitear; se conserva:" >&2
            printf '%s\n' "$status" >&2
            kept=$((kept + 1)); continue
        fi
        git -C "$MAIN_ROOT" worktree remove "$dir" >/dev/null 2>&1 \
            || { echo "AVISO: no se pudo eliminar el worktree '$dir'; se conserva" >&2; kept=$((kept + 1)); continue; }
        git -C "$MAIN_ROOT" branch -D "$branch" >/dev/null 2>&1 || true
        echo "Eliminado: $dir (rama '$branch')"
        removed=$((removed + 1))
    done
    echo "Limpieza: $removed eliminados, $kept conservados"
}

case "${1:-}" in
    new) shift; cmd_new "$@" ;;
    clean) cmd_clean ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
esac
