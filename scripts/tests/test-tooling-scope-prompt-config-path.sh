#!/usr/bin/env bash
# test-tooling-scope-prompt-config-path.sh -- Contrato de config canonico en los
# prompts de ALCANCE PERMITIDO de tooling-pipeline.sh (#1512).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/tooling-pipeline.sh"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "[1] Ambos prompts nombran el config canonico"
CANONICAL_COUNT=$(grep -Fc '.mefisto/harness.config.json' "$SCRIPT")
if [ "$CANONICAL_COUNT" -ge 2 ]; then
    pass ".mefisto/harness.config.json aparece en ambos prompts ($CANONICAL_COUNT ocurrencias)"
else
    fail ".mefisto/harness.config.json aparece menos de 2 veces ($CANONICAL_COUNT)"
fi

echo "[2] Ninguna linea nombra el config legacy sin el calificativo 'legacy'"
UNQUALIFIED=$(grep -n '\.claude/harness\.config\.json' "$SCRIPT" | grep -v 'legacy' || true)
if [ -z "$UNQUALIFIED" ]; then
    pass "toda mencion de .claude/harness.config.json lleva 'legacy' en la misma linea"
else
    fail "mencion sin calificar 'legacy': $UNQUALIFIED"
fi

echo "[3] El canonico aparece antes que el legacy en el prompt del writer"
WRITER_CANONICAL_LINE=$(grep -n '\.mefisto/harness\.config\.json' "$SCRIPT" | head -1 | cut -d: -f1)
WRITER_LEGACY_LINE=$(grep -n '\.claude/harness\.config\.json' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -n "$WRITER_CANONICAL_LINE" ] && [ -n "$WRITER_LEGACY_LINE" ] && [ "$WRITER_CANONICAL_LINE" -lt "$WRITER_LEGACY_LINE" ]; then
    pass "canonico (linea $WRITER_CANONICAL_LINE) antes que legacy (linea $WRITER_LEGACY_LINE)"
else
    fail "orden inesperado: canonico=$WRITER_CANONICAL_LINE legacy=$WRITER_LEGACY_LINE"
fi

echo "[4] El reviewer conserva la nota 'igual al del writer'"
if grep -Fq 'igual al del writer' "$SCRIPT"; then
    pass "nota de paridad presente"
else
    fail "no se encontro 'igual al del writer'"
fi

echo "[5] Gate y prompt siguen coherentes: is_path_in_consumer_blocklist no bloquea ninguna ruta"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/_pipeline-common.sh"

if is_path_in_consumer_blocklist ".mefisto/harness.config.json"; then
    fail "is_path_in_consumer_blocklist bloquea .mefisto/harness.config.json (deberia devolver 1)"
else
    pass "is_path_in_consumer_blocklist no bloquea .mefisto/harness.config.json"
fi

if is_path_in_consumer_blocklist ".claude/harness.config.json"; then
    fail "is_path_in_consumer_blocklist bloquea .claude/harness.config.json (deberia devolver 1)"
else
    pass "is_path_in_consumer_blocklist no bloquea .claude/harness.config.json"
fi

echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
