#!/usr/bin/env bash
# Verifica que la clausura publicada permite arrancar TDD desde un consumidor.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

declare -a CLOSURE_ASSETS=(
    'scripts/_pipeline-common.sh'
    'scripts/tooling-pipeline.sh'
    'scripts/tdd-pipeline.sh'
    'src/runtime/mefisto-run-agent.sh'
    'src/runtime/lib/mefisto-runtime.sh'
    'src/runtime/lib/mefisto-models.sh'
)

is_declared_asset() {
    local needle="$1" asset
    for asset in "${CLOSURE_ASSETS[@]}"; do
        [ "$asset" = "$needle" ] && return 0
    done
    return 1
}

assert_dependency_closure() {
    local pipeline="$1" line dependency=0
    while IFS= read -r line; do
        case "$line" in
            *'source '*'_pipeline-common.sh'*) dependency='scripts/_pipeline-common.sh' ;;
            *'source '*'$RUNTIME_LIB_DIR/mefisto-runtime.sh'*) dependency='src/runtime/lib/mefisto-runtime.sh' ;;
            *'source '*'$RUNTIME_LIB_DIR/mefisto-models.sh'*) dependency='src/runtime/lib/mefisto-models.sh' ;;
            *'$SCRIPT_DIR/../src/runtime'*) dependency='src/runtime/mefisto-run-agent.sh' ;;
            *'$RUNTIME_DIR/mefisto-run-agent.sh'*) dependency='src/runtime/mefisto-run-agent.sh' ;;
            *) continue ;;
        esac
        if ! is_declared_asset "$dependency"; then
            fail "${pipeline##*/} referencia $dependency fuera de la clausura"
            return
        fi
    done < "$pipeline"
    pass "${pipeline##*/} solo referencia dependencias declaradas en la clausura"
}

echo '[pre] sintaxis y dependencias de clausura'
if bash -n "$REPO_ROOT/dist/claude/scripts/tdd-pipeline.sh" && bash -n "$REPO_ROOT/dist/opencode/scripts/tdd-pipeline.sh"; then
    pass 'ambas copias publicadas de TDD tienen sintaxis Bash valida'
else
    fail 'alguna copia publicada de TDD tiene sintaxis Bash invalida'
fi
assert_dependency_closure "$REPO_ROOT/scripts/tdd-pipeline.sh"
assert_dependency_closure "$REPO_ROOT/scripts/tooling-pipeline.sh"

CONSUMER="$WORK/consumidor"
mkdir -p "$CONSUMER/.mefisto"
git -C "$CONSUMER" init -q
cat > "$CONSUMER/.mefisto/harness.config.json" <<'EOF'
{
  "projectName": "Consumidor",
  "namespacePrefix": "Consumidor",
  "solutionFile": "Consumidor.sln",
  "domainLabels": ["ventas"],
  "boundedContext": {"name": "Ventas", "domains": ["ventas"]}
}
EOF
OUTPUT="$(cd "$CONSUMER" && "$REPO_ROOT/dist/opencode/scripts/tdd-pipeline.sh" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUTPUT" | grep -Fq 'Uso:'; then
    pass 'TDD publicado arranca desde dist/opencode y llega al uso sin argumentos'
else
    fail "TDD publicado no llego al uso desde la clausura (exit $RC)"
fi

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
