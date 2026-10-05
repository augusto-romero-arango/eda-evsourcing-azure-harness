#!/usr/bin/env bash
# mefisto-nightly-report.sh -- Cuerpo markdown del issue de la nightly (issue #1773).
#
# Uso: mefisto-nightly-report.sh <log-dir> <run-url> <sha> [<failed-log>]
#
# Lee los results.tsv que deja mefisto-test-suite.sh --log-dir (un archivo por
# carril: <log-dir>/<carril>/results.tsv; columnas orden, ruta, estado, exit,
# inicio, fin, duracion, log) y escribe en stdout el cuerpo markdown: enlace al
# run, SHA evaluado, conteo PASS/FAIL total y por carril, y rutas con FAIL.
# Las entradas CANCELLED (interrumpidas o nunca lanzadas, p. ej. por timeout)
# no cuentan como PASS ni FAIL: se reportan aparte solo si hay alguna.
# Si no hay ningun results.tsv, el cuerpo lo dice explicitamente. Sale 0 en
# ambos casos. No invoca gh: la publicacion la hace el workflow.
# <failed-log> (opcional, issue #1969): salida de 'gh run view --log-failed'
# (lineas '<job>\t<paso>\t<timestamp> <texto>'). Si existe y no esta vacio se
# agrega '### Evidencia del paso fallido': nombre del paso, lineas
# ERROR:/::error::/FAIL: y las ultimas 40 lineas, sin ANSI ni timestamps, en un
# bloque de codigo con cerco de 4 backticks (un log con ``` no lo rompe),
# truncado por lineas para que el cuerpo no pase de 60000 caracteres.
# Neutral a runtime (MEF-ADR-0050): solo bash y coreutils.

set -uo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "Uso: $0 <log-dir> <run-url> <sha> [<failed-log>]" >&2
    exit 2
fi

log_dir="$1"
run_url="$2"
sha="$3"
failed_log="${4:-}"
MAX_BODY=60000

render_base() {
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
    return 0
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
}

buf="$(mktemp)"
trap 'rm -f "$buf"' EXIT
render_base > "$buf"
cat "$buf"

if [ -n "$failed_log" ] && [ -s "$failed_log" ]; then
    esc="$(printf '\033')"
    clean="$(mktemp)"
    trap 'rm -f "$buf" "$clean"' EXIT
    # Quita ANSI y el prefijo de timestamp ISO del texto (3.er campo).
    awk -F'\t' 'BEGIN{OFS="\t"} NF>=3 {t=$3; for(i=4;i<=NF;i++) t=t "\t" $i; print $2, t; next} {print "", $0}' "$failed_log" \
        | sed -e "s/${esc}\[[0-9;?]*[A-Za-z]//g" -e 's/\r$//' \
        | sed -E $'s/^([^\t]*)\t[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?/\\1\t/' > "$clean"
    steps="$(cut -f1 "$clean" | awk 'NF && !seen[$0]++' | paste -sd, - | sed 's/,/, /g')"
    texts="$(mktemp)"
    trap 'rm -f "$buf" "$clean" "$texts"' EXIT
    cut -f2- "$clean" > "$texts"
    section="$(mktemp)"
    trap 'rm -f "$buf" "$clean" "$texts" "$section"' EXIT
    {
        echo
        echo "### Evidencia del paso fallido"
        echo
        echo "Paso: ${steps:-(desconocido)}"
        echo
        echo '````'
        if grep -qE 'ERROR:|::error::|FAIL:' "$texts"; then
            echo "# Lineas de error"
            grep -E 'ERROR:|::error::|FAIL:' "$texts"
            echo
        fi
        echo "# Ultimas 40 lineas"
        tail -n 40 "$texts"
        echo '````'
    } > "$section"
    base_size="$(wc -c < "$buf" | tr -d ' ')"
    note=$'(evidencia truncada: se recorto para no superar el limite del cuerpo)\n````'
    reserve=$(( ${#note} + 8 ))
    budget=$(( MAX_BODY - base_size - reserve ))
    sec_size="$(wc -c < "$section" | tr -d ' ')"
    if [ $(( base_size + sec_size )) -le "$MAX_BODY" ]; then
        cat "$section"
    elif [ "$budget" -gt 0 ]; then
        # Corta en el ultimo salto de linea completo: nunca a mitad de linea ni de un caracter UTF-8.
        head -c "$budget" "$section" | sed '$d'
        printf '%s\n' "$note"
    else
        printf '\n### Evidencia del paso fallido\n\n(evidencia omitida: el cuerpo ya alcanza el limite)\n'
    fi
fi
exit 0
