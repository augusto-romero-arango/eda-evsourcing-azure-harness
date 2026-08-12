#!/usr/bin/env bash
# test-pr-sync-desbloqueo.sh -- Tests de desbloquear_issues_dependientes()
# (scripts/pr-sync.sh, issue #611: falso fallo de merge por array vacio bajo set -u).
#
# pr-sync.sh declara `set -euo pipefail` y promete "Compatible con bash 3.2+"
# (el /bin/bash nativo de macOS), pero expandir "${all_deps[@]}" de un array
# vacio bajo `set -u` es fatal SOLO en bash 3.2 (no en bash >=4.4) -- por eso
# el bug pasaba inadvertido en CI y solo se manifestaba en dev local macOS.
# Estos casos invocan la funcion extraida con /bin/bash EXPLICITO (sin importar
# que bash corra este runner) para reproducir el crash real:
#
#   D-1 (CA-1): issue bloqueado que referencia el issue cerrado con redaccion
#       NO canonica ("Depende del write-side: #N") -- referencia_cerrado=true
#       pero all_deps queda vacio -- ya no aborta, la funcion retorna 0.
#   D-2 (CA-3): el mismo caso de D-1 emite un warn que nombra al issue
#       bloqueado y senala la redaccion no parseable.
#   D-3 (control positivo): redaccion canonica ("Depende de #N") sigue
#       desbloqueando el issue como antes -- el guard de CA-1 no rompio el
#       camino feliz.
#   D-4 (CA-2): las dos invocaciones post-merge en pr-sync.sh aislan el exit
#       code de desbloquear_issues_dependientes con `|| warn`, para que un
#       fallo del post-merge no contamine el resultado del merge.
#
# Uso: scripts/tests/test-pr-sync-desbloqueo.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PR_SYNC="$REPO_ROOT/scripts/pr-sync.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export TMP_DIR

# Extrae SOLO el cuerpo de la funcion (sin correr load_harness_config ni el
# loop principal del script, que requieren un harness.config.json real y PRs).
FUNC_SRC=$(awk '
    /^desbloquear_issues_dependientes\(\) \{/ { flag=1 }
    flag && /Loop principal/ { exit }
    flag { print }
' "$PR_SYNC")

if [ -z "$FUNC_SRC" ]; then
    fail "no se pudo extraer desbloquear_issues_dependientes() de pr-sync.sh (¿cambio el marcador de inicio/fin?)"
    echo ""
    echo "----------------------------------------"
    echo "  Resumen: $PASS pass, $FAIL fail"
    echo "----------------------------------------"
    exit 1
fi
pass "se extrajo desbloquear_issues_dependientes() de pr-sync.sh"

# Arnes comun: stubs de log/warn/success y un mock de gh parametrizado por
# variables de entorno (PR_BODY, BLOQUEADOS_JSON, DEP_STATE) que cada caso
# exporta antes de correr /bin/bash sobre el script generado.
HARNESS_TEMPLATE='
LOG_FILE_ABS="$TMP_DIR/log.txt"
: > "$LOG_FILE_ABS"
: > "$TMP_DIR/warn.txt"
: > "$TMP_DIR/desbloqueados.txt"

log()     { :; }
success() { :; }
warn()    { printf "%s\n" "$1" >> "$TMP_DIR/warn.txt"; }

gh() {
    case "$1 $2" in
        "pr view")
            if [ "$5" = "body" ]; then
                printf "%s" "$PR_BODY"
            else
                printf "%s" "${DEP_STATE:-}"
            fi
            ;;
        "issue list")
            printf "%s" "$BLOQUEADOS_JSON"
            ;;
        "issue view")
            printf "%s" "${DEP_STATE:-}"
            ;;
        "issue edit")
            printf "%s\n" "$3" >> "$TMP_DIR/desbloqueados.txt"
            ;;
        *)
            return 1
            ;;
    esac
}

desbloquear_issues_dependientes "$PR_NUM"
echo "FUNC_EXIT_OK"
'

build_case() {
    local case_file="$1"
    printf '%s\n' "$FUNC_SRC" > "$case_file"
    printf '%s\n' "$HARNESS_TEMPLATE" >> "$case_file"
}

# ─── D-1 / D-2: redaccion NO canonica -- no aborta y emite warn (CA-1/CA-3) ───
echo "[D-1/D-2] issue bloqueado con redaccion NO canonica ('Depende del write-side: #N')"

CASE1="$TMP_DIR/case1.sh"
build_case "$CASE1"

export PR_NUM=999
export PR_BODY="Closes #500"
export BLOQUEADOS_JSON='[{"number":501,"title":"Issue de prueba","body":"## Dependencias\n\nDepende del write-side: #500, algo mas\n"}]'
unset DEP_STATE

OUTPUT=$(/bin/bash "$CASE1" 2>&1)
RC=$?

if [ "$RC" -eq 0 ]; then
    pass "D-1: redaccion no canonica -- la funcion retorna 0 (no crashea bajo /bin/bash 3.2)"
