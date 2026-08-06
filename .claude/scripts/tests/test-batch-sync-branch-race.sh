#!/usr/bin/env bash
# test-batch-sync-branch-race.sh -- Tests de sync_main_after_merge() (issue #566).
#
# Contexto (corrida real del batch 549 550 -> 548 552 553, 2026-08-05): la
# cadena aborto en el tercer eslabon porque otra sesion paralela (el planner
# de #564) hizo `git switch -c ...` en el repo principal MIENTRAS el batch
# corria. El commit de merge del PR #565 SI llego a origin/main -- la base
# real del siguiente worktree (issue #66) -- pero sync_main_after_merge()
# operaba sobre el HEAD del momento (ya en otra rama), asi que el
# fast-forward de "main" fallaba, el mensaje culpaba a una "divergencia de
# main" inexistente, y el motor abortaba la cadena entera pese a que el
# siguiente eslabon podia partir sin problema de origin/main.
#
# El fix (CA-1..CA-5 del issue #566):
#   - Los pasos 4/5 de sync_main_after_merge() operan sobre $MAIN_BRANCH por
#     NOMBRE (git fetch origin main:$MAIN_BRANCH cuando ya no es la rama
#     activa; merge-base contra "$MAIN_BRANCH", nunca contra HEAD).
#   - Si la rama activa cambio, se detecta y se nombra en el warn (en vez de
#     culpar a una divergencia de main).
#   - La funcion devuelve codigos de retorno distintos por severidad: 2 si
#     origin/main no tiene el merge confirmado (fatal, rompe la cadena), 1 si
#     solo fallo el sync de main LOCAL (no fatal: origin/main si lo tiene, y
#     el siguiente worktree nace de ahi), 0 si todo sincronizo.
#
# Casos cubiertos:
#   [pre] El script existe, es ejecutable y tiene sintaxis valida.
#   [A] Rama activa cambio entre eslabones, pero el fast-forward POR NOMBRE de
#       $MAIN_BRANCH si es posible (origin adelanto de forma fast-forwardeable):
#       la funcion no toca HEAD (sigue en la rama nueva), actualiza main por
#       nombre, warnea nombrando la rama nueva (CA-2) y retorna 0 -- la cadena
#       continua sin degradar (CA-1/CA-2/CA-3).
#   [B] Rama activa cambio Y el fast-forward por nombre de $MAIN_BRANCH falla
#       (main local diverge de origin/main): retorna 1 (no fatal), el warn
#       reporta la rama activa OBSERVADA en el momento del fallo, no el
#       $MAIN_BRANCH capturado al arranque (CA-4), y HEAD sigue intacto.
#   [C] El merge commit nunca llega a origin/main (paso 3): retorna 2 (fatal).
#       Este es el unico caso que debe abortar la cadena.
#   [D] Guard de regresion (CA-5): el mensaje del gate de arranque ya no
#       afirma que el batch crea cada worktree desde la rama activa del repo,
#       y si menciona origin/main + issue #66 como la base real.
#
# Uso: .claude/scripts/tests/test-batch-sync-branch-race.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/.claude/scripts/mefisto-batch-pipeline.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# -------- Bloque pre: el script existe, es ejecutable y tiene sintaxis valida --------

echo "[pre] mefisto-batch-pipeline.sh existe, es ejecutable y tiene sintaxis valida"

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

# -------- Extraer la funcion REAL bajo prueba (no reimplementarla) --------

extract_fn() {
    local name="$1" file="$2"
    awk -v fn="$name" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p{print} p && /^}/{p=0}' "$file"
}

SYNC_FN_SRC=$(extract_fn "sync_main_after_merge" "$SCRIPT")
if [ -z "$SYNC_FN_SRC" ]; then
    fail "no se pudo extraer sync_main_after_merge() de $SCRIPT -- el resto de los bloques se omite"
    echo ""
    echo "----------------------------------------"
    echo "  Resumen: $PASS pass, $FAIL fail"
    echo "----------------------------------------"
    exit 1
fi

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- Stub de gh: gh pr view <num> --json mergeCommit -q '.mergeCommit.oid' ---
# Devuelve el valor de FAKE_MERGE_SHA (fijado por cada bloque de test).
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    echo "${FAKE_MERGE_SHA:-}"
    exit 0
fi
exit 1
EOF
chmod +x "$FAKE_BIN/gh"

# --- Cargar la funcion real + un warn() de prueba que registra cada llamada ---
WARN_LOG="$TMP/warn.log"
load_sync_fn() {
    : > "$WARN_LOG"
    warn() { echo "$1" >> "$WARN_LOG"; }
    eval "$SYNC_FN_SRC"
}
load_sync_fn

