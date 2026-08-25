#!/usr/bin/env bash
# test-herdr-workspace.sh -- Tests de las funciones puras de
# herdr-workspace.sh (issue #691): derivacion del slug de agentes y
# seleccion del planner por tipo de repo.
#
# Estilo test-stream-watch.sh: se extrae SOLO el cuerpo de cada funcion (awk
# sobre "nombre() {" .. "}" en columna 0) y se evalua en este proceso, sin
# sourcing el archivo completo (su main llama a herdr; estas piezas no).
#
# Casos cubiertos:
#   [pre] Las funciones bajo prueba se pueden extraer y cargar.
#   [A] workspace_slug: minusculas, caracteres raros a '-', sin guiones en
#       los extremos, tope de 20 caracteres (los nombres de agente de herdr
#       admiten 32 y el prefijo mas largo ocupa 10).
#   [B] planner_agent_for_repo: mefisto-planner en el repo del plugin
#       (.claude-plugin/plugin.json presente), mefisto:planner en un consumidor.
#
# Uso: scripts/tests/test-herdr-workspace.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/herdr-workspace.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

extract_fn() {
    local name="$1" file="$2"
    awk -v fn="$name" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p{print} p && /^}/{p=0}' "$file"
}

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "[pre] Las funciones bajo prueba se pueden extraer y cargar desde herdr-workspace.sh"
ALL_LOADED=1
for fn in workspace_slug planner_agent_for_repo; do
    body=$(extract_fn "$fn" "$TARGET")
    if [ -n "$body" ]; then
        eval "$body"
        if declare -F "$fn" >/dev/null; then
            pass "$fn definida y cargable"
        else
            fail "$fn: eval no la dejo definida"
            ALL_LOADED=0
        fi
    else
        fail "$fn: no se pudo extraer el cuerpo"
        ALL_LOADED=0
    fi
done

if [ "$ALL_LOADED" -ne 1 ]; then
    echo "Abortando: no se pudieron cargar todas las funciones bajo prueba."
    exit 1
fi

# -------- Bloque A: workspace_slug --------

echo ""
echo "[A] workspace_slug: minusculas, caracteres raros a '-', extremos limpios, tope de 20"

SLUG_A1=$(workspace_slug "Bitakora.ControlAsistencia")
if [ "$SLUG_A1" = "bitakora-controlasis" ] && [ "${#SLUG_A1}" -le 20 ]; then
    pass "A-1: 'Bitakora.ControlAsistencia' -> '$SLUG_A1' (minusculas, punto a guion, 20 max)"
else
    fail "A-1: slug inesperado para el nombre real de un consumidor: '$SLUG_A1'"
fi

SLUG_A2=$(workspace_slug "eda-evsourcing-azure-harness")
if [ "$SLUG_A2" = "eda-evsourcing-azure" ] && [ "${#SLUG_A2}" -le 20 ]; then
    pass "A-2: el nombre del repo de Mefisto se trunca a 20 sin guion colgante"
else
    fail "A-2: slug inesperado para el repo de Mefisto: '$SLUG_A2'"
fi

SLUG_A3=$(workspace_slug "__Mi  Proyecto!!")
case "$SLUG_A3" in
    -*|*-) fail "A-3: el slug conserva guiones en los extremos: '$SLUG_A3'" ;;
    mi-proyecto) pass "A-3: espacios y simbolos colapsan a '-' y los extremos quedan limpios" ;;
    *) fail "A-3: slug inesperado: '$SLUG_A3'" ;;
esac

SLUG_A4=$(workspace_slug "abc")
if [ "$SLUG_A4" = "abc" ]; then
    pass "A-4: un nombre ya valido se devuelve intacto"
else
    fail "A-4: se esperaba 'abc', se obtuvo '$SLUG_A4'"
fi

# -------- Bloque B: planner_agent_for_repo --------

echo ""
echo "[B] planner_agent_for_repo: interno con plugin.json, publicado sin el"

mkdir -p "$TMP/mefisto/.claude-plugin" "$TMP/consumidor"
echo '{}' > "$TMP/mefisto/.claude-plugin/plugin.json"

if [ "$(planner_agent_for_repo "$TMP/mefisto")" = "mefisto-planner" ]; then
    pass "B-1: con .claude-plugin/plugin.json el planner es el interno (mefisto-planner)"
else
    fail "B-1: se esperaba mefisto-planner, se obtuvo '$(planner_agent_for_repo "$TMP/mefisto")'"
fi

if [ "$(planner_agent_for_repo "$TMP/consumidor")" = "mefisto:planner" ]; then
    pass "B-2: sin plugin.json el planner es el publicado calificado por plugin (mefisto:planner)"
else
    fail "B-2: se esperaba mefisto:planner, se obtuvo '$(planner_agent_for_repo "$TMP/consumidor")'"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
