#!/usr/bin/env bash
# test-next-order.sh -- Tests de mefisto-next-order.sh (issue #936).
#
# Ese script calcula el orden topologico de lanzamiento de los issues
# 'estado:listo' abiertos, algo que hoy mefisto-planner razona a mano leyendo
# '## Dependencias' (modo 'orden-de-batch') sin garantia de determinismo ni
# deteccion de ciclos. Mismo patron de stub de gh que
# test-batch-deps-validation.sh: un fixture JSON con la respuesta de
# 'gh issue list' y archivos '<num>.state' / '<num>.pr_state' para las
# dependencias que caen fuera de ese listado.
#
# Casos cubiertos (CA-5):
#   [pre]     El script existe, es ejecutable y tiene sintaxis valida.
#   [A]       Cadena lineal (1 -> 2 -> 3): orden exacto con justificacion.
#   [B]       Diamante (1 -> {2,3} -> 4): orden valido, 4 lista ambas deps.
#   [C]       Ciclo de dos: se reporta 'ciclo: #A -> #B -> #A', excluido del
#             orden, exit 1.
#   [D]       Ciclo de tres: se reporta con sus tres miembros, excluido.
#   [E]       Bloqueo externo abierto: '#N bloqueado por #M: fuera de
#             estado:listo, estado OPEN', excluido del orden.
#   [F]       Dependencia CLOSED se ignora (no genera arista ni bloqueo).
#   [G]       Referencia inversa ('Bloquea #N') se ignora como dependencia.
#   [H]       Empate resuelto por numero de issue ascendente (dos issues sin
#             dependencias entre si).
#   [I]       Conjunto vacio: 'Sin ciclos ni bloqueos externos.' + linea de
#             lanzamiento '(sin issues lanzables)', exit 1.
#   [J]       Fallo de 'gh issue list' -> exit 2, sin imprimir ningun orden.
#   [K]       Guardas: argumento desconocido -> exit 2; universo sano sin
#             ciclos/bloqueos imprime 'Sin ciclos ni bloqueos externos.'.
#   [L]       Bloqueo indirecto: un issue cuya dependencia intra-universo esta
#             bloqueada por un externo no se cuela al orden y se reporta.
#   [M]       Dependiente de un ciclo: queda fuera del orden, se reporta, y no
#             se confunde con un miembro del ciclo.
#   [N]       Higiene de formato: la cabecera no arranca con lineas en blanco.
#   [O]       --refinement: el universo es estado:borrador; un borrador que
#             depende de otro va despues de el.
#   [P]       --refinement: una dependencia 'estado:listo' abierta esta
#             satisfecha; una abierta sin estado bloquea.
#   [Q]       --json: objeto valido con items (after, hasDepsSection),
#             blocked, cycles y launch; mismos exit codes.
#
# Uso: .claude/scripts/tests/test-next-order.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/src/internal/scripts/mefisto-next-order.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# -------- Bloque pre: el script existe, es ejecutable y tiene sintaxis valida --------

echo "[pre] mefisto-next-order.sh existe, es ejecutable y tiene sintaxis valida"

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

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$SCRIPT" >/dev/null 2>&1; then
        pass "shellcheck limpio"
    else
        fail "shellcheck reporto hallazgos en $SCRIPT: $(shellcheck "$SCRIPT")"
    fi
else
    pass "shellcheck no esta instalado, se omite (no es requisito duro)"
fi

# -------- Fixtures y stub de gh --------

FAKE_BIN=$(mktemp -d)
FAKE_DATA=$(mktemp -d)
cleanup() { rm -rf "$FAKE_BIN" "$FAKE_DATA"; }
trap cleanup EXIT

# Stub de gh dirigido por fixtures en $FAKE_DATA_DIR:
#   issue_list.json      -- respuesta de 'gh issue list --json number,title,body'
#   <num>.state           -- estado de una dependencia-issue fuera del listado
#   <num>.pr_state        -- estado de una dependencia que en realidad es un PR
#   listo_nums            -- en --refinement, los numeros 'estado:listo' abiertos
#                            (la consulta de borradores sigue en issue_list.json)
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
DATA="${FAKE_DATA_DIR:?FAKE_DATA_DIR no seteado}"

if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
    if [ -f "$DATA/listo_nums" ] && [[ " $* " == *" estado:listo "* ]]; then
        cat "$DATA/listo_nums"
        exit 0
    fi
    cat "$DATA/issue_list.json"
    exit 0
