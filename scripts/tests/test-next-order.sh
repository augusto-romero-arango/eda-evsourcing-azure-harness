#!/usr/bin/env bash
# test-next-order.sh -- Tests de scripts/next-order.sh (issue #940).
#
# Copia hermana de .claude/scripts/tests/test-next-order.sh (issue #936):
# mismos casos del algoritmo (cadena, diamante, ciclos, bloqueos externos e
# indirectos, empates, conjunto vacio, fallos de 'gh') mas los especificos de
# este lado publicado -- guard contra el repo de Mefisto, '--launch-command'
# personalizado y su default, y el label 'tipo:' en cada linea del orden.
#
# El script real arranca con un guard que aborta si detecta
# .claude-plugin/plugin.json en la raiz del repo (este es justamente ese
# repo). Por eso se corre como subproceso real dentro de un repo de mentira
# (git init, SIN ese archivo) -- mismo patron que test-appinsights-query.sh --
# con un stub de 'gh' en el PATH dirigido por fixtures.
#
# Casos cubiertos:
#   [pre]     El script existe, es ejecutable y tiene sintaxis valida.
#   [Guard]   Corrido dentro del repo de Mefisto (con .claude-plugin/plugin.json)
#             aborta con exit 1 y mensaje claro; corrido en el repo de mentira
#             no aborta por este motivo.
#   [A]       Cadena lineal (1 -> 2 -> 3): orden exacto con justificacion y
#             label 'tipo:' en cada linea.
#   [B]       Diamante (1 -> {2,3} -> 4): orden valido, 4 lista ambas deps.
#   [C]       Ciclo de dos: se reporta 'ciclo: #A -> #B -> #A', excluido del
#             orden, exit 1.
#   [D]       Ciclo de tres: se reporta con sus tres miembros, excluido.
#   [E]       Bloqueo externo abierto: '#N bloqueado por #M: fuera de
#             estado:listo, estado OPEN', excluido del orden.
#   [F]       Dependencia CLOSED se ignora (no genera arista ni bloqueo).
#   [G]       Referencia inversa ('Bloquea #N') se ignora como dependencia.
#   [H]       Empate resuelto por numero de issue ascendente.
#   [I]       Conjunto vacio: 'Sin ciclos ni bloqueos externos.' + linea de
#             lanzamiento default '(sin issues lanzables)', exit 1.
#   [J]       Fallo de 'gh issue list' -> exit 2, sin imprimir ningun orden.
#   [K]       Guardas: argumento desconocido -> exit 2; dependencia-PR MERGED
#             no bloquea.
#   [L]       Bloqueo indirecto: un issue cuya dependencia intra-universo esta
#             bloqueada por un externo no se cuela al orden y se reporta.
#   [M]       Dependiente de un ciclo: queda fuera del orden, se reporta.
#   [N]       Higiene de formato: la cabecera no arranca con lineas en blanco.
#   [O]       '--launch-command' personalizado se refleja en la ultima linea,
#             tanto con issues lanzables como con el conjunto vacio.
#   [P]       Sin el flag, la linea de lanzamiento cae al default
#             '/mefisto:sequential'.
#   [Q]       '--launch-command' sin argumento, o con texto vacio, -> exit 2.
#
# Uso: scripts/tests/test-next-order.sh
# Exit code: 0 si todos los checks pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAL_SCRIPT="$REPO_ROOT/scripts/next-order.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# -------- Bloque pre: el script existe, es ejecutable y tiene sintaxis valida --------

echo "[pre] next-order.sh existe, es ejecutable y tiene sintaxis valida"

if [ -x "$REAL_SCRIPT" ]; then
    pass "el script existe y es ejecutable"
else
    fail "el script no existe o no es ejecutable: $REAL_SCRIPT"
fi

if bash -n "$REAL_SCRIPT" 2>/dev/null; then
    pass "sintaxis valida (bash -n)"
else
    fail "bash -n reporto un error de sintaxis en $REAL_SCRIPT"
fi

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$REAL_SCRIPT" >/dev/null 2>&1; then
        pass "shellcheck limpio"
    else
        fail "shellcheck reporto hallazgos en $REAL_SCRIPT: $(shellcheck "$REAL_SCRIPT")"
    fi
else
    pass "shellcheck no esta instalado, se omite (no es requisito duro)"
fi

# -------- Arnes: repo de mentira sin plugin.json + stub de gh --------

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAKE_REPO="$TMP/fake-consumer"
mkdir -p "$FAKE_REPO/scripts"
git -C "$FAKE_REPO" init -q
cp "$REAL_SCRIPT" "$FAKE_REPO/scripts/next-order.sh"
chmod +x "$FAKE_REPO/scripts/next-order.sh"

