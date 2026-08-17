#!/usr/bin/env bash
# test-harness-version.sh -- Tests de get_harness_version y su cableado en los
# tres pipelines publicados (issue #660).
#
# Contexto: pipeline-history.jsonl no registraba con que version del plugin
# corrio cada pipeline -- el unico rastro de version (.claude/pipeline/.plugin-root)
# es un snapshot que el hook SessionStart sobreescribe en cada arranque, y no
# permite reconstruir la version de corridas historicas. Este issue agrega:
#
#   - get_harness_version (scripts/_pipeline-common.sh): imprime el '.version'
#     de .claude-plugin/plugin.json, ubicado relativo al propio script (via
#     _pc_script_dir) y no al cwd del pipeline. Con jq, lee '.version'; sin
#     jq, degrada a extraccion con sed; si nada funciona o el archivo no
#     existe, imprime cadena vacia. Nunca aborta, siempre retorna 0.
#   - HARNESS_VERSION/HARNESS_VERSION_JSON calculados UNA vez en el prologo de
#     tdd-pipeline.sh/tooling-pipeline.sh/iac-pipeline.sh (CA-3), interpolados
#     como "harness_version":<string o null> en las 6 escrituras de
#     pipeline-history.jsonl (feliz + aborto x 3 pipelines, CA-2).
#
# Las pruebas de get_harness_version usan un fixture propio (copia de
# _pipeline-common.sh + un .claude-plugin/plugin.json de prueba en un dir
# temporal) para poder variar el contenido/ausencia de plugin.json sin tocar
# el plugin.json real del repo -- _pc_script_dir resuelve SIEMPRE relativo al
# BASH_SOURCE del archivo sourceado, así que sourcear la copia en el fixture
# hace que get_harness_version mire el plugin.json del fixture.
#
# Casos cubiertos:
#   [pre] get_harness_version esta definida en scripts/_pipeline-common.sh.
#   [A] con jq: plugin.json con version valida -> la imprime tal cual.
#   [B] con jq: plugin.json sin campo 'version' -> cadena vacia (CA-1).
#   [C] sin jq en PATH: fallback con sed extrae la misma version (CA-1).
#   [D] plugin.json ausente: cadena vacia, exit 0, nunca aborta (CA-1).
#   [E] smoke test contra el plugin.json REAL del repo (con y sin jq).
#   [F] cableado: HARNESS_VERSION se calcula UNA sola vez en el prologo de
#       cada pipeline, no dentro de la funcion abort() (CA-3).
#   [G] cableado: el campo "harness_version" aparece en las 6 escrituras de
#       pipeline-history.jsonl (feliz + aborto x tdd/tooling/iac, CA-2).
#   [H] un caller con 'set -euo pipefail' (como los tres pipelines) sobrevive
#       a plugin.json ausente: HARNESS_VERSION queda vacia y el script sigue
#       corriendo, en vez de morir en el prologo (CA-1).
#   [I] retrocompatibilidad: metrics-report.sh agrega sin cambios un historial
#       mixto de lineas legadas (sin el campo) y nuevas (con el campo) --
#       nada se migra ni se reescribe (CA-4).
#
# Uso: scripts/tests/test-harness-version.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# -------- Bloque pre: la funcion existe --------

echo "[pre] get_harness_version esta definida en scripts/_pipeline-common.sh"
if declare -F get_harness_version >/dev/null; then
    pass "get_harness_version definida"
else
    fail "get_harness_version NO definida"
fi

# -------- Fixture: copia de _pipeline-common.sh + plugin.json de prueba --------
#
# FIXTURE/scripts/_pipeline-common.sh (copia) + FIXTURE/.claude-plugin/plugin.json
# -- misma forma relativa que el plugin real (scripts/ y .claude-plugin/ hermanos).

FIXTURE="$TMP/fixture"
mkdir -p "$FIXTURE/scripts" "$FIXTURE/.claude-plugin"
cp "$REPO_ROOT/scripts/_pipeline-common.sh" "$FIXTURE/scripts/_pipeline-common.sh"

# -------- Bloque A: con jq, version valida --------

