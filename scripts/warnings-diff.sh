#!/usr/bin/env bash
# warnings-diff.sh -- Detecta los warnings NUEVOS que introduce el arbol de
# trabajo respecto al commit base (MEF-ADR-0056, issue #2405).
#
# Uso:
#   scripts/warnings-diff.sh --toolchain <t> [--base <sha>] [--path <dir>]
#
#   --toolchain  Obligatorio. Hoy solo 'shell' (shellcheck). 'dotnet' y
#                'terraform' las registran otros issues apoyandose en este nucleo.
#   --base       Commit base. Default: git merge-base HEAD origin/main.
#   --path       Acota el analisis a un subdirectorio relativo a la raiz del repo.
#
# Lado "antes": worktree temporal en --base (se elimina siempre via trap).
# Lado "despues": el arbol de trabajo actual (incluye .sh nuevos sin commitear).
# Cache de la base: <raiz>/.mefisto/pipeline/warnings-baseline/
#   <toolchain>-<sha>-<path-slug>.txt
# Comparacion: multiconjunto de claves '<toolchain>|<archivo>|<codigo>|<mensaje>'
# (sin linea ni columna). Las supresiones anadidas (lineas '+' de git diff
# <base>) cuentan como warning nuevo con codigo SUPPRESSION.
#
# Extensibilidad: cada toolchain <t> aporta run_<t> <raiz> <lado> <salida>,
# parse_<t> (stdin crudo -> claves normalizadas) y suppression_patterns_<t>
# (regex ERE, uno por linea). Con WARNINGS_DIFF_FIXTURE_DIR, run_<t> lee la
# salida cruda de <dir>/<lado>.out (base.out / current.out) en vez de ejecutar
# la herramienta (y no se usa worktree ni cache).
#
# Salida: 'NEW <toolchain> <archivo> <codigo> <mensaje>' por warning nuevo y
# una linea final 'warnings nuevos: <N>'.
#
# Exit codes: 0 sin warnings nuevos; 1 error; 2 hay warnings nuevos.

set -uo pipefail

# Guard defensivo: plugin publicado, solo aplica al consumidor. No sourcea
# _pipeline-common.sh (igual que next-order.sh).
_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$_REPO_TOP/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/warnings-diff.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Estas en el repo de Mefisto." >&2
    exit 1
fi
REPO_ROOT="$_REPO_TOP"
unset _REPO_TOP

usage() {
    echo "Uso: scripts/warnings-diff.sh --toolchain <t> [--base <sha>] [--path <dir>]" >&2
}

TOOLCHAIN=""
BASE=""
SCOPE_PATH=""
while [ $# -gt 0 ]; do
    case "$1" in
        --toolchain) TOOLCHAIN="${2:-}"; shift 2 || { usage; exit 1; } ;;
        --base) BASE="${2:-}"; shift 2 || { usage; exit 1; } ;;
        --path) SCOPE_PATH="${2:-}"; shift 2 || { usage; exit 1; } ;;
        *) echo "ERROR: argumento desconocido: $1" >&2; usage; exit 1 ;;
    esac
done

if [ -z "$TOOLCHAIN" ]; then
    echo "ERROR: falta --toolchain" >&2
    usage
    exit 1
fi

# -------- Toolchain: shell --------

run_shell() {
    local root="$1" side="$2" out="$3"
    if [ -n "${WARNINGS_DIFF_FIXTURE_DIR:-}" ]; then
        cat "$WARNINGS_DIFF_FIXTURE_DIR/$side.out" > "$out" 2>/dev/null || : > "$out"
        return 0
    fi
    if ! command -v shellcheck >/dev/null 2>&1; then
        echo "ERROR: shellcheck no esta instalado" >&2
        return 1
    fi
    : > "$out"
    local files f
    files=$(cd "$root" && git ls-files --cached --others --exclude-standard -- "${SCOPE_PATH:-.}" | grep -E '\.sh$' | sort -u)
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -f "$root/$f" ] || continue
        # El exit 1 de la herramienta con hallazgos no es un fallo.
        (cd "$root" && shellcheck -S warning -f gcc "$f" 2>/dev/null) >> "$out" || true
    done <<< "$files"
    return 0
}

parse_shell() {
    # a.sh:2:1: warning: msg [SC2034] -> shell|a.sh|SC2034|msg
    sed -nE 's#^(\./)?([^:]+):[0-9]+:[0-9]+: (warning|error): (.*) \[(SC[0-9]+)\]$#shell|\2|\5|\4#p'
}

suppression_patterns_shell() {
    printf '%s\n' 'shellcheck[[:space:]]+disable=' '^disable=.*@@shellcheckrc'
}

# -------- Validacion de toolchain --------

if [ "$TOOLCHAIN" != "shell" ]; then
    echo "ERROR: toolchain no soportada: $TOOLCHAIN" >&2
    usage
    exit 1
fi
for fn in run_"$TOOLCHAIN" parse_"$TOOLCHAIN" suppression_patterns_"$TOOLCHAIN"; do
    declare -F "$fn" >/dev/null || { echo "ERROR: toolchain no soportada: $TOOLCHAIN" >&2; exit 1; }
done

# -------- Resolucion de la base --------

if [ -z "$BASE" ]; then
    BASE=$(git -C "$REPO_ROOT" merge-base HEAD origin/main 2>/dev/null) || {
        echo "ERROR: no se pudo resolver la base (git merge-base HEAD origin/main); usa --base" >&2
        exit 1
    }
