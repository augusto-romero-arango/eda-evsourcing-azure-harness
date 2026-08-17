#!/usr/bin/env bash
# test-sessions-jsonl-hook.sh -- Tests del hook SessionStart que anota
# .claude/pipeline/sessions.jsonl, y en particular del campo harness_version
# (issue #661).
#
# Contexto: las entradas de sessions.jsonl no registraban con que version del
# plugin arranco la sesion, asi que un transcript historico no se podia
# correlacionar con la version de Mefisto que lo ejecuto. El issue agrega al
# hook el campo harness_version con el basename de ${CLAUDE_PLUGIN_ROOT}
# (mismo nombre de campo que pipeline-history.jsonl, issue #660, para cruzar
# ambos artefactos sin mapeos).
#
# El comando del hook es un one-liner de shell embebido en un string JSON de
# hooks/hooks.json: no lo cubre ningun compilador ni ningun linter, y su modo
# de falla es silencioso por diseno (`2>/dev/null ... || true`), asi que una
# regresion no aparece en ningun log de pipeline. Por eso el test lo extrae
# del propio hooks.json con jq y lo EJECUTA en un directorio temporal, en vez
# de comparar el string contra una copia esperada.
#
# Casos cubiertos:
#   [pre] hooks.json parsea como JSON y expone exactamente un hook de
#         SessionStart que escribe sessions.jsonl.
#   [A] CA-1: con CLAUDE_PLUGIN_ROOT apuntando al cache
#       (<cache>/<marketplace>/mefisto/<version>), harness_version queda con
#       el basename -- la version -- y no con la ruta completa.
#   [B] CA-1: el valor entra por `--arg`, y el filtro jq no menciona
#       CLAUDE_PLUGIN_ROOT (nada interpolado dentro del filtro).
#   [C] CA-2: con la variable vacia, el campo serializa null y el hook no falla.
#   [D] CA-2: con la variable no definida, idem (null, exit 0).
#   [E] CA-2: sin jq en PATH, el hook degrada en silencio -- exit 0 y ninguna
#       linea nueva (ni una linea corrupta) en el jsonl.
#   [F] CA-3: los 5 campos previos conservan nombre y forma, la entrada tiene
#       exactamente esas 6 claves y las claves extra del payload se siguen
#       descartando.
#   [G] CA-3: una linea legada (sin harness_version) sobrevive intacta al
#       append y el archivo entero sigue siendo JSONL valido.
#   [H] un CLAUDE_PLUGIN_ROOT que no sigue la estructura del cache
#       (instalacion local por path, con espacios y slash final) se acepta tal
#       cual: el campo describe lo cargado, no valida formato.
#   [I] portabilidad: el mismo comando produce el mismo resultado bajo /bin/sh
#       (POSIX) que bajo bash -- Claude Code no garantiza cual shell lo corre.
#
# Uso: scripts/tests/test-sessions-jsonl-hook.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

if ! command -v jq >/dev/null 2>&1; then
    echo "  SKIP: este test necesita jq para extraer el comando de hooks.json"
    exit 0
fi

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

PAYLOAD='{"session_id":"ses-abc","transcript_path":"/tmp/proyectos/ses-abc.jsonl","cwd":"/tmp/consumidor","source":"resume","hook_event_name":"SessionStart","extra":"ignorame"}'

# ejecutar_hook <dir> <shell> <modo> [valor]
#   modo: con-valor | vacia | sin-definir | sin-jq
# Corre el comando del hook con el cwd en <dir> (el hook escribe rutas
# relativas, igual que en el repo del consumidor) y deja su exit code en $?.
ejecutar_hook() {
    local dir="$1" shell_bin="$2" modo="$3" valor="${4:-}"
    mkdir -p "$dir"
    case "$modo" in
        con-valor)
            ( cd "$dir" && printf '%s' "$PAYLOAD" | env CLAUDE_PLUGIN_ROOT="$valor" "$shell_bin" -c "$HOOK_CMD" ) ;;
        vacia)
            ( cd "$dir" && printf '%s' "$PAYLOAD" | env CLAUDE_PLUGIN_ROOT= "$shell_bin" -c "$HOOK_CMD" ) ;;
        sin-definir)
            ( cd "$dir" && printf '%s' "$PAYLOAD" | env -u CLAUDE_PLUGIN_ROOT "$shell_bin" -c "$HOOK_CMD" ) ;;
        sin-jq)
            ( cd "$dir" && printf '%s' "$PAYLOAD" | env PATH="$BIN_SIN_JQ" CLAUDE_PLUGIN_ROOT="$valor" "$BIN_SIN_JQ/$(basename "$shell_bin")" -c "$HOOK_CMD" ) ;;
    esac
}