fi

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    num="$3"
    if [ -f "$DATA/$num.state" ]; then
        cat "$DATA/$num.state"
        exit 0
    fi
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

exit 1
EOF
chmod +x "$FAKE_BIN/gh"
cp "$FAKE_BIN/gh" "$FAKE_BIN/gh.normal"

reset_fixtures() { rm -rf "$FAKE_DATA"; mkdir -p "$FAKE_DATA"; }
set_issue_list() { cat > "$FAKE_DATA/issue_list.json"; }
set_state() { echo "$2" > "$FAKE_DATA/$1.state"; }
set_pr_state() { echo "$2" > "$FAKE_DATA/$1.pr_state"; }

run_script() {
    FAKE_DATA_DIR="$FAKE_DATA" PATH="$FAKE_BIN:$PATH" "$SCRIPT" "$@"
}

# -------- Bloque A: cadena lineal --------

echo ""
echo "[A] Cadena lineal: 401 -> 402 -> 403 (402 depende de 401, 403 depende de 402)"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":401,"title":"Base","body":"## Dependencias\n\nNinguna."},
  {"number":402,"title":"Medio","body":"## Dependencias\n\nDepende de #401"},
  {"number":403,"title":"Tope","body":"## Dependencias\n\nDepende de #402"}
]
EOF

OUTPUT=$(run_script)
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "A: exit 0"
else
    fail "A: se esperaba exit 0, se obtuvo $RC: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^1\. #401 Base -- sin dependencias abiertas$"; then
    pass "A: #401 primero, sin dependencias abiertas"
else
    fail "A: no se encontro la linea esperada de #401: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^2\. #402 Medio -- tras #401$"; then
    pass "A: #402 segundo, tras #401"
else
    fail "A: no se encontro la linea esperada de #402: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^3\. #403 Tope -- tras #402$"; then
    pass "A: #403 tercero, tras #402"
else
    fail "A: no se encontro la linea esperada de #403: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^/mefisto-sequential 401 402 403$"; then
    pass "A: linea de lanzamiento '/mefisto-sequential 401 402 403'"
else
    fail "A: linea de lanzamiento inesperada: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "Sin ciclos ni bloqueos externos\."; then
    pass "A: reporta 'Sin ciclos ni bloqueos externos.'"
else
    fail "A: no reporto la linea explicita de ausencia de ciclos/bloqueos: $OUTPUT"
fi

# -------- Bloque B: diamante --------

echo ""
echo "[B] Diamante: 410 -> {411,412} -> 413 (413 depende de 411 y 412)"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":410,"title":"Base","body":"## Dependencias\n\nNinguna."},
  {"number":411,"title":"RamaA","body":"## Dependencias\n\nDepende de #410"},
  {"number":412,"title":"RamaB","body":"## Dependencias\n\nDepende de #410"},
  {"number":413,"title":"Junta","body":"## Dependencias\n\nDepende de #411\nDepende de #412"}
]
EOF

OUTPUT=$(run_script)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUTPUT" | grep -q "^4\. #413 Junta -- tras #411, #412$"; then
    pass "B: #413 lista ambas dependencias ascendente ('tras #411, #412')"
else
    fail "B: se esperaba exit 0 con '#413 ... tras #411, #412', se obtuvo exit $RC: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^/mefisto-sequential 410 411 412 413$"; then
    pass "B: linea de lanzamiento con las 4 issues en orden"
else
    fail "B: linea de lanzamiento inesperada: $OUTPUT"
fi

# -------- Bloque C: ciclo de dos --------

echo ""
echo "[C] Ciclo de dos: 420 depende de 421, 421 depende de 420"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":420,"title":"A","body":"## Dependencias\n\nDepende de #421"},
  {"number":421,"title":"B","body":"## Dependencias\n\nDepende de #420"}
]
EOF

OUTPUT=$(run_script)
RC=$?
if [ "$RC" -eq 1 ]; then
    pass "C: exit 1 (ningun issue lanzable)"
else
    fail "C: se esperaba exit 1, se obtuvo $RC: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^ciclo: #420 -> #421 -> #420$"; then
    pass "C: reporta 'ciclo: #420 -> #421 -> #420'"
else
    fail "C: no reporto el ciclo esperado: $OUTPUT"
