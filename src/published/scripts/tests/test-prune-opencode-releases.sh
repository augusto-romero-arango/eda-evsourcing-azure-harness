#!/usr/bin/env bash
# Pruebas hermeticas de poda de releases OpenCode (issue #1093).
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
INSTALLER="$REPO_ROOT/src/published/scripts/install-opencode-release.sh"
WORK="$(mktemp -d)"; trap 'chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_rc() { [ "$1" -eq "$2" ] && pass "$3" || fail "$3 (exit $1)"; }
run_interactive() {
    local answer="$1" keep="$2" command
    if [ "$(uname -s)" = Darwin ]; then
        printf '%s\n' "$answer" | script -q /dev/null env HOME="$HOME" XDG_DATA_HOME="$XDG_DATA_HOME" bash "$INSTALLER" prune --keep "$keep"
    else
        printf -v command '%q ' env "HOME=$HOME" "XDG_DATA_HOME=$XDG_DATA_HOME" bash "$INSTALLER" prune --keep "$keep"
        printf '%s\n' "$answer" | script -q -e -c "$command" /dev/null
    fi
}
release() {
    local version="$1" root
    root="$XDG_DATA_HOME/mefisto/releases/$version"
    mkdir -p "$root/bin"
    cp "$INSTALLER" "$root/install.sh"; cp "$INSTALLER" "$root/project-opencode-release.sh"; cp "$INSTALLER" "$root/diagnose-installation-identity.sh"; cp "$INSTALLER" "$root/bin/mefisto-opencode"
    chmod +x "$root/install.sh" "$root/project-opencode-release.sh" "$root/diagnose-installation-identity.sh" "$root/bin/mefisto-opencode"
    dd if=/dev/zero of="$root/payload" bs=1024 count=2 2>/dev/null
    jq -n --arg version "$version" '{schemaVersion: 1, runtime: "opencode", version: $version, commit: "0123456789abcdef0123456789abcdef01234567", minimumRuntimeVersion: "1.18.29"}' > "$root/mefisto-manifest.json"
    chmod -R a-w "$root"
}
prepare_store() {
    local root="$1"
    HOME="$root/home"; XDG_DATA_HOME="$HOME/data"; export HOME XDG_DATA_HOME
    mkdir -p "$XDG_DATA_HOME/mefisto/releases" "$HOME/config"
    printf 'no tocar\n' > "$HOME/config/sentinel"
    release 1.0.0; release 2.0.0; release 3.0.0; release 4.0.0; release 5.0.0
    ln -s releases/2.0.0 "$XDG_DATA_HOME/mefisto/active"
    mkdir "$XDG_DATA_HOME/mefisto/releases/ajeno"; printf ajeno > "$XDG_DATA_HOME/mefisto/releases/ajeno/no-tocar"
}