ultima_linea() { tail -n 1 "$1/.claude/pipeline/sessions.jsonl" 2>/dev/null; }

# -------- Bloque pre: el hook existe y hooks.json es JSON valido --------

echo "[pre] hooks.json parsea y expone el hook que escribe sessions.jsonl"

if jq -e . "$HOOKS_JSON" >/dev/null 2>&1; then
    pass "hooks.json es JSON valido"
else
    fail "hooks.json NO parsea como JSON"
    echo "  Resumen: $PASS pass, $FAIL fail"
    exit 1
fi

CUANTOS=$(jq -r '[.hooks.SessionStart[].hooks[].command | select(contains("sessions.jsonl"))] | length' "$HOOKS_JSON")
if [ "$CUANTOS" = "1" ]; then
    pass "hay exactamente un hook de SessionStart que escribe sessions.jsonl"
else
    fail "se esperaba 1 hook que escriba sessions.jsonl, se encontraron $CUANTOS"
    echo "  Resumen: $PASS pass, $FAIL fail"
    exit 1
fi

HOOK_CMD=$(jq -r '[.hooks.SessionStart[].hooks[].command | select(contains("sessions.jsonl"))] | .[0]' "$HOOKS_JSON")

# PATH hermetico sin jq: solo los binarios que el hook necesita, enlazados uno
# a uno. Un PATH del estilo "$BIN_SIN_JQ:/bin:/usr/bin" NO sirve como sandbox
# -- en macOS jq vive en /usr/bin/jq y seguiria resolviendo.
BIN_SIN_JQ="$TMP/bin-sin-jq"
mkdir -p "$BIN_SIN_JQ"
for bin in bash sh mkdir basename tail cat; do
    origen=$(command -v "$bin" 2>/dev/null) && ln -sf "$origen" "$BIN_SIN_JQ/$bin"
done

# -------- Bloque A: el basename del cache (CA-1) --------

echo "[A] con CLAUDE_PLUGIN_ROOT del cache, harness_version es la version (CA-1)"

DIR_A="$TMP/caso-a"
ejecutar_hook "$DIR_A" bash con-valor "/Users/x/.claude/plugins/cache/mefisto-marketplace/mefisto/0.25.0"
A_RC=$?
A_LINEA=$(ultima_linea "$DIR_A")

if [ "$A_RC" -eq 0 ] && [ "$(printf '%s' "$A_LINEA" | jq -r '.harness_version')" = "0.25.0" ]; then
    pass "A-1: harness_version = '0.25.0' (basename), exit 0"
else
    fail "A-1: se esperaba exit 0 y harness_version='0.25.0', se obtuvo rc=$A_RC linea='$A_LINEA'"
fi

if printf '%s' "$A_LINEA" | jq -e '.harness_version | contains("/") | not' >/dev/null 2>&1; then
    pass "A-2: el campo no arrastra la ruta completa del plugin"
else
    fail "A-2: harness_version contiene la ruta completa: '$A_LINEA'"
fi

# -------- Bloque B: inyeccion por --arg, no interpolacion (CA-1) --------

echo "[B] el valor viaja por --arg y no interpolado dentro del filtro (CA-1)"

case "$HOOK_CMD" in
    *"--arg harness_version"*) pass "B-1: el hook inyecta el valor con --arg harness_version" ;;
    *) fail "B-1: el hook no usa '--arg harness_version': $HOOK_CMD" ;;
esac

# El filtro jq es lo que va entre la primera y la ultima comilla simple.
FILTRO_JQ=$(printf '%s' "$HOOK_CMD" | sed "s/^[^']*'//; s/'[^']*$//")
case "$FILTRO_JQ" in
    *CLAUDE_PLUGIN_ROOT*) fail "B-2: el filtro jq interpola CLAUDE_PLUGIN_ROOT: $FILTRO_JQ" ;;
    *) pass "B-2: el filtro jq no menciona CLAUDE_PLUGIN_ROOT" ;;
