#!/usr/bin/env bash
# test-watchdog-trabajo-util.sh -- Tests del watchdog de timeout y del
# criterio de recuperacion "has_work" de run_agent() (issue #424).
#
# Contexto: dos grietas de correctitud, ambas con evidencia en el historico.
#
#   1. El watchdog no mataba nada y su mensaje nunca se escribia. `kill -9
#      -$CLAUDE_PID` apunta al GRUPO de procesos, pero el subshell lanzado con
#      `&` no era lider de grupo (heredaba el PGID del script) -- el kill
#      fallaba, y como el `echo` colgaba de un `&&`, el evento TIMEOUT nunca
#      se escribia. Los stages de #416 (writer, 1883s) y #414 (reviewer,
#      1919s) excedieron el limite nominal de 1800s y events.log tuvo CERO
#      lineas TIMEOUT en todo el historico: el limite de 30 min era decorativo.
#
#   2. Un agente que muere a mitad de respuesta abria PR igual. El reviewer de
#      #416 murio con "API Error: Connection closed mid-response" tras 882s;
#      el pipeline evaluo has_work=true (bastaba cualquier archivo sucio en el
#      worktree) y abrio el PR #421 con una revision truncada a mitad de frase.
#
# Arreglo (.claude/scripts/_mefisto-common.sh):
#   - run_agent_with_watchdog: activa job control (`set -m`/`set +m`) al
#     lanzar el comando para que el job sea lider de su propio grupo de
#     procesos -- asi `kill -9 -$pid` SI alcanza a todo el arbol (CA-1); deja
#     el evento TIMEOUT como sentencia independiente, nunca colgada de un
#     `&&` (CA-2); y deja una senal en disco cuando dispara (CA-3).
#   - agent_log_has_stream_cut / agent_failure_is_unrecoverable: derivan si el
#     fallo admite recuperacion (CA-4).
#   - agent_work_is_trustworthy: el atajo has_work deja de aplicar cuando el
#     fallo es irrecuperable (CA-4), y para el resto de fallos exige ademas
#     que el resumen de stage exista y no este vacio -- evidencia de que el
#     agente llego al final de su contrato (CA-5).
#
# Casos cubiertos:
#   [pre] Las funciones nuevas estan definidas en _mefisto-common.sh.
#   [A] CA-1: el watchdog mata TODO el arbol de procesos (proceso + hijos),
#       con un stand-in de CLI que lanza hijos (`bash -c 'sleep N & ...'`).
#   [B] CA-2: el evento TIMEOUT se escribe en events.log de forma
#       incondicional al vencer el timeout.
#   [C] CA-3: la senal de timeout se crea SOLO cuando el watchdog dispara; un
#       comando que termina antes del timeout no la deja, el exit code real
#       del comando (no 137) viaja intacto, y cancelar el watchdog no deja su
#       `sleep` huerfano.
#   [D] CA-4: agent_failure_is_unrecoverable deriva bien el flag (senal de
#       timeout, exit de senal, corte de stream en el log) y
#       agent_work_is_trustworthy nunca recupera cuando el flag esta puesto,
#       sin importar cuan sucio este el worktree.
#   [E] CA-5: para fallos recuperables, has_work exige ademas el resumen de
#       stage no vacio -- fixtures de worktree sucio con y sin resumen.
#   [F] Paridad: run_agent en el pipeline real invoca las funciones nuevas y
#       ya no contiene el patron viejo (kill encadenado con `&&`).
#
# Uso: .claude/scripts/tests/test-watchdog-trabajo-util.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# shellcheck source=/dev/null
source "$REPO_ROOT/.claude/scripts/_mefisto-common.sh" 2>/dev/null

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# -------- Bloque pre: funciones existen --------

echo "[pre] Las funciones nuevas estan definidas en _mefisto-common.sh"
for fn in run_agent_with_watchdog agent_log_has_stream_cut agent_failure_is_unrecoverable agent_work_is_trustworthy; do
    if declare -F "$fn" >/dev/null; then
        pass "$fn definida"
    else
        fail "$fn NO definida"
    fi
done

# -------- Bloque A: CA-1, mata todo el arbol de procesos --------

echo ""
echo "[A] CA-1: el watchdog mata TODO el arbol de procesos, no solo el subshell"

