#!/usr/bin/env bash
# test-rescue-remediation.sh -- Tests de remediate_main_after_rescue() (issue #2112).
# Remoto local de fixture: rescate + squash en remoto -> remedia; commit local no
# rescatado -> no remedia; arbol sucio -> no remedia.
# Uso: .claude/scripts/tests/test-rescue-remediation.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
COMMON_LIB="$REPO_ROOT/src/internal/scripts/lib/_mefisto-common.sh"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# shellcheck disable=SC1090
source "$COMMON_LIB"
warn() { :; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# make_fixture <nombre>: origin bare + clon con 1 commit base
make_fixture() {
    local d="$TMP/$1"
    mkdir -p "$d"
    git init -q --bare -b main "$d/origin.git"
    git clone -q "$d/origin.git" "$d/work" 2>/dev/null
    git -C "$d/work" config user.email t@t; git -C "$d/work" config user.name t
    git -C "$d/work" checkout -q -b main 2>/dev/null || true
    echo base > "$d/work/f"; git -C "$d/work" add f; git -C "$d/work" commit -qm base
    git -C "$d/work" push -q origin main
    mkdir -p "$d/work/.git/info"; echo ".mefisto/" >> "$d/work/.git/info/exclude"
    echo "$d/work"
}

# squash en remoto: origin/main avanza con un commit distinto (equivalente al squash)
squash_remote() {
    local w="$1" o="$TMP/squash-$RANDOM"
    git clone -q "$(dirname "$w")/origin.git" "$o" 2>/dev/null
    git -C "$o" config user.email t@t; git -C "$o" config user.name t
    echo squash > "$o/g"; git -C "$o" add g; git -C "$o" commit -qm squash
    git -C "$o" push -q origin main
    git -C "$w" fetch -q origin
}

echo "[A] commits rescatados + arbol limpio -> remedia y limpia la lista"
W=$(make_fixture a)
echo r > "$W/r"; git -C "$W" add r; git -C "$W" commit -qm rescatado
SHA=$(git -C "$W" rev-parse HEAD)
OTRO=0123456789abcdef0123456789abcdef01234567
mkdir -p "$W/.mefisto/pipeline"; printf '%s\n%s\n' "$OTRO" "$SHA" > "$W/.mefisto/pipeline/rescued-main.txt"
squash_remote "$W"
if remediate_main_after_rescue "$W" main origin/main \
   && [ "$(git -C "$W" rev-parse HEAD)" = "$(git -C "$W" rev-parse origin/main)" ]; then
    pass "main quedo igual a origin/main"
else fail "no remedio"; fi
if ! grep -q "$SHA" "$W/.mefisto/pipeline/rescued-main.txt"; then pass "SHA retirado de rescued-main.txt"; else fail "SHA sigue en la lista"; fi
if grep -qx "$OTRO" "$W/.mefisto/pipeline/rescued-main.txt"; then pass "SHA ajeno conservado en rescued-main.txt"; else fail "se borro un SHA ajeno"; fi

echo "[B] commit local no rescatado -> no remedia"
W=$(make_fixture b)
echo r > "$W/r"; git -C "$W" add r; git -C "$W" commit -qm rescatado
mkdir -p "$W/.mefisto/pipeline"; git -C "$W" rev-parse HEAD > "$W/.mefisto/pipeline/rescued-main.txt"
echo x > "$W/x"; git -C "$W" add x; git -C "$W" commit -qm propio
BEFORE=$(git -C "$W" rev-parse HEAD)
squash_remote "$W"
if ! remediate_main_after_rescue "$W" main origin/main && [ "$(git -C "$W" rev-parse HEAD)" = "$BEFORE" ]; then
    pass "aborta y deja main intacto"
else fail "remedio un commit no rescatado"; fi

echo "[C] arbol sucio -> no remedia"
W=$(make_fixture c)
echo r > "$W/r"; git -C "$W" add r; git -C "$W" commit -qm rescatado
mkdir -p "$W/.mefisto/pipeline"; git -C "$W" rev-parse HEAD > "$W/.mefisto/pipeline/rescued-main.txt"
BEFORE=$(git -C "$W" rev-parse HEAD)
squash_remote "$W"
echo dirty >> "$W/f"
if ! remediate_main_after_rescue "$W" main origin/main && [ "$(git -C "$W" rev-parse HEAD)" = "$BEFORE" ]; then
    pass "aborta con arbol sucio"
else fail "remedio con arbol sucio"; fi

echo "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
