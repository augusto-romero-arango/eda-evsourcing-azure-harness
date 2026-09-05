#!/usr/bin/env bash
# test-agents-md-shim.sh -- Tests del shim CLAUDE.md -> AGENTS.md (issue #855, MEF-ADR-0049 CA-3).
#
# AGENTS.md es la fuente canonica de las directivas del repo (doctrina neutral a
# runtime); CLAUDE.md queda como shim de compatibilidad que la importa via
# `@AGENTS.md` (sintaxis de imports de Claude Code, ver Referencias en AGENTS.md).
# Este test evita que alguien vuelva a poblar CLAUDE.md con doctrina duplicada.
#
#   [A] CLAUDE.md: <= 10 lineas y exactamente una linea `@AGENTS.md`.
#   [B] AGENTS.md: existe, no esta vacio y contiene los encabezados obligatorios.
#   [C] AGENTS.md: ninguna linea presenta a Claude Code como runtime unico (las
#       3 frases retiradas por este issue).
#
# Uso: .claude/scripts/tests/test-agents-md-shim.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
AGENTS_MD="$REPO_ROOT/AGENTS.md"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# -------- Bloque A: CLAUDE.md es un shim minimo --------

echo "[A] CLAUDE.md es un shim de compatibilidad de <= 10 lineas"
if [ -f "$CLAUDE_MD" ]; then
    pass "CLAUDE.md existe"

    LINE_COUNT=$(wc -l < "$CLAUDE_MD" | tr -d ' ')
    if [ "$LINE_COUNT" -le 10 ]; then
        pass "CLAUDE.md tiene $LINE_COUNT lineas (<= 10)"
    else
        fail "CLAUDE.md tiene $LINE_COUNT lineas (esperaba <= 10): dejo de ser un shim"
    fi

    IMPORT_LINES=$(grep -c '^@AGENTS\.md$' "$CLAUDE_MD")
    if [ "$IMPORT_LINES" -eq 1 ]; then
        pass "CLAUDE.md contiene exactamente una linea '@AGENTS.md'"
    else
        fail "CLAUDE.md contiene $IMPORT_LINES lineas '@AGENTS.md' (esperaba exactamente 1)"
    fi
else
    fail "CLAUDE.md no existe: el import de Claude Code hacia AGENTS.md no cargaria"
fi

# -------- Bloque B: AGENTS.md es la fuente canonica completa --------

echo ""
echo "[B] AGENTS.md existe, no esta vacio y trae las secciones obligatorias"
if [ -s "$AGENTS_MD" ]; then
    pass "AGENTS.md existe y no esta vacio"
else
    fail "AGENTS.md no existe o esta vacio: la doctrina canonica desaparecio"
fi

for header in \
    "## Principios de respuesta" \
    "## Convenciones del marco" \
    "## Dos paquetes de tooling: publicado vs interno" \
    "## Trabajar sobre el propio plugin"
do
    if grep -qF "$header" "$AGENTS_MD" 2>/dev/null; then
        pass "AGENTS.md contiene el encabezado '$header'"
    else
        fail "AGENTS.md no contiene el encabezado '$header'"
    fi
done

# -------- Bloque C: las frases retiradas no reaparecen --------

echo ""
echo "[C] AGENTS.md no presenta a Claude Code como runtime unico"
for frase in \
    "Claude Code carga" \
    "Es un **Claude Code Plugin**" \
    "Harness opinionado para Claude Code"
do
    if grep -qF "$frase" "$AGENTS_MD" 2>/dev/null; then
        fail "AGENTS.md todavia contiene la frase retirada '$frase'"
    else
        pass "AGENTS.md no contiene '$frase'"
    fi
done

echo ""
echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
