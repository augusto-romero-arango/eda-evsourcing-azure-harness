#!/usr/bin/env bash
# test-worktree-clean.sh -- Tests de scripts/worktree-clean.sh (issue #2342).
# Repo temporal con remoto local y gh simulado en PATH.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CLEAN="$SCRIPT_DIR/../worktree-clean.sh"
PASS=0; FAIL=0
ok()  { echo "  OK   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git init -q --bare -b main "$TMP/remote.git"
git init -q -b main "$TMP/repo"
R="$TMP/repo"
git -C "$R" remote add origin "$TMP/remote.git"
git -C "$R" commit -q --allow-empty -m init
git -C "$R" push -q origin main

# gh simulado: issue 100 cerrado, el resto abierto
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$3" = "100" ]; then echo CLOSED; else echo OPEN; fi
EOF
chmod +x "$TMP/bin/gh"

mkwt() { git -C "$R" worktree add -q --no-track -b "$1" "$TMP/wt-$1" origin/main; }
commit_in() { echo x >"$TMP/wt-$1/f-$1"; git -C "$TMP/wt-$1" add .; git -C "$TMP/wt-$1" commit -q -m "c $1"; }

# 1) mergeada y limpia (fast-forward en origin/main)
mkwt merged; commit_in merged
git -C "$TMP/wt-merged" push -q origin HEAD:main
# 2) [gone]
mkwt gone; commit_in gone
git -C "$TMP/wt-gone" push -q -u origin gone
git -C "$TMP/wt-gone" push -q origin --delete gone
# 3) pipeline abandonada (issue 100 cerrado) y 4) en vuelo (issue 200 abierto)
mkwt worktree-issue-100-abandonada
mkwt worktree-issue-200-enuelo
# 5) mergeada pero con cambios sin commitear
mkwt dirty; commit_in dirty
git -C "$TMP/wt-dirty" push -q origin HEAD:main
echo y >"$TMP/wt-dirty/untracked"
# 6) sin mergear
mkwt unmerged; commit_in unmerged
# 7) recien creada sin commits
mkwt fresh
# 8) desacoplada
git -C "$R" worktree add -q --detach "$TMP/wt-detached" origin/main

OUT="$(cd "$R" && PATH="$TMP/bin:$PATH" "$CLEAN" 2>&1)"; RC=$?
echo "$OUT" | sed 's/^/    | /'

[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC"
gone_wt() { [ ! -d "$TMP/wt-$1" ] && ! git -C "$R" show-ref --verify --quiet "refs/heads/$1"; }
kept_wt() { [ -d "$TMP/wt-$1" ] && git -C "$R" show-ref --verify --quiet "refs/heads/$1"; }

gone_wt merged && ok "mergeada y limpia: eliminada" || bad "mergeada y limpia"
gone_wt gone && ok "[gone]: eliminada" || bad "[gone]"
gone_wt worktree-issue-100-abandonada && ok "pipeline abandonada: eliminada" || bad "pipeline abandonada"
kept_wt worktree-issue-200-enuelo && ok "pipeline en vuelo (issue abierto): conservada" || bad "pipeline en vuelo"
kept_wt dirty && ok "con cambios: conservada" || bad "con cambios"
kept_wt unmerged && ok "sin mergear: conservada" || bad "sin mergear"
kept_wt fresh && ok "recien creada sin commits: conservada" || bad "recien creada"
[ -d "$TMP/wt-detached" ] && ok "desacoplada: conservada" || bad "desacoplada"
echo "$OUT" | grep -qxF "Limpieza: 3 eliminados, 5 conservados" && ok "resumen final" || bad "resumen final"

# Sin gh: la pipeline abandonada se conserva
mkwt worktree-issue-100-sin-gh
OUT2="$(cd "$R" && PATH="/usr/bin:/bin" "$CLEAN" 2>&1)"
if command -v gh >/dev/null 2>&1 && [ "$(PATH=/usr/bin:/bin command -v gh || true)" != "" ]; then
    echo "  SKIP sin gh (gh en /usr/bin)"
else
    kept_wt worktree-issue-100-sin-gh && ok "sin gh: conservada" || bad "sin gh"
fi

echo "Resultado: $PASS ok, $FAIL fallos"
[ "$FAIL" -eq 0 ]