esac

# -------- Bloque C/D: variable vacia o ausente -> null (CA-2) --------

echo "[C] con CLAUDE_PLUGIN_ROOT vacia, el campo es null y el hook no falla (CA-2)"

DIR_C="$TMP/caso-c"
ejecutar_hook "$DIR_C" bash vacia
C_RC=$?
C_LINEA=$(ultima_linea "$DIR_C")

if [ "$C_RC" -eq 0 ] && printf '%s' "$C_LINEA" | jq -e '.harness_version == null' >/dev/null 2>&1; then
    pass "C-1: harness_version = null (JSON null, no la cadena vacia), exit 0"
else
    fail "C-1: se esperaba exit 0 y harness_version=null, se obtuvo rc=$C_RC linea='$C_LINEA'"
fi

echo "[D] con CLAUDE_PLUGIN_ROOT no definida, idem (CA-2)"

DIR_D="$TMP/caso-d"
ejecutar_hook "$DIR_D" bash sin-definir
D_RC=$?
D_LINEA=$(ultima_linea "$DIR_D")

if [ "$D_RC" -eq 0 ] && printf '%s' "$D_LINEA" | jq -e '.harness_version == null' >/dev/null 2>&1; then
    pass "D-1: harness_version = null con la variable ausente, exit 0"
else
    fail "D-1: se esperaba exit 0 y harness_version=null, se obtuvo rc=$D_RC linea='$D_LINEA'"
fi

# -------- Bloque E: sin jq, degradacion silenciosa (CA-2) --------

echo "[E] sin jq en PATH, el hook degrada en silencio (CA-2)"

if env PATH="$BIN_SIN_JQ" sh -c 'command -v jq' >/dev/null 2>&1; then
    echo "  SKIP: el PATH sandbox no logro ocultar jq en este entorno"
else
    DIR_E="$TMP/caso-e"
    mkdir -p "$DIR_E/.claude/pipeline"
    printf '%s\n' '{"session_id":"vieja","transcript_path":"/tmp/v.jsonl","cwd":"/tmp","source":"startup","timestamp":"2026-01-01T00:00:00Z"}' \
        > "$DIR_E/.claude/pipeline/sessions.jsonl"
    LINEAS_ANTES=$(wc -l < "$DIR_E/.claude/pipeline/sessions.jsonl" | tr -d ' ')

    ejecutar_hook "$DIR_E" bash sin-jq "/cache/mefisto/0.25.0" 2>/dev/null
    E_RC=$?
    LINEAS_DESPUES=$(wc -l < "$DIR_E/.claude/pipeline/sessions.jsonl" | tr -d ' ')

    if [ "$E_RC" -eq 0 ]; then
        pass "E-1: sin jq el hook sale con 0 (se preserva el '|| true')"
    else
        fail "E-1: sin jq el hook salio con rc=$E_RC"
    fi

    if [ "$LINEAS_ANTES" = "$LINEAS_DESPUES" ]; then
        pass "E-2: no se escribe ninguna linea (ni corrupta) sin jq"
    else
        fail "E-2: el jsonl paso de $LINEAS_ANTES a $LINEAS_DESPUES lineas sin jq"
    fi
fi

# -------- Bloque F: los campos previos no cambian (CA-3) --------

echo "[F] los 5 campos previos conservan nombre y forma (CA-3)"

if printf '%s' "$A_LINEA" | jq -e '
        .session_id == "ses-abc"
        and .transcript_path == "/tmp/proyectos/ses-abc.jsonl"
        and .cwd == "/tmp/consumidor"
        and .source == "resume"
    ' >/dev/null 2>&1; then
    pass "F-1: session_id/transcript_path/cwd/source pasan tal cual"
else
    fail "F-1: alguno de los 4 campos copiados cambio de nombre o forma: '$A_LINEA'"
fi

if printf '%s' "$A_LINEA" | jq -e '.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' >/dev/null 2>&1; then
    pass "F-2: timestamp sigue siendo ISO-8601 UTC con sufijo Z"
else
    fail "F-2: timestamp cambio de forma: '$A_LINEA'"
fi

