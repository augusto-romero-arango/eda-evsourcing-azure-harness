#!/usr/bin/env bash
# generate-published-adapters.sh -- Orquesta los adaptadores publicados desde
# src/published/{agents,commands}. No conoce formatos de runtime: cada
# adapter-<runtime>.sh declara su raiz y renderiza sus propios archivos.
#
# Uso: generate-published-adapters.sh [--check] [--out <raiz>] [archivo...]
# Sin archivos valida y procesa src/published/{agents,commands}/*.md en orden
# LC_ALL=C. --out es la raiz que contiene dist/ (principalmente para tests).
# --check nunca crea --out y lista <ruta>: faltante|distinta|huerfana|sin marcador.
#
# Interfaz de un adaptador ejecutable adapter-<runtime>.sh:
#   root                         imprime su raiz relativa bajo --out (p.ej. dist/foo)
#   path <fuente-relativa>        imprime la ruta relativa del archivo renderizado
#   render <fuente> <marcador>    imprime el contenido completo del archivo
# `path` no puede escapar de `root`; `render` debe dejar <marcador> como primera
# linea. El core no interpreta frontmatter, directivas ni capacidades.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VALIDATOR="$SCRIPT_DIR/validate-published-artifacts.sh"
ADAPTER_DIR="$SCRIPT_DIR/adapters"
MARKER_SCRIPT="src/published/scripts/generate-published-adapters.sh"
CHECK_MODE=0
OUT_ROOT="$REPO_ROOT"
FILES=()

usage_error() { echo "ERROR: $1" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_MODE=1; shift ;;
        --out)
            [ $# -ge 2 ] || usage_error "--out requiere una raiz"
            OUT_ROOT="$2"; shift 2 ;;
        --*) usage_error "opcion desconocida: $1" ;;
        *) FILES+=("$1"); shift ;;
    esac
done

# CA-1: esto ocurre antes de descubrir, preparar o crear cualquier salida.
[ -x "$VALIDATOR" ] || usage_error "no existe o no es ejecutable '$VALIDATOR'"
if [ ${#FILES[@]} -eq 0 ]; then
    VALIDATION="$($VALIDATOR 2>&1)"; VALIDATION_RC=$?
else
    VALIDATION="$($VALIDATOR "${FILES[@]}" 2>&1)"; VALIDATION_RC=$?
fi
if [ "$VALIDATION_RC" -ne 0 ]; then
    [ -n "$VALIDATION" ] && printf '%s\n' "$VALIDATION" >&2
    exit 1
fi

if [ ${#FILES[@]} -eq 0 ]; then
    while IFS= read -r file; do
        [ -n "$file" ] && FILES+=("$file")
    done < <(find "$REPO_ROOT/src/published/agents" "$REPO_ROOT/src/published/commands" -name '*.md' -type f 2>/dev/null | sort)
fi

if ! command -v jq >/dev/null 2>&1; then
    usage_error "jq no esta instalado (MEF-ADR-0049: bash + jq)"
fi

ADAPTERS=()
if [ -d "$ADAPTER_DIR" ]; then
    while IFS= read -r adapter; do
        [ -n "$adapter" ] && ADAPTERS+=("$adapter")
    done < <(find "$ADAPTER_DIR" -maxdepth 1 -type f -name 'adapter-*.sh' 2>/dev/null | sort)
fi
if [ ${#ADAPTERS[@]} -eq 0 ]; then
    if [ ${#FILES[@]} -eq 0 ]; then
        exit 0
    fi
    usage_error "no hay adaptadores registrados en '$ADAPTER_DIR' para renderizar fuentes explicitas"
fi

ROOTS=()
for adapter in "${ADAPTERS[@]}"; do
    [ -x "$adapter" ] || usage_error "adaptador no ejecutable: '$adapter'"
    root="$($adapter root)" || usage_error "adaptador '$adapter' no pudo declarar su raiz"
    case "$root" in
        dist/*) ;;
        *) usage_error "adaptador '$adapter' declaro una raiz invalida: '$root' (se esperaba dist/<runtime>)" ;;
    esac
    case "$root" in *'..'*|/*|'') usage_error "adaptador '$adapter' declaro una raiz insegura: '$root'" ;; esac
    ROOTS+=("$root")
done

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
GENERATED=()

for file in ${FILES[@]+"${FILES[@]}"}; do
    case "$file" in
        "$REPO_ROOT"/*) rel_source="${file#"$REPO_ROOT"/}" ;;
        /*) usage_error "fuente fuera del repositorio: '$file'" ;;
        *) rel_source="$file" ;;
    esac
    marker="<!-- GENERADO por $MARKER_SCRIPT desde $rel_source. No editar a mano. -->"
    for adapter in "${ADAPTERS[@]}"; do
        root="$($adapter root)" || usage_error "adaptador '$adapter' no pudo declarar su raiz"
        relpath="$($adapter path "$rel_source")" || usage_error "adaptador '$adapter' no pudo calcular la ruta de '$rel_source'"
        case "$relpath" in /*|*'..'*|'') usage_error "adaptador '$adapter' devolvio una ruta insegura: '$relpath'" ;; esac
        full_rel="$root/$relpath"
        mkdir -p "$(dirname "$STAGE_DIR/$full_rel")"
        if ! "$adapter" render "$file" "$marker" > "$STAGE_DIR/$full_rel"; then
            echo "ERROR: adaptador '$adapter' no pudo renderizar '$rel_source'; no se escribio nada" >&2
            exit 1
        fi
        IFS= read -r first_line < "$STAGE_DIR/$full_rel" || true
        [ "$first_line" = "$marker" ] || usage_error "adaptador '$adapter' no escribio el marcador estable para '$rel_source'"
        GENERATED+=("$full_rel")
    done
done

generated_contains() {
    local needle="$1" candidate
    for candidate in ${GENERATED[@]+"${GENERATED[@]}"}; do [ "$candidate" = "$needle" ] && return 0; done
    return 1
}

has_marker() {
    case "$1" in
        "<!-- GENERADO por $MARKER_SCRIPT desde "*) return 0 ;;
        *) return 1 ;;
    esac
}

if [ "$CHECK_MODE" -eq 1 ]; then
    divergent=0
    for relpath in ${GENERATED[@]+"${GENERATED[@]}"}; do
        existing="$OUT_ROOT/$relpath"
        if [ ! -f "$existing" ]; then
            echo "$relpath: faltante"; divergent=1
        else
            IFS= read -r first_line < "$existing" || true
            if ! has_marker "$first_line"; then
                echo "$relpath: sin marcador"; divergent=1
            elif ! cmp -s "$STAGE_DIR/$relpath" "$existing"; then
                echo "$relpath: distinta"; divergent=1
            fi
        fi
    done
    for root in "${ROOTS[@]}"; do
        while IFS= read -r existing; do
            [ -n "$existing" ] || continue
            relpath="${existing#"$OUT_ROOT"/}"
            generated_contains "$relpath" && continue
            IFS= read -r first_line < "$existing" || true
            if has_marker "$first_line"; then
                echo "$relpath: huerfana"
            else
                echo "$relpath: sin marcador"
            fi
            divergent=1
        done < <(find "$OUT_ROOT/$root" -type f 2>/dev/null | sort)
    done
    exit "$divergent"
fi

for relpath in ${GENERATED[@]+"${GENERATED[@]}"}; do
    destination="$OUT_ROOT/$relpath"
    mkdir -p "$(dirname "$destination")"
    cp "$STAGE_DIR/$relpath" "$destination"
done
