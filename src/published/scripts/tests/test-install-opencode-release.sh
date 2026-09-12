#!/usr/bin/env bash
# Pruebas del almacen OpenCode: Bash 3.2, fixtures locales y ninguna red real.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
INSTALLER="$REPO_ROOT/src/published/scripts/install-opencode-release.sh"
LAUNCHER="$REPO_ROOT/src/published/scripts/mefisto-opencode"
PROJECTOR="$REPO_ROOT/src/published/scripts/project-opencode-release.sh"
DIAGNOSTIC="$REPO_ROOT/src/published/scripts/diagnose-installation-identity.sh"
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
    cp "$INSTALLER" "$root/install.sh"; cp "$LAUNCHER" "$root/bin/mefisto-opencode"; cp "$PROJECTOR" "$root/project-opencode-release.sh"; cp "$DIAGNOSTIC" "$root/diagnose-installation-identity.sh"
    chmod +x "$root/install.sh" "$root/bin/mefisto-opencode" "$root/project-opencode-release.sh" "$root/diagnose-installation-identity.sh"
    printf 'fixture %s\n' "$version" > "$root/contenido con espacios.txt"
    jq -n --arg version "$version" --arg commit "$commit" '{schemaVersion: 1, runtime: "opencode", version: $version, commit: $commit, minimumRuntimeVersion: "1.18.29"}' > "$root/mefisto-manifest.json"
    (cd "$root" && tar -czf "$WORK/assets/v$version/$asset" .) || exit 1
    (cd "$WORK/assets/v$version" && shasum -a 256 "$asset" > "$asset.sha256") || exit 1
}

make_link_release() {
    local version="$1" root asset
    root="$WORK/release-$version"; asset="mefisto-opencode-v$version.tar.gz"
    mkdir -p "$root/bin" "$WORK/assets/v$version"
    cp "$INSTALLER" "$root/install.sh"; cp "$LAUNCHER" "$root/bin/mefisto-opencode"; cp "$PROJECTOR" "$root/project-opencode-release.sh"; cp "$DIAGNOSTIC" "$root/diagnose-installation-identity.sh"
    chmod +x "$root/install.sh" "$root/bin/mefisto-opencode" "$root/project-opencode-release.sh" "$root/diagnose-installation-identity.sh"
    ln -s /tmp "$root/enlace"
    jq -n --arg version "$version" '{schemaVersion: 1, runtime: "opencode", version: $version, commit: "3333333333333333333333333333333333333333", minimumRuntimeVersion: "1.18.29"}' > "$root/mefisto-manifest.json"
    (cd "$root" && tar -czf "$WORK/assets/v$version/$asset" .) || exit 1
    (cd "$WORK/assets/v$version" && shasum -a 256 "$asset" > "$asset.sha256") || exit 1
}

make_divergent_manifest_release() {
    local version="$1" root asset
    make_release "$version" 4444444444444444444444444444444444444444
    root="$WORK/release-$version"; asset="mefisto-opencode-v$version.tar.gz"
    jq '.version = "6.0.1"' "$root/mefisto-manifest.json" > "$WORK/manifest-divergente.json" || exit 1
    command cp "$WORK/manifest-divergente.json" "$root/mefisto-manifest.json" || exit 1
    (cd "$root" && tar -czf "$WORK/assets/v$version/$asset" .) || exit 1
    (cd "$WORK/assets/v$version" && shasum -a 256 "$asset" > "$asset.sha256") || exit 1
}

printf '[pre] sintaxis y ejecutables\n'
bash -n "$INSTALLER" && bash -n "$LAUNCHER" && bash -n "$PROJECTOR" && bash -n "$DIAGNOSTIC" && pass 'instalador, proyector, diagnostico y launcher Bash validos' || fail 'instalador, proyector, diagnostico o launcher invalido'

