#!/usr/bin/env bash
# Instala releases OpenCode verificadas bajo la raiz de datos del usuario.
# Uso: install.sh bootstrap <semver> | install.sh install <semver> | install.sh activate <semver> | install.sh prune [--keep <n>] [--yes] | install.sh project | install.sh deactivate | install.sh status | install.sh projection-status | install.sh diagnose | install.sh package-root
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY="${MEFISTO_OPENCODE_REPOSITORY:-augusto-romero-arango/eda-evsourcing-azure-harness}"

error() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
usage() { error 'uso: mefisto-opencode bootstrap <semver> | install <semver> | activate <semver> | prune [--keep <n>] [--yes] | project | deactivate | status | projection-status | diagnose | package-root'; }
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

lock_owner_description() {
    local operation pid
    operation="$(command cat "$LOCK/operation" 2>/dev/null || true)"
    pid="$(command cat "$LOCK/pid" 2>/dev/null || true)"
    [ -n "$operation" ] || operation='operacion desconocida'
    [ -n "$pid" ] || pid='PID desconocido'
    printf '%s (PID %s)' "$operation" "$pid"
}

release_lock() {
    if [ -n "${WORK:-}" ] && [ -e "$WORK" ]; then
        chmod -R u+w "$WORK" 2>/dev/null || true
        rm -rf "$WORK"
    fi
    if [ -n "${LOCK:-}" ] && [ -n "${LOCK_TOKEN:-}" ] && [ -f "$LOCK/owner" ] \
        && [ "$(command cat "$LOCK/owner" 2>/dev/null || true)" = "$LOCK_TOKEN" ]; then
        rm -rf "$LOCK"
    fi
}

acquire_lock() {
    local operation="$1" owner
    mkdir -p "$RELEASES" || error 'no se pudo crear el almacen de releases'
    LOCK="$RELEASES/.operation.lock"
    if ! mkdir "$LOCK" 2>/dev/null; then
        owner="$(lock_owner_description)"
        error "hay una operacion OpenCode en curso: $owner ($LOCK); reintente cuando termine. Si quedo abandonado, revise su PID y retire el lock manualmente"
    fi
    LOCK_TOKEN="$$-${RANDOM}-${RANDOM}"
    if ! printf '%s\n' "$LOCK_TOKEN" > "$LOCK/owner" || ! printf '%s\n' "$operation" > "$LOCK/operation" || ! printf '%s\n' "$$" > "$LOCK/pid"; then
        rm -f "$LOCK/owner" "$LOCK/operation" "$LOCK/pid" 2>/dev/null || true
        rmdir "$LOCK" 2>/dev/null || true
        error 'no se pudo registrar la operacion que adquirio el lock'
    fi
    trap release_lock EXIT
    trap 'exit 1' HUP INT TERM
    if [ -n "${MEFISTO_OPENCODE_TEST_HOLD_LOCK_SECONDS:-}" ]; then
        sleep "$MEFISTO_OPENCODE_TEST_HOLD_LOCK_SECONDS"
    fi
}

