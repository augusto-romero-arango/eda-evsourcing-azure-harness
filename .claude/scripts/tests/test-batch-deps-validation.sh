#!/usr/bin/env bash
# test-batch-deps-validation.sh -- Tests de mefisto-validate-batch-deps.sh (issue #436).
#
# Ese script reemplaza el bloque bash de ~95 lineas que vivia incrustado en el
# paso 1.5 de .claude/commands/mefisto-sequential.md. El defecto que motivo la
# extraccion: Claude Code expande los placeholders $N del ARCHIVO DEL COMANDO
# antes de entregar su contenido al modelo, asi que la sintaxis posicional de
# shell ($1, $*, $#) dentro de ese bloque se corrompia en cada invocacion real
# (`local target="437"` fijo en vez de `local target="$1"`) -- el agente nunca
# leyo el codigo que estaba en disco. El sintoma no fallaba: `pos_in_batch`
# comparaba todo contra un unico numero fijo y la clasificacion intra-batch
# (satisfactible / mal ordenada / bloqueo real) daba resultados falsos sin
# exit code que lo delatara.
#
# Casos cubiertos:
#   [pre] El script existe, es ejecutable, tiene sintaxis valida y la guarda
#         fail-loud (invocado sin argumentos) sale con exit 2.
#   [A] pos_in_batch (extraida del script real, no reimplementada) calcula la
#       posicion correcta para CADA UNO de los tres issues de un batch de tres
#       -- el caso exacto que el defecto original rompia.
#   [B] Los tres ejemplos canonicos del issue #47: batch bien ordenado lanza,
#       batch mal ordenado aborta sugiriendo el reordenamiento concreto, y
#       dependencia real fuera del batch aborta. En los dos casos de abort se
#       verifica ademas que el stub de gh NO recibio ningun 'issue edit': si el
#       batch aborta no se muta ningun label.
#   [C] Dependencia CLOSED no bloquea (aunque este fuera del batch).
#   [D] Dependencia que en realidad es un PR (issue view falla, pr view
#       responde) se tolera igual que en el bloque original.
#   [E] 'Bloquea #NNN' (referencia inversa, sin marcador forward) se ignora:
#       no cuenta como dependencia de este issue.
#   [G] Guard de regresion (CA-5): ningun bloque bash de .claude/commands/*.md
#       contiene sintaxis posicional de shell ($1..$9, ${N}, $*, $@, $#), sin
#       marcar $ARGUMENTS ni ${#ARRAY[@]} como falsos positivos -- y el guard
#       SI detecta un $1 introducido a mano en un archivo sintetico (prueba de
#       que el guard funciona, no solo que hoy no encuentra nada).
#
# Uso: .claude/scripts/tests/test-batch-deps-validation.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/.claude/scripts/mefisto-validate-batch-deps.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# -------- Bloque pre: el script existe, es ejecutable y tiene sintaxis valida --------

echo "[pre] mefisto-validate-batch-deps.sh existe, es ejecutable, sintaxis valida y guarda fail-loud"

if [ -x "$SCRIPT" ]; then
    pass "el script existe y es ejecutable"
else
    fail "el script no existe o no es ejecutable: $SCRIPT"
fi

if bash -n "$SCRIPT" 2>/dev/null; then
    pass "sintaxis valida (bash -n)"
else
    fail "bash -n reporto un error de sintaxis en $SCRIPT"
fi

"$SCRIPT" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "invocado sin argumentos: exit 2 (guarda fail-loud, no se valido nada)"
else
    fail "invocado sin argumentos: se esperaba exit 2, se obtuvo $RC"
fi

# -------- Fixtures y stub de gh --------

FAKE_BIN=$(mktemp -d)
FAKE_DATA=$(mktemp -d)
cleanup() { rm -rf "$FAKE_BIN" "$FAKE_DATA"; }
trap cleanup EXIT

