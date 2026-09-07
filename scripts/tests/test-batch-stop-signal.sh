#!/usr/bin/env bash
# test-batch-stop-signal.sh -- Tests de la senal de parada suave de los
# orquestadores publicados (issue #974, mismo diseno que el motor interno
# #966): detiene batch-pipeline.sh/parallel-pipeline.sh tras el trabajo en
# curso sin matar ningun proceso, via pipeline-state/batch-stop (MEF-ADR-0017).
#
# Cubre:
#   [pre] Ambos scripts existen, son ejecutables y tienen sintaxis valida.
#   [A]   batch_stop_requested()/defer_from_index() de batch-pipeline.sh en
#         aislamiento: sin senal no dispara nada; con senal, defer_from_index
#         consume el archivo (CA-4) y marca "aplazado" (CA-2/CA-3) solo desde
#         el indice indicado, sin tocar los issues anteriores.
#   [B]   Guard de regresion: defer_from_index() de batch-pipeline.sh nunca
#         toca HAVE_ERRORS ni FAILED (CA-5 -- una parada solicitada no es un
#         fallo).
#   [C]   batch_stop_requested()/defer_pending_issues() de parallel-pipeline.sh
#         en aislamiento: consume la senal y marca DEFERRED_FLAG solo para los
#         indices que seguian pendientes de lanzar (CA-3/CA-4), sin tocar los
#         ya lanzados.
#   [D]   Guard de regresion: defer_pending_issues() de parallel-pipeline.sh
#         nunca toca PIDS ni FAILED (CA-5).
#   [E]   batch-pipeline.sh, corrida real end-to-end: la senal YA presente
#         antes de arrancar detiene el batch entero sin invocar
#         tooling-pipeline.sh para NINGUN issue (CA-1 momento 1, CA-2), deja
#         "aplazado" a los tres, exit 0 (CA-5) y consume la senal (CA-4).
#   [F]   batch-pipeline.sh, corrida real end-to-end: la senal aparece DURANTE
#         el primer eslabon -- ese eslabon se completa entero (pipeline, PR,
#         merge) y los restantes quedan "aplazado" sin arrancar ningun
#         worktree (CA-1 momento 2, CA-2), exit 0 y sin incrementar FAILED
#         (CA-5), con la linea de relanzamiento en el orden correcto (CA-3).
#   [G]   Caso limite: la senal llega durante el ULTIMO eslabon. No queda nada
#         que aplazar (defer de cero issues, que bajo `set -e` no debe matar
#         al motor), no se imprime linea de relanzamiento y la senal se
#         consume igual (CA-4).
#
# Uso: scripts/tests/test-batch-stop-signal.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BATCH_SCRIPT="$REPO_ROOT/scripts/batch-pipeline.sh"
PARALLEL_SCRIPT="$REPO_ROOT/scripts/parallel-pipeline.sh"
COMMON_LIB="$REPO_ROOT/scripts/_pipeline-common.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# -------- Bloque pre: ambos scripts existen, son ejecutables y compilan --------

echo "[pre] batch-pipeline.sh y parallel-pipeline.sh existen, son ejecutables y tienen sintaxis valida"

for f in "$BATCH_SCRIPT" "$PARALLEL_SCRIPT"; do
    if [ -x "$f" ]; then
        pass "$(basename "$f"): existe y es ejecutable"
    else
        fail "$(basename "$f"): no existe o no es ejecutable"
    fi
    if bash -n "$f" 2>/dev/null; then
        pass "$(basename "$f"): sintaxis valida (bash -n)"
    else
        fail "$(basename "$f"): bash -n reporto un error de sintaxis"
    fi
done

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# -------- Extraer las funciones REALES bajo prueba (no reimplementarlas) --------

extract_fn() {
    local name="$1" file="$2"
    awk -v fn="$name" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p{print} p && /^}/{p=0}' "$file"
}

