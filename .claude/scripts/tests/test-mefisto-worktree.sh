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

echo "[#2336] clean recorre todos los worktrees del repo"
# Worktree antiguo al lado del repo, mergeado por squash con la rama remota borrada -> se elimina
git -C "$TMP/repo" fetch -q origin main
git -C "$TMP/repo" worktree add -q -b legacy-e "$TMP/worktree-legacy-e" origin/main 2>/dev/null
echo e > "$TMP/worktree-legacy-e/e.txt" && git -C "$TMP/worktree-legacy-e" add e.txt && git -C "$TMP/worktree-legacy-e" commit -q -m e
git -C "$TMP/worktree-legacy-e" push -q -u origin legacy-e 2>/dev/null
git -C "$TMP/origin.git" branch -q -D legacy-e
# Antiguo al lado del repo con trabajo sin mergear (sin push) -> se conserva
git -C "$TMP/repo" worktree add -q -b legacy-f "$TMP/worktree-legacy-f" origin/main 2>/dev/null
echo f > "$TMP/worktree-legacy-f/f.txt" && git -C "$TMP/worktree-legacy-f" add f.txt && git -C "$TMP/worktree-legacy-f" commit -q -m f
# Raiz de batch de un proceso muerto -> se elimina; la de un proceso vivo -> se conserva
sleep 60 & LIVE_PID=$!
( exit 0 ) & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null
mkdir -p "$TMP/repo/.mefisto/worktrees"
DEAD_ROOT="$TMP/repo/.mefisto/worktrees/mefisto-batch-execution-20260101-000000-$DEAD_PID"
LIVE_ROOT="$TMP/repo/.mefisto/worktrees/mefisto-batch-execution-20260101-000001-$LIVE_PID"
git -C "$TMP/repo" worktree add -q --detach "$DEAD_ROOT" origin/main 2>/dev/null
git -C "$TMP/repo" worktree add -q --detach "$LIVE_ROOT" origin/main 2>/dev/null

"$HELPER" clean >/dev/null 2>&1
[ -d "$TMP/worktree-legacy-e" ] && ko "worktree antiguo mergeado debia eliminarse" || ok "worktree antiguo al lado del repo, mergeado, eliminado"
[ -d "$TMP/worktree-legacy-f" ] && ok "worktree antiguo sin mergear conservado" || ko "worktree antiguo sin mergear debia conservarse"
[ -d "$DEAD_ROOT" ] && ko "raiz de batch sin proceso vivo debia eliminarse" || ok "raiz de batch sin proceso vivo eliminada"
[ -d "$LIVE_ROOT" ] && ok "raiz de batch con proceso vivo conservada" || ko "raiz de batch con proceso vivo debia conservarse"
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null
check "checkout principal intacto tras el segundo clean" "$BR0" "$(git symbolic-ref --short HEAD)"

echo "[#2338] ramas de pipeline sin trabajo segun el estado del issue"
# gh simulado: el issue 901 esta cerrado y el 902 abierto
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  *"issue view 901"*) echo CLOSED ;;
  *"issue view 902"*) echo OPEN ;;
  *) exit 1 ;;
esac
GH
chmod +x "$TMP/bin/gh"
git -C "$TMP/repo" fetch -q origin main
git -C "$TMP/repo" worktree add -q -b worktree-mefisto-issue-901-cerrado "$TMP/worktree-mefisto-issue-901-cerrado" origin/main 2>/dev/null
git -C "$TMP/repo" worktree add -q -b worktree-mefisto-issue-902-abierto "$TMP/worktree-mefisto-issue-902-abierto" origin/main 2>/dev/null
PG="$("$HELPER" new feat-g 2>/dev/null)"
PATH="$TMP/bin:$PATH" "$HELPER" clean >/dev/null 2>&1
[ -d "$TMP/worktree-mefisto-issue-901-cerrado" ] && ko "rama de pipeline sin trabajo e issue cerrado debia eliminarse" || ok "rama de pipeline sin trabajo e issue cerrado eliminada"
git show-ref --verify --quiet refs/heads/worktree-mefisto-issue-901-cerrado && ko "la rama del 901 debia borrarse" || ok "rama del 901 borrada"
[ -d "$TMP/worktree-mefisto-issue-902-abierto" ] && ok "rama de pipeline con issue abierto conservada" || ko "rama de pipeline con issue abierto debia conservarse"
[ -d "$PG" ] && ok "sesion directa recien creada conservada" || ko "sesion directa recien creada debia conservarse"
# Sin gh disponible: la del 902 tampoco se toca (y no hay error)
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
exit 1
GH
PATH="$TMP/bin:$PATH" "$HELPER" clean >/dev/null 2>&1
[ -d "$TMP/worktree-mefisto-issue-902-abierto" ] && ok "con gh fallando se conserva" || ko "con gh fallando debia conservarse"

echo "Resultado: $PASS OK, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