echo ""
echo "[A] con jq: plugin.json con version valida -> la imprime tal cual"

cat > "$FIXTURE/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "mefisto",
  "version": "9.9.9"
}
EOF

if command -v jq >/dev/null 2>&1; then
    A_OUT=$(bash -c "source '$FIXTURE/scripts/_pipeline-common.sh'; get_harness_version")
    A_RC=$?
    if [ "$A_RC" -eq 0 ] && [ "$A_OUT" = "9.9.9" ]; then
        pass "A-1: version leida via jq"
    else
        fail "A-1: se esperaba '9.9.9' rc=0, se obtuvo rc=$A_RC salida='$A_OUT'"
    fi
else
    echo "  SKIP: jq no disponible en este entorno"
fi

# -------- Bloque B: con jq, sin campo 'version' --------

echo ""
echo "[B] con jq: plugin.json sin campo 'version' -> cadena vacia (CA-1)"

cat > "$FIXTURE/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "mefisto"
}
EOF

if command -v jq >/dev/null 2>&1; then
    B_OUT=$(bash -c "source '$FIXTURE/scripts/_pipeline-common.sh'; get_harness_version")
    B_RC=$?
    if [ "$B_RC" -eq 0 ] && [ "$B_OUT" = "" ]; then
        pass "B-1: sin campo 'version' -> exit 0 y cadena vacia"
    else
        fail "B-1: se esperaba exit 0 y vacio, se obtuvo rc=$B_RC salida='$B_OUT'"
    fi
else
    echo "  SKIP: jq no disponible en este entorno"
fi

# -------- Bloque C: sin jq en PATH, fallback con sed --------

echo ""
echo "[C] sin jq en PATH: el fallback con sed extrae la misma version (CA-1)"

cat > "$FIXTURE/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "mefisto",
  "version": "1.2.3",
  "description": "algo con la palabra version adentro"
}
EOF

BIN_SIN_JQ="$TMP/bin-sin-jq"
mkdir -p "$BIN_SIN_JQ"
C_OUT=$(env PATH="$BIN_SIN_JQ:/bin:/usr/bin" bash -c "source '$FIXTURE/scripts/_pipeline-common.sh'; get_harness_version")
C_RC=$?
if [ "$C_RC" -eq 0 ] && [ "$C_OUT" = "1.2.3" ]; then
    pass "C-1: fallback con sed sin jq -> '1.2.3'"
else
    fail "C-1: se esperaba exit 0 y '1.2.3', se obtuvo rc=$C_RC salida='$C_OUT'"
fi

# -------- Bloque D: plugin.json ausente --------

echo ""
echo "[D] plugin.json ausente -> cadena vacia, exit 0, nunca aborta (CA-1)"

rm -f "$FIXTURE/.claude-plugin/plugin.json"
D_OUT=$(bash -c "source '$FIXTURE/scripts/_pipeline-common.sh'; get_harness_version")
D_RC=$?
if [ "$D_RC" -eq 0 ] && [ "$D_OUT" = "" ]; then
    pass "D-1: plugin.json ausente -> exit 0 y cadena vacia"
else
    fail "D-1: se esperaba exit 0 y vacio, se obtuvo rc=$D_RC salida='$D_OUT'"
fi

# -------- Bloque E: smoke test contra el plugin.json REAL del repo --------

echo ""
echo "[E] smoke test contra .claude-plugin/plugin.json real del repo"

REAL_VERSION=""
if command -v jq >/dev/null 2>&1; then
    REAL_VERSION=$(jq -r '.version // ""' "$REPO_ROOT/.claude-plugin/plugin.json" 2>/dev/null)
fi

if [ -n "$REAL_VERSION" ]; then
    E1_OUT=$(get_harness_version)
    if [ "$E1_OUT" = "$REAL_VERSION" ]; then
        pass "E-1: con jq, get_harness_version coincide con el plugin.json real ($REAL_VERSION)"
    else
        fail "E-1: se esperaba '$REAL_VERSION', se obtuvo '$E1_OUT'"
    fi

    E2_OUT=$(env PATH="$BIN_SIN_JQ:/bin:/usr/bin" bash -c "source '$REPO_ROOT/scripts/_pipeline-common.sh'; get_harness_version")
    if [ "$E2_OUT" = "$REAL_VERSION" ]; then
        pass "E-2: sin jq, el fallback con sed tambien coincide ($REAL_VERSION)"
    else
        fail "E-2: se esperaba '$REAL_VERSION' via sed, se obtuvo '$E2_OUT'"
    fi
