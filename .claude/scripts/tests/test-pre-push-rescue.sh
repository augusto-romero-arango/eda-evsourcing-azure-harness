#!/usr/bin/env bash
# test-pre-push-rescue.sh -- Hook pre-push de rescate y ensure_githooks_installed (issue #2110).
# Casos: [A] rescate OK, [B] otra rama pasa, [C] falla push de rescate,
# [D] falla gh, [E] ensure_githooks_installed (vacio, propio, ajeno).
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="$ROOT/src/internal/githooks/pre-push"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  OK   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
[ "${GH_FAIL:-0}" = 1 ] && { echo "gh boom" >&2; exit 1; }
echo "https://github.com/o/r/pull/77"
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log"

setup() {
    rm -rf "$TMP/remote.git" "$TMP/work"
    git init -q --bare "$TMP/remote.git"
    git init -q -b main "$TMP/work"
    cd "$TMP/work" || exit 1
    git config user.email t@t; git config user.name t
    git remote add origin "$TMP/remote.git"
    echo 1 > a; git add a; git commit -qm "base"
    git push -q origin main
    echo 2 > a; git commit -qam "cambio directo"
    git config core.hooksPath "$ROOT/src/internal/githooks"
    : > "$GH_LOG"
}

echo "[A] rescate exitoso"
setup
out="$(git push origin main 2>&1)"; rc=$?
check "push rechazado" "[ $rc -ne 0 ]"
check "mensaje PR #77" "printf '%s' \"\$out\" | grep -q 'entregado como PR #77'"
check "main remoto intacto" "[ \"\$(git --git-dir=$TMP/remote.git rev-parse main)\" != \"\$(git rev-parse HEAD)\" ]"
check "rama rescate existe" "git --git-dir=$TMP/remote.git branch --list 'rescate/*' | grep -q rescate"
check "gh con titulo del commit" "grep -q 'cambio directo' $GH_LOG"
check "SHA anotado" "grep -q \"\$(git rev-parse HEAD)\" .mefisto/pipeline/rescued-main.txt"

echo "[B] push a otra rama"
setup
git push -q origin HEAD:refs/heads/feature/x 2>&1; rc=$?
check "pasa sin intervencion" "[ $rc -eq 0 ] && [ ! -s $GH_LOG ]"

echo "[C] falla push de rescate"
setup
git remote set-url origin "$TMP/remote.git"
cat > "$TMP/remote.git/hooks/pre-receive" <<'H'
#!/bin/sh
while read o n r; do case "$r" in refs/heads/rescate/*) exit 1;; esac; done
H
chmod +x "$TMP/remote.git/hooks/pre-receive"
out="$(git push origin main 2>&1)"; rc=$?
check "rechazado" "[ $rc -ne 0 ]"
check "sin PR" "[ ! -s $GH_LOG ]"
check "da comando de reintento" "printf '%s' \"\$out\" | grep -q 'Reintenta'"
rm -f "$TMP/remote.git/hooks/pre-receive"

echo "[D] falla gh"
setup
out="$(GH_FAIL=1 git push origin main 2>&1)"; rc=$?
check "rechazado" "[ $rc -ne 0 ]"
check "rama empujada" "git --git-dir=$TMP/remote.git branch --list 'rescate/*' | grep -q rescate"
check "imprime gh pr create" "printf '%s' \"\$out\" | grep -q 'gh pr create --base main --head rescate/'"

echo "[E] ensure_githooks_installed"
setup
git config --unset core.hooksPath
export MEFISTO_REPO_ROOT="$TMP/work"
source "$ROOT/src/internal/scripts/lib/_mefisto-common.sh"
w="$(ensure_githooks_installed 2>&1)"
check "vacio: configura" "[ \"\$(git config core.hooksPath)\" = src/internal/githooks ] && printf '%s' \"\$w\" | grep -q AVISO"
w="$(ensure_githooks_installed 2>&1)"
check "propio: idempotente y silencioso" "[ -z \"\$w\" ] && [ \"\$(git config core.hooksPath)\" = src/internal/githooks ]"
git config core.hooksPath /otro/lugar
w="$(ensure_githooks_installed 2>&1)"
check "ajeno: no pisa, avisa" "[ \"\$(git config core.hooksPath)\" = /otro/lugar ] && printf '%s' \"\$w\" | grep -q AVISO"

echo "Resultado: $PASS ok, $FAIL fail"
[ "$FAIL" -eq 0 ]