FAKE_BIN=$(mktemp -d)
FAKE_DATA=$(mktemp -d)
trap 'rm -rf "$TMP" "$FAKE_BIN" "$FAKE_DATA"' EXIT

# Stub de gh dirigido por fixtures en $FAKE_DATA_DIR:
#   issue_list.json      -- respuesta de 'gh issue list --json number,title,body,labels'
#   <num>.state           -- estado de una dependencia-issue fuera del listado
#   <num>.pr_state        -- estado de una dependencia que en realidad es un PR
GH_STUB='#!/usr/bin/env bash
set -uo pipefail
DATA="${FAKE_DATA_DIR:?FAKE_DATA_DIR no seteado}"

if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
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
'
write_gh_stub() { printf '%s' "$GH_STUB" > "$FAKE_BIN/gh"; chmod +x "$FAKE_BIN/gh"; }
write_gh_stub

reset_fixtures() { rm -rf "$FAKE_DATA"; mkdir -p "$FAKE_DATA"; }
set_issue_list() { cat > "$FAKE_DATA/issue_list.json"; }
set_state() { echo "$2" > "$FAKE_DATA/$1.state"; }
set_pr_state() { echo "$2" > "$FAKE_DATA/$1.pr_state"; }

run_script() {
    ( cd "$FAKE_REPO" && FAKE_DATA_DIR="$FAKE_DATA" PATH="$FAKE_BIN:$PATH" ./scripts/next-order.sh "$@" )
}

# -------- Bloque Guard: guard contra el repo de Mefisto --------

echo ""
echo "[Guard] Corrido dentro del repo de Mefisto aborta; en el repo de mentira, no"

OUTPUT=$(cd "$REPO_ROOT" && "$REAL_SCRIPT" 2>&1)
RC=$?
if [ "$RC" -eq 1 ] && echo "$OUTPUT" | grep -q "plugin publicado y solo aplica al consumidor"; then
    pass "Guard: aborta con exit 1 y mensaje correcto en el repo de Mefisto"
else
    fail "Guard: no aborto como se espera en el repo de Mefisto (exit=$RC): $OUTPUT"
fi

reset_fixtures
set_issue_list <<'EOF'
[]
EOF
OUTPUT=$(run_script 2>&1)
RC=$?
if [ "$RC" -eq 1 ] && ! echo "$OUTPUT" | grep -q "plugin publicado y solo aplica al consumidor"; then
    pass "Guard: en el repo de mentira (sin plugin.json) no aborta por el guard"
else
    fail "Guard: el repo de mentira disparo el guard indebidamente (exit=$RC): $OUTPUT"
fi

# -------- Bloque A: cadena lineal --------

echo ""
echo "[A] Cadena lineal: 401 -> 402 -> 403 (402 depende de 401, 403 depende de 402)"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":401,"title":"Base","body":"## Dependencias\n\nNinguna.","labels":[{"name":"tipo:feature"}]},
  {"number":402,"title":"Medio","body":"## Dependencias\n\nDepende de #401","labels":[{"name":"tipo:tooling"}]},
  {"number":403,"title":"Tope","body":"## Dependencias\n\nDepende de #402","labels":[{"name":"tipo:refactor"}]}
]
EOF

OUTPUT=$(run_script)
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "A: exit 0"
else
    fail "A: se esperaba exit 0, se obtuvo $RC: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^1\. #401 \[tipo:feature\] Base -- sin dependencias abiertas$"; then
    pass "A: #401 primero, con label tipo: y sin dependencias abiertas"
else
    fail "A: no se encontro la linea esperada de #401: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^2\. #402 \[tipo:tooling\] Medio -- tras #401$"; then
    pass "A: #402 segundo, con label tipo:, tras #401"
else
    fail "A: no se encontro la linea esperada de #402: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^3\. #403 \[tipo:refactor\] Tope -- tras #402$"; then
    pass "A: #403 tercero, con label tipo:, tras #402"
else
    fail "A: no se encontro la linea esperada de #403: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^/mefisto:sequential 401 402 403$"; then
    pass "A: linea de lanzamiento default '/mefisto:sequential 401 402 403'"
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
  {"number":410,"title":"Base","body":"## Dependencias\n\nNinguna.","labels":[{"name":"tipo:feature"}]},
  {"number":411,"title":"RamaA","body":"## Dependencias\n\nDepende de #410","labels":[{"name":"tipo:feature"}]},
  {"number":412,"title":"RamaB","body":"## Dependencias\n\nDepende de #410","labels":[{"name":"tipo:feature"}]},
  {"number":413,"title":"Junta","body":"## Dependencias\n\nDepende de #411\nDepende de #412","labels":[{"name":"tipo:feature"}]}
]
EOF

