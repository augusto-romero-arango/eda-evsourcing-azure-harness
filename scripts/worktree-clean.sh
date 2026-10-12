#!/usr/bin/env bash
# worktree-clean.sh — Limpia los worktrees mergeados o abandonados del repo del consumidor
#
# Uso:
#   ./scripts/worktree-clean.sh
#
# Recorre `git worktree list --porcelain` (menos el principal) y elimina el worktree
# y su rama local cuando:
#   - la rama esta mergeada en origin/main habiendo tenido commits propios, o
#   - su upstream esta [gone], o
#   - es una rama de pipeline (worktree-issue-N-, infra-issue-N-, scaffold-issue-N-)
#     sin commits fuera de origin/main y con el issue #N cerrado (sin gh, se conserva).
# Conserva, con aviso: cambios sin commitear, rama no mergeada y HEAD desacoplado.
# Solo usa `git worktree remove` y `git branch -D`; nunca mata procesos.
#
# Compatible con bash 3.2+ (macOS nativo)

set -uo pipefail

BASE_BRANCH="${BASE_BRANCH:-main}"

COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)" \
    || { echo "ERROR: no estas dentro de un repositorio git" >&2; exit 1; }
COMMON_DIR="$(cd "$COMMON_DIR" && pwd -P)"
MAIN_ROOT="$(dirname "$COMMON_DIR")"

# Rama mergeada: punta en origin/main habiendo tenido commits propios (una rama
# recien creada tambien es ancestro y no debe borrarse), upstream [gone] o rama
# de pipeline abandonada.
branch_is_merged() {
    local branch="$1" n track
    n="$(git -C "$MAIN_ROOT" reflog show "refs/heads/$branch" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${n:-0}" -gt 1 ] && git -C "$MAIN_ROOT" merge-base --is-ancestor "refs/heads/$branch" "origin/$BASE_BRANCH" 2>/dev/null; then
        return 0
    fi
    track="$(git -C "$MAIN_ROOT" for-each-ref --format='%(upstream:track)' "refs/heads/$branch")"
    [ "$track" = "[gone]" ] && return 0
    pipeline_branch_abandoned "$branch"
}

# Rama de pipeline sin commits propios y con el issue #N cerrado. Sin gh, o si gh
# falla, se conserva.
pipeline_branch_abandoned() {
    local branch="$1" issue state
    [[ "$branch" =~ ^(worktree|infra|scaffold)-issue-([0-9]+)- ]] || return 1
    issue="${BASH_REMATCH[2]}"
    [ "$(git -C "$MAIN_ROOT" rev-list --count "origin/$BASE_BRANCH..refs/heads/$branch" 2>/dev/null)" = "0" ] || return 1
    command -v gh >/dev/null 2>&1 || return 1
    state="$(cd "$MAIN_ROOT" && gh issue view "$issue" --json state -q .state 2>/dev/null)" || return 1
    [ "$state" = "CLOSED" ]
}

# Sin refspec: con 'origin main', --prune solo poda origin/main y una rama
# mergeada por squash nunca quedaria con upstream [gone].
git -C "$MAIN_ROOT" fetch --prune origin >&2 \
    || { echo "ERROR: 'git fetch --prune origin' fallo; verifica la red y las credenciales" >&2; exit 1; }
git -C "$MAIN_ROOT" worktree prune >/dev/null 2>&1 || true

dirs=()
while IFS= read -r line; do
    case "$line" in "worktree "*) dirs+=("${line#worktree }") ;; esac
done < <(git -C "$MAIN_ROOT" worktree list --porcelain)

removed=0
kept=0
for dir in "${dirs[@]}"; do
    [ "$dir" = "$MAIN_ROOT" ] && continue
    [ -d "$dir" ] || continue
    branch="$(git -C "$dir" symbolic-ref -q --short HEAD 2>/dev/null || true)"
    if [ -z "$branch" ]; then
        echo "AVISO: '$dir' sin rama (HEAD desacoplado); se conserva" >&2
        kept=$((kept + 1)); continue
    fi
    if ! branch_is_merged "$branch"; then
        echo "Conservado (rama '$branch' aun no mergeada en origin/$BASE_BRANCH): $dir"
        kept=$((kept + 1)); continue
    fi
    status="$(git -C "$dir" status --porcelain --untracked-files=all 2>/dev/null || true)"
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
