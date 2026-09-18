#!/usr/bin/env bash
# mefisto-test-suite.sh -- Runner repo-only de la suite completa de tests de
# Mefisto (issue #1416).
#
# #1438 (mefisto-test-inventory.sh) define QUE archivos forman la suite
# completa (tres carriles disjuntos: publicado, interno, canonico-adicional).
# #1440 (mefisto-test-executor.sh) resuelve COMO correrlos: un worker
# concurrente por carril, continuidad ante un rojo, reconciliacion CANCELLED
# y cierre limpio ante INT/TERM. Este script es la entrada ESTABLE que
# compone ambos contratos sin reimplementarlos:
#
#   1. Valida el inventario (mefisto_test_inventory_validate y
#      mefisto_test_inventory_check_canonical_coverage) ANTES de lanzar nada.
#      Si cualquiera falla, no arranca ninguna prueba ni crea un run dir.
#   2. Resuelve el directorio de la corrida: uno unico bajo
#      .mefisto/pipeline/test-suite/ por defecto, o el que indique
#      --log-dir (creandolo si no existe).
#   3. Invoca mefisto_test_executor_run UNA sola vez, con los tres carriles
#      en el orden fijo del inventario (publicado -> interno ->
#      canonico-adicional).
#   4. Combina los tres results.tsv EN ESE MISMO ORDEN (nunca en el orden
#      real de terminacion de los workers) y emite un resumen humano
#      determinista: estado y duracion por entrada, subtotal por carril,
#      totales globales, tiempo de pared y las rutas del run dir y de cada
#      log.
#
# Deliberadamente NO convierte la regresion completa en gate implicito de
# ningun stage interno (issue #1416, seccion "Contexto"): es un comando que
# se invoca a proposito, nunca un hook automatico.
#
# Uso:
#   src/internal/scripts/mefisto-test-suite.sh [--log-dir <dir>]
#   src/internal/scripts/mefisto-test-suite.sh --help
#
# Exit code:
#   0   todas las entradas terminaron PASS.
#   1   inventario invalido, cobertura canonica incompleta, argumentos
#       invalidos, o al menos una entrada termino FAIL.
#   130 la corrida se interrumpio con INT (se propaga tal cual de
#       mefisto_test_executor_run).
#   143 la corrida se interrumpio con TERM (idem).
# En todos los casos se conservan los logs ya escritos y se emite un resumen
# final coherente con las entradas completadas y las marcadas CANCELLED.
#
# Neutral a runtime/proveedor (MEF-ADR-0050): la raiz del repo se resuelve
# siempre con 'git rev-parse --show-toplevel' (funciona desde cualquier
# subdirectorio del repo), nunca con variables de entorno de un runtime
# concreto. No invoca ningun CLI de un runtime de agente -- solo bash,
# coreutils y git.
#
# No instala un trap propio de INT/TERM: mefisto_test_executor_run ya
# instala, gestiona y restaura los suyos durante la corrida (ver la cabecera
# de mefisto-test-executor.sh); un trap adicional aqui que hiciera `exit`
# antes de que esa funcion retorne se comeria la reconciliacion CANCELLED y
# el resumen final.
#
# Bash 3.2 (macOS): sin 'declare -A', 'mapfile', 'readarray' ni 'wait -n'.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat >&2 <<'EOF'
Uso: mefisto-test-suite.sh [--log-dir <dir>]
     mefisto-test-suite.sh --help

Corre los tres carriles de la suite completa de Mefisto (publicado, interno,
canonico-adicional) tal como los define el inventario autoritativo
(src/internal/scripts/lib/mefisto-test-inventory.sh), usando el ejecutor
concurrente (src/internal/scripts/lib/mefisto-test-executor.sh), y emite un
resumen humano determinista con veredicto agregado. Puede invocarse desde
cualquier subdirectorio del repo.

  --log-dir <dir>   Usa <dir> como directorio de la corrida (se crea si no
                     existe), en vez del run dir unico que se crea por
                     defecto bajo .mefisto/pipeline/test-suite/.
  -h, --help        Muestra esta ayuda y termina con exit 0.

Exit code:
  0    todas las entradas de la suite terminaron PASS.
  1    inventario invalido, cobertura canonica incompleta, argumentos
       invalidos, o al menos una entrada termino FAIL.
  130  la corrida se interrumpio con INT.
  143  la corrida se interrumpio con TERM.
