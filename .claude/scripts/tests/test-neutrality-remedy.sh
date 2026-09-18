#!/usr/bin/env bash
# test-neutrality-remedy.sh -- Tests de mefisto_neutrality_remedy
# (src/internal/scripts/lib/_mefisto-common.sh, issue #1469).
#
# Cubre:
#   [una-regla]     Una sola violacion de una regla de texto produce
#                   exactamente una linea de remedio para esa regla.
#   [mezcla]        Varias reglas mezcladas y en orden aleatorio en la
#                   entrada salen deduplicadas y en el orden fijo
#                   R1, R2, R3, R4, adapters-check.
#   [R4]            Una violacion R4 produce su propio remedio (restaurar el
#                   shim o registrar not_migrated), distinto del de R1-R3.
#   [adapters-check] Las dos formas de violacion de adapters-check ("<ruta>:
#                   <estado>: adapters-check" y la generica de exit sin
#                   lineas) producen la MISMA (unica) linea de remedio.
#   [desconocido]   Un sufijo de regla no reconocido produce una linea
#                   generica propia, sin tocar las reglas conocidas.
#   [vacio]         Entrada vacia no emite nada y retorna 0.
#
# Uso: .claude/scripts/tests/test-neutrality-remedy.sh
# Exit code: 0 si todos los checks pasan, 1 si alguno falla.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/src/internal/scripts/lib/_mefisto-common.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# --- [una-regla] -------------------------------------------------------------
echo "[una-regla] una sola violacion R1 produce exactamente una linea, con el prefijo 'R1:'"

OUT_R1="$(printf 'src/internal/agents/fx-leak.md:3: R1\n' | mefisto_neutrality_remedy)"
RC=$?
N_LINES=$(printf '%s\n' "$OUT_R1" | grep -c .)
if [ "$RC" -eq 0 ] && [ "$N_LINES" -eq 1 ] && printf '%s' "$OUT_R1" | grep -q '^R1:'; then
    pass "una-regla-1: R1 sola -> una linea que empieza con 'R1:' (rc=0)"
else
    fail "una-regla-1: esperado rc=0, 1 linea con prefijo 'R1:'; obtuve rc=$RC lineas=$N_LINES out=[$OUT_R1]"
fi

# --- [mezcla] ----------------------------------------------------------------
echo ""
echo "[mezcla] reglas mezcladas y desordenadas -> deduplicadas, orden fijo R1,R2,R3,R4,adapters-check"

MIXED_INPUT='src/internal/scripts/generate-internal-adapters.sh: exit 1 sin lineas de divergencia: adapters-check
src/internal/agents/b.md:9: R3
src/internal/agents/a.md:5: R1
.claude/scripts/mefisto-x.sh:1: R4
src/internal/agents/a2.md:6: R1
src/internal/scripts/foo.sh:2: R2
src/internal/agents/b2.md:10: R3'

OUT_MIXED="$(printf '%s\n' "$MIXED_INPUT" | mefisto_neutrality_remedy)"
EXPECTED_PREFIXES="R1: R2: R3: R4: adapters-check:"
ACTUAL_PREFIXES="$(printf '%s\n' "$OUT_MIXED" | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
if [ "$ACTUAL_PREFIXES" = "$EXPECTED_PREFIXES" ]; then
    pass "mezcla-1: orden y deduplicacion correctos ($ACTUAL_PREFIXES)"
else
    fail "mezcla-1: orden/deduplicacion incorrectos -- esperado [$EXPECTED_PREFIXES] obtuve [$ACTUAL_PREFIXES]"
fi

N_MIXED_LINES=$(printf '%s\n' "$OUT_MIXED" | grep -c .)
if [ "$N_MIXED_LINES" -eq 5 ]; then
    pass "mezcla-2: exactamente 5 lineas (una por regla presente, sin repetir R1/R3)"
else
    fail "mezcla-2: esperaba 5 lineas, obtuve $N_MIXED_LINES: [$OUT_MIXED]"
fi

# --- [R4] ----------------------------------------------------------------
echo ""
echo "[R4] una violacion R4 sola produce su propio remedio (shim/not_migrated)"

OUT_R4="$(printf '.claude/scripts/mefisto-x.sh:1: R4\n' | mefisto_neutrality_remedy)"
if printf '%s' "$OUT_R4" | grep -qi 'not_migrated'; then
    pass "R4-1: el remedio de R4 menciona 'not_migrated' como alternativa a restaurar el shim"