run_sync() {
    local pr_num="$1"
    : > "$WARN_LOG"
    PATH="$FAKE_BIN:$PATH" sync_main_after_merge "$pr_num"
}

# -------- Fixture de repos: bare "origin" + un clone "publisher" que simula --------
# -------- el PR ya mergeado llegando al remoto, separado del work tree bajo prueba --------

BARE="$TMP/origin.git"
git init -q --bare "$BARE"

PUBLISHER="$TMP/publisher"
git clone -q "$BARE" "$PUBLISHER"
git -C "$PUBLISHER" config user.email "test@mefisto.local"
git -C "$PUBLISHER" config user.name "Mefisto Test"
git -C "$PUBLISHER" checkout -q -b main 2>/dev/null || git -C "$PUBLISHER" checkout -q main
git -C "$PUBLISHER" commit -q --allow-empty -m "c1 (estado inicial)"
git -C "$PUBLISHER" push -q origin main

new_work_clone() {
    local name="$1"
    git clone -q "$BARE" "$TMP/$name"
    git -C "$TMP/$name" config user.email "test@mefisto.local"
    git -C "$TMP/$name" config user.name "Mefisto Test"
    echo "$TMP/$name"
}

# -------- Bloque A: rama activa cambio, fast-forward por nombre SI es posible --------

echo ""
echo "[A] Rama activa cambio entre eslabones, fast-forward por nombre de main procede (CA-1/CA-2/CA-3)"

WORK_A=$(new_work_clone "work-a")
git -C "$WORK_A" checkout -q -b docs/otra-sesion-en-paralelo

git -C "$PUBLISHER" commit -q --allow-empty -m "c2 (merge commit del PR simulado)"
git -C "$PUBLISHER" push -q origin main
MERGE_SHA_A=$(git -C "$PUBLISHER" rev-parse main)

MAIN_BRANCH="main"
LOG_FILE_ABS="$TMP/batch-a.log"
touch "$LOG_FILE_ABS"

(
    cd "$WORK_A" || exit 9
    export FAKE_MERGE_SHA="$MERGE_SHA_A"
    export MAIN_BRANCH LOG_FILE_ABS
    run_sync 565
)
RC=$?

if [ "$RC" -eq 0 ]; then
    pass "A: retorna 0 (sync completo, la cadena continua sin degradar)"
else
    fail "A: se esperaba exit 0, se obtuvo $RC"
fi

HEAD_AFTER=$(git -C "$WORK_A" rev-parse --abbrev-ref HEAD)
if [ "$HEAD_AFTER" = "docs/otra-sesion-en-paralelo" ]; then
    pass "A: HEAD no se toco, sigue en 'docs/otra-sesion-en-paralelo' (CA-1)"
else
    fail "A: HEAD deberia seguir en 'docs/otra-sesion-en-paralelo', quedo en '$HEAD_AFTER'"
fi

MAIN_SHA_AFTER=$(git -C "$WORK_A" rev-parse refs/heads/main)
if [ "$MAIN_SHA_AFTER" = "$MERGE_SHA_A" ]; then
    pass "A: la ref 'main' (por nombre) quedo fast-forwardeada al merge commit (CA-1)"
else
    fail "A: 'main' deberia apuntar a $MERGE_SHA_A, quedo en $MAIN_SHA_AFTER"
fi

if grep -qF "rama activa del repo cambio a 'docs/otra-sesion-en-paralelo'" "$WARN_LOG"; then
    pass "A: el warn nombra la rama nueva ('docs/otra-sesion-en-paralelo'), no una divergencia de main (CA-2)"
else
    fail "A: el warn no nombro la rama activa nueva. Contenido: $(cat "$WARN_LOG")"
fi

if grep -qi "divergencia" "$WARN_LOG"; then
    fail "A: el warn no deberia culpar a una 'divergencia' de main (no hubo)"
else
    pass "A: el warn no culpa a una divergencia inexistente de main"
fi

# -------- Bloque B: rama activa cambio Y el fast-forward por nombre falla --------

echo ""
echo "[B] Rama activa cambio Y main diverge (no fast-forwardeable): no fatal, warn con rama observada (CA-1/CA-3/CA-4)"

WORK_B=$(new_work_clone "work-b")
# main local diverge: un commit propio que origin no tiene.
git -C "$WORK_B" checkout -q main
git -C "$WORK_B" commit -q --allow-empty -m "commit local divergente (nunca llego a origin)"
DIVERGENT_SHA=$(git -C "$WORK_B" rev-parse main)
git -C "$WORK_B" checkout -q -b feature-en-paralelo

