#!/usr/bin/env bash
# test-guards.sh -- Tests de los guards defensivos de skills publicados e internos.
#
# Valida que:
#   A) Los skills publicados (commands/*.md) llevan el guard "cwd != Mefisto"
#      al inicio (presencia del bloque que verifica .claude-plugin/plugin.json).
#   B) Los skills internos (.claude/commands/mefisto-*.md) llevan el guard inverso.
#   C) Los pipelines publicados (scripts/tooling-pipeline.sh, scripts/parallel-pipeline.sh,
#      scripts/batch-pipeline.sh, scripts/pr-sync.sh, scripts/tdd-pipeline.sh,
#      scripts/iac-pipeline.sh, scripts/scaffold-pipeline.sh, scripts/tmux-pipeline.sh)
#      y los scripts auxiliares publicados (appinsights-query.sh, eda-lint.sh,
#      setup-github-ci.sh, setup-github-labels.sh) abortan si se sourcean en un
#      contexto donde .claude-plugin/plugin.json existe.
#   D) Las funciones validate_*_scope_changes son sourceables sin errores.
#
# Uso: scripts/tests/test-guards.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# -------- Bloque A: guards en skills publicados --------

echo "[A] Skills publicados (commands/*.md): guard 'cwd != Mefisto' presente"

PUBLISHED_SKILLS=(
    bug.md draft.md eraser-diagram.md fix-review.md health-check.md
    implement.md infra.md merge.md parallel.md scaffold.md sequential.md
    show-flow.md tooling.md work-status.md
)

for skill in "${PUBLISHED_SKILLS[@]}"; do
    path="$REPO_ROOT/commands/$skill"
    if [ ! -f "$path" ]; then
        fail "$skill: archivo no existe"
        continue
    fi
    if grep -q '\.claude-plugin/plugin\.json' "$path"; then
        pass "$skill: menciona .claude-plugin/plugin.json"
    else
        fail "$skill: no menciona .claude-plugin/plugin.json (falta guard)"
    fi
done

# -------- Bloque B: guards inversos en skills internos --------

echo ""
echo "[B] Skills internos (.claude/commands/mefisto-*.md): guard inverso presente"

INTERNAL_SKILLS=(
    mefisto-tooling.md mefisto-plan.md mefisto-bug.md mefisto-fix-review.md
    mefisto-merge.md mefisto-work-status.md
)

for skill in "${INTERNAL_SKILLS[@]}"; do
    path="$REPO_ROOT/.claude/commands/$skill"
    if [ ! -f "$path" ]; then
        fail "$skill: archivo no existe"
        continue
    fi
    # El guard inverso verifica que el archivo NO existe -> aborta
    if grep -q '\.claude-plugin/plugin\.json' "$path"; then
        pass "$skill: menciona .claude-plugin/plugin.json (guard inverso)"
    else
        fail "$skill: no menciona .claude-plugin/plugin.json"
    fi
done

# -------- Bloque C: pipelines publicados abortan en repo de Mefisto --------

echo ""
echo "[C] Pipelines publicados: contienen guard contra repo de Mefisto"

PUBLISHED_PIPELINES=(
    tooling-pipeline.sh parallel-pipeline.sh batch-pipeline.sh pr-sync.sh
    tdd-pipeline.sh iac-pipeline.sh scaffold-pipeline.sh tmux-pipeline.sh
    appinsights-query.sh eda-lint.sh setup-github-ci.sh setup-github-labels.sh
    bootstrap-backend.sh
)

for pipe in "${PUBLISHED_PIPELINES[@]}"; do
    path="$REPO_ROOT/scripts/$pipe"
    if [ ! -f "$path" ]; then
        fail "$pipe: archivo no existe"
        continue
    fi
    if grep -q '\.claude-plugin/plugin\.json' "$path"; then
        pass "$pipe: menciona .claude-plugin/plugin.json (guard)"
    else
        fail "$pipe: no menciona .claude-plugin/plugin.json"
    fi

    # Validar sintaxis bash
    if bash -n "$path" 2>/dev/null; then
        pass "$pipe: sintaxis bash valida"
    else
        fail "$pipe: sintaxis bash invalida"
    fi
done

# -------- Bloque C2: scripts auxiliares publicados abortan en repo de Mefisto --------

echo ""
echo "[C2] Scripts auxiliares publicados: el guard aborta cuando se ejecutan en Mefisto"

