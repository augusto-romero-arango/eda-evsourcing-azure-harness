#!/usr/bin/env bash
# test-mefisto-worktree.sh -- helper mefisto-worktree.sh con remoto local (issue #2108)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="$ROOT/src/internal/scripts/mefisto-worktree.sh"

PASS=0; FAIL=0
ok() { echo "  OK: $1"; PASS=$((PASS + 1)); }
ko() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 (esperado '$2', actual '$3')"; fi; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare -b main "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
cd "$TMP/repo" || exit 1
git checkout -q -b main 2>/dev/null || true
echo base > f.txt
git add f.txt && git commit -q -m base && git push -q -u origin main
echo ".mefisto/" > .gitignore && git add .gitignore && git commit -q -m ignore && git push -q origin main

HEAD0="$(git rev-parse HEAD)"; BR0="$(git symbolic-ref --short HEAD)"; ST0="$(git status --porcelain)"

echo "[CA-1] new"
P1="$("$HELPER" new feat-a 2>/dev/null)"
check "imprime la ruta del worktree" "$TMP/repo/.mefisto/worktrees/feat-a" "$P1"
check "rama del worktree" "feat-a" "$(git -C "$P1" symbolic-ref --short HEAD)"
check "checkout principal: HEAD" "$HEAD0" "$(git rev-parse HEAD)"
check "checkout principal: rama" "$BR0" "$(git symbolic-ref --short HEAD)"
check "checkout principal: status" "$ST0" "$(git status --porcelain)"
P1b="$("$HELPER" new feat-a 2>/dev/null)"
check "new repetido reutiliza" "$P1" "$P1b"
P1c="$(cd "$P1" && "$HELPER" new feat-a 2>/dev/null)"
check "new desde dentro del worktree reutiliza" "$P1" "$P1c"

echo "[CA-2] clean"
# feat-a: con commit, mergeada (ff) y limpia -> se elimina
echo a > "$P1/a.txt" && git -C "$P1" add a.txt && git -C "$P1" commit -q -m a
git push -q origin feat-a:main
# feat-b: sin commits propios -> se conserva
PB="$("$HELPER" new feat-b 2>/dev/null)"
# feat-c: mergeada pero con cambios sin commitear -> se conserva
PC="$("$HELPER" new feat-c 2>/dev/null)"
git -C "$PC" pull -q --rebase origin main 2>/dev/null
echo c > "$PC/c.txt" && git -C "$PC" add c.txt && git -C "$PC" commit -q -m c
git -C "$PC" push -q origin feat-c:main
echo dirty > "$PC/dirty.txt"
# feat-d: mergeada por squash y rama remota borrada (upstream [gone]) -> se elimina
PD="$("$HELPER" new feat-d 2>/dev/null)"
git -C "$PD" pull -q --rebase origin main 2>/dev/null
echo d > "$PD/d.txt" && git -C "$PD" add d.txt && git -C "$PD" commit -q -m d
git -C "$PD" push -q -u origin feat-d 2>/dev/null
git -C "$PD" fetch -q origin main && git -C "$PD" merge-base --is-ancestor HEAD origin/main && ko "feat-d no debia ser ancestro (squash)"
git -C "$TMP/origin.git" branch -q -D feat-d

"$HELPER" clean >/dev/null 2>&1
[ -d "$P1" ] && ko "feat-a mergeada y limpia debia eliminarse" || ok "feat-a eliminada"
git show-ref --verify --quiet refs/heads/feat-a && ko "rama feat-a debia borrarse" || ok "rama feat-a borrada"
[ -d "$PB" ] && ok "feat-b sin commits conservada" || ko "feat-b debia conservarse"
[ -d "$PD" ] && ko "feat-d mergeada por squash (upstream gone) debia eliminarse" || ok "feat-d (squash, upstream gone) eliminada"
[ -d "$PC" ] && ok "feat-c con cambios sin commitear conservada" || ko "feat-c debia conservarse"
check "checkout principal intacto tras clean" "$BR0" "$(git symbolic-ref --short HEAD)"

echo "Resultado: $PASS OK, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
