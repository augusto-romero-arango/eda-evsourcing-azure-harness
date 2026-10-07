#!/usr/bin/env bash
# mefisto-nightly-report.sh -- Cuerpo markdown del issue de la nightly (issue #1773).
#
# Uso: mefisto-nightly-report.sh <log-dir> <run-url> <sha>
#
# Lee los results.tsv que deja mefisto-test-suite.sh --log-dir (un archivo por
# carril: <log-dir>/<carril>/results.tsv; columnas orden, ruta, estado, exit,
# inicio, fin, duracion, log) y escribe en stdout el cuerpo markdown: enlace al
# run, SHA evaluado, conteo PASS/FAIL total y por carril, y rutas con FAIL.
# Las entradas CANCELLED (interrumpidas o nunca lanzadas, p. ej. por timeout)
# no cuentan como PASS ni FAIL: se reportan aparte solo si hay alguna.
# Si no hay ningun results.tsv, el cuerpo lo dice explicitamente. Sale 0 en
# ambos casos. No invoca gh: la publicacion la hace el workflow.
# Neutral a runtime (MEF-ADR-0050): solo bash y coreutils.

set -uo pipefail

if [ "$#" -ne 3 ]; then
    echo "Uso: $0 <log-dir> <run-url> <sha>" >&2
    exit 2
fi

log_dir="$1"
run_url="$2"
sha="$3"

echo "## Nightly roja"
echo
echo "- Run: $run_url"
echo "- SHA evaluado: \`$sha\`"
echo

files=""
if [ -d "$log_dir" ]; then
    files="$(find "$log_dir" -name results.tsv -type f 2>/dev/null | LC_ALL=C sort)"
fi

if [ -z "$files" ]; then
    echo "La suite no produjo resultados (timeout o fallo del runner): no se encontro ningun \`results.tsv\` en el artefacto \`test-suite-logs\`."
    echo "Revisa el log del run para ver en que paso fallo."
    exit 0
fi

total_pass=0
total_fail=0
total_cancelled=0
lane_lines=""
fail_lines=""

while IFS= read -r file; do
    [ -z "$file" ] && continue
    lane="$(basename "$(dirname "$file")")"
    npass=0
    nfail=0
    ncancelled=0
    while IFS=$'\t' read -r orden ruta estado _rest; do
        [ -z "$orden" ] && continue
        case "$estado" in
            PASS) npass=$((npass + 1)) ;;
            FAIL)
                nfail=$((nfail + 1))
                fail_lines="${fail_lines}- \`${ruta}\` (carril \`${lane}\`)"$'\n'
                ;;
            CANCELLED) ncancelled=$((ncancelled + 1)) ;;
        esac
    done < "$file"
    total_pass=$((total_pass + npass))
    total_fail=$((total_fail + nfail))
    total_cancelled=$((total_cancelled + ncancelled))
    lane_lines="${lane_lines}| ${lane} | ${npass} | ${nfail} |"$'\n'
done <<EOF
$files
EOF

echo "### Conteo"
echo
echo "Total: PASS=$total_pass FAIL=$total_fail"
if [ "$total_cancelled" -gt 0 ]; then
    echo
    echo "CANCELLED=$total_cancelled: entradas interrumpidas o que no llegaron a correr (timeout o cancelacion del job)."
fi
echo
echo "| Carril | PASS | FAIL |"
echo "|---|---|---|"
printf '%s' "$lane_lines"
echo
echo "### Rutas con FAIL"
echo
if [ -n "$fail_lines" ]; then
    printf '%s' "$fail_lines"
else
    echo "(ninguna: todos los tests registrados pasaron; el rojo viene de otro paso del job)"
fi
exit 0
