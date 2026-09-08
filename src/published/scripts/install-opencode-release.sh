#!/usr/bin/env bash
# Instala releases OpenCode verificadas bajo la raiz de datos del usuario.
# Uso: install.sh install <semver> | install.sh activate <semver> | install.sh project | install.sh deactivate | install.sh status
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY="${MEFISTO_OPENCODE_REPOSITORY:-augusto-romero-arango/eda-evsourcing-azure-harness}"

error() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
usage() { error 'uso: mefisto-opencode install <semver> | activate <semver> | project | deactivate | status'; }
valid_version() {
    printf '%s\n' "$1" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
}

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
    trap 'if [ -n "${WORK:-}" ] && [ -e "$WORK" ]; then chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"; fi; rm -rf "${LOCK:-}"' EXIT
    trap 'exit 1' HUP INT TERM
}

manifest_valid() {
    local release="$1" version="$2" manifest
    manifest="$release/mefisto-manifest.json"
    [ -d "$release" ] && [ ! -L "$release" ] || return 1
    [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
    [ -f "$release/install.sh" ] && [ ! -L "$release/install.sh" ] && [ -x "$release/install.sh" ] || return 1
    [ -f "$release/project-opencode-release.sh" ] && [ ! -L "$release/project-opencode-release.sh" ] && [ -x "$release/project-opencode-release.sh" ] || return 1
    [ -f "$release/bin/mefisto-opencode" ] && [ ! -L "$release/bin/mefisto-opencode" ] && [ -x "$release/bin/mefisto-opencode" ] || return 1
    [ -z "$(find "$release" -type l -print -quit)" ] || return 1
    [ -z "$(find "$release" ! -type f ! -type d -print -quit)" ] || return 1
    jq -e --arg version "$version" '
      .schemaVersion == 1 and .runtime == "opencode" and .version == $version and
      (.commit | type == "string" and test("^[0-9a-f]{40}$")) and
      (.minimumRuntimeVersion | type == "string") and (keys | length == 5)
    ' "$manifest" >/dev/null 2>&1
}

release_immutable() {
    local release="$1"
    [ -z "$(find "$release" -type f -links +1 -print -quit)" ] || return 1
    [ -z "$(find "$release" \( -perm -0200 -o -perm -0020 -o -perm -0002 \) -print -quit)" ]
}

prepare_release() {
    local release="$1"
    chmod -R a-w "$release" || error 'no se pudo hacer inmutable la release preparada'
    chmod u+w "$release" || error 'no se pudo preparar la publicacion atomica de la release'
    [ -z "$(find "$release" -mindepth 1 \( -perm -0200 -o -perm -0020 -o -perm -0002 \) -print -quit)" ] \
        || error 'la release preparada conserva entradas mutables'
    [ -z "$(find "$release" -type f -links +1 -print -quit)" ] \
        || error 'la release preparada contiene hard links'
}

publish_release() {
    local staging="$1" destination="$2"
    prepare_release "$staging"
    mv "$staging" "$destination" || error 'no se pudo publicar la release preparada'
    chmod a-w "$destination" || error 'no se pudo sellar la release publicada'
    release_immutable "$destination" || error 'la release publicada no quedo inmutable'
}

activate() {
    local version="$1" release temp_link
    valid_version "$version" || error "version SemVer invalida: $version"
    release="$RELEASES/$version"
    manifest_valid "$release" "$version" && release_immutable "$release" \
        || error "la release instalada $version no es valida, inmutable o completa"
    temp_link="$ROOT/.active.$$.new"
    rm -f "$temp_link" || error 'no se pudo limpiar el nombre temporal del puntero activo'
    if [ -e "$ACTIVE" ] && [ ! -L "$ACTIVE" ]; then
        error 'active existe y no es un enlace simbolico; no se reemplazara'
    fi
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
    publish_release "$staging" "$RELEASES/$version"
}

download_release() {
    local version="$1" asset checksum_url tarball checksum staging entries verbose_entries checksum_line digest filename actual
    asset="mefisto-opencode-v$version.tar.gz"
    checksum_url="${MEFISTO_OPENCODE_RELEASE_BASE_URL:-https://github.com/$REPOSITORY/releases/download}/v$version"
    tarball="$WORK/$asset"; checksum="$WORK/$asset.sha256"; staging="$WORK/release"
    command -v curl >/dev/null 2>&1 || error 'curl es requerido para descargar una release'
    command -v tar >/dev/null 2>&1 || error 'tar es requerido para extraer una release'
    command -v shasum >/dev/null 2>&1 || error 'shasum es requerido para validar SHA-256'
    curl --disable --fail --location --silent --show-error "$checksum_url/$asset" -o "$tarball" || error "no se pudo descargar $asset"
    curl --disable --fail --location --silent --show-error "$checksum_url/$asset.sha256" -o "$checksum" || error "no se pudo descargar el checksum de $asset"
    checksum_line="$(command cat "$checksum")" || error 'no se pudo leer el checksum del release'
    digest="${checksum_line%%  *}"; filename="${checksum_line#*  }"
    [ "${#digest}" -eq 64 ] && [ -z "${digest//[0123456789abcdef]/}" ] && [ "$filename" = "$asset" ] \
        || error 'el archivo de checksum no tiene el formato canonico esperado'
    actual="$(shasum -a 256 "$tarball")" || error 'no se pudo calcular el checksum del release'
    actual="${actual%% *}"
    [ "$actual" = "$digest" ] || error 'el checksum del release no coincide'
    entries="$(tar -tzf "$tarball")" || error 'el tarball verificado no se puede listar'
    printf '%s\n' "$entries" | grep -Eq '(^/|(^|/)\.\.(/|$))' && error 'el tarball contiene rutas inseguras'
    verbose_entries="$(tar -tvzf "$tarball")" || error 'el tarball verificado no se puede inspeccionar'
    printf '%s\n' "$verbose_entries" | grep -Eq '^[^-d]' && error 'el tarball contiene enlaces o entradas no regulares'
    mkdir "$staging" || error 'no se pudo preparar la extraccion temporal'
    tar -xzf "$tarball" -C "$staging" || error 'no se pudo extraer el tarball verificado'
    manifest_valid "$staging" "$version" || error 'el release descargado no tiene la estructura o manifiesto esperados'
    publish_release "$staging" "$RELEASES/$version"
}

install() {
    local version="$1" destination
    valid_version "$version" || error "version SemVer invalida: $version"
    mkdir -p "$RELEASES" || error 'no se pudo crear el almacen de releases'
    destination="$RELEASES/$version"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        manifest_valid "$destination" "$version" && release_immutable "$destination" \
            || error "la ruta de release existente $version no es valida o inmutable"
    else
        WORK="$(mktemp -d "$ROOT/.install.XXXXXX")" || error 'no se pudo crear el staging de instalacion'
        if [ -z "${MEFISTO_OPENCODE_INSTALLED:-}" ]; then copy_local_release "$version" "$SCRIPT_DIR"; else download_release "$version"; fi
    fi
    activate "$version"
}

status() {
    local target manifest version tag commit
    printf 'Raiz de datos: %s\n' "$ROOT"
    if [ ! -L "$ACTIVE" ]; then
        printf 'Estado: sin release activa\n'
        printf 'Diagnostico: ejecute install <semver> desde un release verificado.\n'
        return 0
    fi
    target="$(readlink "$ACTIVE")" || target=''
    version="${target#releases/}"
    manifest="$RELEASES/$version/mefisto-manifest.json"
    if [ "$target" != "releases/$version" ] || ! valid_version "$version" \
        || ! manifest_valid "$RELEASES/$version" "$version" || ! release_immutable "$RELEASES/$version"; then
        printf 'Estado: puntero active invalido\nDiagnostico: active debe apuntar a una release valida bajo %s/releases.\n' "$ROOT"
        return 1
    fi
    tag="v$version"; commit="$(jq -r '.commit' "$manifest")"
    printf 'Runtime: opencode\nVersion: %s\nTag: %s\nCommit: %s\n' "$version" "$tag" "$commit"
    printf 'Diagnostico: use activate <semver> para rollback; las releases quedan en %s/releases.\n' "$ROOT"
}

command -v jq >/dev/null 2>&1 || error 'jq es requerido para validar el manifiesto'
case "${1:-}" in
    install) [ "$#" -eq 2 ] || usage; acquire_lock; install "$2" ;;
    activate) [ "$#" -eq 2 ] || usage; acquire_lock; activate "$2" ;;
    project) [ "$#" -eq 1 ] || usage; exec "$SCRIPT_DIR/project-opencode-release.sh" project ;;
    deactivate) [ "$#" -eq 1 ] || usage; exec "$SCRIPT_DIR/project-opencode-release.sh" deactivate ;;
    status) [ "$#" -eq 1 ] || usage; status ;;
    *) usage ;;
esac
