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
#   root                          imprime su raiz relativa bajo --out (p.ej. dist/foo)
#   path <fuente-relativa>        imprime la ruta relativa del archivo renderizado
#   render <fuente> <marcador>    imprime el contenido completo del archivo
#
# `root` y `path` deben imprimir una unica ruta relativa segura. Las raices de
# adaptadores distintos no pueden coincidir ni anidarse. `render` debe incluir
# el marcador recibido como una linea completa; puede ubicarlo despues del
# frontmatter que exija el runtime. El core no interpreta frontmatter,
# directivas, capacidades, namespaces, modelos ni permisos.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
VALIDATOR="$SCRIPT_DIR/validate-published-artifacts.sh"
ADAPTER_DIR="$SCRIPT_DIR/adapters"
MARKER_SCRIPT="src/published/scripts/generate-published-adapters.sh"
CHECK_MODE=0
OUT_ROOT="$REPO_ROOT"
FILES=()

usage_error() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

safe_relative_path() {
    local value="$1" segment
    local segments=()
    case "$value" in
        ''|/*|*/|*//*|*$'\n'*|*$'\r'*) return 1 ;;
    esac
    IFS='/' read -r -a segments <<< "$value"
    for segment in "${segments[@]}"; do
        case "$segment" in ''|.|..) return 1 ;; esac
    done
    return 0
}

paths_overlap() {
    case "$1/" in "$2/"*) return 0 ;; esac
    case "$2/" in "$1/"*) return 0 ;; esac
    return 1
}

has_marker() {
    # Coincidencia de linea completa: evita aceptar un prefijo parecido y
    # permite frontmatter antes del marcador.
    LC_ALL=C grep -Fqx "${1}" "$2" 2>/dev/null
}

has_any_generated_marker() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "<!-- GENERADO por $MARKER_SCRIPT desde "*". No editar a mano. -->") return 0 ;;
        esac
    done < "$1"
    return 1
}

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

# La validacion es deliberadamente la primera operacion sobre los artefactos:
# ningun rechazo puede crear ni modificar la salida.
[ -x "$VALIDATOR" ] || usage_error "no existe o no es ejecutable el validador publicado"
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
    usage_error "no hay adapter-<runtime>.sh registrados para renderizar fuentes explicitas"
fi

if ! command -v jq >/dev/null 2>&1; then
    usage_error "jq no esta instalado (MEF-ADR-0049: bash + jq)"
fi

