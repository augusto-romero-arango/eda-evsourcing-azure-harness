#!/usr/bin/env bash
# Construye el asset OpenCode desde la unica frontera publicable: dist/opencode.
# Uso: package-opencode-release.sh [--output <directorio>]
set -uo pipefail
export LC_ALL=C
# Evita que las herramientas BSD incorporen metadata AppleDouble/xattrs del host.
export COPYFILE_DISABLE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="${MEFISTO_PACKAGE_REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd -P)}"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
DIST_ROOT="$REPO_ROOT/dist/opencode"
INSTALLER_SOURCE="$REPO_ROOT/src/published/scripts/install-opencode-release.sh"
LAUNCHER_SOURCE="$REPO_ROOT/src/published/scripts/mefisto-opencode"
PROJECTOR_SOURCE="$REPO_ROOT/src/published/scripts/project-opencode-release.sh"
DIAGNOSTIC_SOURCE="$REPO_ROOT/src/published/scripts/diagnose-installation-identity.sh"
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
MINIMUM_RUNTIME_VERSION="1.18.29"
OUTPUT_DIR="$REPO_ROOT/dist/releases"

usage_error() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --output)
            [ $# -ge 2 ] || usage_error "--output requiere un directorio"
            OUTPUT_DIR="$2"; shift 2 ;;
        --*) usage_error "opcion desconocida: $1" ;;
        *) usage_error "argumento inesperado: $1" ;;
    esac
done

[ -x "$GENERATOR" ] || usage_error "no existe o no es ejecutable el generador publicado"
[ -f "$INSTALLER_SOURCE" ] || usage_error "no existe el instalador OpenCode"
[ -f "$LAUNCHER_SOURCE" ] || usage_error "no existe el launcher OpenCode"
[ -f "$PROJECTOR_SOURCE" ] || usage_error "no existe el proyector OpenCode"
[ -f "$DIAGNOSTIC_SOURCE" ] || usage_error "no existe el diagnostico de identidad"
[ -f "$PLUGIN_JSON" ] || usage_error "no existe .claude-plugin/plugin.json"
command -v jq >/dev/null 2>&1 || usage_error "jq no esta instalado (MEF-ADR-0049: bash + jq)"
command -v tar >/dev/null 2>&1 || usage_error "tar no esta instalado"
command -v gzip >/dev/null 2>&1 || usage_error "gzip no esta instalado"
command -v shasum >/dev/null 2>&1 || usage_error "shasum no esta instalado"

# Esta comprobacion ocurre antes de crear staging u outputs: el paquete nunca
# puede ocultar una distribucion generada desactualizada.
"$GENERATOR" --check || usage_error "la distribucion publicada no esta al dia"

[ -d "$DIST_ROOT" ] && [ ! -L "$DIST_ROOT" ] || usage_error "dist/opencode no existe o es un enlace simbolico"
[ -z "$(find "$DIST_ROOT" -mindepth 1 -print -quit)" ] && usage_error "dist/opencode esta vacio"

invalid_entry="$(find "$DIST_ROOT" -mindepth 1 \( -type l -o ! \( -type f -o -type d \) \) -print -quit)"
[ -z "$invalid_entry" ] || usage_error "dist/opencode contiene una entrada no regular: ${invalid_entry#"$DIST_ROOT"/}"
[ ! -e "$DIST_ROOT/mefisto-manifest.json" ] && [ ! -L "$DIST_ROOT/mefisto-manifest.json" ] || usage_error "dist/opencode no puede contener mefisto-manifest.json"
[ ! -e "$DIST_ROOT/install.sh" ] && [ ! -L "$DIST_ROOT/install.sh" ] || usage_error "dist/opencode no puede contener install.sh"
[ ! -e "$DIST_ROOT/bin/mefisto-opencode" ] && [ ! -L "$DIST_ROOT/bin/mefisto-opencode" ] || usage_error "dist/opencode no puede contener bin/mefisto-opencode"
[ ! -e "$DIST_ROOT/diagnose-installation-identity.sh" ] && [ ! -L "$DIST_ROOT/diagnose-installation-identity.sh" ] || usage_error "dist/opencode no puede contener el diagnostico de identidad"

VERSION="$(jq -er '.version | strings | select(test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$"))' "$PLUGIN_JSON" 2>/dev/null)" || usage_error "plugin.json no contiene una version SemVer valida"
COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)" || usage_error "no se pudo resolver git rev-parse HEAD"
case "$COMMIT" in *[!0123456789abcdef]*|'') usage_error "git rev-parse HEAD devolvio un commit invalido" ;; esac

