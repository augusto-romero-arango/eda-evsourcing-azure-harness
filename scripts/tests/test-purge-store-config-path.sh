#!/usr/bin/env bash
# test-purge-store-config-path.sh -- Contrato de config de purge-store.sh (#1502).
# El resolver del comando /purge-store paso a {{mefisto:config-path}} (#1674) y lo
# cubre test-purge-store-command.sh; aqui queda el lado del script.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/purge-store.sh"
SOURCE="$REPO_ROOT/src/published/commands/purge-store.md"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "[1] Anti-regresion de lecturas y mensajes legacy del script"
if grep -Eq '(^|[;&|[:space:]])jq[[:space:]].*\.claude/harness\.config\.json|(^|[;&|[:space:]])(cat|sed|awk|grep)[[:space:]].*\.claude/harness\.config\.json|<[[:space:]]*[^[:space:]]*\.claude/harness\.config\.json' "$SCRIPT"; then
    fail "reaparecio una lectura directa del config legacy"
else
    pass "no hay lecturas directas del config legacy"
fi
if grep -Eq 'jq[[:space:]].*\.(mefisto|claude)/harness\.config\.json' "$SCRIPT" "$SOURCE"; then
    fail "alguna lectura jq evita la ruta efectiva del config"
else
    pass "las lecturas jq usan la ruta efectiva del config"
fi
if grep -Fq 'de .claude/harness.config.json' "$SCRIPT"; then
    fail "el error de dominio del script no usa HARNESS_CONFIG_PATH"
else
    pass "el error de dominio del script usa la ruta efectiva"
fi
if grep -E '^[[:space:]]*echo .*\.claude/harness\.config\.json' "$SCRIPT" \
    | grep -Ev 'fallback|se ignora el legacy|Se acepta solo para lectura' >/dev/null; then
    fail "un mensaje de usuario nombra el legacy sin calificarlo"
else
    pass "los mensajes de usuario califican la ruta legacy"
fi
if grep -Fq 'fallback' "$SCRIPT" \
    && grep -Fq 'legacy solo de lectura en .claude/harness.config.json' "$SCRIPT"; then
    pass "la prosa del script califica la ruta legacy como fallback de lectura"
else
    fail "la prosa del script no califica la ruta legacy como fallback de lectura"
fi

echo "[2] Sintaxis del script"
if bash -n "$SCRIPT"; then
    pass "purge-store.sh pasa bash -n"
else
    fail "purge-store.sh no pasa bash -n"
fi

echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