EOF
}

LOG_DIR_ARG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --log-dir)
            if [ $# -lt 2 ]; then
                echo "ERROR: --log-dir requiere un valor (directorio de la corrida)" >&2
                usage
                exit 1
            fi
            LOG_DIR_ARG="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: argumento desconocido '$1' (uso: mefisto-test-suite.sh [--log-dir <dir>] | --help)" >&2
            usage
            exit 1
            ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: no se pudo resolver la raiz del repo ('git rev-parse --show-toplevel' fallo); este runner solo opera dentro de un checkout de Mefisto" >&2
    exit 1
fi

INVENTORY_LIB="$SCRIPT_DIR/lib/mefisto-test-inventory.sh"
EXECUTOR_LIB="$SCRIPT_DIR/lib/mefisto-test-executor.sh"
for lib in "$INVENTORY_LIB" "$EXECUTOR_LIB"; do
    if [ ! -f "$lib" ]; then
        echo "ERROR: no se encontro '$lib' (issues #1438/#1440)" >&2
        exit 1
    fi
done
# shellcheck source=lib/mefisto-test-inventory.sh
source "$INVENTORY_LIB"
# shellcheck source=lib/mefisto-test-executor.sh
source "$EXECUTOR_LIB"

# --- 1. Validacion fail-closed del inventario (CA-2) ------------------------
#
# Se invocan AMBAS siempre (no se corta en la primera) para que quien lea
# stderr vea de una sola pasada todo lo que hay que corregir. Ninguna de las
# dos se envuelve ni se reformula: ya imprimen sus propias violaciones en
# stderr con el detalle de carril/ruta -- este runner solo reemite/propaga.
VALIDATE_RC=0
mefisto_test_inventory_validate "$REPO_ROOT" || VALIDATE_RC=$?
COVERAGE_RC=0
mefisto_test_inventory_check_canonical_coverage "$REPO_ROOT" || COVERAGE_RC=$?

if [ "$VALIDATE_RC" -ne 0 ] || [ "$COVERAGE_RC" -ne 0 ]; then
    echo "ERROR: [suite-tests] el inventario no paso la validacion; no se lanzo ninguna prueba (ver violaciones arriba)" >&2
    exit 1
fi

# --- 2. Entradas por carril, en el orden fijo del inventario ----------------
INVENTORY="$(mefisto_test_inventory_list "$REPO_ROOT")"
ENTRIES_PUBLICADO="$(mefisto_test_executor_entries_for_lane "publicado" "$INVENTORY")"
ENTRIES_INTERNO="$(mefisto_test_executor_entries_for_lane "interno" "$INVENTORY")"
ENTRIES_ADICIONAL="$(mefisto_test_executor_entries_for_lane "canonico-adicional" "$INVENTORY")"

# --- 3. Run dir: unico bajo .mefisto/pipeline/test-suite/, o el explicito ---
if [ -n "$LOG_DIR_ARG" ]; then
    mkdir -p -- "$LOG_DIR_ARG" || {
        echo "ERROR: no se pudo crear el directorio de --log-dir '$LOG_DIR_ARG'" >&2
        exit 1
    }
    RUN_DIR="$(cd "$LOG_DIR_ARG" && pwd)"
else
    DEFAULT_RUN_BASE="$REPO_ROOT/.mefisto/pipeline/test-suite"
    mkdir -p -- "$DEFAULT_RUN_BASE" || {
        echo "ERROR: no se pudo crear '$DEFAULT_RUN_BASE'" >&2
        exit 1
    }
    RUN_DIR="$(mktemp -d "$DEFAULT_RUN_BASE/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")" || {
        echo "ERROR: no se pudo crear un run dir unico bajo '$DEFAULT_RUN_BASE'" >&2
        exit 1
    }
fi

echo "Corrida de la suite completa de Mefisto"
echo "Run dir: $RUN_DIR"
echo ""

# --- 4. Una sola invocacion del ejecutor, orden fijo ------------------------
WALL_START=$SECONDS
EXEC_RC=0
mefisto_test_executor_run "$REPO_ROOT" "$RUN_DIR" \
    "publicado" "$ENTRIES_PUBLICADO" \
    "interno" "$ENTRIES_INTERNO" \
    "canonico-adicional" "$ENTRIES_ADICIONAL" || EXEC_RC=$?
WALL_ELAPSED=$((SECONDS - WALL_START))

# --- 5. Resumen determinista: combina los tres results.tsv en orden fijo ---

GLOBAL_TOTAL=0
GLOBAL_PASS=0
GLOBAL_FAIL=0
GLOBAL_CANCEL=0

# emit_lane_summary <carril>
#
# Imprime el bloque de <carril> leyendo su results.tsv (orden por el campo
# 'orden', numerico, nunca por orden de llegada al archivo) y acumula sus
# conteos en los globales GLOBAL_*. Corre en el shell actual (here-string, sin
# pipe a un subshell) para que la acumulacion sea visible al llamador.
emit_lane_summary() {
    local carril="$1"
    local results_file log_dir
    results_file="$(mefisto_test_executor_results_file "$RUN_DIR" "$carril")"
    log_dir="$(mefisto_test_executor_log_dir "$RUN_DIR" "$carril")"

    echo "--- Carril: $carril ---"

    local npass=0 nfail=0 ncancel=0 ntotal=0 dur_sum=0
    local rows=""
    if [ -f "$results_file" ]; then
        rows="$(LC_ALL=C sort -t $'\t' -k1,1n "$results_file" 2>/dev/null)"
    fi

    if [ -z "$rows" ]; then
        echo "  (sin entradas registradas)"
    else
        local orden ruta estado exit_code inicio fin duracion log
        while IFS=$'\t' read -r orden ruta estado exit_code inicio fin duracion log; do
            [ -z "$orden" ] && continue
            ntotal=$((ntotal + 1))
            case "$estado" in
                PASS) npass=$((npass + 1)) ;;
                FAIL) nfail=$((nfail + 1)) ;;
                CANCELLED) ncancel=$((ncancel + 1)) ;;
            esac
            if [ "$duracion" != "-" ]; then
                dur_sum=$((dur_sum + duracion))
            fi
            local dur_display="$duracion"
            [ "$dur_display" != "-" ] && dur_display="${dur_display}s"
            printf '  [%s] %s  %s\n' "$estado" "$dur_display" "$ruta"
            printf '        log: %s\n' "$log"
        done <<< "$rows"
    fi

    echo "Subtotal $carril: $npass PASS, $nfail FAIL, $ncancel CANCELLED ($ntotal entradas, ${dur_sum}s acumulados)"
    echo "Directorio de logs: $log_dir"
    echo ""

    GLOBAL_TOTAL=$((GLOBAL_TOTAL + ntotal))
    GLOBAL_PASS=$((GLOBAL_PASS + npass))
    GLOBAL_FAIL=$((GLOBAL_FAIL + nfail))
    GLOBAL_CANCEL=$((GLOBAL_CANCEL + ncancel))
}