make_release 1.2.3 0123456789abcdef0123456789abcdef01234567
make_release 2.0.0 abcdef0123456789abcdef0123456789abcdef01
make_release 3.0.0 1111111111111111111111111111111111111111
make_release 4.0.0 2222222222222222222222222222222222222222
make_link_release 5.0.0
make_divergent_manifest_release 6.0.0
HOME="$WORK/home con espacios"; XDG_DATA_HOME="$HOME/datos con espacios"; export HOME XDG_DATA_HOME
mkdir -p "$HOME"
EXTRACT="$WORK/extract inicial"; mkdir "$EXTRACT"; tar -xzf "$WORK/assets/v1.2.3/mefisto-opencode-v1.2.3.tar.gz" -C "$EXTRACT"
"$EXTRACT/install.sh" install 1.2.3 >/dev/null; assert_rc "$?" 0 'primera instalacion desde bootstrap local verificado'
assert_active 1.2.3 'primera instalacion activa la version inicial'
[ -f "$XDG_DATA_HOME/mefisto/releases/1.2.3/contenido con espacios.txt" ] && pass 'release inmutable conserva paths con espacios' || fail 'release no conserva paths con espacios'
[ -z "$(find "$XDG_DATA_HOME/mefisto/releases/1.2.3" \( -perm -0200 -o -perm -0020 -o -perm -0002 \) -print -quit)" ] && pass 'release instalada queda sin permisos de escritura' || fail 'release instalada conserva permisos de escritura'
assert_only_data_root 'bootstrap solo escribe bajo la raiz de datos'

ACTIVE="$XDG_DATA_HOME/mefisto/active/bin/mefisto-opencode"
PACKAGE_ROOT="$("$ACTIVE" package-root)"; rc=$?
EXPECTED_PACKAGE_ROOT="$(cd "$XDG_DATA_HOME/mefisto/releases/1.2.3" && pwd -P)"
[ "$rc" -eq 0 ] && [ "$PACKAGE_ROOT" = "$EXPECTED_PACKAGE_ROOT" ] && pass 'package-root imprime solo la ruta fisica de la release activa' || fail "package-root no resolvio la release activa: '$PACKAGE_ROOT'"
MEFISTO_OPENCODE_RELEASE_BASE_URL="file://$WORK/assets" "$EXTRACT/install.sh" bootstrap 2.0.0 >/dev/null; assert_rc "$?" 0 'bootstrap remoto descarga fixture local y valida checksum'
assert_active 2.0.0 'bootstrap remoto activa la version descargada'
[ -d "$XDG_DATA_HOME/mefisto/releases/1.2.3" ] && [ -d "$XDG_DATA_HOME/mefisto/releases/2.0.0" ] && pass 'bootstrap remoto conserva release anterior'
assert_only_data_root 'bootstrap remoto solo escribe bajo la raiz de datos'

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
MEFISTO_OPENCODE_RELEASE_BASE_URL="file://$WORK/assets" "$EXTRACT/install.sh" bootstrap 4.0.0 >/dev/null 2>&1; assert_rc "$?" 1 'bootstrap remoto rechaza checksum corrupto'
assert_active 1.2.3 'checksum fallido conserva active aunque el destino falle'
[ ! -e "$XDG_DATA_HOME/mefisto/releases/4.0.0" ] && pass 'checksum fallido no publica una release parcial' || fail 'checksum fallido publico un destino instalable'

