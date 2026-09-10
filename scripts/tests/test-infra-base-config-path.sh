#!/usr/bin/env bash
# test-infra-base-config-path.sh -- Contrato de lectura de config de /infra-base (#1212).
#
# Cubre MEF-ADR-0053 para el prompt de infra-base-scaffolder: canonico, ambos
# divergentes (prevalece canonico), legacy y ausencia. Tambien evita que una
# lectura directa legacy reaparezca fuera de los bloques de fallback explicitos
# del agente y del workflow generado.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT="$REPO_ROOT/agents/infra-base-scaffolder.md"
COMMAND="$REPO_ROOT/commands/infra-base.md"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

resolve_config() {
    local root="$1"
    local config="$root/.mefisto/harness.config.json"
    [ -f "$config" ] || config="$root/.claude/harness.config.json"
    [ -f "$config" ] || return 1
    printf '%s\n' "$config"
}

write_config() {
    local path="$1" project="$2" projections="$3" secret="$4"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<JSON
{"projectName":"$project","infraResourceGroupPrefix":"rg-$project","terraformStateStorage":"st${project}tfstate","azureLocation":"$project-location","azureRegionShort":"$project-region","resourceSequence":"$project-seq","serviceBus":{"internal":{"secretName":"$secret"},"external":[{"alias":"$project-bus","alcance":"compartido","secretName":"$secret-external"}]},"projections":{"enabled":$projections},"secrets":[{"name":"$secret","source":{"type":"output","value":"$project-output"}}]}
JSON
}

read_tokens() {
    jq -r '[.projectName, .infraResourceGroupPrefix, .terraformStateStorage, .azureLocation, .azureRegionShort, .resourceSequence, .serviceBus.internal.secretName, .serviceBus.external[0].alias, .projections.enabled, .secrets[0].name] | join("|")' "$1"
}

assert_effective() {
    local label="$1" root="$2" expected="$3" actual rc
    actual=$(resolve_config "$root"); rc=$?
    if [ "$rc" -eq 0 ] && [ "$actual" = "$expected" ]; then
        pass "$label resuelve la ruta efectiva esperada"
    else
        fail "$label esperaba '$expected' y obtuvo '${actual:-<sin ruta>}'"
    fi
}

echo "[1] Consumidor canonico"
CANONICAL_ROOT="$TMP_DIR/canonical"
write_config "$CANONICAL_ROOT/.mefisto/harness.config.json" canonical true canonical-secret
assert_effective "canonico" "$CANONICAL_ROOT" "$CANONICAL_ROOT/.mefisto/harness.config.json"
CANONICAL_TOKENS=$(read_tokens "$(resolve_config "$CANONICAL_ROOT")")
if [ "$CANONICAL_TOKENS" = "canonical|rg-canonical|stcanonicaltfstate|canonical-location|canonical-region|canonical-seq|canonical-secret|canonical-bus|true|canonical-secret" ]; then
    pass "canonico provee todos los tokens y secrets"
else
    fail "canonico no provee todos los tokens esperados: $CANONICAL_TOKENS"
fi

echo "[2] Ambos configs divergentes: prevalece el canonico para todos los tokens"
BOTH_ROOT="$TMP_DIR/both"
write_config "$BOTH_ROOT/.mefisto/harness.config.json" canonical true canonical-secret
write_config "$BOTH_ROOT/.claude/harness.config.json" legacy false legacy-secret
assert_effective "ambos" "$BOTH_ROOT" "$BOTH_ROOT/.mefisto/harness.config.json"
EFFECTIVE=$(resolve_config "$BOTH_ROOT")
TOKENS=$(read_tokens "$EFFECTIVE")
if [ "$TOKENS" = "canonical|rg-canonical|stcanonicaltfstate|canonical-location|canonical-region|canonical-seq|canonical-secret|canonical-bus|true|canonical-secret" ]; then
    pass "ambos usa exclusivamente tokens y secrets canonicos"
else
    fail "ambos mezclo tokens legacy: $TOKENS"
fi

