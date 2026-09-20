#!/usr/bin/env bash
# test-readme-consumer-contract.sh -- Contrato canonico .mefisto/harness.config.json en README.md (#1518).
#
# Grep puro sobre README.md: ninguna instruccion de instalacion/onboarding debe
# nacer legacy (MEF-ADR-0053 decision 4). Verifica que toda mencion superviviente
# de la ruta legacy sea explicitamente de fallback/migracion, que el canonico
# aparezca lo suficiente, la regla de .gitignore de .mefisto/pipeline/ (igual que
# scripts/onboard-diagnose.sh) y el enlace al indice tematico de ADRs.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
README="$REPO_ROOT/README.md"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "[1] Toda mencion del config legacy en README declara ser legacy/fallback"
LEGACY_LINES=$(grep -n '\.claude/harness\.config\.json' "$README" || true)
if [ -z "$LEGACY_LINES" ]; then
    fail "no se encontro ninguna mencion del config legacy (se esperaba al menos la subseccion de migracion)"
else
    BAD=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        text="${line#*:}"
        if ! printf '%s' "$text" | grep -qi 'legacy\|fallback'; then
            echo "    linea sin 'legacy'/'fallback': $line"
            BAD=1
        fi
    done <<< "$LEGACY_LINES"
    if [ "$BAD" -eq 0 ]; then
        pass "cada linea con el config legacy incluye 'legacy' o 'fallback'"
    else
        fail "hay lineas con el config legacy sin marcarlo como legacy/fallback"
    fi
fi

echo "[2] El canonico .mefisto/harness.config.json aparece al menos 6 veces"
CANONICAL_COUNT=$(grep -c '\.mefisto/harness\.config\.json' "$README" || true)
if [ "$CANONICAL_COUNT" -ge 6 ]; then
    pass "aparece $CANONICAL_COUNT veces"
else
    fail "aparece solo $CANONICAL_COUNT veces (se esperaban >= 6)"
fi

echo "[3] Instruccion de .gitignore: ignora .mefisto/pipeline/, nunca .mefisto/ completo"
if grep -Fq '.mefisto/pipeline/' "$README" && grep -Fq '.gitignore' "$README"; then
    pass "el README menciona .mefisto/pipeline/ y .gitignore"
else
    fail "falta la mencion de .mefisto/pipeline/ o .gitignore"
fi
BAD_IGNORE_LINES=$(grep -E "ignor(a|es|ar)[^.]*\`?\.mefisto/\`?[[:space:]]+completo" "$README" | grep -vi 'nunca\|no ignores' || true)
if [ -n "$BAD_IGNORE_LINES" ]; then
    fail "el README sigue instruyendo ignorar .mefisto/ completo: $BAD_IGNORE_LINES"
else
    pass "el README no instruye ignorar .mefisto/ completo (solo lo niega explicitamente)"
fi
if grep -Fq 'nunca ignores `.mefisto/` completo' "$README"; then
    pass "el paso 3 aclara explicitamente que no se ignora .mefisto/ completo"
else
    fail "falta la aclaracion explicita de no ignorar .mefisto/ completo"
fi

echo "[4] Indice tematico de ADRs enlaza a docs/adr/INDICE-TEMATICO.md"
if grep -Fq 'docs/adr/INDICE-TEMATICO.md' "$README"; then
    pass "el README enlaza docs/adr/INDICE-TEMATICO.md"
else
    fail "el README no enlaza docs/adr/INDICE-TEMATICO.md"
fi
if grep -Fq 'índice temático en `CLAUDE.md`' "$README"; then
    fail "sigue remitiendo el indice tematico a CLAUDE.md"
else
    pass "ya no remite el indice tematico a CLAUDE.md"
fi
if [ ! -f "$REPO_ROOT/docs/adr/INDICE-TEMATICO.md" ]; then
    fail "docs/adr/INDICE-TEMATICO.md no existe"
else
    pass "docs/adr/INDICE-TEMATICO.md existe"
fi

echo "[5] Subseccion de migracion del config al canonico"
if grep -Fq '### Migrar el config al canónico `.mefisto/harness.config.json`' "$README" \
    && grep -Fq 'git mv .claude/harness.config.json .mefisto/harness.config.json' "$README" \
    && grep -Fq '/mefisto:onboard' "$README"; then
    pass "existe la subseccion de migracion con git mv y /mefisto:onboard"
else
    fail "falta la subseccion de migracion del config al canonico"
fi

echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
