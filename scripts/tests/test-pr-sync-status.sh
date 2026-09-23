#!/usr/bin/env bash
# test-pr-sync-status.sh -- Regresiones del status estructurado por PR de
# pr-sync.sh (issue #1601): write_pr_status_file()/fail_pr()/pr_sync_exit_trap()
# escriben pipeline-status-pr-sync-<pr>.json con el mismo esquema y nombres de
# campo que update_status() de tooling-pipeline.sh.
#
# Mismo patron de extraccion por awk que test-pr-sync-hold.sh: las funciones
# reales se extraen tal cual viven en pr-sync.sh y se ejecutan con un harness
# minimo sobre mefisto_state_path() REAL (via _pipeline-common.sh), apuntando
# MEFISTO_STATE_DIR a un directorio temporal -- sin invocar gh/git/dotnet ni
# ningun runtime real.
#
#   T-1 (CA-1): write_pr_status_file escribe JSON valido con exactamente los
#       campos declarados (issue, pr, title, pipeline, variant, runtime,
#       started, stage, state, updated, log, last_error, y el sub-objeto
#       hold.{cause,next_probe,ceiling_seconds,accumulated_seconds}).
#   T-2 (CA-1): "started" se preserva entre dos escrituras sucesivas del mismo
#       PR -- no se recalcula en cada transicion de stage/state.
#   T-3 (CA-2/CA-4): fail_pr() escribe state:"failed" con last_error igual al
#       mensaje recibido, y usa "sync" como stage de fallback si el loop no
#       fijo CURRENT_PR_STAGE.
#   T-4 (CA-4): pr_sync_exit_trap() convierte en "failed" (last_error
#       "pr-sync interrumpido") el status del PR EN CURSO (CURRENT_PR_STATUS)
#       si sigue "running"; un PR ya "completed" no se toca.
#
# Uso: scripts/tests/test-pr-sync-status.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PR_SYNC="$REPO_ROOT/scripts/pr-sync.sh"
COMMON_LIB="$REPO_ROOT/scripts/_pipeline-common.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export TMP_DIR