ROOTS=()
for adapter in "${ADAPTERS[@]}"; do
    adapter_name="$(basename "$adapter")"
    [ -x "$adapter" ] || usage_error "adaptador no ejecutable: $adapter_name"
    root="$($adapter root)" || usage_error "$adapter_name no pudo declarar su raiz"
    safe_relative_path "$root" || usage_error "$adapter_name declaro una raiz insegura"
    case "$root" in
        dist/*) ;;
        *) usage_error "$adapter_name debe declarar una raiz dist/<runtime>" ;;
    esac
    for registered_root in ${ROOTS[@]+"${ROOTS[@]}"}; do
        paths_overlap "$root" "$registered_root" && usage_error "$adapter_name declaro una raiz duplicada o anidada: $root"
    done
    ROOTS+=("$root")
done

STAGE_DIR="$(mktemp -d)" || usage_error "no se pudo crear el staging temporal"
PUBLISH_DIR=""
cleanup() {
    rm -rf "$STAGE_DIR"
    [ -z "$PUBLISH_DIR" ] || rm -rf "$PUBLISH_DIR"
}
trap cleanup EXIT
GENERATED=()

for root in "${ROOTS[@]}"; do
    mkdir -p "$STAGE_DIR/$root" || usage_error "no se pudo preparar el staging"
done

for file in ${FILES[@]+"${FILES[@]}"}; do
    file_dir="$(cd "$(dirname "$file")" 2>/dev/null && pwd -P)" || usage_error "fuente inaccesible"
    absolute_source="$file_dir/$(basename "$file")"
    case "$absolute_source" in
        "$REPO_ROOT"/*) rel_source="${absolute_source#"$REPO_ROOT"/}" ;;
        *) usage_error "fuente fuera del repositorio" ;;
    esac
    marker="<!-- GENERADO por $MARKER_SCRIPT desde $rel_source. No editar a mano. -->"
    adapter_index=0
    for adapter in "${ADAPTERS[@]}"; do
        adapter_name="$(basename "$adapter")"
        root="${ROOTS[$adapter_index]}"
        adapter_index=$((adapter_index + 1))
        relpath="$($adapter path "$rel_source")" || usage_error "$adapter_name no pudo calcular la ruta de $rel_source"
        safe_relative_path "$relpath" || usage_error "$adapter_name devolvio una ruta insegura para $rel_source"
        full_rel="$root/$relpath"
        generated_contains=0
        for generated_path in ${GENERATED[@]+"${GENERATED[@]}"}; do
            [ "$generated_path" = "$full_rel" ] && generated_contains=1
        done
        [ "$generated_contains" -eq 0 ] || usage_error "$adapter_name produjo una ruta duplicada: $full_rel"
        mkdir -p "$(dirname "$STAGE_DIR/$full_rel")" || usage_error "no se pudo preparar $full_rel"
        if ! "$adapter" render "$absolute_source" "$marker" > "$STAGE_DIR/$full_rel"; then
            printf "ERROR: %s no pudo renderizar '%s'; no se escribio nada\n" "$adapter_name" "$rel_source" >&2
            exit 1
        fi
        has_marker "$marker" "$STAGE_DIR/$full_rel" || usage_error "$adapter_name no escribio el marcador estable para $rel_source"
        GENERATED+=("$full_rel")
    done
done

generated_contains() {
    local needle="$1" candidate
    for candidate in ${GENERATED[@]+"${GENERATED[@]}"}; do
        [ "$candidate" = "$needle" ] && return 0
    done
    return 1
}

if [ "$CHECK_MODE" -eq 1 ]; then
    divergent=0
    for relpath in ${GENERATED[@]+"${GENERATED[@]}"}; do
        existing="$OUT_ROOT/$relpath"
        if [ ! -f "$existing" ]; then
            printf '%s: faltante\n' "$relpath"; divergent=1
        elif ! has_any_generated_marker "$existing"; then
            printf '%s: sin marcador\n' "$relpath"; divergent=1
        elif ! cmp -s "$STAGE_DIR/$relpath" "$existing"; then
            printf '%s: distinta\n' "$relpath"; divergent=1
        fi
    done
    for root in "${ROOTS[@]}"; do
        while IFS= read -r existing; do
            [ -n "$existing" ] || continue
            relpath="${existing#"$OUT_ROOT"/}"
            generated_contains "$relpath" && continue
            if has_any_generated_marker "$existing"; then
                printf '%s: huerfana\n' "$relpath"
            else
                printf '%s: sin marcador\n' "$relpath"
            fi
            divergent=1
        done < <(find "$OUT_ROOT/$root" -type f 2>/dev/null | sort)
    done
    exit "$divergent"
fi

# Se preparan arboles completos antes de reemplazar las raices declaradas. Esto
# elimina huerfanos y archivos manuales, de modo que escribir y luego comprobar
# siempre converge al mismo arbol.
mkdir -p "$OUT_ROOT" || usage_error "no se pudo crear la raiz de salida"
PUBLISH_DIR="$(mktemp -d "$OUT_ROOT/.published-adapters.XXXXXX")" || usage_error "no se pudo preparar la publicacion"
mkdir -p "$PUBLISH_DIR/candidates" "$PUBLISH_DIR/backups" || usage_error "no se pudo preparar la publicacion"
index=0
for root in "${ROOTS[@]}"; do
    mkdir -p "$PUBLISH_DIR/candidates/$index" || usage_error "no se pudo preparar $root"
    cp -R "$STAGE_DIR/$root/." "$PUBLISH_DIR/candidates/$index/" || usage_error "no se pudo preparar $root"
    index=$((index + 1))
done

swapped=0
index=0
for root in "${ROOTS[@]}"; do
    destination="$OUT_ROOT/$root"
    mkdir -p "$(dirname "$destination")" || break
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        mv "$destination" "$PUBLISH_DIR/backups/$index" || break
    fi
    if mv "$PUBLISH_DIR/candidates/$index" "$destination"; then
        swapped=$((swapped + 1))
    else
        [ ! -e "$PUBLISH_DIR/backups/$index" ] || mv "$PUBLISH_DIR/backups/$index" "$destination"
        break
    fi
    index=$((index + 1))
done

if [ "$swapped" -ne "${#ROOTS[@]}" ]; then
    index=$((swapped - 1))
    while [ "$index" -ge 0 ]; do
        root="${ROOTS[$index]}"
        rm -rf "$OUT_ROOT/$root"
        [ ! -e "$PUBLISH_DIR/backups/$index" ] || mv "$PUBLISH_DIR/backups/$index" "$OUT_ROOT/$root"
        index=$((index - 1))
    done
    usage_error "no se pudieron publicar todas las raices; se restauro la salida anterior"
fi

exit 0
