#!/usr/bin/env bash
# test-cross-repo-slug-config-path.sh -- Contrato de ruta efectiva para leer
# `repoSlug` en los tres caminos de draft cross-repo hacia Mefisto (#1534,
# MEF-ADR-0053 decision 4).
#
# Cubre agents/planner.md ("### Slug del repo de Mefisto"),
# agents/tooling-investigator.md y commands/fix-review.md (ambos con el
# anclaje "Lee el slug del repo de Mefisto (configurable para forks):"):
# canonico, ambos divergentes (prevalece canonico), solo legacy, ausencia de
# ambos y canonico sin el campo opcional `repoSlug`. A diferencia de otros
# contratos de config efectivo, este campo nunca aborta: siempre cae al
# default. Tambien evita que una lectura directa del config legacy reaparezca
# fuera del fallback sancionado en los cuatro artefactos que mencionan
# `repoSlug`/`domainLabels` (los tres anteriores mas commands/draft.md).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLANNER="$REPO_ROOT/agents/planner.md"
INVESTIGATOR="$REPO_ROOT/agents/tooling-investigator.md"
FIX_REVIEW="$REPO_ROOT/commands/fix-review.md"
DRAFT="$REPO_ROOT/commands/draft.md"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

DEFAULT_SLUG="augusto-romero-arango/eda-evsourcing-azure-harness"

extract_after_anchor() {
    # $1: archivo, $2: substring literal del anclaje que precede el primer ```bash
    local file="$1" anchor="$2"
    awk -v anchor="$anchor" '
        index($0, anchor) { found=1 }
        found && /^```bash$/ { inside=1; next }
        found && inside && /^```$/ { exit }
        found && inside { print }
    ' "$file"
}

BLOCK_PLANNER="$(extract_after_anchor "$PLANNER" '### Slug del repo de Mefisto')"
BLOCK_INVESTIGATOR="$(extract_after_anchor "$INVESTIGATOR" 'Lee el slug del repo de Mefisto (configurable para forks):')"
BLOCK_FIX_REVIEW="$(extract_after_anchor "$FIX_REVIEW" 'Lee el slug del repo de Mefisto (configurable para forks):')"

echo "[1] Extraccion e identidad de los tres bloques"
if [ -n "$BLOCK_PLANNER" ] && [ -n "$BLOCK_INVESTIGATOR" ] && [ -n "$BLOCK_FIX_REVIEW" ]; then
    pass "los tres bloques se extrajeron desde sus anclajes"
else
    fail "no se pudo extraer alguno de los tres bloques"
fi
if [ "$BLOCK_PLANNER" = "$BLOCK_INVESTIGATOR" ] && [ "$BLOCK_PLANNER" = "$BLOCK_FIX_REVIEW" ]; then
    pass "los tres bloques son literalmente identicos"
else
    fail "los bloques divergen entre si"
fi

write_json() {
    local path="$1" slug="$2"
    mkdir -p "$(dirname "$path")"
    printf '{"repoSlug":"%s"}\n' "$slug" > "$path"
}

run_block() {
    # $1: bloque bash, $2: directorio raiz del repo temporal, $3: subdirectorio de trabajo relativo
    local block="$1" root="$2" subdir="$3"
    mkdir -p "$root/$subdir"
    (cd "$root/$subdir" && bash -c "$block")
}