# write_pr_status_file()/fail_pr() viven en un bloque contiguo, justo antes de
# "Parsear argumentos" (mismo patron que test-pr-sync-hold.sh).
STATUS_FUNC_SRC=$(awk '
    /^write_pr_status_file\(\) \{/ { flag=1 }
    flag && /^# ─── Parsear argumentos/ { exit }
    flag { print }
' "$PR_SYNC")

if [ -z "$STATUS_FUNC_SRC" ]; then
    fail "no se pudo extraer write_pr_status_file()/fail_pr() de pr-sync.sh"
    echo ""
    echo "----------------------------------------"
    echo "  Resumen: $PASS pass, $FAIL fail"
    echo "----------------------------------------"
    exit 1
fi
pass "se extrajo write_pr_status_file()/fail_pr() de pr-sync.sh"

if grep -q '^write_pr_status_file() {' <<< "$STATUS_FUNC_SRC" && grep -q '^fail_pr() {' <<< "$STATUS_FUNC_SRC"; then
    pass "el bloque extraido contiene ambas funciones"
else
    fail "el bloque extraido no contiene write_pr_status_file()/fail_pr() completas"
fi

# pr_sync_exit_trap() vive despues, junto a EVENTS_LOG_ABS, antes de su propio
# registro con 'trap ... EXIT INT TERM'.
TRAP_FUNC_SRC=$(awk '
    /^pr_sync_exit_trap\(\) \{/ { flag=1 }
    flag && /^trap pr_sync_exit_trap/ { exit }
    flag { print }
' "$PR_SYNC")

if [ -z "$TRAP_FUNC_SRC" ]; then
    fail "no se pudo extraer pr_sync_exit_trap() de pr-sync.sh"
else
    pass "se extrajo pr_sync_exit_trap() de pr-sync.sh"
fi

STATE_DIR="$TMP_DIR/state"
mkdir -p "$STATE_DIR"

# run_snippet <bash-code>
#
# Ejecuta <bash-code> en un script que primero source-a _pipeline-common.sh
# (mefisto_state_path REAL), luego las funciones extraidas, luego un harness
# minimo (MEFISTO_STATE_DIR bajo TMP_DIR, contexto de PR neutro, log()/warn()
# y set_status() como no-ops -- el tracker en memoria no es lo que se prueba
# aqui) y por ultimo <bash-code>. Deja $OUTPUT/$RC.
run_snippet() {
    local snippet="$1"
    local case_file="$TMP_DIR/case.sh"
    {
        printf '%s\n' 'set -uo pipefail'
        printf '%s\n' "source \"$COMMON_LIB\""
        printf '%s\n' "$STATUS_FUNC_SRC"
        printf '%s\n' "$TRAP_FUNC_SRC"
        cat <<HARNESS
MEFISTO_STATE_DIR="$STATE_DIR"
LOG_FILE_ABS="$TMP_DIR/log.txt"
MEFISTO_RUNTIME_RESUELTO="fake-runtime"
CURRENT_PR_TITLE="Titulo de prueba"
CURRENT_PR_STATUS=""
CURRENT_PR_STAGE=""
HOLD_CAUSE_JSON="null"
HOLD_NEXT_PROBE_JSON="null"
HOLD_CEILING_JSON="null"
HOLD_TOTAL=0
CURRENT_WORKTREE=""
RED='' BOLD='' NC=''
set_status() { :; }
log() { :; }
warn() { :; }
HARNESS
        printf '%s\n' "$snippet"
    } > "$case_file"
    OUTPUT=$(/bin/bash "$case_file" 2>&1)
    RC=$?
}

echo "[T-1] write_pr_status_file escribe JSON valido con todos los campos (CA-1)"
run_snippet 'write_pr_status_file "501" "sync" "running"'
STATUS_FILE_501="$STATE_DIR/pipeline-status-pr-sync-501.json"
if [ -f "$STATUS_FILE_501" ] && jq -e . "$STATUS_FILE_501" >/dev/null 2>&1; then
    pass "T-1: el archivo existe y es JSON valido"
else
    fail "T-1: no existe o no es JSON valido: $(cat "$STATUS_FILE_501" 2>/dev/null || echo '<no existe>')"
fi
EXPECTED_KEYS='["hold","issue","last_error","log","pipeline","pr","runtime","stage","started","state","title","updated","variant"]'
ACTUAL_KEYS=$(jq -cS 'keys' "$STATUS_FILE_501" 2>/dev/null)
if [ "$ACTUAL_KEYS" = "$EXPECTED_KEYS" ]; then
    pass "T-1: el JSON declara exactamente los campos de nivel superior de CA-1"
else
    fail "T-1: claves inesperadas. Esperado: $EXPECTED_KEYS. Obtenido: $ACTUAL_KEYS"
fi
HOLD_KEYS_EXPECTED='["accumulated_seconds","cause","ceiling_seconds","next_probe"]'
HOLD_KEYS_ACTUAL=$(jq -cS '.hold | keys' "$STATUS_FILE_501" 2>/dev/null)
if [ "$HOLD_KEYS_ACTUAL" = "$HOLD_KEYS_EXPECTED" ]; then
    pass "T-1: hold declara cause/next_probe/ceiling_seconds/accumulated_seconds"
else
    fail "T-1: claves de hold inesperadas. Esperado: $HOLD_KEYS_EXPECTED. Obtenido: $HOLD_KEYS_ACTUAL"
fi
if [ "$(jq -r '.issue' "$STATUS_FILE_501")" = "501" ] && [ "$(jq -r '.pr' "$STATUS_FILE_501")" = "501" ]; then
    pass "T-1: issue y pr repiten el numero de PR (clave de deduplicacion #1597)"
else
    fail "T-1: issue/pr no coinciden con el numero de PR"
fi
if [ "$(jq -r '.pipeline' "$STATUS_FILE_501")" = "pr-sync" ] && [ "$(jq -r '.variant' "$STATUS_FILE_501")" = "null" ]; then
    pass "T-1: pipeline es 'pr-sync' y variant es null"
else
    fail "T-1: pipeline/variant no coinciden con lo esperado"
fi
if [ "$(jq -r '.title' "$STATUS_FILE_501")" = "Titulo de prueba" ] && [ "$(jq -r '.runtime' "$STATUS_FILE_501")" = "fake-runtime" ]; then
    pass "T-1: title y runtime vienen del contexto fijado por el loop"
else
    fail "T-1: title/runtime no coinciden con el contexto"
fi
if [ "$(jq -r '.stage' "$STATUS_FILE_501")" = "sync" ] && [ "$(jq -r '.state' "$STATUS_FILE_501")" = "running" ]; then
    pass "T-1: stage/state reflejan los argumentos"
else
    fail "T-1: stage/state no coinciden con los argumentos"
fi
if [ "$(jq -r '.log' "$STATUS_FILE_501")" = "$TMP_DIR/log.txt" ] && [ "$(jq -r '.last_error' "$STATUS_FILE_501")" = "null" ]; then
    pass "T-1: log referencia LOG_FILE_ABS y last_error es null sin fallo"
else
    fail "T-1: log/last_error no coinciden con lo esperado"
fi

echo ""
echo "[T-2] 'started' se preserva entre escrituras sucesivas del mismo PR (CA-1)"
run_snippet '
write_pr_status_file "502" "sync" "running"
S1="$(jq -r ".started" "$MEFISTO_STATE_DIR/pipeline-status-pr-sync-502.json")"
write_pr_status_file "502" "merge" "completed"
S2="$(jq -r ".started" "$MEFISTO_STATE_DIR/pipeline-status-pr-sync-502.json")"
printf "STARTED1=%s\nSTARTED2=%s\n" "$S1" "$S2"
'
STARTED1="$(printf '%s\n' "$OUTPUT" | sed -n 's/^STARTED1=//p')"
STARTED2="$(printf '%s\n' "$OUTPUT" | sed -n 's/^STARTED2=//p')"
if [ -n "$STARTED1" ] && [ "$STARTED1" = "$STARTED2" ]; then
    pass "T-2: 'started' no cambia entre transiciones sucesivas del mismo PR"
else
    fail "T-2: 'started' cambio o esta vacio (STARTED1='$STARTED1', STARTED2='$STARTED2')"
fi
STATUS_FILE_502="$STATE_DIR/pipeline-status-pr-sync-502.json"
if [ "$(jq -r '.stage' "$STATUS_FILE_502")" = "merge" ] && [ "$(jq -r '.state' "$STATUS_FILE_502")" = "completed" ]; then
    pass "T-2: la segunda escritura si actualiza stage/state"
else
    fail "T-2: stage/state no se actualizaron en la segunda escritura"
fi

echo ""
echo "[T-3] fail_pr() escribe failed con last_error (CA-2/CA-4)"
run_snippet 'fail_pr "503" "mensaje de error de prueba"'
STATUS_FILE_503="$STATE_DIR/pipeline-status-pr-sync-503.json"
if [ -f "$STATUS_FILE_503" ] \
    && [ "$(jq -r '.state' "$STATUS_FILE_503")" = "failed" ] \
    && [ "$(jq -r '.last_error' "$STATUS_FILE_503")" = "mensaje de error de prueba" ]; then
    pass "T-3: fail_pr escribe state:failed con last_error igual al mensaje recibido"
else
    fail "T-3: status inesperado: $(cat "$STATUS_FILE_503" 2>/dev/null || echo '<no existe>')"
fi
if [ "$(jq -r '.stage' "$STATUS_FILE_503")" = "sync" ]; then
    pass "T-3: sin CURRENT_PR_STAGE fijado, fail_pr usa 'sync' como fallback"
else
    fail "T-3: stage inesperado: $(jq -r '.stage' "$STATUS_FILE_503" 2>/dev/null)"
fi

echo ""
echo "[T-4] pr_sync_exit_trap() marca failed solo el PR en curso si sigue running (CA-4)"
run_snippet '
write_pr_status_file "504" "sync" "running"
write_pr_status_file "505" "sync" "completed"
CURRENT_PR_STATUS="504"
CURRENT_PR_STAGE="sync"
pr_sync_exit_trap
'
STATUS_FILE_504="$STATE_DIR/pipeline-status-pr-sync-504.json"
STATUS_FILE_505="$STATE_DIR/pipeline-status-pr-sync-505.json"
if [ "$(jq -r '.state' "$STATUS_FILE_504")" = "failed" ] && [ "$(jq -r '.last_error' "$STATUS_FILE_504")" = "pr-sync interrumpido" ]; then
    pass "T-4: el PR en curso (running) pasa a failed con last_error 'pr-sync interrumpido'"
else
    fail "T-4: PR #504 no quedo failed: $(cat "$STATUS_FILE_504" 2>/dev/null || echo '<no existe>')"
fi
if [ "$(jq -r '.state' "$STATUS_FILE_505")" = "completed" ]; then
    pass "T-4: un PR ya cerrado (completed) no se toca"
else
    fail "T-4: PR #505 fue modificado indebidamente: $(cat "$STATUS_FILE_505" 2>/dev/null || echo '<no existe>')"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