# Stub de gh dirigido por fixtures en $FAKE_DATA_DIR/<issue>.{labels,body,state,pr_state}.
# Registra toda invocacion "issue edit" en $FAKE_DATA_DIR/gh_calls.log -- es lo
# que permite afirmar que un batch abortado no muta ningun label (CA-3).
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
DATA="${FAKE_DATA_DIR:?FAKE_DATA_DIR no seteado}"

json_field_of() {
    local prev=""
    for a in "$@"; do
        [ "$prev" = "--json" ] && { echo "$a"; return 0; }
        prev="$a"
    done
    echo ""
}

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    num="$3"
    field=$(json_field_of "$@")
    case "$field" in
        labels)
            [ -f "$DATA/$num.labels" ] && cat "$DATA/$num.labels" || echo ""
            exit 0
            ;;
        body)
            [ -f "$DATA/$num.body" ] && cat "$DATA/$num.body" || echo ""
            exit 0
            ;;
        state)
            if [ -f "$DATA/$num.state" ]; then
                cat "$DATA/$num.state"
                exit 0
            fi
            exit 1
            ;;
    esac
    exit 1
fi

if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    num="$3"
    if [ -f "$DATA/$num.pr_state" ]; then
        cat "$DATA/$num.pr_state"
        exit 0
    fi
    exit 1
fi

if [ "$1" = "issue" ] && [ "$2" = "edit" ]; then
    echo "$*" >> "$DATA/gh_calls.log"
    exit 0
fi

exit 1
EOF
chmod +x "$FAKE_BIN/gh"

reset_fixtures() { rm -rf "$FAKE_DATA"; mkdir -p "$FAKE_DATA"; }
set_labels() { echo "$2" > "$FAKE_DATA/$1.labels"; }
set_state()  { echo "$2" > "$FAKE_DATA/$1.state"; }
set_pr_state() { echo "$2" > "$FAKE_DATA/$1.pr_state"; }
set_body() { cat > "$FAKE_DATA/$1.body"; }

run_script() {
    FAKE_DATA_DIR="$FAKE_DATA" PATH="$FAKE_BIN:$PATH" "$SCRIPT" "$@"
}

assert_gh_calls_empty() {
    local ctx="$1"
    if [ ! -s "$FAKE_DATA/gh_calls.log" ]; then
        pass "$ctx: gh_calls.log vacio (no se muto ningun label)"
    else
        fail "$ctx: gh_calls.log NO deberia tener entradas, tiene: $(cat "$FAKE_DATA/gh_calls.log")"
    fi
}

assert_issue_edit_called() {
    local ctx="$1" num="$2"
    if grep -q "issue edit $num --remove-label bloqueado" "$FAKE_DATA/gh_calls.log" 2>/dev/null; then
        pass "$ctx: gh recibio 'issue edit $num --remove-label bloqueado'"
    else
        fail "$ctx: gh NO recibio 'issue edit $num --remove-label bloqueado'"
    fi
}

assert_issue_edit_not_called() {
    local ctx="$1" num="$2"
    if grep -q "issue edit $num " "$FAKE_DATA/gh_calls.log" 2>/dev/null; then
        fail "$ctx: gh recibio 'issue edit $num', no deberia (no tiene label 'bloqueado')"
    else
        pass "$ctx: gh NO recibio 'issue edit $num'"
    fi
}

# -------- Bloque A: pos_in_batch calcula la posicion correcta para los 3 --------
# Extrae la funcion REAL del script (no la reimplementa): el test unitario
# corre contra el mismo codigo que usa el resto del script. Este es el caso
# exacto que el defecto original rompia -- "local target" fijo en vez de "$1"
# hacia que toda llamada devolviera (o fallara en encontrar) la posicion de un
# unico numero fijo, sin importar el argumento real.

echo ""
echo "[A] pos_in_batch calcula la posicion correcta para cada uno de los 3 issues del batch"

