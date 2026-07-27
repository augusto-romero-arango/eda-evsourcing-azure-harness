#!/usr/bin/env bash
# test-release-pr-body.sh -- Tests de summarize_version_section (issue #405),
# la funcion que acota el body del PR de release (fase prepare de
# /mefisto-release) para no exceder el limite de 65536 caracteres de la API
# de GitHub.
#
#   [A] Con la seccion [0.18.0] REAL del CHANGELOG (109010+ caracteres, 1.66x
#       el limite): el resumen mantiene las 4 categorias con su conteo real y
#       el body completo del PR (template + resumen + link) queda muy por
#       debajo de 65536, sin importar el tamano de las notas originales.
#   [B] Conteo de entradas por categoria correcto sobre un ejemplo sintetico.
#   [C] Orden de salida siempre Added/Changed/Fixed/Removed, aunque el texto
#       las declare en otro orden.
#   [D] Release pequeno (1 entrada, 1 categoria): el resumen sigue siendo no
#       vacio y legible (CA-5 -- la solucion no degrada el caso comun).
#   [E] Guarda de regresion sobre el template REAL del body en
#       mefisto-release.sh: [A] mide una replica escrita a mano del body, asi
#       que por si sola no detectaria que alguien vuelva a interpolar las notas
#       integras. Este bloque lee el heredoc real y exige que NO referencie
#       RELEASE_NOTES y que SI traiga el resumen, el link al CHANGELOG y la
#       seccion "Siguiente paso" (CA-1 a CA-3).
#   [F] Robustez del conteo: las lineas "- ..." dentro de un bloque cercado
#       (```) no son entradas y no deben inflar el indice; y una seccion sin
#       subsecciones "### Categoria" produce resumen vacio, caso para el que el
#       script trae un fallback (el body nunca queda con una seccion muda).
#
# summarize_version_section vive en mefisto-release.sh, que NO es sourceable
# (ejecuta el pipeline completo -- git switch, push, gh pr create -- en su
# nivel superior). Para probar la funcion sin disparar esos efectos, se
# extrae su definicion con sed y se evalua de forma aislada.
#
# Uso: .claude/scripts/tests/test-release-pr-body.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RELEASE_SCRIPT="$REPO_ROOT/.claude/scripts/mefisto-release.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

FN_FILE=$(mktemp)
trap 'rm -f "$FN_FILE"' EXIT
sed -n '/^summarize_version_section() {/,/^}/p' "$RELEASE_SCRIPT" > "$FN_FILE"
# shellcheck source=/dev/null
source "$FN_FILE"

BODY_MAX=65536

# -------- Bloque A: seccion real (109010+ caracteres) --------

echo "[A] summarize_version_section con la seccion [0.18.0] real del CHANGELOG"

REAL_NOTES=$(python3 - "$REPO_ROOT/CHANGELOG.md" <<'PYEOF'
import re, sys
with open(sys.argv[1], encoding='utf-8') as f:
    text = f.read()
m = re.search(r'(?ms)^##\s*\[0\.18\.0\][^\n]*\n(.*?)(?=^##\s*\[|\Z)', text)
sys.stdout.write(m.group(1).strip())
PYEOF
)

if [ "${#REAL_NOTES}" -gt "$BODY_MAX" ]; then
    pass "A-0: precondicion -- la seccion [0.18.0] real (${#REAL_NOTES} caracteres) supera el limite de la API (control del bug original)"
else
    fail "A-0: la seccion [0.18.0] deberia superar $BODY_MAX caracteres (¿cambio el CHANGELOG.md de main?)"
fi

REAL_SUMMARY=$(summarize_version_section "$REAL_NOTES")

for cat in Added Changed Fixed Removed; do
    if echo "$REAL_SUMMARY" | grep -q "\\*\\*${cat}\\*\\*:"; then
        pass "A-1: el resumen incluye la categoria ${cat}"
    else
        fail "A-1: el resumen deberia incluir la categoria ${cat}"
    fi
done