SET_STATUS_SRC=$(extract_fn "set_status" "$BATCH_SCRIPT")
GET_STATUS_SRC=$(extract_fn "get_status" "$BATCH_SCRIPT")
BATCH_STOP_REQ_SRC=$(extract_fn "batch_stop_requested" "$BATCH_SCRIPT")
DEFER_SRC=$(extract_fn "defer_from_index" "$BATCH_SCRIPT")
PARALLEL_STOP_REQ_SRC=$(extract_fn "batch_stop_requested" "$PARALLEL_SCRIPT")
DEFER_PENDING_SRC=$(extract_fn "defer_pending_issues" "$PARALLEL_SCRIPT")

for pair in "batch-pipeline.sh:set_status:$SET_STATUS_SRC" "batch-pipeline.sh:get_status:$GET_STATUS_SRC" \
    "batch-pipeline.sh:batch_stop_requested:$BATCH_STOP_REQ_SRC" "batch-pipeline.sh:defer_from_index:$DEFER_SRC" \
    "parallel-pipeline.sh:batch_stop_requested:$PARALLEL_STOP_REQ_SRC" "parallel-pipeline.sh:defer_pending_issues:$DEFER_PENDING_SRC"; do
    file="${pair%%:*}"; rest="${pair#*:}"; name="${rest%%:*}"; src="${rest#*:}"
    if [ -z "$src" ]; then
        fail "no se pudo extraer $name() de $file -- el resto de los bloques se omite"
        echo ""
        echo "----------------------------------------"
        echo "  Resumen: $PASS pass, $FAIL fail"
        echo "----------------------------------------"
        exit 1
    fi
done
pass "las seis funciones se extrajeron de los scripts reales"

# -------- Bloque A: batch_stop_requested()/defer_from_index() (batch-pipeline.sh) --------

echo ""
echo "[A] batch-pipeline.sh: batch_stop_requested()/defer_from_index() en aislamiento (CA-2/CA-3/CA-4)"

load_batch_fns() {
    ISSUE_STATUS_NUMS=()
    ISSUE_STATUS_VALUES=()
    ISSUE_STATUS_PRS=()
    eval "$SET_STATUS_SRC"
    eval "$GET_STATUS_SRC"
    eval "$BATCH_STOP_REQ_SRC"
    eval "$DEFER_SRC"
}

load_batch_fns
BATCH_STOP_SIGNAL="$TMP/batch-stop"
ISSUE_NUMS=(101 102 103)
for i in "${ISSUE_NUMS[@]}"; do set_status "$i" "pendiente"; done

if ! batch_stop_requested; then
    pass "A: sin archivo de senal, batch_stop_requested() es falso"
else
    fail "A: sin archivo de senal, batch_stop_requested() no deberia ser verdadero"
fi

touch "$BATCH_STOP_SIGNAL"
if batch_stop_requested; then
    pass "A: con el archivo presente, batch_stop_requested() es verdadero"
else
    fail "A: con el archivo presente, batch_stop_requested() deberia ser verdadero"
fi

defer_from_index 1

if [ ! -e "$BATCH_STOP_SIGNAL" ]; then
    pass "A: defer_from_index() consumio (borro) la senal (CA-4)"
else
    fail "A: la senal deberia haberse borrado tras defer_from_index()"
fi

if [ "$(get_status 101)" = "pendiente" ]; then
    pass "A: el issue ANTES del indice (101) no se toco"
else
    fail "A: el issue 101 no deberia haberse tocado, quedo en '$(get_status 101)'"
fi

for i in 102 103; do
    st="$(get_status "$i")"
    case "$st" in
        aplazado*) pass "A: issue $i quedo 'aplazado' ($st)" ;;
        *) fail "A: issue $i deberia quedar 'aplazado', quedo en '$st'" ;;
    esac
done

# -------- Bloque B: defer_from_index() nunca toca HAVE_ERRORS/FAILED (CA-5) --------

