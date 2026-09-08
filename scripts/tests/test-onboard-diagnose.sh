#!/usr/bin/env bash
# test-onboard-diagnose.sh -- Tests de scripts/onboard-diagnose.sh (issue #443).
#
# Cubre, sin invocar gh/az/jq reales (CA-4):
#   S-1: row() -- los tres estados (OK/FALTA/cualquier otra cosa -> NO VERIFICADO)
#        incrementan el contador correcto y respetan el formato fijo de impresion.
#   S-2: _secret_present() -- la verificacion de secretos aisla la PRIMERA columna
#        de una linea estilo 'gh secret list' (NAME<TAB>UPDATED_AT) antes de
#        comparar, en vez de buscar el texto en cualquier parte de la linea. Cubre
#        el caso que motiva la extraccion (issue #443): un awk '{print $1}' sin
#        aislar en una funcion se hubiera repetido 4 veces sin test que probara
#        que de verdad ignora las demas columnas.
#   S-3: _check_consumer_directives() -- contrato canónico, puente y fallback legacy.
#   S-4: _mefisto_pipeline_ignored() -- exige el ignore especifico del estado y
#        rechaza ignorar tambien la configuracion sibling versionada.
#
# El script se sourcea (no se ejecuta): scripts/onboard-diagnose.sh solo corre su
# main() cuando BASH_SOURCE[0] == $0, asi que sourcearlo aqui carga row()/
# _secret_present() sin disparar el diagnostico completo (que si invoca gh/az/jq).
#
# Uso: scripts/tests/test-onboard-diagnose.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

source "$REPO_ROOT/scripts/onboard-diagnose.sh"

# row() incrementa N_OK/N_FALTA/N_NV (variables globales del script fuente).
# $(row ...) correria row() en un subshell -- sus incrementos se perderian al
# volver -- asi que se captura la salida redirigiendo a un archivo (misma
# invocacion, mismo shell) en vez de con command substitution.
ROW_OUT="$(mktemp)"
trap 'rm -f "$ROW_OUT"' EXIT

echo "[S-1] row(): estados, contadores y formato"

N_OK=0; N_FALTA=0; N_NV=0

row OK "config presente" > "$ROW_OUT"
OUT=$(cat "$ROW_OUT")
if [ "$N_OK" -eq 1 ] && [ "$N_FALTA" -eq 0 ] && [ "$N_NV" -eq 0 ]; then
    pass "row OK incrementa N_OK y solo N_OK"
else
    fail "row OK: contadores inesperados (N_OK=$N_OK N_FALTA=$N_FALTA N_NV=$N_NV)"
fi
if [ "$OUT" = "  [OK           ] config presente" ]; then
    pass "row OK imprime con el formato fijo '  [%-13s] %s'"
else
    fail "row OK: formato inesperado: '$OUT'"
fi

row FALTA "faltan labels: dom:x" > "$ROW_OUT"
OUT=$(cat "$ROW_OUT")
if [ "$N_OK" -eq 1 ] && [ "$N_FALTA" -eq 1 ] && [ "$N_NV" -eq 0 ]; then
    pass "row FALTA incrementa N_FALTA y solo N_FALTA"
else
    fail "row FALTA: contadores inesperados (N_OK=$N_OK N_FALTA=$N_FALTA N_NV=$N_NV)"
fi
if [ "$OUT" = "  [FALTA        ] faltan labels: dom:x" ]; then
    pass "row FALTA imprime con el formato fijo"
else
    fail "row FALTA: formato inesperado: '$OUT'"
fi

# Cualquier estado que no sea OK/FALTA cuenta como NO VERIFICADO -- incluido el
# literal "NV" que usa el resto del script, y cualquier otro texto (defensivo:
# row() nunca debe dejar un estado desconocido sin contar).
for estado_input in NV algo-no-reconocido; do
    N_OK=0; N_FALTA=0; N_NV=0
    row "$estado_input" "seccion sin verificar" > "$ROW_OUT"
    OUT=$(cat "$ROW_OUT")
    if [ "$N_NV" -eq 1 ] && [ "$N_OK" -eq 0 ] && [ "$N_FALTA" -eq 0 ]; then
        pass "row '$estado_input' incrementa N_NV y solo N_NV"
    else
        fail "row '$estado_input': contadores inesperados (N_OK=$N_OK N_FALTA=$N_FALTA N_NV=$N_NV)"
    fi
    if [ "$OUT" = "  [NO VERIFICADO] seccion sin verificar" ]; then
        pass "row '$estado_input' normaliza la etiqueta impresa a 'NO VERIFICADO'"
    else
        fail "row '$estado_input': etiqueta impresa inesperada: '$OUT'"
    fi
done

# row() acepta el item en varias palabras (shift + "$*"), no solo la primera --
# es la forma en que las secciones 1, 4, 5, etc. le pasan texto con espacios.
N_OK=0; N_FALTA=0; N_NV=0
row OK "el archivo existe y parsea con jq" > "$ROW_OUT"
OUT=$(cat "$ROW_OUT")
if [ "$OUT" = "  [OK           ] el archivo existe y parsea con jq" ]; then
    pass "row OK preserva un item multi-palabra completo"