else
    echo "  SKIP: no se pudo leer la version real (jq ausente o plugin.json sin 'version')"
fi

# -------- Bloque F: HARNESS_VERSION se calcula UNA vez en el prologo (CA-3) --------

echo ""
echo "[F] HARNESS_VERSION se calcula UNA vez en el prologo, no dentro de abort() (CA-3)"

for pipe in tdd-pipeline.sh tooling-pipeline.sh iac-pipeline.sh; do
    PIPE_PATH="$REPO_ROOT/scripts/$pipe"
    occurrences=$(grep -c 'HARNESS_VERSION="\$(get_harness_version)"' "$PIPE_PATH")
    if [ "$occurrences" = "1" ]; then
        pass "F-1 ($pipe): HARNESS_VERSION se asigna exactamente una vez"
    else
        fail "F-1 ($pipe): se esperaba 1 asignacion, se encontraron $occurrences"
    fi

    # La asignacion debe quedar ANTES de la definicion de abort() -- si cayera
    # dentro del cuerpo de abort() se recalcularia (y potencialmente fallaria)
    # en cada aborto en vez de una sola vez en el prologo.
    assign_line=$(grep -n 'HARNESS_VERSION="\$(get_harness_version)"' "$PIPE_PATH" | head -n1 | cut -d: -f1)
    abort_line=$(grep -n '^abort() {' "$PIPE_PATH" | head -n1 | cut -d: -f1)
    if [ -n "$assign_line" ] && [ -n "$abort_line" ] && [ "$assign_line" -lt "$abort_line" ]; then
        pass "F-2 ($pipe): la asignacion vive antes de la definicion de abort()"
    else
        fail "F-2 ($pipe): la asignacion (linea $assign_line) no antecede a abort() (linea $abort_line)"
    fi
done

# -------- Bloque G: el campo "harness_version" viaja en las 6 escrituras (CA-2) --------

echo ""
echo "[G] \"harness_version\" aparece en las 6 escrituras de pipeline-history.jsonl (CA-2)"

for pipe in tdd-pipeline.sh tooling-pipeline.sh iac-pipeline.sh; do
    PIPE_PATH="$REPO_ROOT/scripts/$pipe"
    field_count=$(grep -c '\\"harness_version\\"' "$PIPE_PATH")
    if [ "$field_count" = "2" ]; then
        pass "G-1 ($pipe): harness_version aparece en las 2 escrituras (feliz + aborto)"
    else
        fail "G-1 ($pipe): se esperaban 2 apariciones de harness_version, se encontraron $field_count"
    fi
done

# -------- Bloque H: un caller con 'set -euo pipefail' no muere (CA-1) --------
#
# Los tres pipelines corren con 'set -euo pipefail' y toman el valor por
# sustitucion de comando en su prologo. "Nunca aborta" no es una propiedad de
# la funcion aislada sino de esa combinacion: basta que un paso interno se
# escape con estado != 0 para que errexit mate la corrida antes del primer
# stage. Reproducimos el prologo real (asignacion + derivacion del literal
# JSON) sobre el fixture SIN plugin.json, que es el peor caso.

echo ""
echo "[H] caller con 'set -euo pipefail' sobrevive a plugin.json ausente (CA-1)"