echo ""
echo "[B] batch-pipeline.sh: defer_from_index() no incrementa FAILED ni toca HAVE_ERRORS (CA-5)"

if echo "$DEFER_SRC" | grep -qE 'HAVE_ERRORS|FAILED'; then
    fail "B: defer_from_index() referencia HAVE_ERRORS o FAILED -- una parada solicitada no es un fallo"
else
    pass "B: defer_from_index() no referencia HAVE_ERRORS ni FAILED"
fi

# -------- Bloque C: batch_stop_requested()/defer_pending_issues() (parallel-pipeline.sh) --------

echo ""
echo "[C] parallel-pipeline.sh: batch_stop_requested()/defer_pending_issues() en aislamiento (CA-3/CA-4)"

load_parallel_fns() {
    PENDING_IDXS=()
    DEFERRED_FLAG=()
    eval "$PARALLEL_STOP_REQ_SRC"
    eval "$DEFER_PENDING_SRC"
}

load_parallel_fns
BATCH_STOP_SIGNAL="$TMP/batch-stop-parallel"
# Simula 5 issues (indices 0..4): 0 y 1 ya lanzados (no aparecen en PENDING_IDXS), 2,3,4 en cola.
PENDING_IDXS=(2 3 4)

if ! batch_stop_requested; then
    pass "C: sin archivo de senal, batch_stop_requested() es falso"
else
    fail "C: sin archivo de senal, batch_stop_requested() no deberia ser verdadero"
fi

touch "$BATCH_STOP_SIGNAL"
if batch_stop_requested; then
    pass "C: con el archivo presente, batch_stop_requested() es verdadero"
else
    fail "C: con el archivo presente, batch_stop_requested() deberia ser verdadero"
fi

defer_pending_issues

if [ ! -e "$BATCH_STOP_SIGNAL" ]; then
    pass "C: defer_pending_issues() consumio (borro) la senal (CA-4)"
else
    fail "C: la senal deberia haberse borrado tras defer_pending_issues()"
fi

if [ "${#PENDING_IDXS[@]}" -eq 0 ]; then
    pass "C: PENDING_IDXS quedo vacio (el scheduler no vuelve a intentar lanzarlos)"
else
    fail "C: PENDING_IDXS deberia quedar vacio, tiene ${#PENDING_IDXS[@]} elemento(s)"
fi

for i in 2 3 4; do
    if [ "${DEFERRED_FLAG[$i]:-false}" = "true" ]; then
        pass "C: indice $i (pendiente) quedo marcado DEFERRED_FLAG=true"
    else
        fail "C: indice $i deberia quedar DEFERRED_FLAG=true"
    fi
done

for i in 0 1; do
    if [ "${DEFERRED_FLAG[$i]:-false}" = "false" ]; then
        pass "C: indice $i (ya lanzado, fuera de PENDING_IDXS) no se toco"
    else
        fail "C: indice $i no deberia haberse marcado como aplazado"
    fi
done

# -------- Bloque D: defer_pending_issues() nunca toca PIDS/FAILED (CA-5) --------

echo ""
echo "[D] parallel-pipeline.sh: defer_pending_issues() no toca PIDS ni FAILED (CA-5)"

if echo "$DEFER_PENDING_SRC" | grep -qE '\bPIDS\[|FAILED'; then
    fail "D: defer_pending_issues() referencia PIDS o FAILED -- solo debe afectar a los pendientes sin lanzar"
else
    pass "D: defer_pending_issues() no referencia PIDS ni FAILED"
fi

# -------- Fixtures compartidas de los bloques E/F/G: repo consumidor + origin real --------

# setup_work_repo <dir> -- clone de un origin real (en 'main') sumandole el
# scaffold minimo de un CONSUMIDOR (sin .claude-plugin/plugin.json -- el guard
# defensivo de batch-pipeline.sh aborta si lo detecta) + los canonicos reales
# bajo prueba.
setup_work_repo() {
    local dir="$1"
    mkdir -p "$dir/scripts"
    cp "$COMMON_LIB" "$dir/scripts/_pipeline-common.sh"
    cp "$BATCH_SCRIPT" "$dir/scripts/batch-pipeline.sh"
    chmod +x "$dir/scripts/batch-pipeline.sh"
}

