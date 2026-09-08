#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/scripts/package-opencode-release.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_rc() { [ "$1" -eq "$2" ] && pass "$3" || fail "$3 (exit $1)"; }

setup_repo() {
    TEST_REPO="$WORK/repo-$1"
    mkdir -p "$TEST_REPO/src/published/scripts" "$TEST_REPO/dist/opencode/comandos" "$TEST_REPO/.claude-plugin" "$TEST_REPO/bin"
    cp "$SOURCE" "$TEST_REPO/src/published/scripts/package-opencode-release.sh"
    chmod +x "$TEST_REPO/src/published/scripts/package-opencode-release.sh"
    printf '{"version":"1.2.3"}\n' > "$TEST_REPO/.claude-plugin/plugin.json"
    printf '#!/usr/bin/env bash\nexit "${GENERATOR_RC:-0}"\n' > "$TEST_REPO/src/published/scripts/generate-published-adapters.sh"
    chmod +x "$TEST_REPO/src/published/scripts/generate-published-adapters.sh"
    printf '#!/usr/bin/env bash\nif [ "$1" = "-C" ]; then shift 2; fi\n[ "$1" = "rev-parse" ] && printf "0123456789abcdef0123456789abcdef01234567\\n"\n' > "$TEST_REPO/bin/git"
    chmod +x "$TEST_REPO/bin/git"
    printf '#!/usr/bin/env bash\nprintf "ejecutable\\n"\n' > "$TEST_REPO/dist/opencode/comandos/run.sh"
    chmod +x "$TEST_REPO/dist/opencode/comandos/run.sh"
    printf 'contenido\n' > "$TEST_REPO/dist/opencode/archivo con espacios.txt"
}
run_package() { PATH="$TEST_REPO/bin:$PATH" MEFISTO_PACKAGE_REPO_ROOT="$TEST_REPO" "$TEST_REPO/src/published/scripts/package-opencode-release.sh" "$@"; }

echo '[pre] sintaxis y ejecutable'
bash -n "$SOURCE" && [ -x "$SOURCE" ] && pass 'packager Bash valido y ejecutable' || fail 'packager invalido'

setup_repo success; OUT="$WORK/salida con espacios"; run_package --output "$OUT" >/dev/null; rc=$?
assert_rc "$rc" 0 'crea assets en output con espacios'
TAR="$OUT/mefisto-opencode-v1.2.3.tar.gz"; SHA="$TAR.sha256"
[ -f "$TAR" ] && [ -f "$SHA" ] && pass 'nombres canonicos de assets' || fail 'faltan assets canonicos'
(cd "$OUT" && shasum -a 256 -c "$(basename "$SHA")" >/dev/null 2>&1); assert_rc "$?" 0 'checksum externo valido'
(cd "$OUT" && EXPECTED_CHECKSUM="$(shasum -a 256 "$(basename "$TAR")")" && [ "$(< "$(basename "$SHA")")" = "$EXPECTED_CHECKSUM" ]); assert_rc "$?" 0 'checksum usa basename exacto'
EXTRACT="$WORK/extract"; mkdir "$EXTRACT"; tar -xzf "$TAR" -C "$EXTRACT"
[ -f "$EXTRACT/mefisto-manifest.json" ] && [ -x "$EXTRACT/comandos/run.sh" ] && pass 'extrae sin directorio envolvente y preserva ejecutable' || fail 'layout o permisos incorrectos'
jq -e '.schemaVersion == 1 and .runtime == "opencode" and .version == "1.2.3" and .commit == "0123456789abcdef0123456789abcdef01234567" and .minimumRuntimeVersion == "1.18.29"' "$EXTRACT/mefisto-manifest.json" >/dev/null && pass 'manifiesto completo y versionado' || fail 'manifiesto invalido'
tar -tzf "$TAR" | grep -Eq '(^/|\.\./)' && fail 'tarball contiene ruta insegura' || pass 'tarball no contiene rutas inseguras'
cp "$TAR" "$WORK/primero.tar.gz"; run_package --output "$OUT" >/dev/null; cmp -s "$TAR" "$WORK/primero.tar.gz" && pass 'reproducible byte a byte' || fail 'tarball no reproducible'
printf x >> "$TAR"; (cd "$OUT" && shasum -a 256 -c "$(basename "$SHA")" >/dev/null 2>&1); assert_rc "$?" 1 'checksum detecta tarball corrompido'

setup_repo absent; rm -rf "$TEST_REPO/dist/opencode"; run_package --output "$WORK/absent" >/dev/null 2>&1; assert_rc "$?" 1 'rechaza dist ausente'
setup_repo empty; rm -rf "$TEST_REPO/dist/opencode"; mkdir "$TEST_REPO/dist/opencode"; run_package --output "$WORK/empty" >/dev/null 2>&1; assert_rc "$?" 1 'rechaza dist vacia'
setup_repo stale; GENERATOR_RC=1 run_package --output "$WORK/stale" >/dev/null 2>&1; assert_rc "$?" 1 'rechaza dist desactualizada antes de output'; [ ! -e "$WORK/stale" ] && pass 'dist desactualizada no deja output' || fail 'dist desactualizada dejo output'
setup_repo link; ln -s archivo "$TEST_REPO/dist/opencode/link"; run_package --output "$WORK/link" >/dev/null 2>&1; assert_rc "$?" 1 'rechaza symlink'
setup_repo special; mkfifo "$TEST_REPO/dist/opencode/pipe"; run_package --output "$WORK/special" >/dev/null 2>&1; assert_rc "$?" 1 'rechaza archivo especial'
setup_repo manifest; printf '{}' > "$TEST_REPO/dist/opencode/mefisto-manifest.json"; run_package --output "$WORK/manifest" >/dev/null 2>&1; assert_rc "$?" 1 'rechaza manifiesto preexistente'
setup_repo write; printf x > "$WORK/no-directorio"; run_package --output "$WORK/no-directorio" >/dev/null 2>&1; assert_rc "$?" 1 'fallo de escritura no publica assets'

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