WT_A="$TMP/wt-a"; mkdir -p "$WT_A"
CHILD_PID_FILE="$TMP/a-child.pid"
EXIT_A=$(run_agent_with_watchdog "$WT_A" 1 "$TMP/a-log.txt" "$TMP/a-events.log" "writer" "$TMP/a-signal" \
    bash -c "sleep 30 & echo \$! > '$CHILD_PID_FILE'; sleep 30")

if [ "$EXIT_A" = "137" ]; then
    pass "A-1: exit code 137 (grupo completo recibio SIGKILL)"
else
    fail "A-1: se esperaba exit 137, se obtuvo '$EXIT_A'"
fi

# Margen para que el sistema termine de limpiar los procesos matados.
sleep 1

CHILD_PID="$(cat "$CHILD_PID_FILE" 2>/dev/null || echo "")"
if [ -n "$CHILD_PID" ] && ! kill -0 "$CHILD_PID" 2>/dev/null; then
    pass "A-2: el hijo anidado ($CHILD_PID) tambien murio -- no solo el proceso top-level"
else
    fail "A-2: el hijo anidado ($CHILD_PID) sigue vivo -- el kill no alcanzo todo el arbol"
fi

# -------- Bloque B: CA-2, evento TIMEOUT incondicional --------

echo ""
echo "[B] CA-2: el evento TIMEOUT se escribe en events.log de forma incondicional"

if grep -q "TIMEOUT: writer supero 1s" "$TMP/a-events.log" 2>/dev/null; then
    pass "B-1: la linea TIMEOUT quedo escrita en events.log (no colgo del exito del kill)"
else
    fail "B-1: no se encontro la linea TIMEOUT en events.log: $(cat "$TMP/a-events.log" 2>/dev/null)"
fi

# -------- Bloque C: CA-3, senal de timeout solo cuando el watchdog dispara --------

echo ""
echo "[C] CA-3: la senal de timeout distingue TIMEOUT de un fallo normal"

if [ -f "$TMP/a-signal" ]; then
    pass "C-1: la corrida con timeout (bloque A) dejo la senal en disco"
else
    fail "C-1: la corrida con timeout deberia haber dejado la senal en disco"
fi

WT_C="$TMP/wt-c"; mkdir -p "$WT_C"
# Timeout deliberadamente largo y con un valor irrepetible: el comando termina
# de inmediato, asi que el watchdog tiene que quedar cancelado -- y C-5 busca
# su `sleep` por ese valor exacto para que no se confunda con ningun otro
# `sleep` de la maquina.
C_TIMEOUT=3607
EXIT_C=$(run_agent_with_watchdog "$WT_C" "$C_TIMEOUT" "$TMP/c-log.txt" "$TMP/c-events.log" "writer" "$TMP/c-signal" \
    bash -c "echo hola; exit 3")

if [ "$EXIT_C" = "3" ]; then
    pass "C-2: el exit code real del comando (3) viaja intacto -- no se confunde con TIMEOUT"
else
    fail "C-2: se esperaba exit 3, se obtuvo '$EXIT_C'"
fi
if [ ! -f "$TMP/c-signal" ]; then
    pass "C-3: sin timeout, NO se crea la senal"
else
    fail "C-3: se creo la senal sin que hubiera timeout"
fi
if [ ! -s "$TMP/c-events.log" ]; then
    pass "C-4: sin timeout, events.log queda vacio (ningun evento espurio)"
else
    fail "C-4: events.log no deberia tener contenido: $(cat "$TMP/c-events.log")"
fi

# C-5: cancelar el watchdog tiene que llevarse tambien su `sleep`. Matar solo
# el PID del subshell dejaba el `sleep <timeout>` huerfano hasta media hora
# (uno por stage). Por eso el watchdog se lanza dentro de la ventana de
# `set -m` -- como lider de su propio grupo -- y se cancela con
# `kill -9 -$watchdog_pid`, que barre subshell y `sleep` de una.
sleep 1
ORPHANS=$(pgrep -f "sleep $C_TIMEOUT" 2>/dev/null | wc -l | tr -d ' ')
if [ "$ORPHANS" = "0" ]; then
    pass "C-5: cancelar el watchdog no deja el 'sleep' huerfano"
else
    fail "C-5: quedaron $ORPHANS 'sleep $C_TIMEOUT' huerfanos tras cancelar el watchdog"
fi

# -------- Fixtures de worktree para los bloques D y E --------