printf '[pre] sintaxis\n'
bash -n "$INSTALLER" && pass 'instalador Bash valido' || fail 'instalador Bash invalido'
prepare_store "$WORK/cancel"
OUT="$(run_interactive no 1 2>&1)"; assert_rc "$?" 0 'cancelar confirmacion no falla'
[ -d "$XDG_DATA_HOME/mefisto/releases/3.0.0" ] && [ -d "$XDG_DATA_HOME/mefisto/releases/4.0.0" ] && pass 'cancelacion conserva candidatas' || fail 'cancelacion borro una candidata'
printf '%s' "$OUT" | grep -q 'KiB recuperables' && printf '%s' "$OUT" | grep -q '  - 3.0.0' && pass 'previsualizacion lista candidatas y espacio recuperable' || fail 'previsualizacion incompleta'
[ -f "$XDG_DATA_HOME/mefisto/releases/ajeno/no-tocar" ] && pass 'entrada ajena se conserva al cancelar' || fail 'entrada ajena fue tocada'
OUT="$(printf 'si\n' | bash "$INSTALLER" prune --keep 1 2>&1)"; assert_rc "$?" 1 'stdin no interactivo no sustituye a --yes'
[ -d "$XDG_DATA_HOME/mefisto/releases/3.0.0" ] && pass 'rechazo no interactivo no borra candidatas' || fail 'stdin no interactivo borro una candidata'
OUT="$(bash "$INSTALLER" prune --keep 1 --yes 2>&1)"; assert_rc "$?" 0 'poda no interactiva requiere y acepta --yes'
[ -d "$XDG_DATA_HOME/mefisto/releases/1.0.0" ] && [ -d "$XDG_DATA_HOME/mefisto/releases/2.0.0" ] && pass 'activa y anterior inmediata se preservan' || fail 'poda borro activa o anterior'
[ ! -e "$XDG_DATA_HOME/mefisto/releases/3.0.0" ] && [ ! -e "$XDG_DATA_HOME/mefisto/releases/4.0.0" ] && [ ! -e "$XDG_DATA_HOME/mefisto/releases/5.0.0" ] && pass 'retencion menor que el minimo conserva solo las protegidas' || fail 'retencion minima no poda lo esperado'
[ -f "$XDG_DATA_HOME/mefisto/releases/ajeno/no-tocar" ] && pass 'entrada ajena se reporta y conserva' || fail 'entrada ajena fue borrada'
printf '%s' "$OUT" | grep -q 'ADVERTENCIA: se conserva entrada ajena o invalida:.*ajeno' && pass 'entrada ajena se reporta antes de podar' || fail 'entrada ajena no fue reportada'
[ "$(readlink "$XDG_DATA_HOME/mefisto/active")" = releases/2.0.0 ] && [ -f "$XDG_DATA_HOME/mefisto/active/mefisto-manifest.json" ] && pass 'poda no altera active' || fail 'poda dejo active inconsistente'
[ -f "$HOME/config/sentinel" ] && pass 'poda no escribe ni borra fuera de releases' || fail 'poda altero una ruta fuera de releases'
prepare_store "$WORK/retencion"
bash "$INSTALLER" prune --keep 4 --yes >/dev/null 2>&1; assert_rc "$?" 0 'retencion total configurable se aplica'
[ ! -e "$XDG_DATA_HOME/mefisto/releases/3.0.0" ] && [ -d "$XDG_DATA_HOME/mefisto/releases/4.0.0" ] && [ -d "$XDG_DATA_HOME/mefisto/releases/5.0.0" ] && pass 'retencion cuatro conserva protegidas y las dos mas nuevas' || fail 'retencion cuatro produjo un conjunto incorrecto'
HOME="$WORK/semver/home"; XDG_DATA_HOME="$HOME/data"; export HOME XDG_DATA_HOME
mkdir -p "$XDG_DATA_HOME/mefisto/releases"
release 1.0.0; release 2.0.0-alpha.2; release 2.0.0-alpha.10; release 2.0.0
ln -s releases/2.0.0-alpha.10 "$XDG_DATA_HOME/mefisto/active"
bash "$INSTALLER" prune --keep 0 --yes >/dev/null 2>&1; assert_rc "$?" 0 'poda ordena versiones SemVer sin sort -V'
[ -d "$XDG_DATA_HOME/mefisto/releases/2.0.0-alpha.2" ] && [ -d "$XDG_DATA_HOME/mefisto/releases/2.0.0-alpha.10" ] && [ ! -e "$XDG_DATA_HOME/mefisto/releases/1.0.0" ] && pass 'predecesora SemVer inmediata se preserva' || fail 'orden SemVer no preservo la predecesora correcta'
prepare_store "$WORK/interrupcion"
MEFISTO_OPENCODE_TEST_ABORT_AFTER_INVALIDATE=1 bash "$INSTALLER" prune --keep 1 --yes >/dev/null 2>&1; assert_rc "$?" 1 'interrupcion tras invalidacion falla controladamente'
[ "$(readlink "$XDG_DATA_HOME/mefisto/active")" = releases/2.0.0 ] && [ -f "$XDG_DATA_HOME/mefisto/active/mefisto-manifest.json" ] && pass 'interrupcion conserva active completo' || fail 'interrupcion dano active'
if [ -d "$XDG_DATA_HOME/mefisto/releases/.pruning-3.0.0-$$" ] || [ -n "$(ls -d "$XDG_DATA_HOME/mefisto/releases"/.pruning-3.0.0-* 2>/dev/null)" ]; then
    pass 'interrupcion deja marca no instalable'
else
    fail 'interrupcion no dejo marca de invalidacion'
fi
mkdir "$XDG_DATA_HOME/mefisto/releases/.operation.lock"
bash "$INSTALLER" activate 3.0.0 >/dev/null 2>&1; assert_rc "$?" 1 'activacion no corre concurrentemente con una poda'
[ "$(readlink "$XDG_DATA_HOME/mefisto/active")" = releases/2.0.0 ] && pass 'lock compartido protege active durante la poda' || fail 'operacion concurrente altero active'
printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
