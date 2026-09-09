#!/usr/bin/env bash
# test-batch-execution-snapshot.sh -- Regresion de la carrera #1075 (issue #1107).
#
# Ejecuta dos eslabones sin proveedor. Durante el primero, el stub cambia el
# checkout lanzador a otra rama que reemplaza el helper de stage; writer y
# reviewer deben seguir ejecutando v1 desde el mismo snapshot detached. El
# merge falso publica v2 en origin/main y el segundo eslabon debe usar v2.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BATCH="$REPO_ROOT/src/internal/scripts/mefisto-batch-pipeline.sh"
TMP=$(mktemp -d)
PASS=0 FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "[snapshot] writer/reviewer aislados y siguiente eslabon actualizado"

BARE="$TMP/origin.git"
ROOT="$TMP/launcher"
PUBLISHER="$TMP/publisher"
STATE="$ROOT/.mefisto/pipeline"
CALLS="$TMP/calls.log"
SHA_FILE="$TMP/merge-sha"
BIN="$TMP/bin"
git init -q --bare "$BARE"
git clone -q "$BARE" "$ROOT"
git -C "$ROOT" config user.email test@mefisto.local
git -C "$ROOT" config user.name 'Mefisto Test'
git -C "$ROOT" checkout -q -b main
mkdir -p "$ROOT/.claude-plugin" "$ROOT/src/internal/scripts/lib" "$ROOT/src/internal/scripts/stages" "$BIN"
printf '{"name":"mefisto","version":"0.0.0"}\n' > "$ROOT/.claude-plugin/plugin.json"
cp "$BATCH" "$ROOT/src/internal/scripts/mefisto-batch-pipeline.sh"
cp "$REPO_ROOT/src/internal/scripts/mefisto-validate-batch-deps.sh" "$ROOT/src/internal/scripts/mefisto-validate-batch-deps.sh"
cp "$REPO_ROOT/src/internal/scripts/lib/_mefisto-common.sh" "$ROOT/src/internal/scripts/lib/"
cp "$REPO_ROOT/src/internal/scripts/lib/mefisto-state.sh" "$ROOT/src/internal/scripts/lib/"
cp -R "$REPO_ROOT/src/runtime" "$ROOT/src/"
printf 'v1\n' > "$ROOT/marker.txt"
cat > "$ROOT/src/internal/scripts/stages/fake-stage.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s|%s|v1|%s|%s\n' "$ISSUE" "$1" "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)" "$MEFISTO_LAUNCH_ROOT" >> "$CALLS"
EOF
cat > "$ROOT/src/internal/scripts/mefisto-tooling-pipeline.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ISSUE="$1" "$SCRIPT_DIR/stages/fake-stage.sh" writer
if [ "$1" = 1 ]; then
    git -C "$MEFISTO_LAUNCH_ROOT" switch -q docs/concurrent
    printf 'modificado\n' >> "$MEFISTO_LAUNCH_ROOT/marker.txt"
    printf 'staged\n' > "$MEFISTO_LAUNCH_ROOT/staged.txt"
    git -C "$MEFISTO_LAUNCH_ROOT" add staged.txt
    printf 'untracked\n' > "$MEFISTO_LAUNCH_ROOT/untracked.txt"
fi
ISSUE="$1" "$SCRIPT_DIR/stages/fake-stage.sh" reviewer
echo "v PR creado: https://github.com/acme/mefisto/pull/$1"
EOF
chmod +x "$ROOT/src/internal/scripts/mefisto-batch-pipeline.sh"
chmod +x "$ROOT/src/internal/scripts/mefisto-validate-batch-deps.sh"
chmod +x "$ROOT/src/internal/scripts/mefisto-tooling-pipeline.sh"
chmod +x "$ROOT/src/internal/scripts/stages/fake-stage.sh"
git -C "$ROOT" add .
git -C "$ROOT" commit -q -m base
git -C "$ROOT" push -q origin main
git -C "$ROOT" switch -q -c docs/concurrent
printf 'mutable\n' > "$ROOT/marker.txt"
sed 's/|v1|/|mutable|/' "$ROOT/src/internal/scripts/stages/fake-stage.sh" > "$ROOT/.stage.new"
mv "$ROOT/.stage.new" "$ROOT/src/internal/scripts/stages/fake-stage.sh"
chmod +x "$ROOT/src/internal/scripts/stages/fake-stage.sh"
git -C "$ROOT" add marker.txt src/internal/scripts/stages/fake-stage.sh && git -C "$ROOT" commit -q -m 'checkout mutable'
git -C "$ROOT" switch -q main
git clone -q "$BARE" "$PUBLISHER"
git -C "$PUBLISHER" config user.email test@mefisto.local
git -C "$PUBLISHER" config user.name 'Mefisto Test'
git -C "$PUBLISHER" checkout -q main

cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "$1" = pr ] && [ "$2" = merge ]; then
    git -C "$PUBLISHER" pull -q --ff-only origin main
    if [ "$3" = 1 ]; then
        printf 'v2\n' > "$PUBLISHER/marker.txt"
        sed 's/|v1|/|v2|/' "$PUBLISHER/src/internal/scripts/stages/fake-stage.sh" > "$PUBLISHER/.stage.new"
        mv "$PUBLISHER/.stage.new" "$PUBLISHER/src/internal/scripts/stages/fake-stage.sh"
        chmod +x "$PUBLISHER/src/internal/scripts/stages/fake-stage.sh"
        git -C "$PUBLISHER" add marker.txt src/internal/scripts/stages/fake-stage.sh
        git -C "$PUBLISHER" commit -q -m snapshot-v2
    else
        git -C "$PUBLISHER" commit -q --allow-empty -m next-merge
    fi
    git -C "$PUBLISHER" push -q origin main
    git -C "$PUBLISHER" rev-parse HEAD > "$SHA_FILE"
    exit 0
fi
if [ "$1" = pr ] && [ "$2" = view ]; then cat "$SHA_FILE"; exit 0; fi
exit 1
EOF
chmod +x "$BIN/claude" "$BIN/gh"

(
    cd "$ROOT" || exit 99
    CALLS="$CALLS" PUBLISHER="$PUBLISHER" SHA_FILE="$SHA_FILE" \
        MEFISTO_STATE_DIR="$STATE" MEFISTO_RUNTIME=claude PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
        ./src/internal/scripts/mefisto-batch-pipeline.sh 1 2
) >"$TMP/out" 2>"$TMP/err"
RC=$?

if [ "$RC" -eq 0 ]; then pass "el batch completo sin proveedor termino en exito"; else fail "el batch termino con $RC: stdout=$(cat "$TMP/out") stderr=$(cat "$TMP/err")"; fi
if [ "$(grep -c '^1|.*|v1|' "$CALLS")" -eq 2 ] && grep -q '^1|writer|v1|' "$CALLS" && grep -q '^1|reviewer|v1|' "$CALLS"; then pass "writer y reviewer del primer eslabon usaron el mismo helper v1"; else fail "el primer eslabon cambio de maquinaria: $(cat "$CALLS")"; fi
if [ "$(grep -c '^2|.*|v2|' "$CALLS")" -eq 2 ] && grep -q '^2|writer|v2|' "$CALLS" && grep -q '^2|reviewer|v2|' "$CALLS"; then pass "el segundo eslabon completo con el helper v2 de origin/main"; else fail "el segundo eslabon no uso v2: $(cat "$CALLS")"; fi
if ! grep -q "|$ROOT|$ROOT$" "$CALLS"; then pass "ningun stage resolvio su ejecutable desde el checkout lanzador"; else fail "un stage uso el checkout lanzador: $(cat "$CALLS")"; fi
if [ "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)" = docs/concurrent ]; then pass "la mutacion concurrente de HEAD del checkout principal se preservo"; else fail "el batch modifico HEAD del checkout principal"; fi
if grep -q '^modificado$' "$ROOT/marker.txt" && ! git -C "$ROOT" diff --cached --quiet --exit-code -- staged.txt >/dev/null 2>&1 && [ -f "$ROOT/untracked.txt" ]; then pass "cambios modificados, staged y untracked del launcher sobrevivieron"; else fail "el batch descarto cambios locales del launcher"; fi
if ! git -C "$ROOT" worktree list | grep -q 'mefisto-batch-execution-'; then pass "la raiz aislada se limpio al cerrar"; else fail "quedo una raiz aislada registrada"; fi

echo "Resumen: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