WT="$TMP/worktree"
mkdir -p "$WT/commands" "$WT/.claude/pipeline/summaries"
git -C "$WT" init -q
git -C "$WT" config user.email "t@t.test"
git -C "$WT" config user.name "test"
echo "base" > "$WT/commands/base.md"
# .claude/pipeline/ replica el .gitignore real del repo (issue #424, bloque E):
# sin esto, escribir el resumen de stage bajo .claude/pipeline/summaries/
# ensuciaria el status por si solo y el fixture de worktree LIMPIO (E-4) seria
# imposible de construir.
echo ".claude/pipeline/" > "$WT/.gitignore"
git -C "$WT" add -A >/dev/null
git -C "$WT" commit -qm "base"
BASE_COMMIT=$(git -C "$WT" rev-parse HEAD)

reset_wt() {
    git -C "$WT" reset -q --hard "$BASE_COMMIT"
    git -C "$WT" clean -qfd
    mkdir -p "$WT/.claude/pipeline/summaries"
}

SUMMARY="$WT/.claude/pipeline/summaries/stage-1-writer.md"

# -------- Bloque D: CA-4, unrecoverable siempre gana --------

echo ""
echo "[D] CA-4: unrecoverable (TIMEOUT / corte de stream) nunca se recupera"

# Primero la DERIVACION del flag (agent_failure_is_unrecoverable): es la
# decision que de hecho corta el paso a un PR truncado, asi que se testea la
# funcion real y no una reimplementacion del criterio.
LOG_LIMPIO="$TMP/d-log-limpio.txt"
printf 'todo bien\nresumen escrito\n' > "$LOG_LIMPIO"
LOG_CORTE="$TMP/d-log-corte.txt"
printf 'trabajando...\nAPI Error: Connection closed mid-response\n' > "$LOG_CORTE"

if agent_failure_is_unrecoverable "true" "0" "$LOG_LIMPIO"; then
    pass "D-1: la senal de TIMEOUT marca irrecuperable aunque el exit code sea 0"
else
    fail "D-1: timed_out=true deberia marcar irrecuperable"
fi

if agent_failure_is_unrecoverable "false" "137" "$LOG_LIMPIO"; then
    pass "D-2: exit 137 (SIGKILL) marca irrecuperable sin mirar el log"
else
    fail "D-2: exit 137 deberia marcar irrecuperable"
fi

# El incidente literal de #416: exit code ordinario, log con el corte de stream.
if agent_failure_is_unrecoverable "false" "1" "$LOG_CORTE"; then
    pass "D-3: 'API Error: Connection closed mid-response' en el log marca irrecuperable (incidente #416)"
else
    fail "D-3: el corte de stream a mitad de respuesta deberia marcar irrecuperable"
fi

if agent_failure_is_unrecoverable "false" "1" "$LOG_LIMPIO"; then
    fail "D-4 (control): un fallo ordinario NO deberia marcarse irrecuperable"
else
    pass "D-4 (control): fallo ordinario (exit 1, log sin corte) sigue siendo recuperable"
fi

# Y ahora el EFECTO del flag sobre el criterio de recuperacion.

# D-5: worktree bien sucio + resumen presente y no vacio, pero unrecoverable=true.
reset_wt
echo "cambio" > "$WT/commands/base.md"
echo "resumen del writer" > "$SUMMARY"
if agent_work_is_trustworthy "$WT" "$BASE_COMMIT" "true" "$SUMMARY"; then
    fail "D-5: unrecoverable=true NO deberia recuperar aunque el worktree este sucio y haya resumen"
else
    pass "D-5: unrecoverable=true aborta pese a worktree sucio y resumen presente"
fi

# D-6: mismo escenario pero unrecoverable=false -- debe SI recuperar (control).
if agent_work_is_trustworthy "$WT" "$BASE_COMMIT" "false" "$SUMMARY"; then
    pass "D-6 (control): unrecoverable=false SI recupera con worktree sucio y resumen"
else
    fail "D-6 (control): deberia recuperar con worktree sucio, resumen presente y unrecoverable=false"
fi

# -------- Bloque E: CA-5, has_work exige resumen de stage no vacio --------

echo ""
echo "[E] CA-5: has_work exige ademas el resumen de stage, no vacio"

