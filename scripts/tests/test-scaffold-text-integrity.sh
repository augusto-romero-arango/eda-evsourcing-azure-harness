#!/usr/bin/env bash
# test-scaffold-text-integrity.sh -- Gate de git diff --check del scaffold (#1229).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PIPELINE="$REPO_ROOT/scripts/scaffold-pipeline.sh"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

create_consumer() {
    local name="$1" consumer remote
    consumer="$TMP_DIR/$name/consumer"
    remote="$TMP_DIR/$name/origin.git"
    mkdir -p "$consumer/.mefisto" "$TMP_DIR/$name"
    git init -q --bare "$remote"
    git init -q -b main "$consumer"
    git -C "$consumer" config user.name "Mefisto Test"
    git -C "$consumer" config user.email "mefisto-test@example.invalid"
    cat > "$consumer/.mefisto/harness.config.json" <<'EOF'
{
  "projectName": "Certificacion",
  "namespacePrefix": "Certificacion",
  "solutionFile": "Certificacion.slnx",
  "domainLabels": ["prueba"],
  "boundedContext": { "name": "Certificacion", "domains": ["prueba"] }
}
EOF
    printf 'base\n' > "$consumer/README.md"
    git -C "$consumer" add .
    git -C "$consumer" commit -qm "base"
    git -C "$consumer" remote add origin "$remote"
    git -C "$consumer" push -qu origin main
    printf '%s\n' "$consumer"
}

assert_gate_order() {
    local defensive_commit gate push
    defensive_commit=$(grep -nF 'commit -m "scaffold($DOMAIN_NAME): nuevo dominio $PASCAL_CASE"' "$PIPELINE" | cut -d: -f1)
    gate=$(grep -nF 'diff --check origin/main...HEAD' "$PIPELINE" | cut -d: -f1)
    push=$(grep -nF 'push -u origin "$BRANCH_NAME"' "$PIPELINE" | cut -d: -f1)

    if [ -n "$defensive_commit" ] && [ -n "$gate" ] && [ -n "$push" ] \
        && [ "$defensive_commit" -lt "$gate" ] && [ "$gate" -lt "$push" ]; then
        pass "el gate cubre origin/main...HEAD despues del commit defensivo y antes del push"
    else
        fail "orden invalido: commit=${defensive_commit:-ausente}, gate=${gate:-ausente}, push=${push:-ausente}"
    fi
}

create_stubs() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$GH_STUB_LOG"
case "${1:-} ${2:-}" in
    "label create") exit 0 ;;
    "pr list") exit 0 ;;
    "pr create") printf '%s\n' 'https://example.invalid/pr/1229'; exit 0 ;;
    *) exit 1 ;;
esac
EOF
    cat > "$bin/claude" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$PWD/src/Certificacion.Prueba"
case "$SCAFFOLD_FIXTURE" in
    sano) printf 'namespace Certificacion.Prueba;\n' > "$PWD/src/Certificacion.Prueba/Program.cs" ;;
    whitespace) printf 'namespace Certificacion.Prueba; \n' > "$PWD/src/Certificacion.Prueba/Program.cs" ;;
    crlf) printf 'namespace Certificacion.Prueba;\r\n' > "$PWD/src/Certificacion.Prueba/Program.cs" ;;
esac
EOF
    chmod +x "$bin/gh" "$bin/claude"
}

run_case() {
    local scenario="$1" consumer bin
    consumer="$(create_consumer "$scenario")"
    bin="$TMP_DIR/$scenario/bin"
    create_stubs "$bin"
    GH_STUB_LOG="$TMP_DIR/$scenario/gh.log"
    : > "$GH_STUB_LOG"
    (
        cd "$consumer" || exit 99
        SCAFFOLD_FIXTURE="$scenario" GH_STUB_LOG="$GH_STUB_LOG" PATH="$bin:$PATH" \
            "$PIPELINE" --domain prueba
    ) > "$TMP_DIR/$scenario.out" 2>&1
    LAST_RC=$?
    LAST_CONSUMER="$consumer"
    LAST_GH_LOG="$GH_STUB_LOG"
}

echo "[1] Output sano: verifica el rango y conserva push/PR (CA-1/CA-4)"
assert_gate_order
run_case sano
if [ "$LAST_RC" -eq 0 ]; then pass "el scaffold sano completa"; else fail "el scaffold sano fallo (rc $LAST_RC)"; fi
if git -C "$LAST_CONSUMER" ls-remote --exit-code origin refs/heads/scaffold-prueba >/dev/null 2>&1; then pass "el camino sano hace push"; else fail "el camino sano no publico la rama"; fi
if grep -qF 'gh pr create' "$LAST_GH_LOG"; then pass "el camino sano crea el PR"; else fail "el camino sano no crea el PR"; fi
if grep -qF 'Integridad textual verificada' "$TMP_DIR/sano.out"; then pass "el camino sano informa el gate"; else fail "no informo la integridad textual"; fi

echo "[2] Trailing whitespace: aborta antes de publicar y conserva diagnostico (CA-2/CA-3)"
run_case whitespace
if [ "$LAST_RC" -ne 0 ]; then pass "trailing whitespace aborta"; else fail "trailing whitespace no debe completar"; fi
if ! git -C "$LAST_CONSUMER" ls-remote --exit-code origin refs/heads/scaffold-prueba >/dev/null 2>&1; then pass "trailing whitespace no hace push"; else fail "trailing whitespace publico una rama"; fi
if ! grep -qF 'gh pr create' "$LAST_GH_LOG"; then pass "trailing whitespace no crea PR"; else fail "trailing whitespace intento crear PR"; fi
if grep -qF "errores de whitespace detectados por 'git diff --check'" "$TMP_DIR/whitespace.out"; then pass "trailing whitespace muestra una ruta de diagnostico"; else fail "trailing whitespace no muestra diagnostico accionable"; fi
if grep -qF 'Program.cs:1:' "$LAST_CONSUMER/.claude/pipeline/logs/"scaffold-*.log 2>/dev/null; then pass "trailing whitespace queda en el diagnostico"; else fail "trailing whitespace no quedo en el diagnostico"; fi

echo "[3] Finales CRLF: abortan antes de publicar (CA-3)"
run_case crlf
if [ "$LAST_RC" -ne 0 ]; then pass "CRLF aborta"; else fail "CRLF no debe completar"; fi
if ! git -C "$LAST_CONSUMER" ls-remote --exit-code origin refs/heads/scaffold-prueba >/dev/null 2>&1; then pass "CRLF no hace push"; else fail "CRLF publico una rama"; fi
if ! grep -qF 'gh pr create' "$LAST_GH_LOG"; then pass "CRLF no crea PR"; else fail "CRLF intento crear PR"; fi
if grep -qF 'Program.cs:1:' "$LAST_CONSUMER/.claude/pipeline/logs/"scaffold-*.log 2>/dev/null; then pass "CRLF queda en el diagnostico"; else fail "CRLF no quedo en el diagnostico"; fi

echo
echo "Resumen: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