emit_lane_summary "publicado"
emit_lane_summary "interno"
emit_lane_summary "canonico-adicional"

echo "=== Totales ==="
echo "Entradas: $GLOBAL_TOTAL ($GLOBAL_PASS PASS, $GLOBAL_FAIL FAIL, $GLOBAL_CANCEL CANCELLED)"
echo "Tiempo de pared: ${WALL_ELAPSED}s"

VEREDICTO="PASS"
if [ "$EXEC_RC" -eq 130 ]; then
    VEREDICTO="INTERRUMPIDA (INT)"
elif [ "$EXEC_RC" -eq 143 ]; then
    VEREDICTO="INTERRUMPIDA (TERM)"
elif [ "$GLOBAL_FAIL" -gt 0 ]; then
    VEREDICTO="FAIL"
fi
echo "Veredicto: $VEREDICTO"
echo "Run dir: $RUN_DIR"

case "$EXEC_RC" in
    130|143)
        exit "$EXEC_RC"
        ;;
    0)
        if [ "$GLOBAL_FAIL" -gt 0 ]; then
            exit 1
        fi
        exit 0
        ;;
    *)
        echo "ERROR: [suite-tests] mefisto_test_executor_run devolvio un codigo inesperado ($EXEC_RC)" >&2
        exit 1
        ;;
esac