fi
if echo "$OUTPUT" | grep -qE "^[0-9]+\. #42[01]"; then
    fail "C: #420/#421 no deberian aparecer en el orden (estan en un ciclo): $OUTPUT"
else
    pass "C: #420/#421 excluidos del orden"
fi
if echo "$OUTPUT" | grep -q "^/mefisto-sequential (sin issues lanzables)$"; then
    pass "C: linea de lanzamiento '(sin issues lanzables)'"
else
    fail "C: linea de lanzamiento inesperada: $OUTPUT"
fi

# -------- Bloque D: ciclo de tres --------

echo ""
echo "[D] Ciclo de tres: 430 -> 431 -> 432 -> 430"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":430,"title":"A","body":"## Dependencias\n\nDepende de #431"},
  {"number":431,"title":"B","body":"## Dependencias\n\nDepende de #432"},
  {"number":432,"title":"C","body":"## Dependencias\n\nDepende de #430"}
]
EOF

OUTPUT=$(run_script)
RC=$?
if [ "$RC" -eq 1 ] && echo "$OUTPUT" | grep -q "^ciclo: #430 -> #431 -> #432 -> #430$"; then
    pass "D: reporta el ciclo de tres con sus tres miembros (exit 1)"
else
    fail "D: se esperaba exit 1 con el ciclo de tres, se obtuvo exit $RC: $OUTPUT"
fi

# -------- Bloque E: bloqueo externo abierto --------

echo ""
echo "[E] Bloqueo externo: 440 depende de 900, que esta fuera de estado:listo y OPEN"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":440,"title":"Depende de externo","body":"## Dependencias\n\nDepende de #900"}
]
EOF
set_state 900 "OPEN"

OUTPUT=$(run_script)
RC=$?
if [ "$RC" -eq 1 ]; then
    pass "E: exit 1 (ningun issue lanzable)"
else
    fail "E: se esperaba exit 1, se obtuvo $RC: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^#440 bloqueado por #900: fuera de estado:listo, estado OPEN$"; then
    pass "E: reporta el bloqueo externo con el formato exacto"
else
    fail "E: no reporto el bloqueo externo esperado: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^1\. #440"; then
    fail "E: #440 no deberia aparecer en el orden (bloqueo externo abierto): $OUTPUT"
else
    pass "E: #440 excluido del orden"
fi

# -------- Bloque F: dependencia CLOSED se ignora --------

echo ""
echo "[F] Dependencia CLOSED (fuera del universo) no bloquea ni genera arista"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":450,"title":"Depende de cerrada","body":"## Dependencias\n\nDepende de #901"}
]
EOF
set_state 901 "CLOSED"

OUTPUT=$(run_script)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUTPUT" | grep -q "^1\. #450 Depende de cerrada -- sin dependencias abiertas$"; then
    pass "F: dependencia CLOSED no bloquea, #450 lanza sin dependencias abiertas (exit 0)"
else
    fail "F: se esperaba exit 0 con #450 sin dependencias abiertas, se obtuvo exit $RC: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "Sin ciclos ni bloqueos externos\."; then
    pass "F: reporta 'Sin ciclos ni bloqueos externos.'"
else
    fail "F: no reporto la linea explicita: $OUTPUT"
fi

# -------- Bloque G: referencia inversa 'Bloquea #N' se ignora --------

echo ""
echo "[G] 'Bloquea #N' (referencia inversa) no cuenta como dependencia forward"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":460,"title":"Bloquea a otra","body":"## Dependencias\n\nBloquea #461"}
]
EOF

OUTPUT=$(run_script)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUTPUT" | grep -q "^1\. #460 Bloquea a otra -- sin dependencias abiertas$"; then
    pass "G: 'Bloquea #461' se ignora, #460 lanza sin dependencias abiertas (exit 0)"
else
    fail "G: se esperaba exit 0 con #460 sin dependencias abiertas, se obtuvo exit $RC: $OUTPUT"
fi

# -------- Bloque H: empate resuelto por numero de issue ascendente --------

echo ""
echo "[H] Empate: dos issues sin dependencias entre si se ordenan por numero ascendente"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":472,"title":"Segunda","body":"## Dependencias\n\nNinguna."},
  {"number":471,"title":"Primera","body":"## Dependencias\n\nNinguna."}
]
EOF