# fake_tooling_pipeline <dir> <call_log> [<signal_after_issue> <signal_path>]
#
# Stub que registra cada issue invocado en <call_log> y siempre "tiene exito"
# imprimiendo una URL de PR reconocible (numero = issue + 1000). Si se pasan
# los dos argumentos opcionales, ademas toca <signal_path> cuando procesa
# <signal_after_issue> -- simula a un humano corriendo /batch-stop mientras
# ese eslabon esta en curso.
fake_tooling_pipeline() {
    local dir="$1" call_log="$2" signal_after="${3:-}" signal_path="${4:-}"
    cat > "$dir/scripts/tooling-pipeline.sh" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$call_log"
if [ -n "$signal_after" ] && [ "\$1" = "$signal_after" ]; then
    mkdir -p "$(dirname "$signal_path")"
    touch "$signal_path"
fi
echo "PR creado: https://github.com/acme/fake-consumer/pull/\$((\$1 + 1000))"
exit 0
EOF
    chmod +x "$dir/scripts/tooling-pipeline.sh"
}

# fake_pr_sync <dir> -- stub de pr-sync.sh --merge: siempre "tiene exito" sin
# tocar git (a diferencia del motor interno, batch-pipeline.sh no verifica que
# el merge llegue a origin/main -- solo hace un `git pull origin main` best
# effort en el paso siguiente, que ya funciona contra el origin real del
# fixture sin necesitar un commit de merge simulado).
fake_pr_sync() {
    local dir="$1"
    cat > "$dir/scripts/pr-sync.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$dir/scripts/pr-sync.sh"
}

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    printf 'OPEN|tipo:tooling\n'
    exit 0
fi
exit 0
STUB
chmod +x "$FAKE_BIN/gh"
cat > "$FAKE_BIN/claude" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FAKE_BIN/claude"
cat > "$FAKE_BIN/dotnet" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FAKE_BIN/dotnet"

# Mismo criterio que test-parallel-projection-serialization.sh y demas tests de
# pipelines publicados: solo el tramo de sistema (git/coreutils) queda fuera de
# FAKE_BIN.
SAFE_SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

new_origin() {
    local bare="$1" work="$2"
    git init -q --bare "$bare"
    git -C "$bare" symbolic-ref HEAD refs/heads/main
    git clone -q "$bare" "$work" 2>/dev/null
    git -C "$work" config user.email "test@mefisto.local"
    git -C "$work" config user.name "Mefisto Test"
    git -C "$work" commit -q --allow-empty -m "base"
    git -C "$work" push -q origin main
}

# run_batch <dir> <args...>
run_batch() {
    local dir="$1"; shift
    local out="$TMP/stdout" err="$TMP/stderr"
    (
        cd "$dir" || exit 99
        PATH="$FAKE_BIN:$SAFE_SYSTEM_PATH" ./scripts/batch-pipeline.sh "$@"
    ) </dev/null >"$out" 2>"$err"
    LAST_RC=$?
    LAST_STDOUT=$(cat "$out")
    LAST_STDERR=$(cat "$err")
}

# -------- Bloque E: la senal YA presente detiene todo antes de arrancar --------

echo ""
echo "[E] batch-pipeline.sh, corrida real: senal presente ANTES de arrancar -- nada se procesa (CA-1 momento 1, CA-2, CA-5)"

WORK_E="$TMP/work-e"
new_origin "$TMP/origin-e.git" "$WORK_E"
setup_work_repo "$WORK_E"
CALL_LOG_E="$TMP/call-log-e"; : > "$CALL_LOG_E"
fake_tooling_pipeline "$WORK_E" "$CALL_LOG_E"
fake_pr_sync "$WORK_E"

