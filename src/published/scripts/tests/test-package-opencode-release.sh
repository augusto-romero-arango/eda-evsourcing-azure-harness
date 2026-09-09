#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/scripts/package-opencode-release.sh"
INSTALLER_SOURCE="$REPO_ROOT/src/published/scripts/install-opencode-release.sh"
LAUNCHER_SOURCE="$REPO_ROOT/src/published/scripts/mefisto-opencode"
PROJECTOR_SOURCE="$REPO_ROOT/src/published/scripts/project-opencode-release.sh"
DIAGNOSTIC_SOURCE="$REPO_ROOT/src/published/scripts/diagnose-installation-identity.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_rc() { [ "$1" -eq "$2" ] && pass "$3" || fail "$3 (exit $1)"; }

setup_repo() {
    TEST_REPO="$WORK/repo-$1"
    mkdir -p "$TEST_REPO/src/published/scripts" "$TEST_REPO/dist/opencode/comandos" "$TEST_REPO/.claude-plugin" "$TEST_REPO/bin"
    cp "$SOURCE" "$TEST_REPO/src/published/scripts/package-opencode-release.sh"
    cp "$INSTALLER_SOURCE" "$TEST_REPO/src/published/scripts/install-opencode-release.sh"
    cp "$LAUNCHER_SOURCE" "$TEST_REPO/src/published/scripts/mefisto-opencode"
    cp "$PROJECTOR_SOURCE" "$TEST_REPO/src/published/scripts/project-opencode-release.sh"
    cp "$DIAGNOSTIC_SOURCE" "$TEST_REPO/src/published/scripts/diagnose-installation-identity.sh"
    chmod +x "$TEST_REPO/src/published/scripts/package-opencode-release.sh" "$TEST_REPO/src/published/scripts/project-opencode-release.sh" "$TEST_REPO/src/published/scripts/diagnose-installation-identity.sh"
    chmod +x "$TEST_REPO/src/published/scripts/install-opencode-release.sh" "$TEST_REPO/src/published/scripts/mefisto-opencode"
    printf '{"version":"1.2.3"}\n' > "$TEST_REPO/.claude-plugin/plugin.json"
    cat > "$TEST_REPO/src/published/scripts/generate-published-adapters.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${GENERATOR_LOG:?}"
[ "$#" -eq 1 ] && [ "$1" = "--check" ] || exit 64
exit "${GENERATOR_RC:-0}"
EOF
    chmod +x "$TEST_REPO/src/published/scripts/generate-published-adapters.sh"
    printf '#!/usr/bin/env bash\nif [ "$1" = "-C" ]; then shift 2; fi\n[ "$1" = "rev-parse" ] && printf "0123456789abcdef0123456789abcdef01234567\\n"\n' > "$TEST_REPO/bin/git"
    chmod +x "$TEST_REPO/bin/git"
    printf '#!/usr/bin/env bash\nprintf "ejecutable\\n"\n' > "$TEST_REPO/dist/opencode/comandos/run.sh"
    chmod +x "$TEST_REPO/dist/opencode/comandos/run.sh"
    printf 'contenido\n' > "$TEST_REPO/dist/opencode/archivo con espacios.txt"
    for source in \
        scripts/_pipeline-common.sh scripts/tmux-pipeline.sh scripts/herdr-pipeline.sh scripts/stream-watch.sh scripts/tooling-pipeline.sh \
        src/runtime/mefisto-run-agent.sh src/runtime/lib/mefisto-runtime.sh src/runtime/lib/mefisto-process.sh \
        src/runtime/lib/runtime-claude.sh src/runtime/lib/runtime-opencode.sh; do
        mkdir -p "$TEST_REPO/dist/opencode/$(dirname "$source")"
        printf '#!/usr/bin/env bash\n' > "$TEST_REPO/dist/opencode/$source"
        chmod 0755 "$TEST_REPO/dist/opencode/$source"
    done
    for source in \
        src/runtime/lib/mefisto-models.sh src/runtime/lib/runtime-claude.jq src/runtime/lib/runtime-opencode.jq \
        src/runtime/contract/models.validate.jq; do
        mkdir -p "$TEST_REPO/dist/opencode/$(dirname "$source")"
        printf 'runtime\n' > "$TEST_REPO/dist/opencode/$source"
        chmod 0644 "$TEST_REPO/dist/opencode/$source"
    done
    mkdir "$TEST_REPO/dist/opencode/directorio-vacio" "$TEST_REPO/.claude" "$TEST_REPO/src/internal" "$TEST_REPO/tests"
    printf 'no publicar\n' > "$TEST_REPO/.claude/local.json"
    printf 'no publicar\n' > "$TEST_REPO/src/internal/secreto.txt"
    printf 'no publicar\n' > "$TEST_REPO/tests/fixture.txt"
    printf 'no publicar\n' > "$TEST_REPO/CLAUDE_PLUGIN_ROOT"
    printf 'no publicar\n' > "$TEST_REPO/auth.json"
    GENERATOR_LOG="$TEST_REPO/generator.log"
}
run_package() { PATH="$TEST_REPO/bin:$PATH" GENERATOR_LOG="$GENERATOR_LOG" MEFISTO_PACKAGE_REPO_ROOT="$TEST_REPO" "$TEST_REPO/src/published/scripts/package-opencode-release.sh" "$@"; }
assert_no_assets() {
    local output="$1" label="$2"
    if [ ! -e "$output/mefisto-opencode-v1.2.3.tar.gz" ] && [ ! -e "$output/mefisto-opencode-v1.2.3.tar.gz.sha256" ]; then pass "$label"; else fail "$label"; fi
}

