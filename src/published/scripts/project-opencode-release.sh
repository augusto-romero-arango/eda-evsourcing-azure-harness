#!/usr/bin/env bash
# Proyecta la release OpenCode activa a la superficie global documentada.
# Uso: project-opencode-release.sh project | deactivate | status | projection-status
set -euo pipefail
export LC_ALL=C

error() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
data_root() {
    if [ -n "${XDG_DATA_HOME:-}" ]; then printf '%s/mefisto\n' "$XDG_DATA_HOME"
    elif [ "$(uname -s)" = Darwin ]; then printf '%s/Library/Application Support/mefisto\n' "$HOME"
    else printf '%s/.local/share/mefisto\n' "$HOME"; fi
}
config_root() {
    if [ "${OPENCODE_CONFIG_DIR+x}" = x ]; then
        [ -n "$OPENCODE_CONFIG_DIR" ] || error 'OPENCODE_CONFIG_DIR esta definido pero vacio'
        printf '%s\n' "$OPENCODE_CONFIG_DIR"
    else
        printf '%s/opencode\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
    fi
}

ROOT="$(data_root)"; RELEASES="$ROOT/releases"; ACTIVE="$ROOT/active"; CONFIG="$(config_root)"; STATE="$CONFIG/.mefisto-projection.json"
lock_owner_description() {
    local operation pid
    operation="$(command cat "$LOCK/operation" 2>/dev/null || true)"
    pid="$(command cat "$LOCK/pid" 2>/dev/null || true)"
    [ -n "$operation" ] || operation='operacion desconocida'
    [ -n "$pid" ] || pid='PID desconocido'
    printf '%s (PID %s)' "$operation" "$pid"
}
release_lock() {
    if [ -n "${LOCK:-}" ] && [ -n "${LOCK_TOKEN:-}" ] && [ -f "$LOCK/owner" ] \
        && [ "$(command cat "$LOCK/owner" 2>/dev/null || true)" = "$LOCK_TOKEN" ]; then
        rm -rf "$LOCK"
    fi
}
try_acquire_lock() {
    local operation="$1"
    mkdir -p "$RELEASES" || error 'no se pudo crear el almacen de releases'
    LOCK="$RELEASES/.operation.lock"
    if ! mkdir "$LOCK" 2>/dev/null; then
        return 1
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

acquire_lock() {
    local operation="$1" owner
    if ! try_acquire_lock "$operation"; then
        owner="$(lock_owner_description)"
        error "hay una operacion OpenCode en curso: $owner ($LOCK); reintente cuando termine. Si quedo abandonado, revise su PID y retire el lock manualmente"
    fi
}
safe_relative_path() {
    local value="$1" rest part
    case "$value" in ''|/*|*/|*//*|*$'\n'*|*$'\r'*) return 1 ;; esac
    rest="$value"
    while :; do
        case "$rest" in */*) part="${rest%%/*}"; rest="${rest#*/}" ;; *) part="$rest"; rest='' ;; esac
        case "$part" in ''|.|..) return 1 ;; esac
        [ -n "$rest" ] || break
    done
    case "$value" in commands/*|agents/*|skills/*|plugins/*) return 0 ;; *) return 1 ;; esac
}
active_release() {
    local target version release manifest_version
    [ -L "$ACTIVE" ] || error 'no hay release activa; ejecute install <semver> primero'
    target="$(readlink "$ACTIVE")" || error 'no se pudo leer active'
    version="${target#releases/}"
    [ "$target" = "releases/$version" ] && printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$' \
        || error 'active no apunta a una release valida'
    release="$ROOT/releases/$version"
    [ -d "$release" ] && [ ! -L "$release" ] && [ -f "$release/mefisto-manifest.json" ] && [ ! -L "$release/mefisto-manifest.json" ] \
        || error 'la release activa no esta completa'
    manifest_version="$(jq -er '.version | strings' "$release/mefisto-manifest.json" 2>/dev/null)" \
        || error 'el manifiesto de la release activa es invalido'
    [ "$manifest_version" = "$version" ] || error 'active y el manifiesto declaran versiones distintas'
    printf '%s\n' "$release"
}
active_version_if_available() {
    local target version release manifest_version
    [ -L "$ACTIVE" ] || return 1
    target="$(readlink "$ACTIVE")" || return 1
    version="${target#releases/}"
    [ "$target" = "releases/$version" ] && printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$' || return 1
    release="$ROOT/releases/$version"
    [ -d "$release" ] && [ ! -L "$release" ] && [ -f "$release/mefisto-manifest.json" ] && [ ! -L "$release/mefisto-manifest.json" ] || return 1
    manifest_version="$(jq -er '.version | strings' "$release/mefisto-manifest.json" 2>/dev/null)" || return 1
    [ "$manifest_version" = "$version" ] || return 1
    printf '%s\n' "$version"
}
list_sources() {
    local release="$1" kind base file rel
    for kind in commands agents skills plugins; do
        base="$release/$kind"
        [ -d "$base" ] && [ ! -L "$base" ] || continue
        find "$base" -type f | LC_ALL=C sort | while IFS= read -r file; do
            rel="${file#"$release/"}"
            safe_relative_path "$rel" || error "la release contiene una ruta no proyectable: $rel"
            printf '%s\n' "$rel"
        done
    done
}
state_valid() {
    local rel
    [ -f "$STATE" ] && [ ! -L "$STATE" ] || return 1
    jq -e 'keys == ["directories", "paths", "release", "schemaVersion"] and .schemaVersion == 1 and (.release | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$")) and (.paths | type == "array" and all(.[]; type == "string") and length == (unique | length)) and (.directories | type == "array" and all(.[]; type == "string") and length == (unique | length))' "$STATE" >/dev/null 2>&1 || return 1
    while IFS= read -r rel; do safe_relative_path "$rel" || return 1; done < <(jq -r '.paths[]' "$STATE")
    while IFS= read -r rel; do [ "$rel" = . ] || safe_relative_path "$rel/x" || return 1; done < <(jq -r '.directories[]' "$STATE")
}
owns() { jq -e --arg path "$1" '.paths | index($path) != null' "$STATE" >/dev/null 2>&1; }
owned_links_valid() {
    local rel target
    while IFS= read -r rel; do
        target="$CONFIG/$rel"
        [ -L "$target" ] && [ "$(readlink "$target")" = "$ACTIVE/$rel" ] || return 1
    done < <(jq -r '.paths[]' "$STATE")
}
validate_owned() {
    [ -e "$STATE" ] || [ -L "$STATE" ] || return 0
    state_valid || error "conflicto: $STATE no es un ledger Mefisto valido; no se modificara"
    owned_links_valid || error 'conflicto: al menos un enlace administrado fue modificado fuera de Mefisto; no se modificara'
}
remove_links() {
    local rel
    [ -f "$STATE" ] || return 0
    while IFS= read -r rel; do rm -f "$CONFIG/$rel" || error "no se pudo retirar $CONFIG/$rel"; done < <(jq -r '.paths[]' "$STATE")
}
remove_directories() {
    local rel
    [ -f "$STATE" ] || return 0
    jq -r '.directories[]' "$STATE" | LC_ALL=C sort -r | while IFS= read -r rel; do
        if [ "$rel" = . ]; then rmdir "$CONFIG" 2>/dev/null || true
        else rmdir "$CONFIG/$rel" 2>/dev/null || true; fi
    done
}
ensure_directory() {
    local relative="$1" current="$CONFIG" prefix='' rest part
    if [ ! -d "$CONFIG" ]; then
        mkdir -p "$CONFIG" || error 'no se pudo crear la raiz de configuracion'
        printf '.\n' >> "$DIRS_FILE"
    fi
    [ "$relative" = . ] && return 0
    rest="$relative"
    while [ -n "$rest" ]; do
        case "$rest" in */*) part="${rest%%/*}"; rest="${rest#*/}" ;; *) part="$rest"; rest='' ;; esac
        prefix="${prefix:+$prefix/}$part"; current="$CONFIG/$prefix"
        if [ ! -d "$current" ]; then mkdir "$current" || error "no se pudo crear $current"; printf '%s\n' "$prefix" >> "$DIRS_FILE"; fi
    done
}
report_capabilities() {
    local release="$1" kind label
    for kind in commands agents skills plugins; do
        case "$kind" in commands) label='comandos';; agents) label='agentes y sus permisos';; skills) label='Skills';; plugins) label='plugins/hooks';; esac
        if [ -d "$release/$kind" ] && [ -n "$(find "$release/$kind" -type f -print -quit)" ]; then printf 'Proyectado: %s.\n' "$label"
        else printf 'DEGRADACION VISIBLE: la release activa no contiene %s; no se simulan.\n' "$label"; fi
    done
    if [ -f "$release/plugins/mefisto-mcp.js" ]; then
        printf 'Proyectado: MCP bundleado mediante plugin local; opencode.json del usuario no se modifica.\n'
    else
        printf 'DEGRADACION VISIBLE: la release activa no contiene el plugin MCP bundleado; no se modifica opencode.json del usuario.\n'
    fi
}
project() {
    local release paths rel target parent tmp previous_dirs='[]'
    command -v jq >/dev/null 2>&1 || error 'jq es requerido para proyectar la configuracion'
    acquire_lock project
    release="$(active_release)"; paths="$(list_sources "$release")"
    validate_owned
    [ ! -f "$STATE" ] || previous_dirs="$(jq -c '.directories' "$STATE")"
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue; target="$CONFIG/$rel"
        if [ -e "$target" ] || [ -L "$target" ]; then
            [ -f "$STATE" ] && owns "$rel" || error "conflicto: $target ya existe; renombrelo o ejecute deactivate antes de proyectar"
        fi
    done <<< "$paths"
    DIRS_FILE="${TMPDIR:-/tmp}/mefisto-projection-dirs.$$"; : > "$DIRS_FILE"
    jq -r '.[]' <<< "$previous_dirs" >> "$DIRS_FILE"
    ensure_directory .
    while IFS= read -r rel; do [ -n "$rel" ] || continue; parent="${rel%/*}"; ensure_directory "$parent"; done <<< "$paths"
    tmp="$STATE.$$.new"
    jq -n --arg release "$(jq -r .version "$release/mefisto-manifest.json")" \
        --argjson paths "$(printf '%s\n' "$paths" | jq -R 'select(length > 0)' | jq -s .)" \
        --argjson directories "$(LC_ALL=C sort -u "$DIRS_FILE" | jq -R . | jq -s .)" \
        '{schemaVersion: 1, release: $release, paths: $paths, directories: $directories}' > "$tmp" || error 'no se pudo preparar el estado de proyeccion'
    remove_links
    while IFS= read -r rel; do [ -n "$rel" ] || continue; ln -s "$ACTIVE/$rel" "$CONFIG/$rel" || error "no se pudo proyectar $CONFIG/$rel"; done <<< "$paths"
    mv -f "$tmp" "$STATE" || error 'no se pudo publicar el estado de proyeccion'
    rm -f "$DIRS_FILE"
    printf 'Proyeccion OpenCode activa en %s (release %s).\n' "$CONFIG" "$(jq -r .release "$STATE")"
    report_capabilities "$release"
}
deactivate() {
    command -v jq >/dev/null 2>&1 || error 'jq es requerido para retirar la proyeccion'
    acquire_lock deactivate
    { [ -e "$STATE" ] || [ -L "$STATE" ]; } || { printf 'No hay proyeccion Mefisto que retirar en %s.\n' "$CONFIG"; return 0; }
    validate_owned; remove_links; remove_directories; rm -f "$STATE"; rmdir "$CONFIG" 2>/dev/null || true
    printf 'Proyeccion Mefisto retirada; la configuracion ajena permanece intacta.\n'
}
status() {
    if [ -e "$STATE" ] || [ -L "$STATE" ]; then state_valid || error "conflicto: $STATE no es un ledger Mefisto valido"; printf 'Configuracion OpenCode: %s\nRelease proyectada: %s\n' "$CONFIG" "$(jq -r .release "$STATE")"
    else printf 'Configuracion OpenCode: %s\nEstado: sin proyeccion Mefisto\n' "$CONFIG"; fi
}
projection_status_json() {
    local projection_state="$1" active_version="$2" ledger_version="$3"
    jq -n --arg status "$projection_state" --arg config_root "$CONFIG" --argjson active_version "$active_version" --argjson ledger_version "$ledger_version" \
        '{schemaVersion: 1, status: $status, configRoot: $config_root, activeVersion: $active_version, ledgerRelease: $ledger_version}'
}
projection_status() {
    local active='' ledger='' active_json='null' ledger_json='null'
    command -v jq >/dev/null 2>&1 || error 'jq es requerido para consultar el estado de proyeccion'
    if ! try_acquire_lock projection-status; then
        projection_status_json operation-in-progress null null
        return 1
    fi
    active="$(active_version_if_available 2>/dev/null || true)"
    [ -z "$active" ] || active_json="$(jq -Rn --arg value "$active" '$value')"
    if [ ! -e "$STATE" ] && [ ! -L "$STATE" ]; then
        projection_status_json disabled "$active_json" "$ledger_json"
        return 0
    fi
    if ! state_valid; then
        projection_status_json conflict "$active_json" "$ledger_json"
        return 1
    fi
    ledger="$(jq -r '.release' "$STATE")"
    ledger_json="$(jq -Rn --arg value "$ledger" '$value')"
    if [ -z "$active" ]; then
        projection_status_json conflict "$active_json" "$ledger_json"
        return 1
    fi
    if ! owned_links_valid; then
        projection_status_json conflict "$active_json" "$ledger_json"
        return 1
    fi
    if [ "$ledger" = "$active" ]; then projection_status_json enabled "$active_json" "$ledger_json"
    else projection_status_json stale "$active_json" "$ledger_json"; fi
}
case "${1:-}" in project) [ "$#" -eq 1 ] || error 'uso: mefisto-opencode project | deactivate | status | projection-status'; project;; deactivate) [ "$#" -eq 1 ] || error 'uso: mefisto-opencode project | deactivate | status | projection-status'; deactivate;; status) [ "$#" -eq 1 ] || error 'uso: mefisto-opencode project | deactivate | status | projection-status'; status;; projection-status) [ "$#" -eq 1 ] || error 'uso: mefisto-opencode project | deactivate | status | projection-status'; projection_status;; *) error 'uso: mefisto-opencode project | deactivate | status | projection-status';; esac