mkdir -p "$WORK_E/pipeline-state"
touch "$WORK_E/pipeline-state/batch-stop"

run_batch "$WORK_E" 201 202 203

if [ "$LAST_RC" -eq 0 ]; then
    pass "E: exit 0 (una parada solicitada no es un fallo, CA-5)"
else
    fail "E: se esperaba exit 0, se obtuvo $LAST_RC. stdout: $LAST_STDOUT / stderr: $LAST_STDERR"
fi

if [ ! -s "$CALL_LOG_E" ]; then
    pass "E: tooling-pipeline.sh nunca se invoco para ningun issue (CA-2)"
else
    fail "E: tooling-pipeline.sh se invoco pese a la senal previa: $(cat "$CALL_LOG_E")"
fi

ALL_DEFERRED=true
for i in 201 202 203; do
    if ! echo "$LAST_STDOUT" | grep -E "#$i\s" | grep -q "aplazado"; then
        ALL_DEFERRED=false
    fi
done
if [ "$ALL_DEFERRED" = true ]; then
    pass "E: los tres issues quedaron 'aplazado' en el resumen"
else
    fail "E: se esperaban tres issues 'aplazado' en el resumen. stdout: $LAST_STDOUT"
fi

if echo "$LAST_STDOUT" | grep -qF "/sequential 201 202 203"; then
    pass "E: la linea de relanzamiento respeta el orden (CA-3)"
else
    fail "E: no se encontro la linea de relanzamiento esperada. stdout: $LAST_STDOUT"
fi

if [ ! -e "$WORK_E/pipeline-state/batch-stop" ]; then
    pass "E: la senal quedo consumida (borrada) al detenerse el batch (CA-4)"
else
    fail "E: la senal deberia haberse borrado tras detenerse el batch"
fi

if ! echo "$LAST_STDOUT" | grep -q "Fallidos: [^0]"; then
    pass "E: FAILED se mantuvo en 0"
else
    fail "E: FAILED no deberia incrementarse por una parada solicitada. stdout: $LAST_STDOUT"
fi

# -------- Bloque F: la senal aparece DURANTE el primer eslabon --------

echo ""
echo "[F] batch-pipeline.sh, corrida real: senal aparece durante el primer eslabon -- ese eslabon se completa entero, el resto queda aplazado (CA-1 momento 2, CA-2, CA-3, CA-5)"

WORK_F="$TMP/work-f"
new_origin "$TMP/origin-f.git" "$WORK_F"
setup_work_repo "$WORK_F"
CALL_LOG_F="$TMP/call-log-f"; : > "$CALL_LOG_F"
SIGNAL_F="$WORK_F/pipeline-state/batch-stop"
fake_tooling_pipeline "$WORK_F" "$CALL_LOG_F" "301" "$SIGNAL_F"
fake_pr_sync "$WORK_F"

run_batch "$WORK_F" 301 302 303

if [ "$LAST_RC" -eq 0 ]; then
    pass "F: exit 0 (una parada solicitada no es un fallo, CA-5)"
else
    fail "F: se esperaba exit 0, se obtuvo $LAST_RC. stdout: $LAST_STDOUT / stderr: $LAST_STDERR"
fi

if grep -qF "301" "$CALL_LOG_F" && ! grep -qF "302" "$CALL_LOG_F" && ! grep -qF "303" "$CALL_LOG_F"; then
    pass "F: solo el primer eslabon (301) arranco un worktree; 302/303 nunca se invocaron (CA-2)"
else
    fail "F: invocaciones inesperadas de tooling-pipeline.sh: $(cat "$CALL_LOG_F")"
fi

if echo "$LAST_STDOUT" | grep -qE '#301\s+1301\s+completado'; then
    pass "F: el issue 301 quedo 'completado' con su PR (1301)"
else
    fail "F: el issue 301 deberia quedar 'completado' con PR 1301. stdout: $LAST_STDOUT"