OUTPUT=$(run_script)
RC=$?
FIRST_LINE=$(echo "$OUTPUT" | grep -E "^1\. #47" || true)
if [ "$RC" -eq 0 ] && echo "$FIRST_LINE" | grep -q "^1\. #471 Primera"; then
    pass "H: #471 sale primero pese a listarse despues en el JSON (empate por numero ascendente)"
else
    fail "H: se esperaba '#471' en la posicion 1, se obtuvo: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^/mefisto-sequential 471 472$"; then
    pass "H: linea de lanzamiento en orden ascendente '471 472'"
else
    fail "H: linea de lanzamiento inesperada: $OUTPUT"
fi

# -------- Bloque I: conjunto vacio --------

echo ""
echo "[I] Conjunto vacio: ningun issue 'estado:listo' abierto"

reset_fixtures
set_issue_list <<'EOF'
[]
EOF

OUTPUT=$(run_script)
RC=$?
if [ "$RC" -eq 1 ]; then
    pass "I: exit 1 (conjunto vacio, ningun issue lanzable)"
else
    fail "I: se esperaba exit 1, se obtuvo $RC: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "Sin ciclos ni bloqueos externos\."; then
    pass "I: reporta 'Sin ciclos ni bloqueos externos.'"
else
    fail "I: no reporto la linea explicita: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^/mefisto-sequential (sin issues lanzables)$"; then
    pass "I: linea de lanzamiento '(sin issues lanzables)'"
else
    fail "I: linea de lanzamiento inesperada: $OUTPUT"
fi

# -------- Bloque J: fallo de 'gh issue list' --------

echo ""
echo "[J] Fallo de 'gh issue list' -> exit 2, sin imprimir ningun orden"

cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_BIN/gh"

OUTPUT=$(run_script 2>&1)
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "J: exit 2 cuando 'gh issue list' falla"
else
    fail "J: se esperaba exit 2, se obtuvo $RC: $OUTPUT"
fi
if echo "$OUTPUT" | grep -qE "^[0-9]+\. #"; then
    fail "J: no deberia imprimir ninguna linea de orden si 'gh' fallo: $OUTPUT"
else
    pass "J: no imprime ninguna linea de orden"
fi

# Restaurar el stub normal para el resto de los bloques.
cp "$FAKE_BIN/gh.normal" "$FAKE_BIN/gh"

# -------- Bloque K: guardas --------

echo ""
echo "[K] Guardas: argumento desconocido -> exit 2"

reset_fixtures
set_issue_list <<'EOF'
[]
EOF

OUTPUT=$(run_script --nunca-existio 2>&1)
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "K: argumento desconocido -> exit 2"
else
    fail "K: se esperaba exit 2 con un argumento desconocido, se obtuvo $RC: $OUTPUT"
fi

# Guarda de no-regresion: dependencia-PR MERGED se trata igual que un issue
# CLOSED/MERGED (satisfecha, no genera arista ni bloqueo).
reset_fixtures
set_issue_list <<'EOF'
[
  {"number":480,"title":"Depende de un PR mergeado","body":"## Dependencias\n\nDepende de #902"}
]
EOF
set_pr_state 902 "MERGED"

OUTPUT=$(run_script)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUTPUT" | grep -q "^1\. #480 Depende de un PR mergeado -- sin dependencias abiertas$"; then
    pass "K: dependencia-PR MERGED no bloquea (exit 0, sin dependencias abiertas)"
else
    fail "K: se esperaba exit 0 con #480 sin dependencias abiertas, se obtuvo exit $RC: $OUTPUT"
fi

# -------- Bloque L: bloqueo indirecto por bloqueo externo aguas arriba --------

echo ""
echo "[L] Bloqueo indirecto: 506 depende de 505, que esta bloqueada por un externo abierto"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":504,"title":"Sana","body":"## Dependencias\n\nNinguna."},
  {"number":505,"title":"Bloqueada por externo","body":"## Dependencias\n\nDepende de #999"},
  {"number":506,"title":"Depende de la bloqueada","body":"## Dependencias\n\nDepende de #505"}
]
EOF
set_state 999 "OPEN"