fi
BASE_SHA=$(git -C "$REPO_ROOT" rev-parse --verify --quiet "$BASE^{commit}") || {
    echo "ERROR: base invalida: $BASE" >&2
    exit 1
}

if [ -n "$SCOPE_PATH" ]; then
    SCOPE_PATH="${SCOPE_PATH#./}"
    SCOPE_PATH="${SCOPE_PATH%/}"
fi
PATH_SLUG=$(printf '%s' "${SCOPE_PATH:-all}" | tr -c 'A-Za-z0-9._-' '_')

TMP_WORK=$(mktemp -d)
WT_DIR=""
cleanup() {
    if [ -n "$WT_DIR" ]; then
        git -C "$REPO_ROOT" worktree remove --force "$WT_DIR" >/dev/null 2>&1 || true
        git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
        rm -rf "$WT_DIR"
    fi
    rm -rf "$TMP_WORK"
}
trap cleanup EXIT

# -------- Lado antes (con cache) --------

BASE_KEYS="$TMP_WORK/base.keys"
CACHE_DIR="$REPO_ROOT/.mefisto/pipeline/warnings-baseline"
CACHE_FILE="$CACHE_DIR/$TOOLCHAIN-$BASE_SHA-$PATH_SLUG.txt"

if [ -z "${WARNINGS_DIFF_FIXTURE_DIR:-}" ] && [ -f "$CACHE_FILE" ]; then
    cp "$CACHE_FILE" "$BASE_KEYS"
else
    if [ -n "${WARNINGS_DIFF_FIXTURE_DIR:-}" ]; then
        run_"$TOOLCHAIN" "$REPO_ROOT" base "$TMP_WORK/base.raw" || exit 1
    else
        WT_DIR=$(mktemp -d)
        if ! git -C "$REPO_ROOT" worktree add --detach "$WT_DIR" "$BASE_SHA" >/dev/null 2>&1; then
            echo "ERROR: no se pudo crear el worktree temporal en $BASE_SHA" >&2
            exit 1
        fi
        run_"$TOOLCHAIN" "$WT_DIR" base "$TMP_WORK/base.raw" || exit 1
    fi
    parse_"$TOOLCHAIN" < "$TMP_WORK/base.raw" | LC_ALL=C sort > "$BASE_KEYS"
    if [ -z "${WARNINGS_DIFF_FIXTURE_DIR:-}" ]; then
        mkdir -p "$CACHE_DIR" && cp "$BASE_KEYS" "$CACHE_FILE"
    fi
fi

# -------- Lado despues: arbol de trabajo --------

run_"$TOOLCHAIN" "$REPO_ROOT" current "$TMP_WORK/current.raw" || exit 1
parse_"$TOOLCHAIN" < "$TMP_WORK/current.raw" | LC_ALL=C sort > "$TMP_WORK/current.keys"

# Multiconjunto: comm sobre listas ordenadas con duplicados.
LC_ALL=C comm -13 "$BASE_KEYS" "$TMP_WORK/current.keys" > "$TMP_WORK/new.keys"

# -------- Supresiones anadidas --------

PATTERNS="$TMP_WORK/patterns"
suppression_patterns_"$TOOLCHAIN" > "$PATTERNS"

# scan_added_lines: lee 'archivo<TAB>linea' de las lineas anadidas.
scan_suppressions() {
    local file line pat kind regex
    while IFS=$'\t' read -r file line; do
        [ -n "$file" ] || continue
        while IFS= read -r pat; do
            [ -n "$pat" ] || continue
            regex="$pat"
            kind=""
            case "$pat" in
                *@@shellcheckrc) regex="${pat%@@shellcheckrc}"; kind="rc" ;;
            esac
            if [ "$kind" = "rc" ] && [ "$(basename "$file")" != ".shellcheckrc" ]; then
                continue
            fi
            if printf '%s\n' "$line" | grep -Eq -- "$regex"; then
                local msg
                msg=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
                printf '%s|%s|SUPPRESSION|%s\n' "$TOOLCHAIN" "$file" "supresion anadida: $msg"
                break
            fi
        done < "$PATTERNS"
    done
}

{
    git -C "$REPO_ROOT" diff "$BASE_SHA" -U0 --no-color --no-ext-diff -- "${SCOPE_PATH:-.}" 2>/dev/null |
        awk '
            /^\+\+\+ / { f = substr($0, 5); if (f == "/dev/null") f = ""; else sub(/^b\//, "", f); next }
            /^\+/ { if (f != "") printf "%s\t%s\n", f, substr($0, 2) }
        '
    # Archivos nuevos sin commitear: todas sus lineas son anadidas.
    while IFS= read -r nf; do
        [ -n "$nf" ] && [ -f "$REPO_ROOT/$nf" ] || continue
        while IFS= read -r l || [ -n "$l" ]; do
            printf '%s\t%s\n' "$nf" "$l"
        done < "$REPO_ROOT/$nf"
    done < <(git -C "$REPO_ROOT" ls-files --others --exclude-standard -- "${SCOPE_PATH:-.}")
} | scan_suppressions >> "$TMP_WORK/new.keys"

# -------- Salida --------

COUNT=0
while IFS='|' read -r t file code msg; do
    [ -n "$t" ] || continue
    printf 'NEW %s %s %s %s\n' "$t" "$file" "$code" "$msg"
    COUNT=$((COUNT + 1))
done < "$TMP_WORK/new.keys"

echo "warnings nuevos: $COUNT"
[ "$COUNT" -gt 0 ] && exit 2
exit 0
