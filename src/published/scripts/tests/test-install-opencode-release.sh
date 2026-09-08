#!/usr/bin/env bash
# Pruebas del almacen OpenCode: Bash 3.2, fixtures locales y ninguna red real.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
INSTALLER="$REPO_ROOT/src/published/scripts/install-opencode-release.sh"
LAUNCHER="$REPO_ROOT/src/published/scripts/mefisto-opencode"
WORK="$(mktemp -d)"; trap 'chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_rc() { [ "$1" -eq "$2" ] && pass "$3" || fail "$3 (exit $1)"; }
assert_active() { [ "$(jq -r .version "$XDG_DATA_HOME/mefisto/active/mefisto-manifest.json")" = "$1" ] && pass "$2" || fail "$2"; }
assert_only_data_root() {
    local outside
    outside="$(find "$HOME" -path "$XDG_DATA_HOME" -prune -o -mindepth 1 -print)"
    [ -z "$outside" ] && pass "$1" || fail "$1: escribio fuera de XDG_DATA_HOME"
}

make_release() {
    local version="$1" commit="$2" root asset
    root="$WORK/release-$version"; asset="mefisto-opencode-v$version.tar.gz"
    mkdir -p "$root/bin" "$WORK/assets/v$version"
    cp "$INSTALLER" "$root/install.sh"; cp "$LAUNCHER" "$root/bin/mefisto-opencode"
    chmod +x "$root/install.sh" "$root/bin/mefisto-opencode"
    printf 'fixture %s\n' "$version" > "$root/contenido con espacios.txt"
    jq -n --arg version "$version" --arg commit "$commit" '{schemaVersion: 1, runtime: "opencode", version: $version, commit: $commit, minimumRuntimeVersion: "1.18.29"}' > "$root/mefisto-manifest.json"
    (cd "$root" && tar -czf "$WORK/assets/v$version/$asset" .) || exit 1
    (cd "$WORK/assets/v$version" && shasum -a 256 "$asset" > "$asset.sha256") || exit 1
}

make_link_release() {
    local version="$1" root asset
    root="$WORK/release-$version"; asset="mefisto-opencode-v$version.tar.gz"
    mkdir -p "$root/bin" "$WORK/assets/v$version"
    cp "$INSTALLER" "$root/install.sh"; cp "$LAUNCHER" "$root/bin/mefisto-opencode"
    chmod +x "$root/install.sh" "$root/bin/mefisto-opencode"
    ln -s /tmp "$root/enlace"
    jq -n --arg version "$version" '{schemaVersion: 1, runtime: "opencode", version: $version, commit: "3333333333333333333333333333333333333333", minimumRuntimeVersion: "1.18.29"}' > "$root/mefisto-manifest.json"
    (cd "$root" && tar -czf "$WORK/assets/v$version/$asset" .) || exit 1
    (cd "$WORK/assets/v$version" && shasum -a 256 "$asset" > "$asset.sha256") || exit 1
}

printf '[pre] sintaxis y ejecutables\n'
bash -n "$INSTALLER" && bash -n "$LAUNCHER" && pass 'instalador y launcher Bash validos' || fail 'instalador o launcher invalido'

make_release 1.2.3 0123456789abcdef0123456789abcdef01234567
make_release 2.0.0 abcdef0123456789abcdef0123456789abcdef01
make_release 3.0.0 1111111111111111111111111111111111111111
make_release 4.0.0 2222222222222222222222222222222222222222
make_link_release 5.0.0
HOME="$WORK/home con espacios"; XDG_DATA_HOME="$HOME/datos con espacios"; export HOME XDG_DATA_HOME
mkdir -p "$HOME"
EXTRACT="$WORK/extract inicial"; mkdir "$EXTRACT"; tar -xzf "$WORK/assets/v1.2.3/mefisto-opencode-v1.2.3.tar.gz" -C "$EXTRACT"
"$EXTRACT/install.sh" install 1.2.3 >/dev/null; assert_rc "$?" 0 'primera instalacion desde bootstrap local verificado'
assert_active 1.2.3 'primera instalacion activa la version inicial'
[ -f "$XDG_DATA_HOME/mefisto/releases/1.2.3/contenido con espacios.txt" ] && pass 'release inmutable conserva paths con espacios' || fail 'release no conserva paths con espacios'
[ -z "$(find "$XDG_DATA_HOME/mefisto/releases/1.2.3" \( -perm -0200 -o -perm -0020 -o -perm -0002 \) -print -quit)" ] && pass 'release instalada queda sin permisos de escritura' || fail 'release instalada conserva permisos de escritura'
assert_only_data_root 'bootstrap solo escribe bajo la raiz de datos'