printf '[pre] sintaxis y ejecutable\n'
bash -n "$SOURCE" && [ -x "$SOURCE" ] && pass 'packager Bash valido y ejecutable' || fail 'packager invalido'

setup_repo success
OUT="$WORK/salida con espacios"; OTHER_CWD="$WORK/cwd externo"; mkdir "$OTHER_CWD"
(cd "$OTHER_CWD" && umask 022 && run_package --output "$OUT" >/dev/null); rc=$?
assert_rc "$rc" 0 'crea assets fuera del checkout desde otro cwd y con output con espacios'
[ "$(< "$GENERATOR_LOG")" = '--check' ] && pass 'ejecuta el generador exclusivamente con --check' || fail 'invocacion incorrecta del generador'
TAR="$OUT/mefisto-opencode-v1.2.3.tar.gz"; SHA="$TAR.sha256"
[ -f "$TAR" ] && [ -f "$SHA" ] && pass 'nombres canonicos de assets' || fail 'faltan assets canonicos'
(cd "$OUT" && shasum -a 256 -c "$(basename "$SHA")" >/dev/null 2>&1); assert_rc "$?" 0 'checksum externo valido'
(cd "$OUT" && EXPECTED_CHECKSUM="$(shasum -a 256 "$(basename "$TAR")")" && [ "$(< "$(basename "$SHA")")" = "$EXPECTED_CHECKSUM" ]); assert_rc "$?" 0 'checksum usa basename exacto'
SHA_VALUE="$(< "$SHA")"
SHA_DIGEST="${SHA_VALUE%%  *}"; SHA_FILE="${SHA_VALUE#*  }"
[ "${#SHA_DIGEST}" -eq 64 ] && [ -z "${SHA_DIGEST//[0123456789abcdef]/}" ] && [ "$SHA_FILE" = 'mefisto-opencode-v1.2.3.tar.gz' ] && pass 'formato sha256 canonico y no interactivo' || fail 'formato sha256 invalido'

EXTRACT="$WORK/extract"; mkdir "$EXTRACT"; tar -xzf "$TAR" -C "$EXTRACT"
[ -f "$EXTRACT/mefisto-manifest.json" ] && [ -x "$EXTRACT/comandos/run.sh" ] && [ -x "$EXTRACT/install.sh" ] && [ -x "$EXTRACT/project-opencode-release.sh" ] && [ -x "$EXTRACT/diagnose-installation-identity.sh" ] && [ -x "$EXTRACT/bin/mefisto-opencode" ] && [ -d "$EXTRACT/directorio-vacio" ] && pass 'extrae instalador, proyector, diagnostico y contenido sin envolvente' || fail 'layout o permisos incorrectos'
closure_ok=true
for source in \
    scripts/_pipeline-common.sh scripts/tmux-pipeline.sh scripts/herdr-pipeline.sh scripts/stream-watch.sh scripts/tooling-pipeline.sh \
    src/runtime/mefisto-run-agent.sh src/runtime/lib/mefisto-runtime.sh src/runtime/lib/mefisto-process.sh \
    src/runtime/lib/runtime-claude.sh src/runtime/lib/runtime-opencode.sh; do
    [ -x "$EXTRACT/$source" ] || closure_ok=false
done
for source in \
    src/runtime/lib/mefisto-models.sh src/runtime/lib/runtime-claude.jq src/runtime/lib/runtime-opencode.jq \
    src/runtime/contract/models.validate.jq; do
    [ -f "$EXTRACT/$source" ] && [ ! -x "$EXTRACT/$source" ] || closure_ok=false