manifest_valid() {
    local release="$1" version="$2" manifest
    manifest="$release/mefisto-manifest.json"
    [ -d "$release" ] && [ ! -L "$release" ] || return 1
    [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
    [ -f "$release/install.sh" ] && [ ! -L "$release/install.sh" ] && [ -x "$release/install.sh" ] || return 1
    [ -f "$release/project-opencode-release.sh" ] && [ ! -L "$release/project-opencode-release.sh" ] && [ -x "$release/project-opencode-release.sh" ] || return 1
    [ -f "$release/diagnose-installation-identity.sh" ] && [ ! -L "$release/diagnose-installation-identity.sh" ] && [ -x "$release/diagnose-installation-identity.sh" ] || return 1
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
    local version="$1" asset checksum_url tarball checksum staging entries verbose_entries checksum_line checksum_lines digest filename actual
    asset="mefisto-opencode-v$version.tar.gz"
    checksum_url="${MEFISTO_OPENCODE_RELEASE_BASE_URL:-https://github.com/$REPOSITORY/releases/download}/v$version"
    tarball="$WORK/$asset"; checksum="$WORK/$asset.sha256"; staging="$WORK/release"
    command -v curl >/dev/null 2>&1 || error 'curl es requerido para descargar una release'
    command -v tar >/dev/null 2>&1 || error 'tar es requerido para extraer una release'
    command -v shasum >/dev/null 2>&1 || error 'shasum es requerido para validar SHA-256'
    curl --disable --fail --location --silent --show-error "$checksum_url/$asset" -o "$tarball" || error "no se pudo descargar $asset"
    curl --disable --fail --location --silent --show-error "$checksum_url/$asset.sha256" -o "$checksum" || error "no se pudo descargar el checksum de $asset"
    checksum_lines="$(wc -l < "$checksum")" || error 'no se pudo inspeccionar el checksum del release'
    checksum_lines="${checksum_lines//[[:space:]]/}"
    [ "$checksum_lines" = 1 ] || error 'el archivo de checksum no tiene el formato canonico esperado'
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

install_release() {
    local version="$1" source="$2" destination
    valid_version "$version" || error "version SemVer invalida: $version"
    mkdir -p "$RELEASES" || error 'no se pudo crear el almacen de releases'
    destination="$RELEASES/$version"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        manifest_valid "$destination" "$version" && release_immutable "$destination" \
            || error "la ruta de release existente $version no es valida o inmutable"
    else
        WORK="$(mktemp -d "$ROOT/.install.XXXXXX")" || error 'no se pudo crear el staging de instalacion'
        if [ "$source" = remote ]; then download_release "$version"; else copy_local_release "$version" "$SCRIPT_DIR"; fi
    fi
    activate "$version"
}

install() {
    local source=local
    [ -z "${MEFISTO_OPENCODE_INSTALLED:-}" ] || source=remote
    install_release "$1" "$source"
}

bootstrap_remote() {
    # Entry point publico para una copia confiable del instalador: no depende del
    # detalle interno que el launcher exporta al actualizar una release activa.
    install_release "$1" remote
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

# Orden SemVer sin depender de sort -V, ausente en el sort BSD de macOS.
version_less_than() {
    local left="$1" right="$2" left_core right_core left_pre right_pre
    local left_major left_minor left_patch right_major right_minor right_patch
    local -a left_parts right_parts
    left_core="${left%%[-+]*}"; right_core="${right%%[-+]*}"
    left_pre="${left#"$left_core"}"; right_pre="${right#"$right_core"}"
    left_pre="${left_pre%%+*}"; right_pre="${right_pre%%+*}"
    IFS=. read -r left_major left_minor left_patch <<EOF
$left_core
EOF
    IFS=. read -r right_major right_minor right_patch <<EOF
$right_core
EOF
    if [ "${#left_major}" -ne "${#right_major}" ]; then [ "${#left_major}" -lt "${#right_major}" ]; return; fi
    if [ "$left_major" != "$right_major" ]; then [[ "$left_major" < "$right_major" ]]; return; fi
    if [ "${#left_minor}" -ne "${#right_minor}" ]; then [ "${#left_minor}" -lt "${#right_minor}" ]; return; fi
    if [ "$left_minor" != "$right_minor" ]; then [[ "$left_minor" < "$right_minor" ]]; return; fi
    if [ "${#left_patch}" -ne "${#right_patch}" ]; then [ "${#left_patch}" -lt "${#right_patch}" ]; return; fi
    if [ "$left_patch" != "$right_patch" ]; then [[ "$left_patch" < "$right_patch" ]]; return; fi
    [ -z "$left_pre" ] && return 1
    [ -z "$right_pre" ] && return 0
    left_pre="${left_pre#-}"; right_pre="${right_pre#-}"
    IFS=. read -r -a left_parts <<< "$left_pre"; IFS=. read -r -a right_parts <<< "$right_pre"
    local i=0 left_part right_part
    while [ "$i" -lt "${#left_parts[@]}" ] && [ "$i" -lt "${#right_parts[@]}" ]; do
        left_part="${left_parts[$i]}"; right_part="${right_parts[$i]}"
        if [ "$left_part" != "$right_part" ]; then
            case "$left_part" in *[!0-9]*) left_numeric=false ;; *) left_numeric=true ;; esac
            case "$right_part" in *[!0-9]*) right_numeric=false ;; *) right_numeric=true ;; esac
            if [ "$left_numeric" = true ] && [ "$right_numeric" = false ]; then return 0; fi
            if [ "$left_numeric" = false ] && [ "$right_numeric" = true ]; then return 1; fi
            if [ "$left_numeric" = true ]; then
                if [ "${#left_part}" -ne "${#right_part}" ]; then [ "${#left_part}" -lt "${#right_part}" ]; return; fi
            fi
            [[ "$left_part" < "$right_part" ]]
            return
        fi
        i=$((i + 1))
    done
    [ "${#left_parts[@]}" -lt "${#right_parts[@]}" ]
}