else
    fail "row OK: item multi-palabra truncado o mal formado: '$OUT'"
fi

echo ""
echo "[S-2] _secret_present(): aisla la columna del nombre, no busca en toda la linea"

# Formato real de 'gh secret list': NAME<TAB>UPDATED_AT (a veces con mas columnas,
# p. ej. visibilidad en secrets de organizacion).
SECRETS_LIST=$(printf 'AZURE_CLIENT_ID\t2024-01-01T00:00:00Z\nAZURE_CLIENT_ID_OLD\t2023-01-01T00:00:00Z\nTF_VAR_POSTGRESQL_ADMIN_PASSWORD\tActions\t2024-06-01T00:00:00Z\n')

if _secret_present "$SECRETS_LIST" "AZURE_CLIENT_ID"; then
    pass "detecta un secreto presente por coincidencia exacta de columna 1"
else
    fail "no detecto 'AZURE_CLIENT_ID' estando presente"
fi

if _secret_present "$SECRETS_LIST" "AZURE_CLIENT_ID_OLD"; then
    pass "detecta el otro secreto (columna 1 completa, sin confundirlo con el primero)"
else
    fail "no detecto 'AZURE_CLIENT_ID_OLD' estando presente"
fi

# 'AZURE_CLIENT_ID' es un prefijo/substring de 'AZURE_CLIENT_ID_OLD'. Si la
# verificacion no aislara la columna 1 con match exacto (grep -Fqx), buscar
# 'AZURE_CLIENT_ID' podria dar un falso OK aunque solo exista la variante _OLD.
SECRETS_LIST_SOLO_OLD=$(printf 'AZURE_CLIENT_ID_OLD\t2023-01-01T00:00:00Z\n')
if _secret_present "$SECRETS_LIST_SOLO_OLD" "AZURE_CLIENT_ID"; then
    fail "falso positivo: 'AZURE_CLIENT_ID' coincidio por substring contra 'AZURE_CLIENT_ID_OLD'"
else
    pass "'AZURE_CLIENT_ID' NO coincide por substring contra 'AZURE_CLIENT_ID_OLD' (match exacto de columna)"
fi

# 'Actions' aparece en la SEGUNDA columna de la fila de TF_VAR_POSTGRESQL_ADMIN_PASSWORD
# (visibilidad del secreto). Si la verificacion buscara en la linea completa en vez de
# solo en la columna 1 (awk '{print $1}'), esto daria un falso OK.
if _secret_present "$SECRETS_LIST" "Actions"; then
    fail "falso positivo: 'Actions' (columna 2, visibilidad) se conto como nombre de secreto"
else
    pass "'Actions' (columna 2) no se confunde con un nombre de secreto -- solo se mira la columna 1"
fi

if _secret_present "$SECRETS_LIST" "NO_EXISTE"; then
    fail "falso positivo: 'NO_EXISTE' no deberia estar presente"
else
    pass "un secreto ausente por completo se reporta ausente"
fi

echo ""
echo "[S-3] _check_consumer_directives(): AGENTS.md canónico y puente CLAUDE.md"
DIRECTIVES_REPO=$(mktemp -d)
trap 'rm -f "$ROW_OUT"; rm -rf "$IGNORE_REPO" "$DIRECTIVES_REPO"' EXIT

write_complete_agents() {
    printf '%s\n' \
        '## Tokens del harness' \
        '**RootNamespace**: Ejemplo' \
        '**SolutionFile**: Ejemplo.sln' \
        '**ProjectDisplayName**: Ejemplo' \
        '**BoundedContext**: Ejemplo' \
        '**BoundedContextDomains**: ejemplo' \
        '## Verificación de fuentes (obligatorio para agentes)' > "$DIRECTIVES_REPO/AGENTS.md"
}

assert_directives() {
    local scenario="$1" expected_agents="$2" expected_claude="$3" needle="$4"
    _check_consumer_directives "$DIRECTIVES_REPO/AGENTS.md" "$DIRECTIVES_REPO/CLAUDE.md"
    if [ "$AGENTS_DIRECTIVES_STATE" = "$expected_agents" ] && [ "$CLAUDE_BRIDGE_STATE" = "$expected_claude" ]; then
        pass "$scenario: estados $expected_agents/$expected_claude"
    else
        fail "$scenario: estados $AGENTS_DIRECTIVES_STATE/$CLAUDE_BRIDGE_STATE (esperaba $expected_agents/$expected_claude)"
    fi
    if printf '%s\n%s\n' "$AGENTS_DIRECTIVES_DETAIL" "$CLAUDE_BRIDGE_DETAIL" | grep -Fq "$needle"; then
        pass "$scenario: detalle accionable contiene '$needle'"
    else
        fail "$scenario: falta detalle '$needle'"
    fi
}

