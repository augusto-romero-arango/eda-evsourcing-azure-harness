#!/usr/bin/env bash
# test-mefisto-bitacora-worktree.sh -- Tests de mefisto-bitacora-worktree.sh (issue #2105).
#
# Cubre sobre un repo temporal con remoto bare local y un 'gh' controlado:
#   [A] prepare + edicion + deliver: el checkout principal conserva rama, HEAD y status.
#   [B] deliver imprime 'PR #<n>' y elimina el worktree limpio.
#   [C] un segundo deliver (tras re-preparar, o con la misma ruta ya eliminada) no duplica commit ni PR.
#   [D] deliver rechaza cambios fuera de docs/bitacora/.
#   [F] PR mergeado: prepare desde origin/main y deliver crea PR nuevo (#2171).
#   [G] segundo deliver tras la reentrega reutiliza el PR abierto.
#   [H] PR cerrado se reabre.
#   [E] el shim reenvia al script canonico.
#
# Exit code: 0 si todo pasa, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

CANON="$REPO_ROOT/src/internal/scripts/mefisto-bitacora-worktree.sh"
SHIM="$REPO_ROOT/.claude/scripts/mefisto-bitacora-worktree.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SAFE_SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
FECHA="2026-10-08"
BRANCH="docs/bitacora-hasta-$FECHA"

echo "[E] shim"
if bash -n "$CANON" && [ -x "$CANON" ]; then pass "sintaxis valida y ejecutable"; else fail "sintaxis/permisos"; fi
if [ "$(sed -n 3p "$SHIM")" = 'exec "$(cd "$(dirname "$0")/../.." && pwd)/src/internal/scripts/$(basename "$0")" "$@"' ]; then
    pass "shim con la plantilla de exec"
else
    fail "shim fuera de plantilla"
fi

MAIN="$TMP/main-checkout"
BARE="$TMP/origin.git"
FAKEBIN="$TMP/bin"
STORE="$TMP/prs.txt"
CALLS="$TMP/gh-calls.log"
mkdir -p "$MAIN" "$FAKEBIN"
git init -q "$MAIN"
git -C "$MAIN" symbolic-ref HEAD refs/heads/main
git -C "$MAIN" config user.email "t@mefisto.local"
git -C "$MAIN" config user.name "Mefisto Test"
mkdir -p "$MAIN/.claude-plugin" "$MAIN/src/internal/scripts/lib" "$MAIN/docs/bitacora/field-notes"
echo '{"name":"mefisto","version":"0.0.0"}' > "$MAIN/.claude-plugin/plugin.json"
echo ".mefisto/" > "$MAIN/.gitignore"
cp "$REPO_ROOT/src/internal/scripts/lib/_mefisto-common.sh" "$MAIN/src/internal/scripts/lib/"
cp "$REPO_ROOT/src/internal/scripts/lib/mefisto-state.sh" "$MAIN/src/internal/scripts/lib/"
cp -R "$REPO_ROOT/src/runtime" "$MAIN/src/runtime"
cp "$CANON" "$MAIN/src/internal/scripts/"
echo "nota" > "$MAIN/docs/bitacora/field-notes/2026-10-08-1000-mefisto-planner.md"
git -C "$MAIN" add .
git -C "$MAIN" commit -q -m base
git init -q --bare "$BARE"
git -C "$MAIN" remote add origin "$BARE"
git -C "$MAIN" push -q origin main
echo "sucio" > "$MAIN/untracked.txt"

echo '[]' > "$STORE"
export GH_STORE="$STORE" GH_CALLS="$CALLS"
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$GH_CALLS"
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then echo "acme/mefisto-fake"; exit 0; fi
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then cat "$GH_STORE"; exit 0; fi
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
    echo "creating..." >&2
    n=$(jq 'length + 77' "$GH_STORE")
    jq --argjson n "$n" '. + [{number:$n,url:("https://github.com/acme/mefisto-fake/pull/"+($n|tostring)),state:"OPEN",mergedAt:null,createdAt:("2026-10-08T00:00:"+(($n|tostring)|.[0:2])+"Z")}]' "$GH_STORE" > "$GH_STORE.tmp" && mv "$GH_STORE.tmp" "$GH_STORE"
    echo "https://github.com/acme/mefisto-fake/pull/$n"
    exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "reopen" ]; then
    jq 'map(if .state == "CLOSED" then .state = "OPEN" else . end)' "$GH_STORE" > "$GH_STORE.tmp" && mv "$GH_STORE.tmp" "$GH_STORE"
    exit 0