CLAVES=$(printf '%s' "$A_LINEA" | jq -c 'keys_unsorted')
if [ "$CLAVES" = '["session_id","transcript_path","cwd","source","timestamp","harness_version"]' ]; then
    pass "F-3: la entrada tiene exactamente las 5 claves previas + harness_version"
else
    fail "F-3: claves inesperadas: $CLAVES"
fi

if printf '%s' "$A_LINEA" | jq -e 'has("extra") | not' >/dev/null 2>&1; then
    pass "F-4: las claves extra del payload se siguen descartando"
else
    fail "F-4: se colo una clave extra del payload: '$A_LINEA'"
fi

# -------- Bloque G: append-only sobre lineas legadas (CA-3) --------

echo "[G] las lineas previas del jsonl siguen siendo validas (CA-3)"

DIR_G="$TMP/caso-g"
mkdir -p "$DIR_G/.claude/pipeline"
LINEA_LEGADA='{"session_id":"legada","transcript_path":"/tmp/legada.jsonl","cwd":"/tmp","source":"startup","timestamp":"2026-01-01T00:00:00Z"}'
printf '%s\n' "$LINEA_LEGADA" > "$DIR_G/.claude/pipeline/sessions.jsonl"

ejecutar_hook "$DIR_G" bash con-valor "/cache/mefisto-marketplace/mefisto/0.26.0" >/dev/null
G_PRIMERA=$(head -n 1 "$DIR_G/.claude/pipeline/sessions.jsonl")

if [ "$G_PRIMERA" = "$LINEA_LEGADA" ]; then
    pass "G-1: la linea legada (sin el campo) sobrevive byte por byte"
else
    fail "G-1: la linea legada cambio: '$G_PRIMERA'"
fi

if jq -e . "$DIR_G/.claude/pipeline/sessions.jsonl" >/dev/null 2>&1; then
    pass "G-2: el archivo entero sigue siendo JSONL valido (legada + nueva)"
else
    fail "G-2: el jsonl dejo de parsear tras el append"
fi

# -------- Bloque H: basename que no es semver --------

echo "[H] un CLAUDE_PLUGIN_ROOT fuera de la estructura del cache se acepta tal cual"

DIR_H="$TMP/caso-h"
ejecutar_hook "$DIR_H" bash con-valor "/Users/x/Codigo con espacios/mefisto-local/"
H_RC=$?
H_LINEA=$(ultima_linea "$DIR_H")

if [ "$H_RC" -eq 0 ] && [ "$(printf '%s' "$H_LINEA" | jq -r '.harness_version')" = "mefisto-local" ]; then
    pass "H-1: instalacion local por path (con espacios y slash final) -> 'mefisto-local'"
else
    fail "H-1: se esperaba exit 0 y harness_version='mefisto-local', se obtuvo rc=$H_RC linea='$H_LINEA'"
fi

# -------- Bloque I: portabilidad bajo /bin/sh --------

echo "[I] el comando produce lo mismo bajo /bin/sh (POSIX) que bajo bash"

DIR_I="$TMP/caso-i"
ejecutar_hook "$DIR_I" sh con-valor "/cache/mefisto-marketplace/mefisto/0.25.0"
I_RC=$?
I_LINEA=$(ultima_linea "$DIR_I")

if [ "$I_RC" -eq 0 ] && [ "$(printf '%s' "$I_LINEA" | jq -r '.harness_version')" = "0.25.0" ]; then
    pass "I-1: bajo sh, harness_version = '0.25.0', exit 0"
else
    fail "I-1: bajo sh se esperaba exit 0 y '0.25.0', se obtuvo rc=$I_RC linea='$I_LINEA'"
fi

DIR_I2="$TMP/caso-i2"
ejecutar_hook "$DIR_I2" sh sin-definir
I2_RC=$?
I2_LINEA=$(ultima_linea "$DIR_I2")

if [ "$I2_RC" -eq 0 ] && printf '%s' "$I2_LINEA" | jq -e '.harness_version == null' >/dev/null 2>&1; then
    pass "I-2: bajo sh y sin la variable, harness_version = null, exit 0"
else
    fail "I-2: bajo sh se esperaba exit 0 y null, se obtuvo rc=$I2_RC linea='$I2_LINEA'"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
