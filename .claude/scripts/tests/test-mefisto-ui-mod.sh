#!/usr/bin/env bash
# test-mefisto-ui-mod.sh -- Modo MEFISTO_UI=mod de mefisto-tmux-pipeline.sh
# (MEF-ADR-0055): --tooling y --batch corren desacoplados, sin sesion tmux ni
# pane herdr, para que los siga el mod mefisto-divine-wager de la sesion que los lanzo.
#
# Cubre:
#   [1] --tooling con MEFISTO_UI=mod no toca tmux ni herdr, aun dentro de herdr.
#   [2] el pipeline recibe el issue y los flags en orden, y escribe su reporte
#       en .mefisto/pipeline/logs/mefisto-tooling-run-*-issue-<n>.report.log.
#   [3] el pipeline corre sin HERDR_* ni MEFISTO_UI y con MEFISTO_RUNTIME.
#   [4] --batch con MEFISTO_UI=mod corre el batch desacoplado, sin tmux ni herdr,
#       con los issues en orden y su reporte mefisto-batch-run-*.report.log.
#   [5] --batch con MEFISTO_UI=mod rechaza un issue no numerico.
#
# Uso: .claude/scripts/tests/test-mefisto-ui-mod.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FAKE_MEFISTO="$TMP_DIR/fake-mefisto"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_MEFISTO/.claude-plugin" "$FAKE_MEFISTO/.claude/scripts" "$FAKE_MEFISTO/src/internal/scripts/lib" "$FAKE_BIN"

printf '{ "name": "mefisto", "version": "0.0.0" }\n' > "$FAKE_MEFISTO/.claude-plugin/plugin.json"
printf '.mefisto/\n' > "$FAKE_MEFISTO/.gitignore"
cp "$REPO_ROOT/src/internal/scripts/lib/_mefisto-common.sh" "$FAKE_MEFISTO/src/internal/scripts/lib/"
cp "$REPO_ROOT/src/internal/scripts/lib/mefisto-state.sh" "$FAKE_MEFISTO/src/internal/scripts/lib/"
cp "$REPO_ROOT/.claude/scripts/_mefisto-common.sh" "$FAKE_MEFISTO/.claude/scripts/"
cp -R "$REPO_ROOT/src/runtime" "$FAKE_MEFISTO/src/runtime"
cp "$REPO_ROOT/.claude/scripts/mefisto-tmux-pipeline.sh" "$FAKE_MEFISTO/.claude/scripts/"
cp "$REPO_ROOT/src/internal/scripts/mefisto-tmux-pipeline.sh" "$FAKE_MEFISTO/src/internal/scripts/"
cp "$REPO_ROOT/.claude/scripts/mefisto-herdr-pipeline.sh" "$FAKE_MEFISTO/.claude/scripts/"
cp "$REPO_ROOT/src/internal/scripts/mefisto-herdr-pipeline.sh" "$FAKE_MEFISTO/src/internal/scripts/"

export PIPELINE_STUB_LOG="$TMP_DIR/pipeline.log"
cat > "$FAKE_MEFISTO/src/internal/scripts/mefisto-tooling-pipeline.sh" <<'STUB'
#!/usr/bin/env bash
{
    echo "args: $*"
    echo "herdr: ${HERDR_ENV:-}${HERDR_PANE_ID:-}"
    echo "ui: ${MEFISTO_UI:-}"
    echo "runtime: ${MEFISTO_RUNTIME:-}"
} > "$PIPELINE_STUB_LOG"
echo "salida del pipeline"
STUB
chmod +x "$FAKE_MEFISTO/src/internal/scripts/mefisto-tooling-pipeline.sh"
export BATCH_STUB_LOG="$TMP_DIR/batch.log"
cat > "$FAKE_MEFISTO/src/internal/scripts/mefisto-batch-pipeline.sh" <<'STUB'
#!/usr/bin/env bash
{
    echo "args: $*"
    echo "herdr: ${HERDR_ENV:-}${HERDR_PANE_ID:-}"
    echo "ui: ${MEFISTO_UI:-}"
} > "$BATCH_STUB_LOG"
echo "salida del batch"
STUB
chmod +x "$FAKE_MEFISTO/src/internal/scripts/mefisto-batch-pipeline.sh"
(cd "$FAKE_MEFISTO" && git init -q && git add . && git -c user.email="t@e.com" -c user.name="T" commit -q -m init && git branch -M main)

export UI_STUB_LOG="$TMP_DIR/ui.log"
for bin in tmux herdr; do
    cat > "$FAKE_BIN/$bin" <<STUB
#!/usr/bin/env bash
echo "$bin \$*" >> "\$UI_STUB_LOG"
exit 0
STUB
    chmod +x "$FAKE_BIN/$bin"
done

wait_for_file() {
    local f="$1" i
    for i in $(seq 1 50); do
        [ -s "$f" ] && return 0
        sleep 0.1
    done
    return 1
}