OUTPUT=$(run_script)
RC=$?
# Regresion: #506 declara una dependencia abierta (#505) que NO entra al orden.
# Colarla al orden emitiria un '/mefisto-sequential 504 506' que
# mefisto-validate-batch-deps.sh rechaza en el paso 1.5 (dependencia abierta
# fuera del batch = bloqueo real, aborta el batch entero).
if echo "$OUTPUT" | grep -q "^/mefisto-sequential 504$"; then
    pass "L: solo #504 es lanzable; #506 no se cuela a la linea de lanzamiento"
else
    fail "L: se esperaba '/mefisto-sequential 504', se obtuvo (exit $RC): $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^#506 bloqueado por #505: excluido del orden$"; then
    pass "L: #506 se reporta como bloqueo indirecto (no queda en silencio)"
else
    fail "L: #506 no se reporto como excluido: $OUTPUT"
fi
if echo "$OUTPUT" | grep -qE "^[0-9]+\. #506"; then
    fail "L: #506 no deberia aparecer en el orden: $OUTPUT"
else
    pass "L: #506 excluido del orden"
fi

# -------- Bloque M: dependiente de un ciclo --------

echo ""
echo "[M] Dependiente de un ciclo: 511<->512 en ciclo, 513 depende de 511"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":511,"title":"CicloA","body":"## Dependencias\n\nDepende de #512"},
  {"number":512,"title":"CicloB","body":"## Dependencias\n\nDepende de #511"},
  {"number":513,"title":"Detras del ciclo","body":"## Dependencias\n\nDepende de #511"},
  {"number":514,"title":"Sana","body":"## Dependencias\n\nNinguna."}
]
EOF

OUTPUT=$(run_script)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUTPUT" | grep -q "^/mefisto-sequential 514$"; then
    pass "M: solo #514 es lanzable (exit 0)"
else
    fail "M: se esperaba exit 0 con '/mefisto-sequential 514', se obtuvo exit $RC: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^ciclo: #511 -> #512 -> #511$"; then
    pass "M: reporta el ciclo #511 <-> #512"
else
    fail "M: no reporto el ciclo: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^#513 bloqueado por #511: excluido del orden$"; then
    pass "M: #513 (detras del ciclo) se reporta, no queda en silencio"
else
    fail "M: #513 no se reporto como excluido: $OUTPUT"
fi
if echo "$OUTPUT" | grep -qE "^ciclo: .*#513"; then
    fail "M: #513 no es miembro del ciclo, no debe aparecer en la linea de ciclo: $OUTPUT"
else
    pass "M: #513 no se reporta como miembro del ciclo"
fi

# -------- Bloque N: higiene de formato de la cabecera --------

echo ""
echo "[N] La cabecera del reporte no arranca con lineas en blanco"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":521,"title":"Bloqueada","body":"## Dependencias\n\nDepende de #998"}
]
EOF
set_state 998 "OPEN"

OUTPUT=$(run_script)
if [ -n "$(echo "$OUTPUT" | head -1)" ]; then
    pass "N: la primera linea de la salida es contenido, no una linea en blanco"
else
    fail "N: la salida arranca con una linea en blanco: $OUTPUT"
fi

# -------- Bloque O: --refinement, borrador tras borrador --------

echo ""
echo "[O] --refinement: 602 depende del borrador 601, 603 no declara '## Dependencias'"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":601,"title":"Base borrador","body":"## Dependencias\n\nNinguna."},
  {"number":602,"title":"Sobre la base","body":"## Dependencias\n\nDepende de #601"},
  {"number":603,"title":"Idea suelta","body":"## Idea\n\nAlgo."}
]
EOF
: > "$FAKE_DATA/listo_nums"

OUTPUT=$(run_script --refinement)
RC=$?
if [ "$RC" -eq 0 ] \
    && echo "$OUTPUT" | grep -q "^1\. #601 Base borrador -- sin dependencias abiertas$" \
    && echo "$OUTPUT" | grep -q "^2\. #602 Sobre la base -- tras #601$" \
    && echo "$OUTPUT" | grep -q "^3\. #603 Idea suelta -- sin dependencias abiertas$"; then
    pass "O: orden de refinamiento 601, 602 (tras #601), 603"
    if echo "$OUTPUT" | tail -1 | grep -q "^Siguiente a refinar: #601$"; then
        pass "O: la ultima linea sugiere el siguiente a refinar, no un /mefisto-sequential"
    else
        fail "O: ultima linea inesperada: $(echo "$OUTPUT" | tail -1)"
    fi