# Greenfield completo: ambas ubicaciones son independientes y quedan listas.
write_complete_agents
printf '  @AGENTS.md  \n' > "$DIRECTIVES_REPO/CLAUDE.md"
BEFORE=$(cksum "$DIRECTIVES_REPO/AGENTS.md" "$DIRECTIVES_REPO/CLAUDE.md")
assert_directives "greenfield completo" OK OK "puente exacto"
AFTER=$(cksum "$DIRECTIVES_REPO/AGENTS.md" "$DIRECTIVES_REPO/CLAUDE.md")
if [ "$BEFORE" = "$AFTER" ]; then pass "la comprobación de directivas no escribe archivos"; else fail "la comprobación de directivas modificó un archivo"; fi

# AGENTS.md incompleto mantiene visible el puente correcto.
printf '## Tokens del harness\n**RootNamespace**: Ejemplo\n' > "$DIRECTIVES_REPO/AGENTS.md"
assert_directives "AGENTS.md incompleto" FALTA OK "BoundedContextDomains"

# Contenido específico de Claude permitido, pero una mención en prosa no es import.
write_complete_agents
printf '%s\n' 'Esta prosa menciona @AGENTS.md pero no lo importa.' > "$DIRECTIVES_REPO/CLAUDE.md"
assert_directives "CLAUDE.md con contenido propio sin import" OK FALTA "linea independiente"

# El fallback legacy explica el estado sin ocultar las dos faltas canónicas.
rm -f "$DIRECTIVES_REPO/AGENTS.md"
printf '%s\n' '## Tokens del harness' '**RootNamespace**: Ejemplo' '## Verificación de fuentes' > "$DIRECTIVES_REPO/CLAUDE.md"
assert_directives "solo legacy" FALTA FALTA "legacy legible"

# El import exacto no habilita duplicar las secciones de la fuente canónica.
write_complete_agents
printf '%s\n' '@AGENTS.md' '## Tokens del harness' '## Verificación de fuentes' > "$DIRECTIVES_REPO/CLAUDE.md"
assert_directives "puente con doctrina contractual duplicada" OK FALTA "duplicadas"

# Un archivo existente pero inaccesible no se confunde con uno ausente.
chmod 000 "$DIRECTIVES_REPO/AGENTS.md"
_check_consumer_directives "$DIRECTIVES_REPO/AGENTS.md" "$DIRECTIVES_REPO/CLAUDE.md"
if [ "$AGENTS_DIRECTIVES_STATE" = "NV" ]; then
    pass "AGENTS.md existente no legible reporta NO VERIFICADO"
else
    fail "AGENTS.md no legible reportó $AGENTS_DIRECTIVES_STATE en vez de NO VERIFICADO"
fi
chmod 644 "$DIRECTIVES_REPO/AGENTS.md"
chmod 000 "$DIRECTIVES_REPO/CLAUDE.md"
_check_consumer_directives "$DIRECTIVES_REPO/AGENTS.md" "$DIRECTIVES_REPO/CLAUDE.md"
if [ "$CLAUDE_BRIDGE_STATE" = "NV" ]; then
    pass "CLAUDE.md existente no legible reporta NO VERIFICADO"
else
    fail "CLAUDE.md no legible reportó $CLAUDE_BRIDGE_STATE en vez de NO VERIFICADO"
fi
chmod 644 "$DIRECTIVES_REPO/CLAUDE.md"

echo ""
echo "[S-4] _mefisto_pipeline_ignored(): diagnostico de solo lectura del ignore especifico"
IGNORE_REPO=$(mktemp -d)
trap 'rm -f "$ROW_OUT"; rm -rf "$IGNORE_REPO" "$DIRECTIVES_REPO"' EXIT
(cd "$IGNORE_REPO" && git init -q)
if _mefisto_pipeline_ignored "$IGNORE_REPO"; then
    fail "reporta ignorado sin patron en .gitignore"
else
    pass "reporta falta cuando .mefisto/pipeline/ no esta ignorado"
fi
printf '.mefisto/pipeline/\n' > "$IGNORE_REPO/.gitignore"
if _mefisto_pipeline_ignored "$IGNORE_REPO"; then
    pass "detecta exactamente .mefisto/pipeline/ via git check-ignore"
else
    fail "no detecto el patron .mefisto/pipeline/"
fi
if git -C "$IGNORE_REPO" check-ignore -q .mefisto/harness.config.json; then
    fail "el patron especifico ignora indebidamente harness.config.json"
else
    pass "no ignora .mefisto/harness.config.json"
fi

printf '.mefisto/\n' > "$IGNORE_REPO/.gitignore"
if _mefisto_pipeline_ignored "$IGNORE_REPO"; then
    fail "acepta indebidamente el ignore amplio .mefisto/"
else
    pass "rechaza .mefisto/ completo porque ocultaria harness.config.json"
fi
if [ "$(cat "$IGNORE_REPO/.gitignore")" = ".mefisto/" ]; then
    pass "el diagnostico no modifica .gitignore"
else
    fail "el diagnostico modifico .gitignore"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
