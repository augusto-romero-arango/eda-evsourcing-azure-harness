#!/usr/bin/env bash
# test-pr-sync-state-paths.sh -- Regresiones de la ubicacion de logs de
# pr-sync.sh (issue #1583): el escritor unico del estado del consumidor es
# .mefisto/pipeline (MEF-ADR-0053 seccion 4), sin fallback de escritura a
# .claude/pipeline.
#
# A diferencia de los otros tests de pr-sync.sh (que extraen una funcion con
# awk), este corre el script COMPLETO con `--all` en un repo git temporal: es
# la unica forma de observar donde caen el log principal y el directorio de
# logs por agente, que hoy dependen de mefisto_state_path().
#
#   S-1 (CA-4a): exit 0 y "No hay PRs abiertos." cuando gh no reporta PRs.
#   S-2 (CA-4b): existe .mefisto/pipeline/logs/pr-sync-*.log.
#   S-3 (CA-4c): no se crea .claude/pipeline/.
#   S-4 (CA-4d): con MEFISTO_STATE_DIR=<dir> exportado, el log cae bajo
#       <dir>/logs/ en vez de la ruta canonica del repo.
#
# Uso: scripts/tests/test-pr-sync-state-paths.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PR_SYNC="$REPO_ROOT/scripts/pr-sync.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# make_consumer_repo <dir>
# Repo git temporal minimo, con harness.config.json canonico valido y SIN
# .claude-plugin/plugin.json (el guard de pr-sync.sh solo aplica al
# consumidor, nunca al propio repo de Mefisto).
make_consumer_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    mkdir -p "$dir/.mefisto"
    cat > "$dir/.mefisto/harness.config.json" <<'JSON'
{
  "projectName": "TestProject",
  "namespacePrefix": "Test.Namespace",
  "solutionFile": "Test.slnx",
  "domainLabels": ["dom1"],
  "boundedContext": { "name": "TestBC", "domains": ["dom1"] }
}
JSON
}

# make_stub_bin <dir>
# gh sin PRs abiertos (pr list vacio) y dotnet no-op: ninguno de los dos se
# invoca mas alla del chequeo de dependencias y de "gh pr list", porque el
# script sale por "No hay PRs abiertos." antes de crear ningun worktree.
make_stub_bin() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
    "pr list") exit 0 ;;
esac
exit 0
GH
    cat > "$dir/dotnet" <<'DOTNET'
#!/usr/bin/env bash
exit 0
DOTNET
    chmod +x "$dir/gh" "$dir/dotnet"
}

# --- S-1/S-2/S-3: corrida sin overrides, estado en la ubicacion canonica ----
REPO_1="$TMP_DIR/consumer-1"
make_consumer_repo "$REPO_1"
BIN_1="$TMP_DIR/bin-1"
make_stub_bin "$BIN_1"

OUTPUT_1=$(cd "$REPO_1" && unset MEFISTO_STATE_DIR MEFISTO_LEGACY_STATE_DIR && PATH="$BIN_1:$PATH" MEFISTO_RUNTIME=fake "$PR_SYNC" --all 2>&1)
RC_1=$?

echo "[S-1] exit 0 sin PRs abiertos"
if [ "$RC_1" -eq 0 ] && echo "$OUTPUT_1" | grep -q 'No hay PRs abiertos\.'; then
    pass "S-1: exit 0 y mensaje 'No hay PRs abiertos.'"
else
    fail "S-1: se esperaba exit 0 con el mensaje. exit=$RC_1 salida: $OUTPUT_1"
fi

echo "[S-2] log principal bajo .mefisto/pipeline/logs/"
CANONICAL_LOGS=("$REPO_1"/.mefisto/pipeline/logs/pr-sync-*.log)
if [ -f "${CANONICAL_LOGS[0]:-}" ]; then
    pass "S-2: existe $REPO_1/.mefisto/pipeline/logs/pr-sync-*.log"
else
    fail "S-2: no se encontro pr-sync-*.log bajo .mefisto/pipeline/logs/"
fi

echo "[S-3] no se crea .claude/pipeline/"
if [ ! -d "$REPO_1/.claude/pipeline" ]; then
    pass "S-3: no existe .claude/pipeline/"
else
    fail "S-3: se creo .claude/pipeline/ (no debia)"
fi

# --- S-4: MEFISTO_STATE_DIR exportado redirige el log --------------------
REPO_2="$TMP_DIR/consumer-2"
make_consumer_repo "$REPO_2"
BIN_2="$TMP_DIR/bin-2"
make_stub_bin "$BIN_2"
OVERRIDE_DIR="$TMP_DIR/override-state"

OUTPUT_2=$(cd "$REPO_2" && unset MEFISTO_LEGACY_STATE_DIR && PATH="$BIN_2:$PATH" MEFISTO_RUNTIME=fake MEFISTO_STATE_DIR="$OVERRIDE_DIR" "$PR_SYNC" --all 2>&1)
RC_2=$?

echo "[S-4] MEFISTO_STATE_DIR override redirige el log"
OVERRIDE_LOGS=("$OVERRIDE_DIR"/logs/pr-sync-*.log)
if [ "$RC_2" -eq 0 ] && [ -f "${OVERRIDE_LOGS[0]:-}" ]; then
    pass "S-4: el log cae bajo \$MEFISTO_STATE_DIR/logs/ con el override exportado"
else
    fail "S-4: no se encontro el log bajo $OVERRIDE_DIR/logs/. exit=$RC_2 salida: $OUTPUT_2"
fi
if [ ! -e "$REPO_2/.mefisto/pipeline/logs" ]; then
    pass "S-4: con el override no se escribio tambien en la ruta canonica del repo"
else
    fail "S-4: se escribio en $REPO_2/.mefisto/pipeline/logs pese al override"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