POS_IN_BATCH_SRC=$(awk '/^pos_in_batch\(\) \{/,/^\}/' "$SCRIPT")
if [ -z "$POS_IN_BATCH_SRC" ]; then
    fail "no se pudo extraer pos_in_batch() de $SCRIPT"
else
    eval "$POS_IN_BATCH_SRC"
    BATCH="44 43 45"
    for pair in "44:1" "43:2" "45:3"; do
        target="${pair%%:*}"
        expected="${pair##*:}"
        got=$(pos_in_batch "$target")
        if [ "$got" = "$expected" ]; then
            pass "pos_in_batch($target) = $expected"
        else
            fail "pos_in_batch($target): se esperaba $expected, se obtuvo '$got'"
        fi
    done
fi

# -------- Bloque B: los tres ejemplos canonicos del issue #47 --------

echo ""
echo "[B] Ejemplos canonicos del issue #47"

# B-1: '44 43 45' (43 y 45 dependen de 44, que va primero) -> lanza.
reset_fixtures
set_labels 44 ""
set_labels 43 "bloqueado"
set_labels 45 "bloqueado"
set_body 43 <<'EOF'
## Dependencias

Depende de #44
EOF
set_body 45 <<'EOF'
## Dependencias

Depende de #44
EOF

OUTPUT=$(run_script 44 43 45 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUTPUT" | grep -q "Validacion 1.5 OK"; then
    pass "B-1: '44 43 45' lanza (exit 0, 'Validacion 1.5 OK')"
else
    fail "B-1: se esperaba exit 0 con 'Validacion 1.5 OK', se obtuvo exit $RC: $OUTPUT"
fi
assert_issue_edit_called "B-1" 43
assert_issue_edit_called "B-1" 45
assert_issue_edit_not_called "B-1" 44

# B-2: '43 44' (43 depende de 44, que va DESPUES) -> aborta sugiriendo reordenar.
reset_fixtures
set_labels 43 "bloqueado"
set_labels 44 ""
set_body 43 <<'EOF'
## Dependencias

Depende de #44
EOF

OUTPUT=$(run_script 43 44 2>&1)
RC=$?
if [ "$RC" -eq 1 ] && echo "$OUTPUT" | grep -q "Mueve #44 antes de #43"; then
    pass "B-2: '43 44' aborta sugiriendo 'Mueve #44 antes de #43'"
else
    fail "B-2: se esperaba exit 1 con el mensaje de reordenamiento, se obtuvo exit $RC: $OUTPUT"
fi
assert_gh_calls_empty "B-2"

# B-3: '43' solo (43 depende de 44, que no esta en el batch y sigue OPEN) -> aborta.
reset_fixtures
set_labels 43 "bloqueado"
set_body 43 <<'EOF'
## Dependencias

Depende de #44
EOF
set_state 44 "OPEN"

OUTPUT=$(run_script 43 2>&1)
RC=$?
if [ "$RC" -eq 1 ] && echo "$OUTPUT" | grep -q "fuera del batch"; then
    pass "B-3: '43' solo aborta por bloqueo real fuera del batch"
else
    fail "B-3: se esperaba exit 1 mencionando 'fuera del batch', se obtuvo exit $RC: $OUTPUT"
fi
assert_gh_calls_empty "B-3"

# -------- Bloque C: dependencia CLOSED no bloquea --------

echo ""
echo "[C] Una dependencia CLOSED (fuera del batch) no bloquea"

reset_fixtures
set_labels 50 "bloqueado"
set_body 50 <<'EOF'
## Dependencias

Depende de #51
EOF
set_state 51 "CLOSED"

OUTPUT=$(run_script 50 2>&1)
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "C: dependencia CLOSED no bloquea (exit 0)"
else
    fail "C: se esperaba exit 0 con dependencia CLOSED, se obtuvo exit $RC: $OUTPUT"
fi
assert_issue_edit_called "C" 50

# -------- Bloque D: la dependencia es en realidad un PR (MERGED) --------

echo ""
echo "[D] Dependencia que es un PR (gh issue view falla, gh pr view responde MERGED)"

reset_fixtures
set_labels 90 "bloqueado"
set_body 90 <<'EOF'
## Dependencias

Depende de #80
EOF
set_pr_state 80 "MERGED"

OUTPUT=$(run_script 90 2>&1)
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "D: dependencia-PR MERGED no bloquea (exit 0)"
else
    fail "D: se esperaba exit 0 con dependencia-PR MERGED, se obtuvo exit $RC: $OUTPUT"
fi
assert_issue_edit_called "D" 90

# -------- Bloque E: 'Bloquea #NNN' (referencia inversa) se ignora --------

echo ""
echo "[E] 'Bloquea #NNN' (referencia inversa, sin marcador forward) no cuenta como dependencia"

reset_fixtures
set_labels 60 "bloqueado"
set_body 60 <<'EOF'
## Dependencias

Bloquea #61
EOF

OUTPUT=$(run_script 60 2>&1)
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "E: 'Bloquea #61' se ignora, el issue no queda bloqueado (exit 0)"
else
    fail "E: se esperaba exit 0 (sin dependencias forward), se obtuvo exit $RC: $OUTPUT"
fi
assert_issue_edit_called "E" 60

# -------- Bloque G: guard de regresion CA-5 --------

echo ""
echo "[G] Guard de regresion: sin sintaxis posicional de shell en bloques bash de .claude/commands/*.md"

scan_bash_positional_leaks() {
    local f="$1"
    awk -v F="$f" '
        /^```bash/ {inb=1; next}
        /^```/ {inb=0; next}
        inb && (/\$[1-9]/ || /\$\{[0-9]+\}/ || /\$\*/ || /\$@/ || /\$#/) { printf "%s:%d: %s\n", F, NR, $0 }
    ' "$f"
}

VIOLATIONS=""
for f in "$REPO_ROOT"/.claude/commands/*.md; do
    hits=$(scan_bash_positional_leaks "$f")
    [ -n "$hits" ] && VIOLATIONS="$VIOLATIONS
$hits"
done
if [ -z "$VIOLATIONS" ]; then
    pass "cero hallazgos de sintaxis posicional en .claude/commands/*.md"
else
    fail "hallazgos de sintaxis posicional en .claude/commands/*.md:$VIOLATIONS"
fi

# El guard debe SI detectar un $1 introducido a mano -- si no, es un guard
# ciego que nunca pondria nada en rojo (verificacion positiva, no solo "hoy no
# encuentra nada").
SYNTH_DIR=$(mktemp -d)
cat > "$SYNTH_DIR/synthetic-leak.md" <<'EOF'
Prosa de un skill sintetico.

```bash
echo "$1"
```
EOF
HITS=$(scan_bash_positional_leaks "$SYNTH_DIR/synthetic-leak.md")
if [ -n "$HITS" ]; then
    pass "el guard detecta un \$1 introducido a mano en un archivo sintetico"
else
    fail "el guard NO detecto un \$1 introducido a mano (guard ciego)"
fi

# El guard NO debe marcar $ARGUMENTS ni ${#ARRAY[@]} (falsos positivos).
cat > "$SYNTH_DIR/synthetic-clean.md" <<'EOF'
Prosa de un skill sintetico.

```bash
echo "$ARGUMENTS"
echo "${#SEC_NAMES[@]}"
```
EOF
HITS2=$(scan_bash_positional_leaks "$SYNTH_DIR/synthetic-clean.md")
if [ -z "$HITS2" ]; then
    pass "el guard no marca \$ARGUMENTS ni \${#ARRAY[@]} (sin falsos positivos)"
else
    fail "falso positivo del guard sobre \$ARGUMENTS/\${#ARRAY[@]}: $HITS2"
fi
rm -rf "$SYNTH_DIR"

# -------- Resumen --------

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
