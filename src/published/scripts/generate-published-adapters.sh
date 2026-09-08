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
#   assets                        opcional: imprime un array JSON de assets
#   render-asset <id> <fuente>    imprime el contenido completo de un asset
#
# `root` y `path` deben imprimir una unica ruta relativa segura. Las raices de
# adaptadores distintos no pueden coincidir ni anidarse. `render` debe incluir
# el marcador recibido como una linea completa; puede ubicarlo despues del
# frontmatter que exija el runtime. El core no interpreta frontmatter,
# directivas, capacidades, namespaces, modelos ni permisos.
#
# Cada elemento de `assets` tiene `id`, `source`, `destination` y `mode`.
# `source` y `destination` son rutas repo-relativas y relativas a la raiz del
# adaptador, respectivamente; `mode` es 0644 o 0755. Los adaptadores previos a
# esta extension pueden rechazar `assets` sin salida y conservan su conducta.
# Los adaptadores que implementan la extension deben diagnosticar por stderr
# cualquier fallo de enumeracion para diferenciarlo de esa ausencia heredada.
# El motor escribe `.mefisto-generated-assets.json` en cada raiz: es su
# inventario versionado (schemaVersion 1), no el manifest de releases.

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

file_mode() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

sha256() {
    shasum -a 256 "$1" | cut -d ' ' -f 1
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
ASSET_PLANS=()
ASSET_COUNT=0

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
        chmod 0644 "$STAGE_DIR/$full_rel" || usage_error "no se pudo fijar el modo de $full_rel"
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

# Los assets se enumeran despues de los Markdown para poder rechazar cualquier
# colision contra sus salidas antes de publicar una sola raiz real.
for adapter_index in "${!ADAPTERS[@]}"; do
    adapter="${ADAPTERS[$adapter_index]}"
    adapter_name="$(basename "$adapter")"
    root="${ROOTS[$adapter_index]}"
    assets_stdout="$STAGE_DIR/assets-$adapter_index.json"
    assets_stderr="$STAGE_DIR/assets-$adapter_index.stderr"
    if ! "$adapter" assets > "$assets_stdout" 2> "$assets_stderr"; then
        # Los adaptadores sin extension existentes rechazan la operacion sin
        # salida. Un diagnostico identifica en cambio un fallo real.
        if [ -s "$assets_stdout" ] || [ -s "$assets_stderr" ]; then
            printf 'ERROR: %s no pudo enumerar assets suplementarios\n' "$adapter_name" >&2
            [ ! -s "$assets_stderr" ] || cat "$assets_stderr" >&2
            exit 1
        fi
        continue
    fi
    jq -e 'type == "array" and all(.[]; type == "object" and (keys | sort) == ["destination", "id", "mode", "source"] and (.id | type == "string") and (.source | type == "string") and (.destination | type == "string") and (.mode | type == "string"))' "$assets_stdout" >/dev/null 2>&1 || usage_error "$adapter_name declaro assets suplementarios invalidos"
    while IFS= read -r asset; do
        asset_id="$(printf '%s' "$asset" | jq -r '.id')"
        asset_source="$(printf '%s' "$asset" | jq -r '.source')"
        asset_destination="$(printf '%s' "$asset" | jq -r '.destination')"
        asset_mode="$(printf '%s' "$asset" | jq -r '.mode')"
        safe_relative_path "$asset_id" || usage_error "$adapter_name asset '$asset_id' declaro un id inseguro"
        safe_relative_path "$asset_source" || usage_error "$adapter_name asset '$asset_id' declaro una fuente insegura"
        safe_relative_path "$asset_destination" || usage_error "$adapter_name asset '$asset_id' declaro un destino inseguro"
        case "$asset_mode" in 0644|0755) ;; *) usage_error "$adapter_name asset '$asset_id' declaro un modo desconocido: $asset_mode" ;; esac
        asset_source_dir="$(cd "$(dirname "$REPO_ROOT/$asset_source")" 2>/dev/null && pwd -P)" || usage_error "$adapter_name asset '$asset_id' declaro una fuente ausente: $asset_source"
        absolute_asset_source="$asset_source_dir/$(basename "$asset_source")"
        case "$absolute_asset_source" in "$REPO_ROOT"/*) ;; *) usage_error "$adapter_name asset '$asset_id' declaro una fuente fuera del repositorio: $asset_source" ;; esac
        [ -f "$absolute_asset_source" ] || usage_error "$adapter_name asset '$asset_id' declaro una fuente ausente: $asset_source"
        full_rel="$root/$asset_destination"
        for plan in ${ASSET_PLANS[@]+"${ASSET_PLANS[@]}"}; do
            plan_adapter="$(printf '%s' "$plan" | jq -r '.adapter')"
            plan_id="$(printf '%s' "$plan" | jq -r '.id')"
            plan_destination="$(printf '%s' "$plan" | jq -r '.destination')"
            [ "$plan_adapter:$plan_id" != "$adapter_name:$asset_id" ] || usage_error "$adapter_name asset '$asset_id' repite un id"
            [ "$plan_destination" != "$full_rel" ] || usage_error "$adapter_name asset '$asset_id' colisiona en destino con otro asset: $full_rel"
        done
        generated_contains "$full_rel" && usage_error "$adapter_name asset '$asset_id' colisiona con salida agent/command: $full_rel"
        mkdir -p "$(dirname "$STAGE_DIR/$full_rel")" || usage_error "no se pudo preparar $full_rel"
        if ! "$adapter" render-asset "$asset_id" "$absolute_asset_source" > "$STAGE_DIR/$full_rel"; then
            printf "ERROR: %s no pudo renderizar el asset '%s'; no se escribio nada\n" "$adapter_name" "$asset_id" >&2
            exit 1
        fi
        chmod "$asset_mode" "$STAGE_DIR/$full_rel" || usage_error "no se pudo fijar el modo de $full_rel"
        ASSET_PLANS+=("$(jq -cn --arg adapter "$adapter_name" --arg id "$asset_id" --arg source "$asset_source" --arg destination "$full_rel" --arg mode "$asset_mode" --arg sha256 "$(sha256 "$STAGE_DIR/$full_rel")" '{adapter: $adapter, id: $id, source: $source, destination: $destination, mode: $mode, sha256: $sha256}')")
        ASSET_COUNT=$((ASSET_COUNT + 1))
        GENERATED+=("$full_rel")
    done < <(jq -c '.[]' "$assets_stdout")
done

for root in "${ROOTS[@]}"; do
    inventory="$root/.mefisto-generated-assets.json"
    if [ "$ASSET_COUNT" -eq 0 ]; then
        inventory_assets='[]'
    else
        inventory_assets="$(printf '%s\n' "${ASSET_PLANS[@]}" | jq -s --arg root "$root" '[.[] | select(.destination | startswith($root + "/")) | {adapter, id, source, destination: (.destination | ltrimstr($root + "/")), mode, sha256}] | sort_by(.adapter, .id)')"
    fi
    jq -cn --argjson assets "$inventory_assets" '{schemaVersion: 1, assets: $assets}' > "$STAGE_DIR/$inventory" || usage_error "no se pudo escribir el inventario de $root"
    chmod 0644 "$STAGE_DIR/$inventory" || usage_error "no se pudo fijar el modo de $inventory"
    GENERATED+=("$inventory")
done

is_supplemental_asset() {
    local needle="$1" plan
    [ "$ASSET_COUNT" -gt 0 ] || return 1
    for plan in "${ASSET_PLANS[@]}"; do
        [ "$(printf '%s' "$plan" | jq -r '.destination')" = "$needle" ] && return 0
    done
    return 1
}

if [ "$CHECK_MODE" -eq 1 ]; then
    divergent=0
    for relpath in ${GENERATED[@]+"${GENERATED[@]}"}; do
        existing="$OUT_ROOT/$relpath"
        if [ ! -f "$existing" ]; then
            printf '%s: faltante\n' "$relpath"; divergent=1
        elif [ "$(basename "$relpath")" = '.mefisto-generated-assets.json' ]; then
            if ! cmp -s "$STAGE_DIR/$relpath" "$existing"; then
                printf '%s: inventario inconsistente\n' "$relpath"
                divergent=1
            elif [ "$(file_mode "$STAGE_DIR/$relpath")" != "$(file_mode "$existing")" ]; then
                printf '%s: modo divergente\n' "$relpath"; divergent=1
            fi
        elif is_supplemental_asset "$relpath"; then
            if ! cmp -s "$STAGE_DIR/$relpath" "$existing"; then
                printf '%s: distinta\n' "$relpath"; divergent=1
            elif [ "$(file_mode "$STAGE_DIR/$relpath")" != "$(file_mode "$existing")" ]; then
                printf '%s: modo divergente\n' "$relpath"; divergent=1
            fi
        elif ! has_any_generated_marker "$existing"; then
            printf '%s: sin marcador\n' "$relpath"; divergent=1
        elif ! cmp -s "$STAGE_DIR/$relpath" "$existing"; then
            printf '%s: distinta\n' "$relpath"; divergent=1
        elif [ "$(file_mode "$STAGE_DIR/$relpath")" != "$(file_mode "$existing")" ]; then
            printf '%s: modo divergente\n' "$relpath"; divergent=1
        fi
    done
    for root in "${ROOTS[@]}"; do
        while IFS= read -r existing; do
            [ -n "$existing" ] || continue
            relpath="${existing#"$OUT_ROOT"/}"
            generated_contains "$relpath" && continue
            if has_any_generated_marker "$existing"; then
                printf '%s: huerfana\n' "$relpath"
            elif [ "$(basename "$existing")" = '.mefisto-generated-assets.json' ]; then
                printf '%s: inventario inconsistente\n' "$relpath"
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