fi
exit 1
EOF
chmod +x "$FAKEBIN/gh"

run() {
    (cd "$MAIN" && env -u MEFISTO_STATE_DIR -u MEFISTO_LEGACY_STATE_DIR -u MEFISTO_REPO_ROOT \
        -u MEFISTO_PROJECT_NAME -u MEFISTO_REPO_SLUG PATH="$FAKEBIN:$SAFE_SYSTEM_PATH" \
        ./src/internal/scripts/mefisto-bitacora-worktree.sh "$@")
}
snap() { echo "$(git -C "$MAIN" symbolic-ref -q --short HEAD)|$(git -C "$MAIN" rev-parse HEAD)|$(git -C "$MAIN" status --porcelain=v1 --untracked-files=all)"; }

BEFORE="$(snap)"

echo "[A] prepare + edicion + deliver"
WT="$(run prepare --fecha "$FECHA" 2>"$TMP/p.err")"
if [ -d "$WT" ] && [ "$(git -C "$WT" symbolic-ref --short HEAD)" = "$BRANCH" ]; then pass "prepare devuelve un worktree en $BRANCH"; else fail "prepare: '$WT' ($(cat "$TMP/p.err"))"; fi
case "$WT" in "$(cd "$MAIN" && pwd -P)"/.mefisto/pipeline/summaries/*) pass "worktree bajo .mefisto/pipeline/summaries/" ;; *) fail "ruta inesperada: $WT" ;; esac
echo "# entrada" > "$WT/docs/bitacora/$FECHA.md"
mkdir -p "$WT/docs/bitacora/field-notes/procesadas"
git -C "$WT" mv docs/bitacora/field-notes/2026-10-08-1000-mefisto-planner.md docs/bitacora/field-notes/procesadas/

OUT="$(run deliver --worktree "$WT" 2>"$TMP/d.err")"; RC=$?
[ "$RC" -eq 0 ] && pass "deliver exit 0" || fail "deliver rc=$RC: $(cat "$TMP/d.err")"
[ "$OUT" = "PR #77" ] && pass "imprime PR #77" || fail "salida: '$OUT'"
[ ! -d "$WT" ] && pass "worktree eliminado" || fail "worktree sigue"
[ "$(snap)" = "$BEFORE" ] && pass "checkout principal intacto (rama, HEAD, status)" || fail "checkout principal cambio"
git -C "$BARE" rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null && pass "rama empujada" || fail "rama no empujada"
COMMITS1="$(git -C "$BARE" rev-list --count "main..$BRANCH")"

echo "[C] segunda entrega idempotente"
WT2="$(run prepare --fecha "$FECHA" 2>/dev/null)"
OUT2="$(run deliver --worktree "$WT2" 2>"$TMP/d2.err")"; RC2=$?
[ "$RC2" -eq 0 ] && [ "$OUT2" = "PR #77" ] && pass "reutiliza PR #77" || fail "rc2=$RC2 salida 2: '$OUT2' ($(cat "$TMP/d2.err"))"
OUT2B="$(run deliver --worktree "$WT" 2>"$TMP/d2b.err")"; RC2B=$?
[ "$RC2B" -eq 0 ] && [ "$OUT2B" = "PR #77" ] && pass "deliver con la ruta ya eliminada reporta el PR" || fail "rc=$RC2B salida: '$OUT2B' ($(cat "$TMP/d2b.err"))"
[ "$(grep -c '^pr create' "$CALLS")" -eq 1 ] && pass "gh pr create una sola vez" || fail "gh pr create repetido"
[ "$(git -C "$BARE" rev-list --count "main..$BRANCH")" = "$COMMITS1" ] && pass "sin commits duplicados" || fail "commits duplicados"
[ "$(snap)" = "$BEFORE" ] && pass "checkout principal intacto tras el reintento" || fail "checkout cambio en reintento"

echo "[C2] reentrega con cambio: reutiliza el PR"
WT2="$(run prepare --fecha "$FECHA" 2>/dev/null)"
echo "# mas" >> "$WT2/docs/bitacora/$FECHA.md"
OUT3="$(run deliver --worktree "$WT2" 2>/dev/null)"
[ "$OUT3" = "PR #77" ] && pass "reutiliza PR existente" || fail "salida 3: '$OUT3'"
[ "$(grep -c '^pr create' "$CALLS")" -eq 1 ] && pass "sigue un solo pr create" || fail "pr create duplicado"

set_state() { # <numero> <estado> <mergedAt|null>
    jq --argjson n "$1" --arg s "$2" --arg m "$3" 'map(if .number == $n then .state = $s | .mergedAt = (if $m == "null" then null else $m end) else . end)' "$STORE" > "$STORE.tmp" && mv "$STORE.tmp" "$STORE"
}

echo "[F] PR mergeado: reentrega con PR nuevo y prepare desde origin/main"
set_state 77 MERGED "2026-10-08T01:00:00Z"
git -C "$MAIN" fetch -q origin main
WT4="$(run prepare --fecha "$FECHA" 2>"$TMP/p4.err")"
[ -d "$WT4" ] && [ -z "$(git -C "$WT4" log origin/main..HEAD --oneline)" ] && pass "prepare recrea la rama desde origin/main (CA-4)" || fail "prepare no recreo desde origin/main ($(cat "$TMP/p4.err"))"
echo "# reentrega" > "$WT4/docs/bitacora/$FECHA-bis.md"
OUT4="$(run deliver --worktree "$WT4" 2>"$TMP/d4.err")"; RC4=$?
[ "$RC4" -eq 0 ] && [ "$OUT4" = "PR #78" ] && pass "deliver crea PR #78 nuevo (CA-1)" || fail "rc=$RC4 salida: '$OUT4' ($(cat "$TMP/d4.err"))"
grep -q "reutilizado" "$TMP/d4.err" && fail "reutilizo el PR mergeado" || pass "no reutiliza el PR mergeado"
[ "$(grep -c '^pr create' "$CALLS")" -eq 2 ] && pass "segundo pr create" || fail "pr create != 2"
grep -q "reentrega" "$CALLS" && pass "titulo de reentrega" || fail "sin titulo de reentrega"

echo "[G] segundo deliver tras la reentrega reutiliza el PR abierto"
WT5="$(run prepare --fecha "$FECHA" 2>/dev/null)"
OUT5="$(run deliver --worktree "$WT5" 2>"$TMP/d5.err")"; RC5=$?
[ "$RC5" -eq 0 ] && [ "$OUT5" = "PR #78" ] && pass "reutiliza PR #78" || fail "rc=$RC5 salida: '$OUT5' ($(cat "$TMP/d5.err"))"
OUT5B="$(run deliver --worktree "$WT4" 2>/dev/null)"
[ "$OUT5B" = "PR #78" ] && pass "ruta eliminada reporta PR #78" || fail "salida: '$OUT5B'"
[ "$(grep -c '^pr create' "$CALLS")" -eq 2 ] && pass "sin pr create adicional" || fail "pr create adicional"

echo "[H] PR CLOSED se reabre"
set_state 78 CLOSED null
WT6="$(run prepare --fecha "$FECHA" 2>/dev/null)"
echo "# cerrado" >> "$WT6/docs/bitacora/$FECHA-bis.md"
OUT6="$(run deliver --worktree "$WT6" 2>/dev/null)"
[ "$OUT6" = "PR #78" ] && grep -q '^pr reopen' "$CALLS" && pass "reabre PR cerrado" || fail "salida: '$OUT6'"
[ "$(grep -c '^pr create' "$CALLS")" -eq 2 ] && pass "CLOSED no crea PR nuevo" || fail "pr create inesperado"

echo "[D] scope"
WT3="$(run prepare --fecha "$FECHA" 2>/dev/null)"
echo x > "$WT3/AGENTS.md"
if run deliver --worktree "$WT3" >/dev/null 2>"$TMP/s.err"; then fail "acepto cambios fuera de docs/bitacora/"; else grep -q "fuera de" "$TMP/s.err" && pass "rechaza rutas fuera de docs/bitacora/" || fail "mensaje inesperado"; fi

echo ""
echo "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