REAL_BODY=$(cat <<EOF
## Resumen

PR de release v0.19.0 (minor: 0.18.0 -> 0.19.0).

- Consolida los fragmentos de changelog.d/.

## Categorias del release

${REAL_SUMMARY}

Notas completas: [CHANGELOG.md](https://github.com/owner/repo/blob/release/v0.19.0/CHANGELOG.md).

## Siguiente paso

1. /mefisto-merge <pr>
EOF
)

if [ "${#REAL_BODY}" -lt "$BODY_MAX" ]; then
    pass "A-2: el body completo del PR (${#REAL_BODY} caracteres) queda por debajo de $BODY_MAX pese a que las notas originales (${#REAL_NOTES}) lo superan"
else
    fail "A-2: el body completo del PR (${#REAL_BODY} caracteres) no deberia superar $BODY_MAX"
fi

# -------- Bloque B: conteo por categoria --------

echo ""
echo "[B] Conteo de entradas por categoria sobre un ejemplo sintetico"

SYNTH_NOTES=$(cat <<'EOF'
### Added

- entrada 1
- entrada 2
- entrada 3

### Fixed

- entrada 4
EOF
)
SYNTH_SUMMARY=$(summarize_version_section "$SYNTH_NOTES")

if echo "$SYNTH_SUMMARY" | grep -q '\*\*Added\*\*: 3 entrada(s)'; then
    pass "B-1: Added cuenta 3 entradas"
else
    fail "B-1: Added deberia contar 3 entradas -- salida: $SYNTH_SUMMARY"
fi
if echo "$SYNTH_SUMMARY" | grep -q '\*\*Fixed\*\*: 1 entrada(s)'; then
    pass "B-1: Fixed cuenta 1 entrada"
else
    fail "B-1: Fixed deberia contar 1 entrada -- salida: $SYNTH_SUMMARY"
fi
if ! echo "$SYNTH_SUMMARY" | grep -q 'Changed\|Removed'; then
    pass "B-1: categorias ausentes (Changed, Removed) no aparecen en el resumen"
else
    fail "B-1: no deberian aparecer categorias ausentes del texto original"
fi

# -------- Bloque C: orden fijo de categorias --------

echo ""
echo "[C] El orden de salida es siempre Added/Changed/Fixed/Removed"

UNORDERED_NOTES=$(cat <<'EOF'
### Removed

- se quita algo

### Added

- se agrega algo
EOF
)
UNORDERED_SUMMARY=$(summarize_version_section "$UNORDERED_NOTES")
LINE_ADDED=$(echo "$UNORDERED_SUMMARY" | grep -n 'Added' | head -1 | cut -d: -f1)
LINE_REMOVED=$(echo "$UNORDERED_SUMMARY" | grep -n 'Removed' | head -1 | cut -d: -f1)
if [ -n "$LINE_ADDED" ] && [ -n "$LINE_REMOVED" ] && [ "$LINE_ADDED" -lt "$LINE_REMOVED" ]; then
    pass "C-1: Added aparece antes que Removed aunque el texto las declare al reves"
else
    fail "C-1: el orden del resumen deberia ser fijo (Added antes que Removed)"
fi

# -------- Bloque D: release pequeno (CA-5) --------

echo ""
echo "[D] Release pequeno (1 entrada) sigue produciendo un resumen no vacio y legible"

SMALL_NOTES=$(cat <<'EOF'
### Fixed

- se corrige un bug puntual
EOF
)
SMALL_SUMMARY=$(summarize_version_section "$SMALL_NOTES")
if [ -n "$SMALL_SUMMARY" ] && echo "$SMALL_SUMMARY" | grep -q '\*\*Fixed\*\*: 1 entrada(s)'; then
    pass "D-1: un release de 1 entrada produce un resumen no vacio con el conteo correcto"
else
    fail "D-1: el resumen de un release pequeno no deberia degradar a vacio -- salida: $SMALL_SUMMARY"
fi

# -------- Bloque E: el template real del body (guarda de regresion) --------

echo ""
echo "[E] El heredoc real del body en mefisto-release.sh no vuelca las notas integras"

# Heredoc del body: desde 'cat > "$PR_BODY_FILE" <<EOF' hasta su 'EOF' de cierre.
REAL_TEMPLATE=$(sed -n '/^    cat > "\$PR_BODY_FILE" <<EOF$/,/^EOF$/p' "$RELEASE_SCRIPT")

if [ -n "$REAL_TEMPLATE" ]; then
    pass "E-0: se localizo el heredoc del body del PR en mefisto-release.sh"
else
    fail "E-0: no se localizo el heredoc del body del PR (¿cambio la forma del 'cat > \$PR_BODY_FILE'?)"
fi

if ! echo "$REAL_TEMPLATE" | grep -q 'RELEASE_NOTES'; then
    pass "E-1: el template no interpola RELEASE_NOTES (causa raiz del issue #405)"
else
    fail "E-1: el template volvio a interpolar RELEASE_NOTES -- el body excedera 65536 caracteres"
fi

for token in 'RELEASE_SUMMARY' 'CHANGELOG_LINK' '## Siguiente paso'; do
    if echo "$REAL_TEMPLATE" | grep -qF "$token"; then
        pass "E-2: el template conserva '${token}'"
    else
        fail "E-2: el template deberia conservar '${token}'"
    fi
done

# -------- Bloque F: robustez del conteo --------

echo ""
echo "[F] Bloques cercados y seccion sin categorias"

FENCED_NOTES=$(cat <<'EOF'
### Added

- entrada real con un snippet:

  ```yaml
- no soy una entrada
- yo tampoco
  ```

- segunda entrada real
EOF
)
FENCED_SUMMARY=$(summarize_version_section "$FENCED_NOTES")
if echo "$FENCED_SUMMARY" | grep -q '\*\*Added\*\*: 2 entrada(s)'; then
    pass "F-1: las lineas '- ...' dentro de un bloque cercado no cuentan como entradas"
else
    fail "F-1: Added deberia contar 2 entradas (las 2 reales, no las del snippet) -- salida: $FENCED_SUMMARY"
fi

NOCAT_SUMMARY=$(summarize_version_section "- entrada suelta sin subseccion")
if [ -z "$NOCAT_SUMMARY" ]; then
    pass "F-2: una seccion sin subsecciones '### Categoria' produce resumen vacio"
else
    fail "F-2: sin '### Categoria' el resumen deberia ser vacio -- salida: $NOCAT_SUMMARY"
fi

if grep -q 'if \[ -z "\$RELEASE_SUMMARY" \]; then' "$RELEASE_SCRIPT"; then
    pass "F-2: mefisto-release.sh trae el fallback para resumen vacio (el body no queda con una seccion muda)"
else
    fail "F-2: falta en mefisto-release.sh la guarda de resumen vacio"
fi

# -------- Resumen --------

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