OUTPUT=$(run_script)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUTPUT" | grep -q "^4\. #413 \[tipo:feature\] Junta -- tras #411, #412$"; then
    pass "B: #413 lista ambas dependencias ascendente ('tras #411, #412')"
else
    fail "B: se esperaba exit 0 con '#413 ... tras #411, #412', se obtuvo exit $RC: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^/mefisto:sequential 410 411 412 413$"; then
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
  {"number":420,"title":"A","body":"## Dependencias\n\nDepende de #421","labels":[{"name":"tipo:feature"}]},
  {"number":421,"title":"B","body":"## Dependencias\n\nDepende de #420","labels":[{"name":"tipo:feature"}]}
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
if echo "$OUTPUT" | grep -q "^/mefisto:sequential (sin issues lanzables)$"; then
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
  {"number":430,"title":"A","body":"## Dependencias\n\nDepende de #431","labels":[{"name":"tipo:feature"}]},
  {"number":431,"title":"B","body":"## Dependencias\n\nDepende de #432","labels":[{"name":"tipo:feature"}]},
  {"number":432,"title":"C","body":"## Dependencias\n\nDepende de #430","labels":[{"name":"tipo:feature"}]}
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
  {"number":440,"title":"Depende de externo","body":"## Dependencias\n\nDepende de #900","labels":[{"name":"tipo:feature"}]}
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
  {"number":450,"title":"Depende de cerrada","body":"## Dependencias\n\nDepende de #901","labels":[{"name":"tipo:feature"}]}
]
EOF
set_state 901 "CLOSED"

OUTPUT=$(run_script)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUTPUT" | grep -q "^1\. #450 \[tipo:feature\] Depende de cerrada -- sin dependencias abiertas$"; then
    pass "F: dependencia CLOSED no bloquea, #450 lanza sin dependencias abiertas (exit 0)"
else
    fail "F: se esperaba exit 0 con #450 sin dependencias abiertas, se obtuvo exit $RC: $OUTPUT"
fi

# -------- Bloque G: referencia inversa 'Bloquea #N' se ignora --------

echo ""
echo "[G] 'Bloquea #N' (referencia inversa) no cuenta como dependencia forward"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":460,"title":"Bloquea a otra","body":"## Dependencias\n\nBloquea #461","labels":[{"name":"tipo:feature"}]}
]
EOF

OUTPUT=$(run_script)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUTPUT" | grep -q "^1\. #460 \[tipo:feature\] Bloquea a otra -- sin dependencias abiertas$"; then
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
  {"number":472,"title":"Segunda","body":"## Dependencias\n\nNinguna.","labels":[{"name":"tipo:feature"}]},
  {"number":471,"title":"Primera","body":"## Dependencias\n\nNinguna.","labels":[{"name":"tipo:feature"}]}
]
EOF

OUTPUT=$(run_script)
RC=$?
FIRST_LINE=$(echo "$OUTPUT" | grep -E "^1\. #47" || true)
if [ "$RC" -eq 0 ] && echo "$FIRST_LINE" | grep -q "^1\. #471 \[tipo:feature\] Primera"; then
    pass "H: #471 sale primero pese a listarse despues en el JSON (empate por numero ascendente)"
else
    fail "H: se esperaba '#471' en la posicion 1, se obtuvo: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "^/mefisto:sequential 471 472$"; then
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
if echo "$OUTPUT" | grep -q "^/mefisto:sequential (sin issues lanzables)$"; then
    pass "I: linea de lanzamiento default '(sin issues lanzables)'"
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
write_gh_stub

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
  {"number":480,"title":"Depende de un PR mergeado","body":"## Dependencias\n\nDepende de #902","labels":[{"name":"tipo:feature"}]}
]
EOF
set_pr_state 902 "MERGED"

OUTPUT=$(run_script)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUTPUT" | grep -q "^1\. #480 \[tipo:feature\] Depende de un PR mergeado -- sin dependencias abiertas$"; then
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
  {"number":504,"title":"Sana","body":"## Dependencias\n\nNinguna.","labels":[{"name":"tipo:feature"}]},
  {"number":505,"title":"Bloqueada por externo","body":"## Dependencias\n\nDepende de #999","labels":[{"name":"tipo:feature"}]},
  {"number":506,"title":"Depende de la bloqueada","body":"## Dependencias\n\nDepende de #505","labels":[{"name":"tipo:feature"}]}
]
EOF
set_state 999 "OPEN"

