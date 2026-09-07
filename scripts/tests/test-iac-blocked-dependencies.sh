#!/usr/bin/env bash
# test-iac-blocked-dependencies.sh -- Gate temprano de dependencias de IaC (#829).
#
# Ejecuta iac-pipeline.sh contra un consumidor falso. Los stubs registran los
# efectos para comprobar que una dependencia abierta aborta antes de fetch,
# worktree o agentes; las otras rutas llegan al fetch normal sin consultar deps
# innecesarias o retiran el semaforo cuando todas estan resueltas. Incluye una
# seccion vacia para cubrir la expansion de arrays bajo Bash 3.2 de macOS.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PIPELINE="$REPO_ROOT/scripts/iac-pipeline.sh"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_contains() {
    local name="$1" needle="$2" file="$3"
    if grep -qF -- "$needle" "$file"; then pass "$name"; else fail "$name (ausente: $needle)"; fi
}
assert_not_contains() {
    local name="$1" needle="$2" file="$3"
    if grep -qF -- "$needle" "$file"; then fail "$name (presente: $needle)"; else pass "$name"; fi
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
FAKE_CONSUMER="$TMP_DIR/consumer"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_CONSUMER/.claude" "$FAKE_CONSUMER/infra/environments/dev" "$FAKE_BIN"
(cd "$FAKE_CONSUMER" && git init -q)
cat > "$FAKE_CONSUMER/.claude/harness.config.json" <<'EOF'
{
  "projectName": "Prueba",
  "namespacePrefix": "Prueba",
  "solutionFile": "Prueba.sln",
  "domainLabels": ["prueba"],
  "boundedContext": { "name": "Prueba", "domains": ["prueba"] }
}
EOF

cat > "$FAKE_BIN/git" <<'STUB'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$STUB_LOG"
if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--show-toplevel" ]; then
    printf '%s\n' "$FAKE_CONSUMER"
    exit 0
fi
if [ "${1:-}" = "fetch" ]; then
    exit 88
fi
exit 0
STUB

cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$STUB_LOG"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ] && [ "${3:-}" = "829" ]; then
    case "$SCENARIO" in
        no-label) printf '%s\n' '{"number":829,"title":"Infra de prueba","body":"## Dependencias\n- Depende de #42\n","state":"OPEN","labels":[]}' ;;
        open)     printf '%s\n' '{"number":829,"title":"Infra de prueba","body":"## Dependencias\n- Depende de #42\n","state":"OPEN","labels":[{"name":"bloqueado"}]}' ;;
        resolved) printf '%s\n' '{"number":829,"title":"Infra de prueba","body":"## Dependencias\n- Depende de #42 y PR #43\n## Ambiente\ndev","state":"OPEN","labels":[{"name":"bloqueado"}]}' ;;
        no-refs)  printf '%s\n' '{"number":829,"title":"Infra de prueba","body":"## Dependencias\nNinguna.\n","state":"OPEN","labels":[{"name":"bloqueado"}]}' ;;
    esac
    exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ] && [ "${3:-}" = "42" ]; then
    case "$SCENARIO" in
        open)     printf '%s\n' '{"state":"OPEN","title":"Dependencia abierta"}' ;;
        resolved) printf '%s\n' '{"state":"CLOSED","title":"Issue cerrado"}' ;;
    esac
    exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ] && [ "${3:-}" = "43" ]; then
    exit 1
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ] && [ "${3:-}" = "43" ]; then
    printf '%s\n' '{"state":"MERGED","title":"PR mergeado"}'
    exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "edit" ]; then exit 0; fi
exit 1
STUB

cat > "$FAKE_BIN/terraform" <<'STUB'
#!/usr/bin/env bash
printf 'terraform %s\n' "$*" >> "$STUB_LOG"
exit 0
STUB
cat > "$FAKE_BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >> "$STUB_LOG"
exit 0
STUB
chmod +x "$FAKE_BIN/git" "$FAKE_BIN/gh" "$FAKE_BIN/terraform" "$FAKE_BIN/claude"

run_case() {
    local scenario="$1"
    STUB_LOG="$TMP_DIR/$scenario.log"
    : > "$STUB_LOG"
    (
        cd "$FAKE_CONSUMER" || exit 99
        SCENARIO="$scenario" FAKE_CONSUMER="$FAKE_CONSUMER" STUB_LOG="$STUB_LOG" \
            PATH="$FAKE_BIN:$PATH" "$PIPELINE" 829
    ) >"$TMP_DIR/$scenario.out" 2>&1
    LAST_RC=$?
}

echo "[1] Sin label: conserva el flujo y no consulta dependencias (CA-1)"
run_case no-label
if [ "$LAST_RC" -ne 0 ]; then pass "el flujo normal alcanza su fetch stub"; else fail "el fetch stub deberia detener la corrida"; fi
assert_contains "la descarga inicial solicita labels" "gh issue view 829 --json number,title,body,state,labels" "$STUB_LOG"
assert_not_contains "sin label no consulta #42" "gh issue view 42" "$STUB_LOG"
assert_not_contains "sin label no intenta quitar el semaforo" "gh issue edit 829 --remove-label bloqueado" "$STUB_LOG"
assert_contains "sin label alcanza fetch normal" "git fetch origin main" "$STUB_LOG"

echo "[2] Dependencia OPEN: aborta antes de Git y agentes (CA-2/CA-3)"
run_case open
if [ "$LAST_RC" -ne 0 ]; then pass "dependencia OPEN aborta"; else fail "dependencia OPEN no debe continuar"; fi
assert_contains "muestra numero, titulo y estado" "#42: Dependencia abierta (OPEN)" "$TMP_DIR/open.out"
assert_contains "consulta la dependencia como issue" "gh issue view 42 --json state,title" "$STUB_LOG"
assert_not_contains "bloqueado no hace fetch" "git fetch origin main" "$STUB_LOG"
assert_not_contains "bloqueado no crea worktree" "git worktree add" "$STUB_LOG"
assert_not_contains "bloqueado no invoca agentes" "claude " "$STUB_LOG"

echo "[3] CLOSED y MERGED: retira label y continua (CA-4)"
run_case resolved
if [ "$LAST_RC" -ne 0 ]; then pass "resueltas alcanzan el fetch normal"; else fail "el fetch stub deberia detener la corrida"; fi
assert_contains "consulta issue cerrado" "gh issue view 42 --json state,title" "$STUB_LOG"
assert_contains "consulta PR tras fallback de issue" "gh pr view 43 --json state,title" "$STUB_LOG"
assert_contains "retira el label bloqueado" "gh issue edit 829 --remove-label bloqueado" "$STUB_LOG"
assert_contains "informa el desbloqueo" "Dependencias resueltas: se quito el label 'bloqueado'" "$TMP_DIR/resolved.out"
assert_contains "continua hacia fetch" "git fetch origin main" "$STUB_LOG"

echo "[4] Seccion sin referencias: no falla por array vacio en Bash 3.2"
run_case no-refs
if [ "$LAST_RC" -ne 0 ]; then pass "sin referencias alcanza el fetch normal"; else fail "el fetch stub deberia detener la corrida"; fi
assert_not_contains "sin referencias no inventa consultas" "gh issue view 42" "$STUB_LOG"
assert_contains "sin referencias retira el label" "gh issue edit 829 --remove-label bloqueado" "$STUB_LOG"
assert_contains "sin referencias continua hacia fetch" "git fetch origin main" "$STUB_LOG"

echo
echo "Resumen: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