run_matrix() {
    # $1: etiqueta, $2: bloque bash a ejecutar
    local label="$1" block="$2"

    local s1="$TMP_DIR/$label-canonico"
    mkdir -p "$s1" && (cd "$s1" && git init -q)
    write_json "$s1/.mefisto/harness.config.json" "org/fork"
    local out
    out=$(run_block "$block" "$s1" "nested/sub")
    if [ "$out" = "org/fork" ]; then
        pass "$label: solo canonico resuelve org/fork"
    else
        fail "$label: solo canonico esperaba org/fork y obtuvo '$out'"
    fi

    local s2="$TMP_DIR/$label-ambos"
    mkdir -p "$s2" && (cd "$s2" && git init -q)
    write_json "$s2/.mefisto/harness.config.json" "org/canonico"
    write_json "$s2/.claude/harness.config.json" "org/legacy"
    out=$(run_block "$block" "$s2" "nested/sub")
    if [ "$out" = "org/canonico" ]; then
        pass "$label: coexistencia prevalece el canonico"
    else
        fail "$label: coexistencia esperaba org/canonico y obtuvo '$out'"
    fi

    local s3="$TMP_DIR/$label-legacy"
    mkdir -p "$s3" && (cd "$s3" && git init -q)
    write_json "$s3/.claude/harness.config.json" "org/legacy"
    out=$(run_block "$block" "$s3" "nested/sub")
    if [ "$out" = "org/legacy" ]; then
        pass "$label: solo legacy resuelve org/legacy"
    else
        fail "$label: solo legacy esperaba org/legacy y obtuvo '$out'"
    fi

    local s4="$TMP_DIR/$label-sin-config"
    mkdir -p "$s4" && (cd "$s4" && git init -q)
    out=$(run_block "$block" "$s4" "nested/sub")
    if [ "$out" = "$DEFAULT_SLUG" ]; then
        pass "$label: sin ningun config aplica el default"
    else
        fail "$label: sin config esperaba el default y obtuvo '$out'"
    fi

    local s5="$TMP_DIR/$label-canonico-sin-campo"
    mkdir -p "$s5/.mefisto" && (cd "$s5" && git init -q)
    printf '{"projectName":"demo"}\n' > "$s5/.mefisto/harness.config.json"
    out=$(run_block "$block" "$s5" "nested/sub")
    if [ "$out" = "$DEFAULT_SLUG" ]; then
        pass "$label: canonico sin repoSlug aplica el default"
    else
        fail "$label: canonico sin repoSlug esperaba el default y obtuvo '$out'"
    fi

    local out_root out_nested
    out_root=$(cd "$s1" && bash -c "$block")
    out_nested=$(run_block "$block" "$s1" "otro/nivel/distinto")
    if [ "$out_root" = "org/fork" ] && [ "$out_nested" = "org/fork" ]; then
        pass "$label: el resultado es independiente del cwd dentro del repo"
    else
        fail "$label: el resultado cambio segun el cwd (root='$out_root', nested='$out_nested')"
    fi
}

echo "[2] Matriz de resolucion (CA-3) para planner.md"
run_matrix "planner" "$BLOCK_PLANNER"

echo "[3] Matriz de resolucion (CA-3) para tooling-investigator.md"
run_matrix "investigator" "$BLOCK_INVESTIGATOR"

echo "[4] Matriz de resolucion (CA-3) para fix-review.md"
run_matrix "fix-review" "$BLOCK_FIX_REVIEW"

echo "[5] Anti-regresion: no hay lecturas directas del legacy fuera del fallback sancionado"
SANCTIONED_LINE='cat .mefisto/harness.config.json 2>/dev/null || cat .claude/harness.config.json 2>/dev/null || echo "No existe"'
ANY_LEAK=0
for f in "$PLANNER" "$INVESTIGATOR" "$FIX_REVIEW" "$DRAFT"; do
    FILTERED=$(grep -vF "$SANCTIONED_LINE" "$f")
    if grep -Eq '(^|[;&|[:space:]])jq[[:space:]].*\.claude/harness\.config\.json' <<< "$FILTERED"; then
        fail "$(basename "$f") tiene una lectura jq directa del config legacy"
        ANY_LEAK=1
    fi
    if grep -Eq '(^|[;&|[:space:]])(cat|sed|awk|grep|python|python3)[[:space:]].*\.claude/harness\.config\.json|<[[:space:]]*[^[:space:]]*\.claude/harness\.config\.json' <<< "$FILTERED"; then
        fail "$(basename "$f") tiene una lectura directa (cat/sed/awk/grep/python/<) del config legacy fuera del fallback sancionado"
        ANY_LEAK=1
    fi
done
if [ "$ANY_LEAK" -eq 0 ]; then
    pass "ningun artefacto reintroduce una lectura directa del config legacy fuera del fallback sancionado"
fi

echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