OUTPUT=$(run_script)
RC=$?
if echo "$OUTPUT" | grep -q "^/mefisto:sequential 504$"; then
    pass "L: solo #504 es lanzable; #506 no se cuela a la linea de lanzamiento"
else
    fail "L: se esperaba '/mefisto:sequential 504', se obtuvo (exit $RC): $OUTPUT"
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
  {"number":511,"title":"CicloA","body":"## Dependencias\n\nDepende de #512","labels":[{"name":"tipo:feature"}]},
  {"number":512,"title":"CicloB","body":"## Dependencias\n\nDepende de #511","labels":[{"name":"tipo:feature"}]},
  {"number":513,"title":"Detras del ciclo","body":"## Dependencias\n\nDepende de #511","labels":[{"name":"tipo:feature"}]},
  {"number":514,"title":"Sana","body":"## Dependencias\n\nNinguna.","labels":[{"name":"tipo:feature"}]}
]
EOF

OUTPUT=$(run_script)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUTPUT" | grep -q "^/mefisto:sequential 514$"; then
    pass "M: solo #514 es lanzable (exit 0)"
else
    fail "M: se esperaba exit 0 con '/mefisto:sequential 514', se obtuvo exit $RC: $OUTPUT"
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
  {"number":521,"title":"Bloqueada","body":"## Dependencias\n\nDepende de #998","labels":[{"name":"tipo:feature"}]}
]
EOF
set_state 998 "OPEN"

OUTPUT=$(run_script)
if [ -n "$(echo "$OUTPUT" | head -1)" ]; then
    pass "N: la primera linea de la salida es contenido, no una linea en blanco"
else
    fail "N: la salida arranca con una linea en blanco: $OUTPUT"
fi

# -------- Bloque O: --launch-command personalizado --------

echo ""
echo "[O] --launch-command personalizado se refleja en la ultima linea"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":601,"title":"Sola","body":"## Dependencias\n\nNinguna.","labels":[{"name":"tipo:feature"}]}
]
EOF

OUTPUT=$(run_script --launch-command "/otro-runtime:sequential")
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUTPUT" | grep -q "^/otro-runtime:sequential 601$"; then
    pass "O: la linea de lanzamiento usa el texto personalizado con issues lanzables"
else
    fail "O: se esperaba '/otro-runtime:sequential 601', se obtuvo (exit $RC): $OUTPUT"
fi

reset_fixtures
set_issue_list <<'EOF'
[]
EOF
OUTPUT=$(run_script --launch-command "/otro-runtime:sequential")
RC=$?
if [ "$RC" -eq 1 ] && echo "$OUTPUT" | grep -q "^/otro-runtime:sequential (sin issues lanzables)$"; then
    pass "O: la linea de lanzamiento usa el texto personalizado con conjunto vacio"
else
    fail "O: se esperaba '/otro-runtime:sequential (sin issues lanzables)', se obtuvo (exit $RC): $OUTPUT"
fi

# -------- Bloque P: sin el flag, cae al default --------

echo ""
echo "[P] Sin --launch-command, la linea de lanzamiento usa el default '/mefisto:sequential'"

reset_fixtures
set_issue_list <<'EOF'
[
  {"number":602,"title":"Sola","body":"## Dependencias\n\nNinguna.","labels":[{"name":"tipo:feature"}]}
]
EOF

OUTPUT=$(run_script)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUTPUT" | grep -q "^/mefisto:sequential 602$"; then
    pass "P: sin el flag, cae al default '/mefisto:sequential'"
else
    fail "P: se esperaba '/mefisto:sequential 602', se obtuvo (exit $RC): $OUTPUT"
fi

# -------- Bloque Q: --launch-command sin argumento --------

echo ""
echo "[Q] --launch-command sin argumento (o vacio) -> exit 2"

OUTPUT=$(run_script --launch-command 2>&1)
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "Q: --launch-command sin argumento -> exit 2"
else
    fail "Q: se esperaba exit 2, se obtuvo $RC: $OUTPUT"
fi

# Un texto vacio emitiria una ultima linea con espacio inicial y sin comando,
# indistinguible de una lista suelta de numeros: se rechaza en vez de degradar.
OUTPUT=$(run_script --launch-command "" 2>&1)
RC=$?
if [ "$RC" -eq 2 ] && echo "$OUTPUT" | grep -q "no admite texto vacio"; then
    pass "Q: --launch-command con texto vacio -> exit 2 con mensaje claro"
else
    fail "Q: se esperaba exit 2 por texto vacio, se obtuvo $RC: $OUTPUT"
fi

# -------- Resumen --------

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