AUX_SCRIPTS=(
    appinsights-query.sh eda-lint.sh setup-github-ci.sh setup-github-labels.sh
    bootstrap-backend.sh
)

for aux in "${AUX_SCRIPTS[@]}"; do
    path="$REPO_ROOT/scripts/$aux"
    output=$("$path" 2>&1)
    rc=$?
    if [ "$rc" -eq 1 ] && echo "$output" | grep -q "plugin publicado y solo aplica al consumidor"; then
        pass "$aux: aborta con exit 1 y mensaje correcto en repo de Mefisto"
    else
        fail "$aux: no aborta como se espera (exit=$rc)"
    fi
done

# -------- Bloque D: _pipeline-common.sh y _mefisto-common.sh sourceables --------

echo ""
echo "[D] Funciones de scope son sourceables y exportan los simbolos esperados"

# Subshell para no contaminar este shell con las funciones
(
    set +u
    source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null
    if declare -F is_path_in_consumer_blocklist >/dev/null; then
        echo "  PASS: is_path_in_consumer_blocklist definida en _pipeline-common.sh"
        exit 0
    else
        echo "  FAIL: is_path_in_consumer_blocklist NO definida"
        exit 1
    fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

(
    set +u
    source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null
    if declare -F validate_consumer_scope_changes >/dev/null; then
        echo "  PASS: validate_consumer_scope_changes definida"
        exit 0
    else
        echo "  FAIL: validate_consumer_scope_changes NO definida"
        exit 1
    fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

(
    set +u
    source "$REPO_ROOT/.claude/scripts/_mefisto-common.sh" 2>/dev/null
    if declare -F is_path_in_mefisto_scope >/dev/null && declare -F validate_mefisto_scope_changes >/dev/null && declare -F assert_in_mefisto >/dev/null; then
        echo "  PASS: _mefisto-common.sh exporta assert_in_mefisto, is_path_in_mefisto_scope, validate_mefisto_scope_changes"
        exit 0
    else
        echo "  FAIL: _mefisto-common.sh no exporta todas las funciones esperadas"
        exit 1
    fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# -------- Bloque E: comportamiento funcional del scope --------

echo ""
echo "[E] is_path_in_consumer_blocklist clasifica correctamente"

(
    set +u
    source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null

    # Rutas que deben estar en el blocklist (reservadas al plugin)
    for blocked in "commands/foo.md" "agents/bar.md" "hooks/baz.json" ".claude-plugin/plugin.json" "docs/adr/0001.md"; do
        if is_path_in_consumer_blocklist "$blocked"; then
            echo "  PASS: '$blocked' detectado como blocklist"
        else
            echo "  FAIL: '$blocked' NO detectado como blocklist"
            exit 1
        fi
    done

    # Rutas que NO deben estar en el blocklist (validas para el consumidor)
    for allowed in "src/Foo.cs" "tests/Bar.cs" ".github/workflows/deploy.yml" ".claude/settings.json" "docs/bitacora/notes.md"; do
        if is_path_in_consumer_blocklist "$allowed"; then
            echo "  FAIL: '$allowed' detectado como blocklist (deberia estar permitido)"
            exit 1
        else
            echo "  PASS: '$allowed' NO detectado como blocklist"
        fi
    done
    exit 0
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ""
echo "[E2] is_path_in_mefisto_scope clasifica correctamente"

(
    set +u
    source "$REPO_ROOT/.claude/scripts/_mefisto-common.sh" 2>/dev/null

    # Rutas validas en Mefisto
    for valid in "commands/foo.md" "agents/bar.md" "scripts/baz.sh" "hooks/hooks.json" "docs/adr/0001.md" ".claude-plugin/plugin.json" ".claude/commands/mefisto-foo.md" "README.md"; do
        if is_path_in_mefisto_scope "$valid"; then
            echo "  PASS: '$valid' en scope de Mefisto"
        else
            echo "  FAIL: '$valid' NO esta en scope (deberia)"
            exit 1
        fi
    done

    # Rutas invalidas en Mefisto
    for invalid in "src/Foo.cs" "tests/Bar.cs" ".github/workflows/deploy.yml" "infra/main.tf" ".claude/harness.config.json"; do
        if is_path_in_mefisto_scope "$invalid"; then
            echo "  FAIL: '$invalid' esta en scope (NO deberia)"
            exit 1
        else
            echo "  PASS: '$invalid' fuera del scope"
        fi
    done
    exit 0
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# -------- Resumen --------

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