else
    fail "D-1: se esperaba exit 0, fue rc=$RC. Salida: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "FUNC_EXIT_OK"; then
    pass "D-1: la funcion completo su ejecucion (no abortó a mitad de camino)"
else
    fail "D-1: la funcion no llego a FUNC_EXIT_OK. Salida: $OUTPUT"
fi

WARN_CONTENT=$(cat "$TMP_DIR/warn.txt" 2>/dev/null || echo "")
if echo "$WARN_CONTENT" | grep -q "#501"; then
    pass "D-2: el warn nombra al issue bloqueado (#501)"
else
    fail "D-2: el warn deberia nombrar a #501. Contenido: $WARN_CONTENT"
fi

if echo "$WARN_CONTENT" | grep -qi "redacción canónica parseable\|redaccion canonica parseable"; then
    pass "D-2: el warn señala la redaccion no canonica parseable"
else
    fail "D-2: el warn deberia señalar la redaccion no canonica. Contenido: $WARN_CONTENT"
fi

if [ ! -s "$TMP_DIR/desbloqueados.txt" ]; then
    pass "D-1: no se intento desbloquear ningun issue (all_deps vacio, sin falso positivo)"
else
    fail "D-1: no deberia haberse desbloqueado ningun issue. Contenido: $(cat "$TMP_DIR/desbloqueados.txt")"
fi

# ─── D-3: control positivo -- redaccion canonica sigue desbloqueando ─────────
echo ""
echo "[D-3] issue bloqueado con redaccion canonica ('Depende de #N') sigue funcionando"

CASE3="$TMP_DIR/case3.sh"
build_case "$CASE3"

export PR_NUM=999
export PR_BODY="Closes #600"
export BLOQUEADOS_JSON='[{"number":602,"title":"Issue canonico","body":"## Dependencias\n\nDepende de #600\n"}]'
export DEP_STATE="CLOSED"

OUTPUT=$(/bin/bash "$CASE3" 2>&1)
RC=$?

if [ "$RC" -eq 0 ]; then
    pass "D-3: redaccion canonica -- la funcion retorna 0"
else
    fail "D-3: se esperaba exit 0, fue rc=$RC. Salida: $OUTPUT"
fi

if grep -q "602" "$TMP_DIR/desbloqueados.txt" 2>/dev/null; then
    pass "D-3: el issue #602 se desbloqueo (camino feliz intacto)"
else
    fail "D-3: se esperaba que #602 se desbloqueara. Contenido: $(cat "$TMP_DIR/desbloqueados.txt" 2>/dev/null)"
fi

if [ ! -s "$TMP_DIR/warn.txt" ]; then
    pass "D-3: no se emitio ningun warn (no es el caso de redaccion no canonica)"
else
    fail "D-3: no se esperaba warn. Contenido: $(cat "$TMP_DIR/warn.txt")"
fi

unset PR_NUM PR_BODY BLOQUEADOS_JSON DEP_STATE

# ─── D-4: el post-merge aisla el exit code del desbloqueo (CA-2) ────────────
echo ""
echo "[D-4] las invocaciones post-merge aislan desbloquear_issues_dependientes con '|| warn'"

D4_MATCHES=$(grep -c 'desbloquear_issues_dependientes "\$PR_NUM" || warn "Post-merge' "$PR_SYNC" || true)
if [ "$D4_MATCHES" -eq 2 ]; then
    pass "D-4: las dos invocaciones post-merge (rama 'al dia' y rama 'sincronizado') aislan el exit code con '|| warn'"
else
    fail "D-4: se esperaban 2 invocaciones aisladas con '|| warn', se encontraron $D4_MATCHES"
fi

# Prueba dinamica generica: el patron '<func> || warn' no aborta el script
# bajo set -e aunque <func> falle, y el warn efectivamente corre.
CASE4="$TMP_DIR/case4.sh"
cat > "$CASE4" <<'CASE4_EOF'
set -euo pipefail
desbloquear_issues_dependientes() { return 1; }
warn() { printf "WARN:%s\n" "$1"; }
desbloquear_issues_dependientes "999" || warn "post-merge fail (demo)"
echo "AFTER_OK"
CASE4_EOF

OUTPUT=$(/bin/bash "$CASE4" 2>&1)
RC=$?

if [ "$RC" -eq 0 ] && echo "$OUTPUT" | grep -q "AFTER_OK"; then
    pass "D-4: el patron '|| warn' no aborta el script bajo set -e aunque el desbloqueo falle"
else
    fail "D-4: se esperaba rc=0 y 'AFTER_OK' en la salida, fue rc=$RC. Salida: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "WARN:post-merge fail (demo)"; then
    pass "D-4: el warn de aislamiento se ejecuta cuando el desbloqueo falla"
else
    fail "D-4: se esperaba el warn de aislamiento. Salida: $OUTPUT"
fi

# ─── Resumen ──────────────────────────────────────────────────────────────
echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