sorted_insert_version() {
    local version="$1" i=0
    if [ "${VALID_RELEASES_INITIALIZED:-false}" = false ]; then
        VALID_RELEASES=( "$version" ); VALID_RELEASES_INITIALIZED=true
        return
    fi
    while [ "$i" -lt "${#VALID_RELEASES[@]}" ]; do
        if version_less_than "$version" "${VALID_RELEASES[$i]}"; then
            VALID_RELEASES=( "${VALID_RELEASES[@]:0:$i}" "$version" "${VALID_RELEASES[@]:$i}" )
            return
        fi
        i=$((i + 1))
    done
    VALID_RELEASES=( "${VALID_RELEASES[@]}" "$version" )
}

active_version() {
    local target version
    [ -L "$ACTIVE" ] || error 'no hay una release activa; instale o active una release OpenCode'
    target="$(readlink "$ACTIVE")" || error 'no se pudo leer active; reinstale o active la release OpenCode'
    version="${target#releases/}"
    [ "$target" = "releases/$version" ] && valid_version "$version" \
        && manifest_valid "$RELEASES/$version" "$version" && release_immutable "$RELEASES/$version" \
        || error 'active no apunta a una release valida, completa e inmutable; reinstale o active la release OpenCode'
    printf '%s\n' "$version"
}

package_root() {
    local version release
    version="$(active_version)"
    release="$RELEASES/$version"
    cd "$release" 2>/dev/null || error 'la release activa no se puede normalizar; reinstale o active la release OpenCode'
    pwd -P
}