else
    fail "O: orden inesperado (exit $RC): $OUTPUT"
fi

# -------- Bloque P: --refinement, dependencia listo satisfecha y abierta sin estado --------

echo ""
echo "[P] --refinement: 611 depende de un listo abierto (#950), 612 de un abierto sin estado (#951)"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":611,"title":"Tras un listo","body":"## Dependencias\n\nDepende de #950"},
  {"number":612,"title":"Tras algo abierto","body":"## Dependencias\n\nDepende de #951"}
]
EOF
printf '950\n' > "$FAKE_DATA/listo_nums"
set_state 951 "OPEN"

OUTPUT=$(run_script --refinement)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUTPUT" | grep -q "^1\. #611 Tras un listo -- sin dependencias abiertas$"; then
    pass "P: una dependencia estado:listo abierta no bloquea el refinamiento"
else
    fail "P: #611 deberia ser refinable (exit $RC): $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^#612 bloqueado por #951: fuera de estado:borrador, estado OPEN$"; then
    pass "P: una dependencia abierta sin estado bloquea y se reporta"
else
    fail "P: falta el bloqueo de #612: $OUTPUT"
fi

# -------- Bloque Q: --json --------

echo ""
echo "[Q] --json: objeto estructurado con items, blocked, cycles y launch"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":621,"title":"Base","body":"## Dependencias\n\nNinguna."},
  {"number":622,"title":"Tras base","body":"## Dependencias\n\nDepende de #621"},
  {"number":623,"title":"Bloqueado","body":"## Dependencias\n\nDepende de #952"},
  {"number":624,"title":"Ciclo A","body":"## Dependencias\n\nDepende de #625"},
  {"number":625,"title":"Ciclo B","body":"## Dependencias\n\nDepende de #624"},
  {"number":626,"title":"Sin seccion","body":"Texto"}
]
EOF
set_state 952 "OPEN"

OUTPUT=$(run_script --json)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUTPUT" | jq -e . >/dev/null 2>&1; then
    pass "Q: JSON valido y exit 0"
else
    fail "Q: JSON invalido o exit $RC: $OUTPUT"
fi
GOT=$(echo "$OUTPUT" | jq -c '[.mode, [.items[].number], .items[1].after, .launch]')
if [ "$GOT" = '["launch",[621,622,626],[621],"/mefisto-sequential 621 622 626"]' ]; then
    pass "Q: mode, orden, after y launch correctos"
else
    fail "Q: items/launch inesperados: $GOT"
fi
GOT=$(echo "$OUTPUT" | jq -c '[([.items[] | select(.number==626) | .hasDepsSection][0]), .blocked, .cycles]')
if [ "$GOT" = '[false,[{"number":623,"by":952,"reason":"external"}],[[624,625]]]' ]; then
    pass "Q: hasDepsSection, blocked y cycles correctos"
else
    fail "Q: blocked/cycles inesperados: $GOT"
fi

reset_fixtures
set_issue_list <<'EOF'
[]
EOF
OUTPUT=$(run_script --json --refinement)
RC=$?
GOT=$(echo "$OUTPUT" | jq -c '[.mode, .items, .launch]')
if [ "$RC" -eq 1 ] && [ "$GOT" = '["refinement",[],null]' ]; then
    pass "Q: universo vacio -> exit 1 con items vacios y launch null"
else
    fail "Q: universo vacio inesperado (exit $RC): $OUTPUT"
fi

# -------- Bloque R: una negacion no genera ciclo (issue #2126) --------

echo ""
echo "[R] 'No depende de #M' no es dependencia: sin ciclo falso, ambos lanzables"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":501,"title":"Neg","body":"## Dependencias\n\n- No depende de #502"},
  {"number":502,"title":"Dep","body":"## Dependencias\n\n- Depende de #501"}
]
EOF

OUTPUT=$(run_script)
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "R: exit 0 (sin ciclos)"
else
    fail "R: se esperaba exit 0, se obtuvo $RC: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^/mefisto-sequential 501 502$"; then
    pass "R: ambos lanzables, 501 antes que 502"
else
    fail "R: linea de lanzamiento inesperada: $OUTPUT"
fi
if echo "$OUTPUT" | grep -qi "ciclo: "; then
    fail "R: reporto un ciclo falso: $OUTPUT"
else
    pass "R: sin ciclo falso"
fi

# -------- Resumen --------

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