echo "[3] Consumidor legacy"
LEGACY_ROOT="$TMP_DIR/legacy"
write_config "$LEGACY_ROOT/.claude/harness.config.json" legacy false legacy-secret
assert_effective "legacy" "$LEGACY_ROOT" "$LEGACY_ROOT/.claude/harness.config.json"
LEGACY_TOKENS=$(read_tokens "$(resolve_config "$LEGACY_ROOT")")
if [ "$LEGACY_TOKENS" = "legacy|rg-legacy|stlegacytfstate|legacy-location|legacy-region|legacy-seq|legacy-secret|legacy-bus|false|legacy-secret" ]; then
    pass "legacy provee todos los tokens y secrets mediante el fallback"
else
    fail "legacy no provee todos los tokens esperados: $LEGACY_TOKENS"
fi

echo "[4] Ausencia de ambos configs"
MISSING_ROOT="$TMP_DIR/missing"
mkdir -p "$MISSING_ROOT"
if resolve_config "$MISSING_ROOT" >/dev/null 2>&1; then
    fail "ausencia debe abortar"
else
    pass "ausencia aborta"
fi

echo "[5] Prompt y workflow generado conservan el fallback explicito"
REPO_CANONICAL_COUNT=$(grep -Fc 'CONFIG="$REPO_ROOT/.mefisto/harness.config.json"' "$AGENT" || true)
REPO_LEGACY_COUNT=$(grep -Fc 'CONFIG="$REPO_ROOT/.claude/harness.config.json"' "$AGENT" || true)
WORKFLOW_CANONICAL_COUNT=$(grep -Fc 'CONFIG="$GITHUB_WORKSPACE/.mefisto/harness.config.json"' "$AGENT" || true)
WORKFLOW_LEGACY_COUNT=$(grep -Fc 'CONFIG="$GITHUB_WORKSPACE/.claude/harness.config.json"' "$AGENT" || true)
if [ "$REPO_CANONICAL_COUNT" -eq 3 ] && [ "$REPO_LEGACY_COUNT" -eq 3 ] \
    && [ "$WORKFLOW_CANONICAL_COUNT" -eq 1 ] && [ "$WORKFLOW_LEGACY_COUNT" -eq 1 ]; then
    pass "cada bloque del agente y el workflow parte del canonico y delimita un fallback legacy"
else
    fail "resolvers inesperados (repo canonico/legacy=$REPO_CANONICAL_COUNT/$REPO_LEGACY_COUNT, workflow=$WORKFLOW_CANONICAL_COUNT/$WORKFLOW_LEGACY_COUNT)"
fi
if grep -Eq '(^|[;&|[:space:]])jq[[:space:]].*\.claude/harness\.config\.json' "$AGENT"; then
    fail "reaparecio una lectura jq directa del config legacy"
else
    pass "no hay lecturas jq directas del config legacy"
fi
if grep -Eq '(^|[;&|[:space:]])(cat|sed|awk|grep|python|python3)[[:space:]].*\.claude/harness\.config\.json|<[[:space:]]*[^[:space:]]*\.claude/harness\.config\.json' "$AGENT"; then
    fail "reaparecio una lectura directa legacy fuera del fallback"
else
    pass "no hay otras lecturas directas del config legacy"
fi
if grep -Eq '(^|[;&|[:space:]])jq[[:space:]].*\.(mefisto|claude)/harness\.config\.json' "$AGENT"; then
    fail "alguna lectura jq evita la ruta efectiva CONFIG"
else
    pass "todas las lecturas jq pasan por la ruta efectiva CONFIG"
fi
if grep -Fq 'jq -r '\''{projectName, infraResourceGroupPrefix, terraformStateStorage, azureLocation, azureRegionShort, resourceSequence, serviceBus, projections}'\'' "$CONFIG"' "$AGENT" \
    && grep -Fq 'COUNT=$(jq -r '\''.secrets // [] | length'\'' "$CONFIG")' "$AGENT" \
    && grep -Fq 'No se encontro .mefisto/harness.config.json ni el fallback legacy .claude/harness.config.json; no se pueden sembrar secretos.' "$AGENT"; then
    pass "tokens del agente y secrets del workflow usan CONFIG y la ausencia aborta"
else
    fail "alguna lectura efectiva o diagnostico de ausencia no usa el contrato resuelto"
fi
if grep -Fq '.mefisto/harness.config.json' "$COMMAND" \
    && grep -Fq 'fallback de **lectura**' "$COMMAND" \
    && grep -Fq 'sin copiarlo ni migrarlo' "$COMMAND"; then
    pass "comando documenta contrato canonico sin instruir migracion"
else
    fail "comando no documenta correctamente el contrato"
fi

echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