run_wrapper() {
    : > "$UI_STUB_LOG"
    rm -f "$PIPELINE_STUB_LOG" "$BATCH_STUB_LOG"
    (
        cd "$FAKE_MEFISTO" || exit 99
        PATH="$FAKE_BIN:$PATH" MEFISTO_UI=mod MEFISTO_RUNTIME=claude HERDR_ENV=1 HERDR_PANE_ID=w1:p1 \
            "$FAKE_MEFISTO/.claude/scripts/mefisto-tmux-pipeline.sh" "$@"
    ) </dev/null >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr"
    LAST_RC=$?
}

echo "[1] --tooling con MEFISTO_UI=mod no abre tmux ni herdr"
run_wrapper --tooling 42 --from-stage 2 --models "reviewer=opus"
if [ "$LAST_RC" -eq 0 ]; then pass "el wrapper termina sin error"; else fail "rc=$LAST_RC stderr: $(cat "$TMP_DIR/stderr")"; fi
if wait_for_file "$PIPELINE_STUB_LOG"; then pass "el pipeline corrio desacoplado"; else fail "el pipeline no corrio"; fi
if [ ! -s "$UI_STUB_LOG" ]; then pass "ni tmux ni herdr fueron invocados"; else fail "se invoco UI: $(cat "$UI_STUB_LOG")"; fi

echo ""
echo "[2] el pipeline recibe issue y flags, y su salida va al reporte"
if grep -qF "args: 42 --from-stage 2 --models reviewer=opus" "$PIPELINE_STUB_LOG"; then pass "issue y flags en orden"; else fail "args: $(cat "$PIPELINE_STUB_LOG")"; fi
REPORT=$(ls "$FAKE_MEFISTO"/.mefisto/pipeline/logs/mefisto-tooling-run-*-issue-42.report.log 2>/dev/null | head -1)
if [ -n "$REPORT" ] && wait_for_file "$REPORT" && grep -q "salida del pipeline" "$REPORT"; then pass "reporte en logs/mefisto-tooling-run-*-issue-42.report.log"; else fail "reporte ausente o vacio: '$REPORT'"; fi
if grep -qF "$REPORT" "$TMP_DIR/stdout"; then pass "el wrapper anuncia la ruta del reporte"; else fail "stdout: $(cat "$TMP_DIR/stdout")"; fi

echo ""
echo "[3] entorno del pipeline aislado"
if grep -qx "herdr: " "$PIPELINE_STUB_LOG"; then pass "sin HERDR_*"; else fail "$(grep herdr "$PIPELINE_STUB_LOG")"; fi
if grep -qx "ui: " "$PIPELINE_STUB_LOG"; then pass "sin MEFISTO_UI (los gates hijos no heredan el modo)"; else fail "$(grep ui "$PIPELINE_STUB_LOG")"; fi
if grep -qx "runtime: claude" "$PIPELINE_STUB_LOG"; then pass "conserva MEFISTO_RUNTIME"; else fail "$(grep runtime "$PIPELINE_STUB_LOG")"; fi

echo ""
echo "[4] --batch con MEFISTO_UI=mod corre el batch desacoplado"
run_wrapper --batch 42 43
if [ "$LAST_RC" -eq 0 ]; then pass "el wrapper termina sin error"; else fail "rc=$LAST_RC stderr: $(cat "$TMP_DIR/stderr")"; fi
if wait_for_file "$BATCH_STUB_LOG"; then pass "el batch corrio desacoplado"; else fail "el batch no corrio"; fi
if [ ! -s "$UI_STUB_LOG" ]; then pass "ni tmux ni herdr fueron invocados"; else fail "se invoco UI: $(cat "$UI_STUB_LOG")"; fi
if grep -qF "args: 42 43" "$BATCH_STUB_LOG"; then pass "issues en orden"; else fail "args: $(cat "$BATCH_STUB_LOG")"; fi
if grep -qx "herdr: " "$BATCH_STUB_LOG" && grep -qx "ui: " "$BATCH_STUB_LOG"; then pass "sin HERDR_* ni MEFISTO_UI"; else fail "$(cat "$BATCH_STUB_LOG")"; fi
REPORT=$(ls "$FAKE_MEFISTO"/.mefisto/pipeline/logs/mefisto-batch-run-*.report.log 2>/dev/null | head -1)
if [ -n "$REPORT" ] && wait_for_file "$REPORT" && grep -q "salida del batch" "$REPORT"; then pass "reporte en logs/mefisto-batch-run-*.report.log"; else fail "reporte ausente o vacio: '$REPORT'"; fi

echo ""
echo "[5] --batch con MEFISTO_UI=mod rechaza un issue no numerico"
run_wrapper --batch 42 '43;touch x'
sleep 0.5
if [ "$LAST_RC" -ne 0 ]; then pass "el wrapper falla"; else fail "rc=0 con un issue invalido"; fi
if [ ! -e "$BATCH_STUB_LOG" ]; then pass "el batch no se lanza"; else fail "se lanzo el batch: $(cat "$BATCH_STUB_LOG")"; fi

echo ""
echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
