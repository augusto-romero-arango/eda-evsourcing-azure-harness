#!/usr/bin/env bash
# test-infra-base-config-path.sh -- Contrato de lectura de config de /infra-base (#1212).
#
# Cubre MEF-ADR-0053 para el prompt de infra-base-scaffolder: canonico, ambos
# divergentes (prevalece canonico), legacy y ausencia. Tambien evita que una
# lectura directa legacy reaparezca fuera de los dos bloques de fallback
# explicitos (agente y workflow generado).

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
{"projectName":"$project","azureLocation":"$project-location","resourceSequence":"$project-seq","serviceBus":{"internal":{"secretName":"$secret"}},"projections":{"enabled":$projections},"secrets":[{"name":"$secret","source":{"type":"output","value":"$project-output"}}]}
JSON
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

echo "[2] Ambos configs divergentes: prevalece el canonico para todos los tokens"
BOTH_ROOT="$TMP_DIR/both"
write_config "$BOTH_ROOT/.mefisto/harness.config.json" canonical true canonical-secret
write_config "$BOTH_ROOT/.claude/harness.config.json" legacy false legacy-secret
assert_effective "ambos" "$BOTH_ROOT" "$BOTH_ROOT/.mefisto/harness.config.json"
EFFECTIVE=$(resolve_config "$BOTH_ROOT")
TOKENS=$(jq -r '[.projectName, .azureLocation, .resourceSequence, .serviceBus.internal.secretName, .projections.enabled, .secrets[0].name] | join("|")' "$EFFECTIVE")
if [ "$TOKENS" = "canonical|canonical-location|canonical-seq|canonical-secret|true|canonical-secret" ]; then
    pass "ambos usa project, region, secuencia, Service Bus, proyecciones y secrets canonicos"
else
    fail "ambos mezclo tokens legacy: $TOKENS"
fi

echo "[3] Consumidor legacy"
LEGACY_ROOT="$TMP_DIR/legacy"
write_config "$LEGACY_ROOT/.claude/harness.config.json" legacy false legacy-secret
assert_effective "legacy" "$LEGACY_ROOT" "$LEGACY_ROOT/.claude/harness.config.json"

echo "[4] Ausencia de ambos configs"
MISSING_ROOT="$TMP_DIR/missing"
mkdir -p "$MISSING_ROOT"
if resolve_config "$MISSING_ROOT" >/dev/null 2>&1; then
    fail "ausencia debe abortar"
else
    pass "ausencia aborta"
fi

echo "[5] Prompt y workflow generado conservan el fallback explicito"
if grep -Fq 'CONFIG="$REPO_ROOT/.mefisto/harness.config.json"' "$AGENT" \
    && grep -Fq 'CONFIG="$GITHUB_WORKSPACE/.mefisto/harness.config.json"' "$AGENT"; then
    pass "agente y workflow parten del config canonico"
else
    fail "falta la ruta canonica en agente o workflow"
fi
if grep -Fq 'CONFIG="$REPO_ROOT/.claude/harness.config.json"' "$AGENT" \
    && grep -Fq 'CONFIG="$GITHUB_WORKSPACE/.claude/harness.config.json"' "$AGENT"; then
    pass "los fallbacks legacy estan delimitados por CONFIG"
else
    fail "faltan los fallbacks legacy explicitos"
fi
if grep -Eq 'jq[^`\n]*\.claude/harness\.config\.json' "$AGENT"; then
    fail "reaparecio una lectura jq directa del config legacy"
else
    pass "no hay lecturas jq directas del config legacy"
fi
if grep -Eq '(cat|sed|awk|grep)[^`\n]*\.claude/harness\.config\.json' "$AGENT"; then
    fail "reaparecio una lectura directa legacy fuera del fallback"
else
    pass "no hay otras lecturas directas del config legacy"
fi
if grep -Fq '.mefisto/harness.config.json' "$COMMAND" \
    && grep -Fq 'fallback de **lectura**' "$COMMAND" \
    && ! grep -Eiq '(copia|migra).*\.claude/harness\.config\.json' "$COMMAND"; then
    pass "comando documenta contrato canonico sin instruir migracion"
else
    fail "comando no documenta correctamente el contrato"
fi

echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