else
    fail "R4-1: el remedio de R4 no menciona 'not_migrated': [$OUT_R4]"
fi
if ! printf '%s' "$OUT_R4" | grep -q 'reformula la mencion'; then
    pass "R4-2: el remedio de R4 no reutiliza el texto de 'reformula la mencion' de R1-R3"
else
    fail "R4-2: el remedio de R4 reutilizo el texto de R1-R3: [$OUT_R4]"
fi

# --- [adapters-check] ---------------------------------------------------------
echo ""
echo "[adapters-check] las dos formas de violacion producen la MISMA linea de remedio"

OUT_ADAPTERS_A="$(printf '.claude/agents/fx-agent.md: distinta: adapters-check\n' | mefisto_neutrality_remedy)"
OUT_ADAPTERS_B="$(printf 'src/internal/scripts/generate-internal-adapters.sh: exit 2 sin lineas de divergencia: adapters-check\n' | mefisto_neutrality_remedy)"
if [ "$OUT_ADAPTERS_A" = "$OUT_ADAPTERS_B" ] && [ -n "$OUT_ADAPTERS_A" ]; then
    pass "adapters-check-1: la forma '<ruta>: <estado>: adapters-check' y la generica de exit producen la misma linea"
else
    fail "adapters-check-1: las dos formas deberian producir la misma linea -- a=[$OUT_ADAPTERS_A] b=[$OUT_ADAPTERS_B]"
fi
if printf '%s' "$OUT_ADAPTERS_A" | grep -qF -- '--check'; then
    pass "adapters-check-2: el remedio menciona regenerar sin --check"
else
    fail "adapters-check-2: el remedio no menciona '--check': [$OUT_ADAPTERS_A]"
fi

# --- [desconocido] -------------------------------------------------------------
echo ""
echo "[desconocido] un sufijo de regla no reconocido produce una linea generica propia"

OUT_UNKNOWN="$(printf 'src/internal/foo.md:1: R99\n' | mefisto_neutrality_remedy)"
N_UNKNOWN_LINES=$(printf '%s\n' "$OUT_UNKNOWN" | grep -c .)
if [ "$N_UNKNOWN_LINES" -eq 1 ] && printf '%s' "$OUT_UNKNOWN" | grep -qF 'R99'; then
    pass "desconocido-1: una linea generica que nombra la regla no reconocida (R99)"
else
    fail "desconocido-1: esperaba 1 linea generica mencionando R99, obtuve: [$OUT_UNKNOWN]"
fi
if printf '%s' "$OUT_UNKNOWN" | grep -qF 'mefisto-neutrality-gate.sh'; then
    pass "desconocido-2: la linea generica remite a mefisto-neutrality-gate.sh"
else
    fail "desconocido-2: la linea generica no remite al gate: [$OUT_UNKNOWN]"
fi

OUT_UNKNOWN_MIX="$(printf 'a.md:1: R1\nb.md:2: R99\n' | mefisto_neutrality_remedy)"
N_UNKNOWN_MIX_LINES=$(printf '%s\n' "$OUT_UNKNOWN_MIX" | grep -c .)
if [ "$N_UNKNOWN_MIX_LINES" -eq 2 ]; then
    pass "desconocido-3: una regla conocida (R1) y una desconocida (R99) mezcladas dan 2 lineas"
else
    fail "desconocido-3: esperaba 2 lineas, obtuve $N_UNKNOWN_MIX_LINES: [$OUT_UNKNOWN_MIX]"
fi

# --- [vacio] -------------------------------------------------------------------
echo ""
echo "[vacio] entrada vacia no emite nada y retorna 0"

OUT_EMPTY="$(printf '' | mefisto_neutrality_remedy)"
RC_EMPTY=$?
if [ "$RC_EMPTY" -eq 0 ] && [ -z "$OUT_EMPTY" ]; then
    pass "vacio-1: sin salida y rc=0 con entrada vacia"
else
    fail "vacio-1: esperaba rc=0 y sin salida, obtuve rc=$RC_EMPTY out=[$OUT_EMPTY]"
fi

echo ""
echo "== Resultado: $PASS pass, $FAIL fail =="
[ "$FAIL" -eq 0 ]