printf '%064d  ../fuera\n' 0 > "$WORK/assets/v4.0.0/mefisto-opencode-v4.0.0.tar.gz.sha256"
MEFISTO_OPENCODE_RELEASE_BASE_URL="file://$WORK/assets" "$EXTRACT/install.sh" bootstrap 4.0.0 >/dev/null 2>&1; assert_rc "$?" 1 'bootstrap remoto rechaza checksum malformado sin leer esa ruta'
assert_active 1.2.3 'checksum no canonico conserva active'
MEFISTO_OPENCODE_RELEASE_BASE_URL="file://$WORK/assets" "$EXTRACT/install.sh" bootstrap 5.0.0 >/dev/null 2>&1; assert_rc "$?" 1 'bootstrap remoto rechaza tarball con enlace antes de extraer'
[ ! -e "$XDG_DATA_HOME/mefisto/releases/5.0.0" ] && pass 'tarball inseguro no publica una release' || fail 'tarball inseguro publico un destino'
MEFISTO_OPENCODE_RELEASE_BASE_URL="file://$WORK/assets" "$EXTRACT/install.sh" bootstrap 6.0.0 >/dev/null 2>&1; assert_rc "$?" 1 'bootstrap remoto rechaza manifiesto divergente'
assert_active 1.2.3 'manifiesto divergente conserva active'
[ ! -e "$XDG_DATA_HOME/mefisto/releases/6.0.0" ] && pass 'manifiesto divergente no publica una release' || fail 'manifiesto divergente publico un destino'
MEFISTO_OPENCODE_RELEASE_BASE_URL="file://$WORK/assets" "$EXTRACT/install.sh" bootstrap latest >/dev/null 2>&1; assert_rc "$?" 1 'bootstrap remoto rechaza latest y exige SemVer exacto'
mkdir "$XDG_DATA_HOME/mefisto/releases/7.0.0"
MEFISTO_OPENCODE_RELEASE_BASE_URL="file://$WORK/assets" "$EXTRACT/install.sh" bootstrap 7.0.0 >/dev/null 2>&1; assert_rc "$?" 1 'bootstrap remoto falla cerrado ante una ruta existente invalida'
[ -L "$XDG_DATA_HOME/mefisto/active" ] && [ "$(readlink "$XDG_DATA_HOME/mefisto/active")" = releases/1.2.3 ] && pass 'ruta existente invalida no altera active' || fail 'ruta existente invalida altero active'

OPENCODE_CONFIG_DIR="$XDG_DATA_HOME/opencode config" "$ACTIVE" project >/dev/null; assert_rc "$?" 0 'project conserva el contrato mediante el launcher instalado'
[ -f "$XDG_DATA_HOME/opencode config/.mefisto-projection.json" ] && pass 'project publica su ledger sin tocar configuracion ajena' || fail 'project no publico su ledger'

STATUS="$("$ACTIVE" status)"; case "$STATUS" in *'Runtime: opencode'*'Version: 1.2.3'*'Tag: v1.2.3'*'Commit: 0123456789abcdef0123456789abcdef01234567'*"$XDG_DATA_HOME/mefisto"*) pass 'status informa identidad y raiz sin secretos' ;; *) fail 'status no informa identidad esperada' ;; esac
DIAGNOSIS="$("$ACTIVE" diagnose)"; printf '%s' "$DIAGNOSIS" | jq -e '.status == "opencode_only" and .opencode.version == "1.2.3"' >/dev/null && pass 'diagnose expone el diagnostico parseable de la release activa' || fail 'diagnose no expone la identidad activa'
rm "$XDG_DATA_HOME/mefisto/active"; ln -s "$HOME" "$XDG_DATA_HOME/mefisto/active"
"$XDG_DATA_HOME/mefisto/releases/1.2.3/bin/mefisto-opencode" status >/dev/null 2>&1; assert_rc "$?" 1 'status rechaza active fuera del almacen sin inspeccionarlo'