# E-1: worktree sucio SIN resumen -> no recuperable.
reset_wt
echo "cambio" > "$WT/commands/base.md"
rm -f "$SUMMARY"
if agent_work_is_trustworthy "$WT" "$BASE_COMMIT" "false" "$SUMMARY"; then
    fail "E-1: sin resumen de stage NO deberia recuperar aunque el worktree este sucio"
else
    pass "E-1: worktree sucio sin resumen de stage -- no se recupera"
fi

# E-2: worktree sucio con resumen VACIO -> no recuperable.
reset_wt
echo "cambio" > "$WT/commands/base.md"
: > "$SUMMARY"
if agent_work_is_trustworthy "$WT" "$BASE_COMMIT" "false" "$SUMMARY"; then
    fail "E-2: con resumen VACIO no deberia recuperar"
else
    pass "E-2: worktree sucio con resumen vacio -- no se recupera"
fi

# E-3: worktree sucio con resumen presente y no vacio -> SI recuperable.
reset_wt
echo "cambio" > "$WT/commands/base.md"
echo "resumen del writer" > "$SUMMARY"
if agent_work_is_trustworthy "$WT" "$BASE_COMMIT" "false" "$SUMMARY"; then
    pass "E-3: worktree sucio con resumen no vacio -- se recupera"
else
    fail "E-3: deberia recuperar con worktree sucio y resumen no vacio"
fi

# E-4: worktree LIMPIO (sin diff, sin status sucio) con resumen presente -> no hay has_work, no se recupera.
reset_wt
echo "resumen del writer" > "$SUMMARY"
git -C "$WT" add -A >/dev/null 2>&1 || true
if agent_work_is_trustworthy "$WT" "$BASE_COMMIT" "false" "$SUMMARY"; then
    fail "E-4: worktree limpio (sin has_work) no deberia recuperar aunque haya resumen"
else
    pass "E-4: worktree limpio -- no hay has_work, no se recupera"
fi

# -------- Bloque F: paridad con el pipeline real --------

echo ""
echo "[F] Paridad: run_agent del pipeline real usa las funciones nuevas"

PIPE="$REPO_ROOT/.claude/scripts/mefisto-tooling-pipeline.sh"

if grep -q "run_agent_with_watchdog" "$PIPE"; then
    pass "F-1: mefisto-tooling-pipeline.sh invoca run_agent_with_watchdog"
else
    fail "F-1: mefisto-tooling-pipeline.sh NO invoca run_agent_with_watchdog"
fi

if grep -q "agent_work_is_trustworthy" "$PIPE"; then
    pass "F-2: mefisto-tooling-pipeline.sh invoca agent_work_is_trustworthy"
else
    fail "F-2: mefisto-tooling-pipeline.sh NO invoca agent_work_is_trustworthy"
fi

# El pipeline tiene que DERIVAR el flag con la funcion testeada arriba, no con
# una copia inline del grep: una copia se desincroniza en silencio y el bloque
# D dejaria de cubrir lo que el pipeline realmente ejecuta.
if grep -q "agent_failure_is_unrecoverable" "$PIPE"; then
    pass "F-3: mefisto-tooling-pipeline.sh deriva el flag con agent_failure_is_unrecoverable"
else
    fail "F-3: mefisto-tooling-pipeline.sh NO invoca agent_failure_is_unrecoverable"
fi

# El patron viejo era exactamente esta cadena de `&&`: kill ... && echo ... El
# arreglo la elimina; si reaparece, el evento TIMEOUT volveria a colgar del
# exito del kill (la grieta original).
if grep -qE 'kill -9 -\$[A-Za-z_]+ 2>/dev/null && echo' "$PIPE"; then
    fail "F-4: reaparecio el patron viejo (kill encadenado con && antes del echo)"
else
    pass "F-4: no quedo el patron viejo de kill encadenado con && antes del echo"
fi

# El patron del corte de stream tiene que vivir en UN solo lugar
# (agent_log_has_stream_cut). Si reaparece como grep inline en el pipeline,
# etiqueta (STREAM_CUT) y decision (abortar) pueden desincronizarse en
# silencio. Se busca la llamada a grep, no la frase suelta: el pipeline la
# menciona legitimamente en un comentario.
if grep -q 'grep -qE "Connection closed mid-response' "$PIPE"; then
    fail "F-5: quedo una copia inline del grep de corte de stream en el pipeline"
else
    pass "F-5: el criterio de corte de stream no quedo duplicado inline en el pipeline"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