# origin avanza con OTRO commit (el merge simulado), que no es descendiente
# del commit local divergente -> el fetch por nombre sera rechazado (non-fast-forward).
git -C "$PUBLISHER" commit -q --allow-empty -m "c3 (otro merge commit simulado)"
git -C "$PUBLISHER" push -q origin main
MERGE_SHA_B=$(git -C "$PUBLISHER" rev-parse main)

MAIN_BRANCH="main"
LOG_FILE_ABS="$TMP/batch-b.log"
touch "$LOG_FILE_ABS"

(
    cd "$WORK_B" || exit 9
    export FAKE_MERGE_SHA="$MERGE_SHA_B"
    export MAIN_BRANCH LOG_FILE_ABS
    run_sync 566
)
RC=$?

if [ "$RC" -eq 1 ]; then
    pass "B: retorna 1 (no fatal -- origin/main SI tiene el merge, solo fallo main LOCAL) (CA-3)"
else
    fail "B: se esperaba exit 1, se obtuvo $RC"
fi

HEAD_AFTER_B=$(git -C "$WORK_B" rev-parse --abbrev-ref HEAD)
if [ "$HEAD_AFTER_B" = "feature-en-paralelo" ]; then
    pass "B: HEAD no se toco, sigue en 'feature-en-paralelo'"
else
    fail "B: HEAD deberia seguir en 'feature-en-paralelo', quedo en '$HEAD_AFTER_B'"
fi

MAIN_SHA_AFTER_B=$(git -C "$WORK_B" rev-parse refs/heads/main)
if [ "$MAIN_SHA_AFTER_B" = "$DIVERGENT_SHA" ]; then
    pass "B: 'main' local se quedo sin tocar (el fetch por nombre fue rechazado, no forzo nada)"
else
    fail "B: 'main' deberia seguir en $DIVERGENT_SHA (sin cambios), quedo en $MAIN_SHA_AFTER_B"
fi

if grep -qF "rama activa observada: 'feature-en-paralelo'" "$WARN_LOG"; then
    pass "B: el warn de fallo reporta la rama OBSERVADA ('feature-en-paralelo'), no el \$MAIN_BRANCH capturado (CA-4)"
else
    fail "B: el warn no reporto la rama observada. Contenido: $(cat "$WARN_LOG")"
fi

# -------- Bloque C: el merge commit nunca llega a origin/main (paso 3) --------

echo ""
echo "[C] El merge commit no aparece en origin/main: retorna 2 (fatal, unico caso que aborta la cadena)"

WORK_C=$(new_work_clone "work-c")

MAIN_BRANCH="main"
LOG_FILE_ABS="$TMP/batch-c.log"
touch "$LOG_FILE_ABS"

(
    cd "$WORK_C" || exit 9
    export FAKE_MERGE_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    export MAIN_BRANCH LOG_FILE_ABS
    run_sync 567
)
RC=$?

if [ "$RC" -eq 2 ]; then
    pass "C: retorna 2 (fatal) cuando el merge commit no llega a origin/main"
else
    fail "C: se esperaba exit 2, se obtuvo $RC"
fi

if grep -q "no aparece en origin/main" "$WARN_LOG"; then
    pass "C: el warn explica que el commit no aparece en origin/main"
else
    fail "C: el warn no explico la causa. Contenido: $(cat "$WARN_LOG")"
fi

# -------- Bloque D: guard de regresion sobre el mensaje del gate de arranque (CA-5) --------

echo ""
echo "[D] Guard de regresion (CA-5): el gate de arranque ya no atribuye el worktree a la rama activa"

GATE_BLOCK=$(awk '/Verificar que el repo principal arranca en main\/master/,/^fi$/' "$SCRIPT")

if [ -z "$GATE_BLOCK" ]; then
    fail "D: no se pudo extraer el bloque del gate de arranque"
elif echo "$GATE_BLOCK" | grep -q "El batch secuencial crea cada worktree desde la rama activa del repo"; then
    fail "D: el mensaje del gate todavia afirma que el worktree nace de la rama activa (falso desde el issue #66)"
else
    pass "D: el mensaje del gate ya no afirma que el worktree nace de la rama activa"
fi

if echo "$GATE_BLOCK" | grep -q "origin/main" && echo "$GATE_BLOCK" | grep -q "#66"; then
    pass "D: el gate cita origin/main + issue #66 como la base real del worktree"
else
    fail "D: el gate no cita origin/main ni el issue #66 como justificacion real"
fi

# -------- Resumen --------

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