prune() {
    local keep="$1" assume_yes="$2" active previous entry version i retained_count=0
    local kb=0 entry_kb marker confirmation candidate_count=0
    local -a protected candidates
    [ -d "$RELEASES" ] && [ ! -L "$RELEASES" ] || { printf 'No hay releases instaladas para podar.\n'; return 0; }
    acquire_lock prune
    active="$(active_version)"
    VALID_RELEASES_INITIALIZED=false
    for entry in "$RELEASES"/.[!.]* "$RELEASES"/..?* "$RELEASES"/*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        [ "$entry" = "$LOCK" ] && continue
        version="${entry##*/}"
        if valid_version "$version" && manifest_valid "$entry" "$version" && release_immutable "$entry"; then
            sorted_insert_version "$version"
        else
            printf 'ADVERTENCIA: se conserva entrada ajena o invalida: %s\n' "$entry" >&2
        fi
    done
    for i in "${!VALID_RELEASES[@]}"; do
        [ "${VALID_RELEASES[$i]}" = "$active" ] && break
    done
    [ "${VALID_RELEASES[$i]:-}" = "$active" ] || error 'la release activa no aparece como release valida'
    previous=''
    [ "$i" -gt 0 ] && previous="${VALID_RELEASES[$((i - 1))]}"
    protected=( "$active" )
    [ -n "$previous" ] && protected=( "${protected[@]}" "$previous" )
    retained_count="${#protected[@]}"
    for ((i=${#VALID_RELEASES[@]} - 1; i >= 0 && retained_count < keep; i--)); do
        version="${VALID_RELEASES[$i]}"
        case " ${protected[*]} " in
            *" $version "*) ;;
            *) protected=( "${protected[@]}" "$version" ); retained_count=$((retained_count + 1)) ;;
        esac
    done
    candidates=()
    for version in "${VALID_RELEASES[@]}"; do
        case " ${protected[*]} " in *" $version "*) continue ;; esac
        if [ "$candidate_count" -eq 0 ]; then candidates=( "$version" ); else candidates=( "${candidates[@]}" "$version" ); fi
        candidate_count=$((candidate_count + 1))
        entry_kb="$(du -sk "$RELEASES/$version" | awk '{print $1}')"; kb=$((kb + entry_kb))
    done
    printf 'Releases conservadas: %s\n' "${protected[*]}"
    if [ "$candidate_count" -eq 0 ]; then printf 'No hay releases podables.\n'; return 0; fi
    printf 'Releases que se eliminaran (%s KiB recuperables):\n' "$kb"
    for version in "${candidates[@]}"; do printf '  - %s\n' "$version"; done
    if [ "$assume_yes" != true ]; then
        [ -t 0 ] || error 'la poda no interactiva requiere el flag explicito --yes'
        printf 'Confirma borrar estas releases? [si/NO] '
        IFS= read -r confirmation || confirmation=''
        [ "$confirmation" = si ] || { printf 'Poda cancelada; no se borro ninguna release.\n'; return 0; }
    fi
    for version in "${candidates[@]}"; do
        marker="$RELEASES/.pruning-$version-$$"
        mv "$RELEASES/$version" "$marker" || error "no se pudo invalidar la release $version"
        [ -z "${MEFISTO_OPENCODE_TEST_ABORT_AFTER_INVALIDATE:-}" ] || error 'interrupcion solicitada tras invalidar una release'
        chmod -R u+w "$marker" || error "no se pudo preparar la eliminacion de $version"
        rm -rf "$marker" || error "no se pudo eliminar la release invalidada $version"
        printf 'Eliminada: %s\n' "$version"
    done
}

parse_prune() {
    local keep=2 assume_yes=false
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --keep) [ "$#" -ge 2 ] && printf '%s\n' "$2" | grep -Eq '^[0-9]+$' || usage; keep="$2"; shift 2 ;;
            --yes) assume_yes=true; shift ;;
            *) usage ;;
        esac
    done
    prune "$keep" "$assume_yes"
}

command -v jq >/dev/null 2>&1 || error 'jq es requerido para validar el manifiesto'
case "${1:-}" in
    bootstrap) [ "$#" -eq 2 ] || usage; acquire_lock bootstrap; bootstrap_remote "$2" ;;
    install) [ "$#" -eq 2 ] || usage; acquire_lock install; install "$2" ;;
    activate) [ "$#" -eq 2 ] || usage; acquire_lock activate; activate "$2" ;;
    prune) shift; parse_prune "$@" ;;
    project) [ "$#" -eq 1 ] || usage; exec "$SCRIPT_DIR/project-opencode-release.sh" project ;;
    deactivate) [ "$#" -eq 1 ] || usage; exec "$SCRIPT_DIR/project-opencode-release.sh" deactivate ;;
    status) [ "$#" -eq 1 ] || usage; status ;;
    projection-status) [ "$#" -eq 1 ] || usage; exec "$SCRIPT_DIR/project-opencode-release.sh" projection-status ;;
    diagnose) [ "$#" -eq 1 ] || usage; exec "$SCRIPT_DIR/diagnose-installation-identity.sh" --opencode-root "$ROOT/active" ;;
    package-root) [ "$#" -eq 1 ] || usage; package_root ;;
    *) usage ;;
esac