done
[ "$closure_ok" = true ] && pass 'extrae la clausura ejecutable declarada con sus modos' || fail 'falta o tiene modo incorrecto la clausura ejecutable'
jq -e '.schemaVersion == 1 and .runtime == "opencode" and .version == "1.2.3" and .commit == "0123456789abcdef0123456789abcdef01234567" and .minimumRuntimeVersion == "1.18.29" and (keys | length == 5)' "$EXTRACT/mefisto-manifest.json" >/dev/null && pass 'manifiesto completo, minimo y versionado' || fail 'manifiesto invalido'
tar -tzf "$TAR" | grep -Eq '(^/|\.\./)' && fail 'tarball contiene ruta insegura' || pass 'tarball no contiene rutas inseguras'
CONTENTS="$(tar -tzf "$TAR")"
case "$CONTENTS" in *'.claude'*|*'src/internal'*|*'src/runtime/tests'*|*'runtime-fake.sh'*|*'tests/'*|*'CLAUDE_PLUGIN_ROOT'*|*'auth.json'*|*'.sha256'*) fail 'tarball incorporo archivos ajenos o checksum interno' ;; *) pass 'paquete limitado a dist/opencode y sin checksum interno' ;; esac
cp "$TAR" "$WORK/primero.tar.gz"
(umask 077 && run_package --output "$OUT" >/dev/null)
cmp -s "$TAR" "$WORK/primero.tar.gz" && pass 'reproducible byte a byte entre umasks' || fail 'tarball no reproducible'
printf x >> "$TAR"; (cd "$OUT" && shasum -a 256 -c "$(basename "$SHA")" >/dev/null 2>&1); assert_rc "$?" 1 'checksum detecta tarball corrompido'

setup_repo absent; rm -rf "$TEST_REPO/dist/opencode"; NEG_OUT="$WORK/absent"; run_package --output "$NEG_OUT" >/dev/null 2>&1; assert_rc "$?" 1 'rechaza dist ausente'; assert_no_assets "$NEG_OUT" 'dist ausente no deja assets'
setup_repo empty; rm -rf "$TEST_REPO/dist/opencode"; mkdir "$TEST_REPO/dist/opencode"; NEG_OUT="$WORK/empty"; run_package --output "$NEG_OUT" >/dev/null 2>&1; assert_rc "$?" 1 'rechaza dist vacia'; assert_no_assets "$NEG_OUT" 'dist vacia no deja assets'
setup_repo stale; NEG_OUT="$WORK/stale"; GENERATOR_RC=1 run_package --output "$NEG_OUT" >/dev/null 2>&1; assert_rc "$?" 1 'rechaza dist desactualizada'; assert_no_assets "$NEG_OUT" 'dist desactualizada no deja assets'
setup_repo link; ln -s archivo "$TEST_REPO/dist/opencode/link"; NEG_OUT="$WORK/link"; run_package --output "$NEG_OUT" >/dev/null 2>&1; assert_rc "$?" 1 'rechaza symlink'; assert_no_assets "$NEG_OUT" 'symlink no deja assets'
setup_repo special; mkfifo "$TEST_REPO/dist/opencode/pipe"; NEG_OUT="$WORK/special"; run_package --output "$NEG_OUT" >/dev/null 2>&1; assert_rc "$?" 1 'rechaza archivo especial'; assert_no_assets "$NEG_OUT" 'archivo especial no deja assets'
setup_repo manifest; printf '{}' > "$TEST_REPO/dist/opencode/mefisto-manifest.json"; NEG_OUT="$WORK/manifest"; run_package --output "$NEG_OUT" >/dev/null 2>&1; assert_rc "$?" 1 'rechaza manifiesto preexistente'; assert_no_assets "$NEG_OUT" 'conflicto de manifiesto no deja assets'
setup_repo write; printf x > "$WORK/no-directorio"; run_package --output "$WORK/no-directorio" >/dev/null 2>&1; assert_rc "$?" 1 'fallo al crear output no publica assets'
setup_repo partial; PARTIAL_OUT="$WORK/partial"; mkdir -p "$PARTIAL_OUT/mefisto-opencode-v1.2.3.tar.gz.sha256"; run_package --output "$PARTIAL_OUT" >/dev/null 2>&1; assert_rc "$?" 1 'conflicto de destino aborta'; [ ! -e "$PARTIAL_OUT/mefisto-opencode-v1.2.3.tar.gz" ] && pass 'fallo de publicacion no deja tarball parcial' || fail 'fallo dejo tarball parcial'

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