ACTIVE="$XDG_DATA_HOME/mefisto/active/bin/mefisto-opencode"
MEFISTO_OPENCODE_RELEASE_BASE_URL="file://$WORK/assets" "$ACTIVE" install 2.0.0 >/dev/null; assert_rc "$?" 0 'upgrade descarga fixture local y valida checksum'
assert_active 2.0.0 'upgrade activa la version descargada'
[ -d "$XDG_DATA_HOME/mefisto/releases/1.2.3" ] && [ -d "$XDG_DATA_HOME/mefisto/releases/2.0.0" ] && pass 'upgrade conserva release anterior' || fail 'upgrade borro release anterior'
assert_only_data_root 'upgrade solo escribe bajo la raiz de datos'

"$ACTIVE" activate 1.2.3 >/dev/null; assert_rc "$?" 0 'activar version instalada hace rollback sin red'
assert_active 1.2.3 'rollback reemplaza active atomicamente'
assert_only_data_root 'rollback solo escribe bajo la raiz de datos'

MEFISTO_OPENCODE_RELEASE_BASE_URL="file://$WORK/assets" MEFISTO_OPENCODE_TEST_ABORT_BEFORE_SWAP=1 "$ACTIVE" install 3.0.0 >/dev/null 2>&1; assert_rc "$?" 1 'interrupcion antes del swap falla'
assert_active 1.2.3 'interrupcion conserva el puntero activo anterior'
[ -d "$XDG_DATA_HOME/mefisto/releases/3.0.0" ] && pass 'interrupcion solo deja una release completa e inactiva' || fail 'interrupcion dejo release parcial'

MEFISTO_OPENCODE_RELEASE_BASE_URL="file://$WORK/assets" "$ACTIVE" install 2.0.0 >/dev/null 2>&1; assert_rc "$?" 0 'reinstalar una release ya valida es idempotente sin red'
assert_active 2.0.0 'reinstalacion activa la release existente sin leer asset corrupto'
"$ACTIVE" activate 1.2.3 >/dev/null
printf corrupto >> "$WORK/assets/v4.0.0/mefisto-opencode-v4.0.0.tar.gz"
MEFISTO_OPENCODE_RELEASE_BASE_URL="file://$WORK/assets" "$ACTIVE" install 4.0.0 >/dev/null 2>&1; assert_rc "$?" 1 'checksum corrupto rechaza descarga'
assert_active 1.2.3 'checksum fallido conserva active aunque el destino falle'
[ ! -e "$XDG_DATA_HOME/mefisto/releases/4.0.0" ] && pass 'checksum fallido no publica una release parcial' || fail 'checksum fallido publico un destino instalable'

printf '%064d  ../fuera\n' 0 > "$WORK/assets/v4.0.0/mefisto-opencode-v4.0.0.tar.gz.sha256"
MEFISTO_OPENCODE_RELEASE_BASE_URL="file://$WORK/assets" "$ACTIVE" install 4.0.0 >/dev/null 2>&1; assert_rc "$?" 1 'checksum con nombre ajeno se rechaza sin leer esa ruta'
assert_active 1.2.3 'checksum no canonico conserva active'
MEFISTO_OPENCODE_RELEASE_BASE_URL="file://$WORK/assets" "$ACTIVE" install 5.0.0 >/dev/null 2>&1; assert_rc "$?" 1 'tarball con enlace se rechaza antes de extraer'
[ ! -e "$XDG_DATA_HOME/mefisto/releases/5.0.0" ] && pass 'tarball inseguro no publica una release' || fail 'tarball inseguro publico un destino'

STATUS="$("$ACTIVE" status)"; case "$STATUS" in *'Runtime: opencode'*'Version: 1.2.3'*'Tag: v1.2.3'*'Commit: 0123456789abcdef0123456789abcdef01234567'*"$XDG_DATA_HOME/mefisto"*) pass 'status informa identidad y raiz sin secretos' ;; *) fail 'status no informa identidad esperada' ;; esac
rm "$XDG_DATA_HOME/mefisto/active"; ln -s "$HOME" "$XDG_DATA_HOME/mefisto/active"
"$XDG_DATA_HOME/mefisto/releases/1.2.3/bin/mefisto-opencode" status >/dev/null 2>&1; assert_rc "$?" 1 'status rechaza active fuera del almacen sin inspeccionarlo'

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