H_OUT=$(bash -c "
set -euo pipefail
source '$FIXTURE/scripts/_pipeline-common.sh'
HARNESS_VERSION=\"\$(get_harness_version)\"
HARNESS_VERSION_JSON=null
[ -n \"\$HARNESS_VERSION\" ] && HARNESS_VERSION_JSON=\"\\\"\$HARNESS_VERSION\\\"\"
echo \"SIGUE-VIVO:\$HARNESS_VERSION_JSON\"
" 2>/dev/null)
H_RC=$?
if [ "$H_RC" -eq 0 ] && [ "$H_OUT" = "SIGUE-VIVO:null" ]; then
    pass "H-1: el prologo sobrevive y deriva harness_version=null"
else
    fail "H-1: se esperaba rc=0 y 'SIGUE-VIVO:null', se obtuvo rc=$H_RC salida='$H_OUT'"
fi

# Y el simetrico: con plugin.json presente, el literal JSON queda entrecomillado.
cat > "$FIXTURE/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "mefisto",
  "version": "7.8.9"
}
EOF
H2_OUT=$(bash -c "
set -euo pipefail
source '$FIXTURE/scripts/_pipeline-common.sh'
HARNESS_VERSION=\"\$(get_harness_version)\"
HARNESS_VERSION_JSON=null
[ -n \"\$HARNESS_VERSION\" ] && HARNESS_VERSION_JSON=\"\\\"\$HARNESS_VERSION\\\"\"
echo \"SIGUE-VIVO:\$HARNESS_VERSION_JSON\"
" 2>/dev/null)
H2_RC=$?
if [ "$H2_RC" -eq 0 ] && [ "$H2_OUT" = 'SIGUE-VIVO:"7.8.9"' ]; then
    pass "H-2: con plugin.json, el literal JSON queda como string entrecomillado"
else
    fail "H-2: se esperaba rc=0 y 'SIGUE-VIVO:\"7.8.9\"', se obtuvo rc=$H2_RC salida='$H2_OUT'"
fi

# -------- Bloque I: metrics-report.sh tolera el historial mixto (CA-4) --------
#
# El campo es aditivo y no se migra nada: las lineas historicas escritas antes
# de este issue conviven con las nuevas en el mismo pipeline-history.jsonl.
# Se corre el reporte real end-to-end dentro de un repo consumidor de mentira
# (git init, SIN .claude-plugin/plugin.json -- si lo tuviera, el guard
# defensivo de metrics-report.sh abortaria) para no tocar nunca el historial
# del repo real.

echo ""
echo "[I] metrics-report.sh agrega historial mixto legado + con harness_version (CA-4)"

if command -v jq >/dev/null 2>&1; then
    FAKE_REPO="$TMP/fake-consumer"
    mkdir -p "$FAKE_REPO/.claude/pipeline"
    git -C "$FAKE_REPO" init -q
    cp "$REPO_ROOT/scripts/metrics-report.sh" "$FAKE_REPO/metrics-report.sh"
    chmod +x "$FAKE_REPO/metrics-report.sh"

    cat > "$FAKE_REPO/.claude/pipeline/pipeline-history.jsonl" <<'EOF'
{"issue":"1","title":"linea legada sin el campo","pipeline":"tooling","started":"20260101-100000","finished":"2026-01-01T10:10:00","state":"completed","agents":{"writer":{"duration":600},"reviewer":{"duration":300}},"tests":null,"pr":"http://x/1"}
{"issue":"2","title":"linea nueva con el campo","pipeline":"tooling","harness_version":"0.25.0","started":"20260102-100000","finished":"2026-01-02T10:10:00","state":"completed","agents":{"writer":{"duration":600},"reviewer":{"duration":300}},"tests":null,"pr":"http://x/2"}
{"issue":"3","title":"aborto con el campo en null","pipeline":"tdd","harness_version":null,"started":"20260103-100000","finished":"2026-01-03T10:10:00","state":"failed","stage":"test-writer","error":"algo"}
EOF

    I_OUT=$( (cd "$FAKE_REPO" && ./metrics-report.sh) 2>&1 )
    I_RC=$?
    if [ "$I_RC" -eq 0 ] && echo "$I_OUT" | grep -q "Corridas totales en la ventana: 3"; then
        pass "I-1: las 3 lineas (legada, con version, con null) se agregan sin cambios"
    else
        fail "I-1: se esperaba rc=0 y 3 corridas, se obtuvo rc=$I_RC: $I_OUT"
    fi
else
    echo "  SKIP: metrics-report.sh requiere jq, no disponible en este entorno"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