fi

for i in 302 303; do
    if echo "$LAST_STDOUT" | grep -E "#$i\s" | grep -q "aplazado"; then
        pass "F: el issue $i quedo 'aplazado'"
    else
        fail "F: el issue $i deberia quedar 'aplazado'. stdout: $LAST_STDOUT"
    fi
done

if echo "$LAST_STDOUT" | grep -qF "/sequential 302 303"; then
    pass "F: la linea de relanzamiento respeta el orden de los aplazados (CA-3)"
else
    fail "F: no se encontro la linea de relanzamiento esperada. stdout: $LAST_STDOUT"
fi

if [ ! -e "$SIGNAL_F" ]; then
    pass "F: la senal quedo consumida (borrada) tras completar el primer eslabon (CA-4)"
else
    fail "F: la senal deberia haberse borrado"
fi

if ! echo "$LAST_STDOUT" | grep -q "Fallidos: [^0]"; then
    pass "F: FAILED se mantuvo en 0 pese a la parada (CA-5)"
else
    fail "F: FAILED no deberia incrementarse por una parada solicitada. stdout: $LAST_STDOUT"
fi

# -------- Bloque G: la senal llega durante el ULTIMO eslabon --------

echo ""
echo "[G] batch-pipeline.sh, corrida real: senal durante el ULTIMO eslabon -- no hay nada que aplazar, pero la senal se consume igual (CA-4)"

WORK_G="$TMP/work-g"
new_origin "$TMP/origin-g.git" "$WORK_G"
setup_work_repo "$WORK_G"
CALL_LOG_G="$TMP/call-log-g"; : > "$CALL_LOG_G"
SIGNAL_G="$WORK_G/pipeline-state/batch-stop"
fake_tooling_pipeline "$WORK_G" "$CALL_LOG_G" "402" "$SIGNAL_G"
fake_pr_sync "$WORK_G"

run_batch "$WORK_G" 401 402

# El caso limite del `for ((i = from; i < ${#ISSUE_NUMS[@]}; i++))` de
# defer_from_index: cero iteraciones bajo `set -e`. Si ese for devolviera un
# exit code no-cero, el motor moriria aqui en vez de cerrar el resumen.
if [ "$LAST_RC" -eq 0 ]; then
    pass "G: exit 0 (el defer de cero issues no mata el motor bajo set -e)"
else
    fail "G: se esperaba exit 0, se obtuvo $LAST_RC. stdout: $LAST_STDOUT / stderr: $LAST_STDERR"
fi

if grep -qF "401" "$CALL_LOG_G" && grep -qF "402" "$CALL_LOG_G"; then
    pass "G: los dos eslabones se procesaron completos"
else
    fail "G: se esperaban los dos eslabones procesados: $(cat "$CALL_LOG_G")"
fi

if ! echo "$LAST_STDOUT" | grep -q "aplazado"; then
    pass "G: ningun issue quedo 'aplazado' (no quedaba ninguno por arrancar)"
else
    fail "G: no deberia haber aplazados. stdout: $LAST_STDOUT"
fi

if ! echo "$LAST_STDOUT" | grep -qF "/sequential 4"; then
    pass "G: no se imprimio linea de relanzamiento (no hay nada que relanzar)"
else
    fail "G: no deberia haber linea de relanzamiento. stdout: $LAST_STDOUT"
fi

if [ ! -e "$SIGNAL_G" ]; then
    pass "G: la senal se consumio igual (CA-4: no envenena la corrida siguiente)"
else
    fail "G: la senal deberia haberse borrado aunque no hubiera eslabones restantes"
fi

if echo "$LAST_STDOUT" | grep -qF "era el ultimo eslabon del batch"; then
    pass "G: el aviso dice la verdad (no promete aplazados inexistentes)"
else
    fail "G: se esperaba el aviso del caso 'ultimo eslabon'. stdout: $LAST_STDOUT"
fi

# -------- Resumen --------

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
