#!/usr/bin/env bash
# Instala releases OpenCode verificadas bajo la raiz de datos del usuario.
# Uso: install.sh install <semver> | install.sh activate <semver> | install.sh status
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY="${MEFISTO_OPENCODE_REPOSITORY:-augusto-romero-arango/eda-evsourcing-azure-harness}"

error() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
usage() { error 'uso: mefisto-opencode install <semver> | activate <semver> | status'; }
valid_version() { printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$'; }

data_root() {
    if [ -n "${XDG_DATA_HOME:-}" ]; then printf '%s/mefisto\n' "$XDG_DATA_HOME"
    elif [ "$(uname -s)" = Darwin ]; then printf '%s/Library/Application Support/mefisto\n' "$HOME"
    else printf '%s/.local/share/mefisto\n' "$HOME"; fi
}

ROOT="$(data_root)"
RELEASES="$ROOT/releases"
ACTIVE="$ROOT/active"

acquire_lock() {
    mkdir -p "$ROOT" || error 'no se pudo crear la raiz de datos'
    LOCK="$ROOT/.activation.lock"
    if ! mkdir "$LOCK" 2>/dev/null; then
        error "hay otra instalacion o activacion en curso ($LOCK); espere y reintente"
    fi
    trap 'rm -rf "${WORK:-}" "${LOCK:-}"' EXIT HUP INT TERM
}

manifest_valid() {
    local release="$1" version="$2" manifest
    manifest="$release/mefisto-manifest.json"
    [ -d "$release" ] && [ ! -L "$release" ] || return 1
    [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
    [ -f "$release/install.sh" ] && [ ! -L "$release/install.sh" ] && [ -x "$release/install.sh" ] || return 1
    [ -f "$release/bin/mefisto-opencode" ] && [ ! -L "$release/bin/mefisto-opencode" ] && [ -x "$release/bin/mefisto-opencode" ] || return 1
    [ -z "$(find "$release" -type l -print -quit)" ] || return 1
    [ -z "$(find "$release" ! -type f ! -type d -print -quit)" ] || return 1
    jq -e --arg version "$version" '
      .schemaVersion == 1 and .runtime == "opencode" and .version == $version and
      (.commit | type == "string" and test("^[0-9a-f]{40}$")) and
      (.minimumRuntimeVersion | type == "string") and (keys | length == 5)
    ' "$manifest" >/dev/null 2>&1
}

activate() {
    local version="$1" release temp_link
    valid_version "$version" || error "version SemVer invalida: $version"
    release="$RELEASES/$version"
    manifest_valid "$release" "$version" || error "la release instalada $version no es valida o esta incompleta"
    temp_link="$ROOT/.active.$$.new"
    rm -f "$temp_link"
    ln -s "releases/$version" "$temp_link" || error 'no se pudo preparar el puntero activo'
    [ -z "${MEFISTO_OPENCODE_TEST_ABORT_BEFORE_SWAP:-}" ] || error 'interrupcion solicitada antes del swap activo'
    # BSD mv sigue el enlace destino que nombra un directorio; -h lo reemplaza.
    # GNU mv usa -T para la misma semantica sin seguirlo.
    if [ "$(uname -s)" = Darwin ]; then mv -f -h "$temp_link" "$ACTIVE"; else mv -fT "$temp_link" "$ACTIVE"; fi \
        || error 'no se pudo reemplazar atomicamente el puntero activo'
    printf 'Activa OpenCode Mefisto v%s.\n' "$version"
}

copy_local_release() {
    local version="$1" source="$2" staging
    manifest_valid "$source" "$version" || error 'el release bootstrap no tiene la estructura o manifiesto esperados'
    staging="$WORK/release"
    cp -pR "$source/." "$staging" || error 'no se pudo preparar el release bootstrap'
    manifest_valid "$staging" "$version" || error 'el release bootstrap copiado no es valido'
    mv "$staging" "$RELEASES/$version" || error 'no se pudo publicar el release bootstrap'
}

download_release() {
    local version="$1" asset checksum_url tarball checksum staging entries
    asset="mefisto-opencode-v$version.tar.gz"
    checksum_url="${MEFISTO_OPENCODE_RELEASE_BASE_URL:-https://github.com/$REPOSITORY/releases/download}/v$version"
    tarball="$WORK/$asset"; checksum="$WORK/$asset.sha256"; staging="$WORK/release"
    curl --fail --location --silent --show-error "$checksum_url/$asset" -o "$tarball" || error "no se pudo descargar $asset"
    curl --fail --location --silent --show-error "$checksum_url/$asset.sha256" -o "$checksum" || error "no se pudo descargar el checksum de $asset"
    (cd "$WORK" && shasum -a 256 -c "$(basename "$checksum")") >/dev/null 2>&1 || error 'el checksum del release no coincide'
    entries="$(tar -tzf "$tarball")" || error 'el tarball verificado no se puede listar'
    printf '%s\n' "$entries" | grep -Eq '(^/|(^|/)\.\.(/|$))' && error 'el tarball contiene rutas inseguras'
    mkdir "$staging" || error 'no se pudo preparar la extraccion temporal'
    tar -xzf "$tarball" -C "$staging" || error 'no se pudo extraer el tarball verificado'
    manifest_valid "$staging" "$version" || error 'el release descargado no tiene la estructura o manifiesto esperados'
    mv "$staging" "$RELEASES/$version" || error 'no se pudo publicar el release descargado'
}

install() {
    local version="$1" destination
    valid_version "$version" || error "version SemVer invalida: $version"
    mkdir -p "$RELEASES" || error 'no se pudo crear el almacen de releases'
    destination="$RELEASES/$version"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        manifest_valid "$destination" "$version" || error "la ruta de release existente $version no es valida"
    else
        WORK="$(mktemp -d "$ROOT/.install.XXXXXX")" || error 'no se pudo crear el staging de instalacion'
        if [ -z "${MEFISTO_OPENCODE_INSTALLED:-}" ]; then copy_local_release "$version" "$SCRIPT_DIR"; else download_release "$version"; fi
    fi
    activate "$version"
}

status() {
    local manifest version tag commit
    printf 'Raiz de datos: %s\n' "$ROOT"
    if [ ! -L "$ACTIVE" ]; then
        printf 'Estado: sin release activa\n'
        printf 'Diagnostico: ejecute install <semver> desde un release verificado.\n'
        return 0
    fi
    manifest="$ACTIVE/mefisto-manifest.json"
    if [ ! -f "$manifest" ] || ! jq -e '.runtime == "opencode"' "$manifest" >/dev/null 2>&1; then
        printf 'Estado: puntero active invalido\nDiagnostico: active debe apuntar a una release valida bajo %s/releases.\n' "$ROOT"
        return 1
    fi
    version="$(jq -r '.version' "$manifest")"; tag="v$version"; commit="$(jq -r '.commit' "$manifest")"
    printf 'Runtime: opencode\nVersion: %s\nTag: %s\nCommit: %s\n' "$version" "$tag" "$commit"
    printf 'Diagnostico: use activate <semver> para rollback; las releases quedan en %s/releases.\n' "$ROOT"
}

command -v jq >/dev/null 2>&1 || error 'jq es requerido para validar el manifiesto'
command -v shasum >/dev/null 2>&1 || error 'shasum es requerido para validar SHA-256'
case "${1:-}" in
    install) [ "$#" -eq 2 ] || usage; acquire_lock; install "$2" ;;
    activate) [ "$#" -eq 2 ] || usage; acquire_lock; activate "$2" ;;
    status) [ "$#" -eq 1 ] || usage; status ;;
    *) usage ;;
esac