printf '\n[package-root] fail-closed sobre el almacen activo\n'
INSTALLED_LAUNCHER="$XDG_DATA_HOME/mefisto/releases/1.2.3/bin/mefisto-opencode"
assert_package_root_fails() {
    local label="$1" output rc
    output="$("$INSTALLED_LAUNCHER" package-root 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        case "$output" in *'instale o active'*|*'reinstale o active'*) pass "$label" ;; *) fail "$label: diagnostico sin accion concreta: $output" ;; esac
    else
        fail "$label"
    fi
}
assert_package_root_fails 'package-root rechaza target externo'
rm "$XDG_DATA_HOME/mefisto/active"; ln -s 'releases/9.9.9' "$XDG_DATA_HOME/mefisto/active"
assert_package_root_fails 'package-root rechaza symlink roto'
rm "$XDG_DATA_HOME/mefisto/active"
assert_package_root_fails 'package-root rechaza active ausente'
ln -s 'releases/1.2.3' "$XDG_DATA_HOME/mefisto/active"
chmod u+w "$XDG_DATA_HOME/mefisto/releases/1.2.3/mefisto-manifest.json"
jq '.runtime = "claude"' "$XDG_DATA_HOME/mefisto/releases/1.2.3/mefisto-manifest.json" > "$WORK/manifest.tmp" && command cp "$WORK/manifest.tmp" "$XDG_DATA_HOME/mefisto/releases/1.2.3/mefisto-manifest.json"
chmod a-w "$XDG_DATA_HOME/mefisto/releases/1.2.3/mefisto-manifest.json"
assert_package_root_fails 'package-root rechaza runtime inesperado'
chmod u+w "$XDG_DATA_HOME/mefisto/releases/1.2.3/mefisto-manifest.json"
jq '.runtime = "opencode" | .version = "2.0.0"' "$XDG_DATA_HOME/mefisto/releases/1.2.3/mefisto-manifest.json" > "$WORK/manifest.tmp" && command cp "$WORK/manifest.tmp" "$XDG_DATA_HOME/mefisto/releases/1.2.3/mefisto-manifest.json"
chmod a-w "$XDG_DATA_HOME/mefisto/releases/1.2.3/mefisto-manifest.json"
assert_package_root_fails 'package-root rechaza version divergente'
chmod u+w "$XDG_DATA_HOME/mefisto/releases/1.2.3/mefisto-manifest.json"
jq '.version = "1.2.3"' "$XDG_DATA_HOME/mefisto/releases/1.2.3/mefisto-manifest.json" > "$WORK/manifest.tmp" && command cp "$WORK/manifest.tmp" "$XDG_DATA_HOME/mefisto/releases/1.2.3/mefisto-manifest.json"
chmod a-w "$XDG_DATA_HOME/mefisto/releases/1.2.3/mefisto-manifest.json"
chmod u+w "$XDG_DATA_HOME/mefisto/releases/1.2.3/mefisto-manifest.json"
printf '%s\n' '{' > "$XDG_DATA_HOME/mefisto/releases/1.2.3/mefisto-manifest.json"
chmod a-w "$XDG_DATA_HOME/mefisto/releases/1.2.3/mefisto-manifest.json"
assert_package_root_fails 'package-root rechaza metadata ilegible'
chmod u+w "$XDG_DATA_HOME/mefisto/releases/1.2.3/mefisto-manifest.json"
jq -n '{schemaVersion: 1, runtime: "opencode", version: "1.2.3", commit: "0123456789abcdef0123456789abcdef01234567", minimumRuntimeVersion: "1.18.29"}' > "$XDG_DATA_HOME/mefisto/releases/1.2.3/mefisto-manifest.json"
chmod a-w "$XDG_DATA_HOME/mefisto/releases/1.2.3/mefisto-manifest.json"
chmod u+w "$XDG_DATA_HOME/mefisto/releases/1.2.3/contenido con espacios.txt"
assert_package_root_fails 'package-root rechaza release mutable'
chmod a-w "$XDG_DATA_HOME/mefisto/releases/1.2.3/contenido con espacios.txt"
chmod u+w "$XDG_DATA_HOME/mefisto/releases/1.2.3" "$XDG_DATA_HOME/mefisto/releases/1.2.3/diagnose-installation-identity.sh"
rm "$XDG_DATA_HOME/mefisto/releases/1.2.3/diagnose-installation-identity.sh"
assert_package_root_fails 'package-root rechaza paquete incompleto'

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
