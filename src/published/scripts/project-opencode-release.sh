#!/usr/bin/env bash
# Proyecta la release OpenCode activa a la superficie global documentada.
# Uso: project-opencode-release.sh project | deactivate | status
set -euo pipefail
export LC_ALL=C

error() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
data_root() {
    if [ -n "${XDG_DATA_HOME:-}" ]; then printf '%s/mefisto\n' "$XDG_DATA_HOME"
    elif [ "$(uname -s)" = Darwin ]; then printf '%s/Library/Application Support/mefisto\n' "$HOME"
    else printf '%s/.local/share/mefisto\n' "$HOME"; fi
}
config_root() {
    if [ -n "${OPENCODE_CONFIG_DIR:-}" ]; then printf '%s\n' "$OPENCODE_CONFIG_DIR"
    else printf '%s/opencode\n' "${XDG_CONFIG_HOME:-$HOME/.config}"; fi
}

ROOT="$(data_root)"; ACTIVE="$ROOT/active"; CONFIG="$(config_root)"; STATE="$CONFIG/.mefisto-projection.json"
active_release() {
    local target version release
    [ -L "$ACTIVE" ] || error 'no hay release activa; ejecute install <semver> primero'
    target="$(readlink "$ACTIVE")" || error 'no se pudo leer active'
    version="${target#releases/}"
    [ "$target" = "releases/$version" ] && printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.[0-9]+\.[0-9]+' \
        || error 'active no apunta a una release valida'
    release="$ROOT/releases/$version"
    [ -d "$release" ] && [ -f "$release/mefisto-manifest.json" ] || error 'la release activa no esta completa'
    printf '%s\n' "$release"
}
list_sources() {
    local release="$1" kind base
    for kind in commands agents skills plugins; do
        base="$release/$kind"
        [ -d "$base" ] || continue
        find "$base" -type f ! -type l | LC_ALL=C sort | while IFS= read -r file; do
            printf '%s\n' "${file#"$release/"}"
        done
    done
}
owns() { [ -f "$STATE" ] && jq -e --arg path "$1" '.paths | index($path) != null' "$STATE" >/dev/null 2>&1; }
remove_owned() {
    local rel target
    [ -f "$STATE" ] || return 0
    while IFS= read -r rel; do
        target="$CONFIG/$rel"
        [ ! -L "$target" ] || rm -f "$target" || error "no se pudo retirar $target"
    done < <(jq -r '.paths[]?' "$STATE")
    rm -f "$STATE"
    for rel in commands agents skills plugins; do rmdir "$CONFIG/$rel" 2>/dev/null || true; done
}
report_capabilities() {
    local release="$1" kind label
    for kind in commands agents skills plugins; do
        case "$kind" in commands) label='comandos';; agents) label='agentes';; skills) label='Skills';; plugins) label='plugins/hooks';; esac
        if [ -d "$release/$kind" ] && [ -n "$(find "$release/$kind" -type f -print -quit)" ]; then
            printf 'Proyectado: %s.\n' "$label"
        else
            printf 'DEGRADACION VISIBLE: la release activa no contiene %s; no se simulan.\n' "$label"
        fi
    done
    printf 'DEGRADACION VISIBLE: MCP solo se proyecta cuando la release contenga una configuracion declarable; no se modifica opencode.json del usuario.\n'
}
project() {
    local release rel target source paths tmp
    command -v jq >/dev/null 2>&1 || error 'jq es requerido para proyectar la configuracion'
    release="$(active_release)"
    paths="$(list_sources "$release")"
    # Se valida todo antes de tocar la configuracion del usuario.
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        target="$CONFIG/$rel"
        if [ -e "$target" ] || [ -L "$target" ]; then
            owns "$rel" || error "conflicto: $target ya existe; renombrelo o ejecute deactivate antes de proyectar"
        fi
    done <<< "$paths"
    remove_owned
    mkdir -p "$CONFIG" || error 'no se pudo crear la raiz de configuracion'
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        source="$ACTIVE/$rel"; target="$CONFIG/$rel"
        mkdir -p "$(dirname "$target")" || error "no se pudo preparar $(dirname "$target")"
        ln -s "$source" "$target" || error "no se pudo proyectar $target"
    done <<< "$paths"
    tmp="$STATE.$$.new"
    jq -n --arg release "$(jq -r .version "$release/mefisto-manifest.json")" --argjson paths "$(printf '%s\n' "$paths" | jq -R . | jq -s .)" \
        '{schemaVersion: 1, release: $release, paths: $paths}' > "$tmp" || error 'no se pudo registrar la proyeccion'
    mv -f "$tmp" "$STATE" || error 'no se pudo publicar el estado de proyeccion'
    printf 'Proyeccion OpenCode activa en %s (release %s).\n' "$CONFIG" "$(jq -r .release "$STATE")"
    report_capabilities "$release"
}
deactivate() {
    command -v jq >/dev/null 2>&1 || error 'jq es requerido para retirar la proyeccion'
    [ -f "$STATE" ] || { printf 'No hay proyeccion Mefisto que retirar en %s.\n' "$CONFIG"; return 0; }
    remove_owned
    rmdir "$CONFIG" 2>/dev/null || true
    printf 'Proyeccion Mefisto retirada; la configuracion ajena permanece intacta.\n'
}
status() {
    if [ -f "$STATE" ]; then printf 'Configuracion OpenCode: %s\nRelease proyectada: %s\n' "$CONFIG" "$(jq -r .release "$STATE")"; else printf 'Configuracion OpenCode: %s\nEstado: sin proyeccion Mefisto\n' "$CONFIG"; fi
}
case "${1:-}" in project) [ "$#" -eq 1 ] || error 'uso: mefisto-opencode project | deactivate | status'; project;; deactivate) [ "$#" -eq 1 ] || error 'uso: mefisto-opencode project | deactivate | status'; deactivate;; status) [ "$#" -eq 1 ] || error 'uso: mefisto-opencode project | deactivate | status'; status;; *) error 'uso: mefisto-opencode project | deactivate | status';; esac