WORK="$(mktemp -d)" || usage_error "no se pudo crear el staging temporal"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT HUP INT TERM
STAGE="$WORK/stage"
TARBALL_NAME="mefisto-opencode-v$VERSION.tar.gz"
CHECKSUM_NAME="$TARBALL_NAME.sha256"
TARBALL="$WORK/$TARBALL_NAME"
CHECKSUM="$WORK/$CHECKSUM_NAME"

mkdir -p "$STAGE" || usage_error "no se pudo preparar el staging"
cp -pR "$DIST_ROOT/." "$STAGE/" || usage_error "no se pudo copiar dist/opencode al staging"
cp -p "$INSTALLER_SOURCE" "$STAGE/install.sh" || usage_error "no se pudo incorporar el instalador"
mkdir -p "$STAGE/bin" || usage_error "no se pudo preparar bin"
chmod 0755 "$STAGE/bin" || usage_error "no se pudo normalizar bin"
cp -p "$LAUNCHER_SOURCE" "$STAGE/bin/mefisto-opencode" || usage_error "no se pudo incorporar el launcher"
cp -p "$PROJECTOR_SOURCE" "$STAGE/project-opencode-release.sh" || usage_error "no se pudo incorporar el proyector"
cp -p "$DIAGNOSTIC_SOURCE" "$STAGE/diagnose-installation-identity.sh" || usage_error "no se pudo incorporar el diagnostico de identidad"
chmod 0755 "$STAGE/install.sh" "$STAGE/bin/mefisto-opencode" "$STAGE/project-opencode-release.sh" "$STAGE/diagnose-installation-identity.sh" || usage_error "no se pudieron normalizar los ejecutables"
jq -n --arg version "$VERSION" --arg commit "$COMMIT" --arg minimumRuntimeVersion "$MINIMUM_RUNTIME_VERSION" \
    '{schemaVersion: 1, runtime: "opencode", version: $version, commit: $commit, minimumRuntimeVersion: $minimumRuntimeVersion}' \
    > "$STAGE/mefisto-manifest.json" || usage_error "no se pudo crear el manifiesto"
chmod 0755 "$STAGE" || usage_error "no se pudo normalizar el directorio raiz"
chmod 0644 "$STAGE/mefisto-manifest.json" || usage_error "no se pudo normalizar el manifiesto"

# El timestamp fijo, el orden C y gzip -n eliminan datos de maquina y de reloj.
find "$STAGE" -exec touch -t 198001010000 {} + || usage_error "no se pudo normalizar timestamps"
(
    cd "$STAGE" || exit 1
    find . -print | sort | tar --no-recursion --format ustar --uid 0 --gid 0 --uname root --gname root -cf - -T - 2>/dev/null | gzip -n > "$TARBALL"
) || usage_error "no se pudo crear el tarball"
[ -s "$TARBALL" ] || usage_error "el tarball quedo vacio"
(cd "$WORK" && shasum -a 256 "$TARBALL_NAME" > "$CHECKSUM") || usage_error "no se pudo calcular SHA-256"

# Ambos candidatos existen y estan completos antes de tocar el directorio pedido.
mkdir -p "$OUTPUT_DIR" || usage_error "no se pudo crear el directorio de salida"
PUBLISH_DIR="$(mktemp -d "$OUTPUT_DIR/.opencode-package.XXXXXX")" || usage_error "no se pudo preparar la publicacion"
if ! cp "$TARBALL" "$CHECKSUM" "$PUBLISH_DIR/"; then
    rm -rf "$PUBLISH_DIR"
    usage_error "no se pudieron preparar los assets de salida"
fi
# `mv origen destino` anida el origen si el destino ya es un directorio. Se
# validan ambos destinos antes del primer reemplazo para no publicar una pareja
# incompleta ni aceptar enlaces como destinos de assets.
for destination in "$OUTPUT_DIR/$TARBALL_NAME" "$OUTPUT_DIR/$CHECKSUM_NAME"; do
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        if [ ! -f "$destination" ] || [ -L "$destination" ]; then
            rm -rf "$PUBLISH_DIR"
            usage_error "el destino de un asset existe y no es un archivo regular: $(basename "$destination")"
        fi
    fi
done
if ! mv "$PUBLISH_DIR/$TARBALL_NAME" "$OUTPUT_DIR/$TARBALL_NAME" || ! mv "$PUBLISH_DIR/$CHECKSUM_NAME" "$OUTPUT_DIR/$CHECKSUM_NAME"; then
    rm -f "$OUTPUT_DIR/$TARBALL_NAME" "$OUTPUT_DIR/$CHECKSUM_NAME"
    rm -rf "$PUBLISH_DIR"
    usage_error "no se pudieron publicar los assets"
fi
rm -rf "$PUBLISH_DIR"
printf '%s\n%s\n' "$OUTPUT_DIR/$TARBALL_NAME" "$OUTPUT_DIR/$CHECKSUM_NAME"
