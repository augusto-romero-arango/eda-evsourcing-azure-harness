#!/usr/bin/env bash
# test-scope-diagnostic-config-path.sh -- Contrato de repoSlug efectivo (#1511).
#
# validate_consumer_scope_changes debe leer repoSlug desde "$HARNESS_CONFIG_PATH"
# (la ruta efectiva ya resuelta por load_harness_config/resolve_harness_config_path,
# canonico o legacy como fallback -- MEF-ADR-0053 decision 4), nunca de un jq
# directo sobre .claude/harness.config.json relativo al cwd.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/_pipeline-common.sh"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# make_scope_fixture -- crea un repo git temporal con un commit base y una
# violacion de scope (docs/adr/mef-adr-0001-ejemplo.md) sin commitear, mismo
# patron que test-guards.sh bloque [D]. Imprime la ruta del fixture.
make_scope_fixture() {
    local fixture
    fixture=$(mktemp -d)
    git -C "$fixture" init -q -b main
    git -C "$fixture" config user.email "test@local"
    git -C "$fixture" config user.name "Test"
    touch "$fixture/README.md"
    git -C "$fixture" add README.md
    git -C "$fixture" commit -q -m "base"

    mkdir -p "$fixture/docs/adr"
    touch "$fixture/docs/adr/mef-adr-0001-ejemplo.md"
    git -C "$fixture" add -A docs
    echo "$fixture"
}

write_minimal_config() {
    local path="$1" repo_slug="$2" repo_slug_fragment=""
    mkdir -p "$(dirname "$path")"
    if [ -n "$repo_slug" ]; then
        repo_slug_fragment=$(printf '  "repoSlug": "%s",\n' "$repo_slug")
    fi
    cat > "$path" <<EOF
{
  "projectName": "Prueba",
  "namespacePrefix": "Prueba.Backend",
  "solutionFile": "Prueba.slnx",
  "infraResourceGroupPrefix": "rg-prueba",
  "githubServicePrincipalName": "github-prueba-ci",
  "appInsightsApp": "appi-prueba",
  "domainLabels": ["prueba"],
${repo_slug_fragment}  "boundedContext": { "name": "Principal", "domains": ["prueba"] }
}
EOF
}

DEFAULT_SLUG="augusto-romero-arango/eda-evsourcing-azure-harness"

echo "[1] Config canonico con repoSlug=org/fork via HARNESS_CONFIG_PATH"
(
    set +u
    source "$LIB" 2>/dev/null
    fixture=$(make_scope_fixture)
    trap 'rm -rf "$fixture"' EXIT
    config="$fixture/.mefisto/harness.config.json"
    write_minimal_config "$config" "org/fork"
    export HARNESS_CONFIG_PATH="$config"
    base=$(git -C "$fixture" rev-parse HEAD)
    output=$(validate_consumer_scope_changes "$fixture" "$base" 2>&1 >/dev/null)
    if grep -Fq "pertenecen al plugin (repo org/fork)" <<< "$output" \
        && grep -Fq "gh issue create -R org/fork" <<< "$output" \
        && ! grep -Fq "$DEFAULT_SLUG" <<< "$output"; then
        echo "OK"
    else
        echo "MISMATCH: $output"
    fi
) | tail -n1 | grep -q '^OK$' && pass "canonico via HARNESS_CONFIG_PATH nombra org/fork" || fail "canonico via HARNESS_CONFIG_PATH no nombro org/fork"

echo "[2] Config legacy resuelto por load_harness_config (sin canonico)"
(
    set +u
    source "$LIB" 2>/dev/null
    fixture=$(make_scope_fixture)
    trap 'rm -rf "$fixture" "${neutral:-}"' EXIT
    legacy_config="$fixture/.claude/harness.config.json"
    write_minimal_config "$legacy_config" "org/legacy-fork"
    base=$(git -C "$fixture" rev-parse HEAD)
    neutral=$(mktemp -d)
    (
        cd "$fixture" && load_harness_config >/dev/null 2>&1
        # El cwd neutral (sin config alguno) prueba CA-2: el slug sale de
        # HARNESS_CONFIG_PATH ya exportada, no de una lectura relativa al cwd.
        cd "$neutral" || exit 1
        output=$(validate_consumer_scope_changes "$fixture" "$base" 2>&1 >/dev/null)
        if grep -Fq "pertenecen al plugin (repo org/legacy-fork)" <<< "$output" \
            && grep -Fq "gh issue create -R org/legacy-fork" <<< "$output" \
            && ! grep -Fq "$DEFAULT_SLUG" <<< "$output"; then
            echo "OK"
        else
            echo "MISMATCH: $output"
        fi
    )
) | tail -n1 | grep -q '^OK$' && pass "legacy via load_harness_config nombra org/legacy-fork" || fail "legacy via load_harness_config no nombro org/legacy-fork"

echo "[3] HARNESS_CONFIG_PATH vacia/unset -> default"
(
    set +u
    source "$LIB" 2>/dev/null
    fixture=$(make_scope_fixture)
    trap 'rm -rf "$fixture"' EXIT
    unset HARNESS_CONFIG_PATH
    base=$(git -C "$fixture" rev-parse HEAD)
    output=$(validate_consumer_scope_changes "$fixture" "$base" 2>&1 >/dev/null)
    if grep -Fq "pertenecen al plugin (repo $DEFAULT_SLUG)" <<< "$output" \
        && grep -Fq "gh issue create -R $DEFAULT_SLUG" <<< "$output"; then
        echo "OK"
    else
        echo "MISMATCH: $output"
    fi
) | tail -n1 | grep -q '^OK$' && pass "HARNESS_CONFIG_PATH vacia aplica el default" || fail "HARNESS_CONFIG_PATH vacia no aplico el default"

echo "[4] Config sin repoSlug -> default"
(
    set +u
    source "$LIB" 2>/dev/null
    fixture=$(make_scope_fixture)
    trap 'rm -rf "$fixture"' EXIT
    config="$fixture/.mefisto/harness.config.json"
    write_minimal_config "$config" ""
    export HARNESS_CONFIG_PATH="$config"
    base=$(git -C "$fixture" rev-parse HEAD)
    output=$(validate_consumer_scope_changes "$fixture" "$base" 2>&1 >/dev/null)
    if grep -Fq "pertenecen al plugin (repo $DEFAULT_SLUG)" <<< "$output" \
        && grep -Fq "gh issue create -R $DEFAULT_SLUG" <<< "$output"; then
        echo "OK"
    else
        echo "MISMATCH: $output"
    fi
) | tail -n1 | grep -q '^OK$' && pass "config sin repoSlug aplica el default" || fail "config sin repoSlug no aplico el default"

echo "[5] Anti-regresion: no reaparece una lectura directa del literal legacy"
# El '(' del char class inicial cubre la forma real del mutante: repo_slug=$(jq ...).
if grep -Eq '(^|[;&|([:space:]])(jq|cat)[[:space:]].*\.claude/harness\.config\.json|<[[:space:]]*[^[:space:]]*\.claude/harness\.config\.json' "$LIB"; then
    fail "reaparecio una lectura directa del literal .claude/harness.config.json"
else
    pass "no hay lecturas directas del literal .claude/harness.config.json"
fi
if grep -Fq "jq -r '.repoSlug // empty' \"\$HARNESS_CONFIG_PATH\"" "$LIB"; then
    pass "repoSlug se lee desde HARNESS_CONFIG_PATH"
else
    fail "repoSlug no usa HARNESS_CONFIG_PATH"
fi

echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
