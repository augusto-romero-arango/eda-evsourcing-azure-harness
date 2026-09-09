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
CLAUDE_ADAPTER_SOURCE="$REPO_ROOT/src/published/scripts/adapters/adapter-claude.sh"
CLAUDE_LIB_SOURCE="$REPO_ROOT/src/published/scripts/lib/adapter-claude.sh"
FIXTURES="$REPO_ROOT/src/published/scripts/tests/fixtures/release-identity"
WORK="$(mktemp -d)"; trap 'chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_rc() { [ "$1" -eq "$2" ] && pass "$3" || fail "$3 (exit $1)"; }
file_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }

setup_repo() {
    TEST_REPO="$WORK/repo-$1"
    mkdir -p "$TEST_REPO/src/published/scripts/adapters" "$TEST_REPO/src/published/scripts/lib" "$TEST_REPO/dist/opencode/comandos" "$TEST_REPO/dist/opencode/skills/mefisto-projections" "$TEST_REPO/dist/opencode/skills/mefisto-comment-cleanup" "$TEST_REPO/.claude-plugin" "$TEST_REPO/bin"
    cp "$SOURCE" "$TEST_REPO/src/published/scripts/package-opencode-release.sh"
    cp "$INSTALLER_SOURCE" "$TEST_REPO/src/published/scripts/install-opencode-release.sh"
    cp "$LAUNCHER_SOURCE" "$TEST_REPO/src/published/scripts/mefisto-opencode"
    cp "$PROJECTOR_SOURCE" "$TEST_REPO/src/published/scripts/project-opencode-release.sh"
    cp "$DIAGNOSTIC_SOURCE" "$TEST_REPO/src/published/scripts/diagnose-installation-identity.sh"
    cp "$CLAUDE_ADAPTER_SOURCE" "$TEST_REPO/src/published/scripts/adapters/adapter-claude.sh"
    cp "$CLAUDE_LIB_SOURCE" "$TEST_REPO/src/published/scripts/lib/adapter-claude.sh"
    chmod +x "$TEST_REPO/src/published/scripts/package-opencode-release.sh" "$TEST_REPO/src/published/scripts/project-opencode-release.sh" "$TEST_REPO/src/published/scripts/diagnose-installation-identity.sh"
    chmod +x "$TEST_REPO/src/published/scripts/install-opencode-release.sh" "$TEST_REPO/src/published/scripts/mefisto-opencode"
    printf '{"version":"1.2.3"}\n' > "$TEST_REPO/.claude-plugin/plugin.json"
    cp "$FIXTURES/valid.json" "$TEST_REPO/src/published/release-identity.json"
    cat > "$TEST_REPO/src/published/scripts/generate-published-adapters.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${GENERATOR_LOG:?}"
[ "$#" -eq 1 ] && [ "$1" = "--check" ] || exit 64
exit "${GENERATOR_RC:-0}"
EOF
    chmod +x "$TEST_REPO/src/published/scripts/generate-published-adapters.sh"
    printf '#!/usr/bin/env bash\nprintf "%s\\n" "git no debe participar en la identidad" >&2\nexit 99\n' > "$TEST_REPO/bin/git"
    chmod +x "$TEST_REPO/bin/git"
    printf '#!/usr/bin/env bash\nprintf "ejecutable\\n"\n' > "$TEST_REPO/dist/opencode/comandos/run.sh"
    chmod +x "$TEST_REPO/dist/opencode/comandos/run.sh"
    printf 'contenido\n' > "$TEST_REPO/dist/opencode/archivo con espacios.txt"
    printf '%s\n' '---' 'name: mefisto-projections' 'description: Proyecciones.' '---' '[recurso](read-apis.md)' > "$TEST_REPO/dist/opencode/skills/mefisto-projections/SKILL.md"
    printf 'recurso projections\n' > "$TEST_REPO/dist/opencode/skills/mefisto-projections/read-apis.md"
    printf '%s\n' '---' 'name: mefisto-comment-cleanup' 'description: Comentarios.' '---' '[recurso](ejemplos.md)' > "$TEST_REPO/dist/opencode/skills/mefisto-comment-cleanup/SKILL.md"
    printf 'recurso comentarios\n' > "$TEST_REPO/dist/opencode/skills/mefisto-comment-cleanup/ejemplos.md"
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
    if [ ! -d "$output" ] || [ -z "$(find "$output" -mindepth 1 -print -quit)" ]; then pass "$label"; else fail "$label"; fi
}
render_claude_manifest() {
    local identity="$1" version="$2" destination="$3"
    mkdir -p "$destination"
    printf '{"version":"%s"}\n' "$version" > "$TEST_REPO/.claude-plugin/plugin.json"
    bash "$TEST_REPO/src/published/scripts/adapters/adapter-claude.sh" render-asset mefisto-manifest "$identity" > "$destination/mefisto-manifest.json"
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
[ "$(file_mode "$EXTRACT/mefisto-manifest.json")" = 644 ] && pass 'manifiesto tiene modo 0644' || fail 'modo del manifiesto invalido'
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
[ -f "$EXTRACT/skills/mefisto-projections/SKILL.md" ] && [ -f "$EXTRACT/skills/mefisto-projections/read-apis.md" ] && [ -f "$EXTRACT/skills/mefisto-comment-cleanup/ejemplos.md" ] && pass 'el paquete conserva Skills y recursos publicados' || fail 'el paquete omitio Skills publicados'
jq -e '.schemaVersion == 1 and .runtime == "opencode" and .version == "1.2.3" and .commit == "0123456789abcdef0123456789abcdef01234567" and .minimumRuntimeVersion == "1.18.29" and (keys | length == 5)' "$EXTRACT/mefisto-manifest.json" >/dev/null && pass 'manifiesto completo usa la identidad neutral' || fail 'manifiesto invalido'
tar -tzf "$TAR" | grep -Eq '(^/|\.\./)' && fail 'tarball contiene ruta insegura' || pass 'tarball no contiene rutas inseguras'
CONTENTS="$(tar -tzf "$TAR")"
case "$CONTENTS" in *'.claude'*|*'release-identity.json'*|*'src/internal'*|*'src/runtime/tests'*|*'runtime-fake.sh'*|*'tests/'*|*'CLAUDE_PLUGIN_ROOT'*|*'auth.json'*|*'.sha256'*) fail 'tarball incorporo metadata o archivos ajenos' ;; *) pass 'paquete limitado a dist/opencode sin fuentes de metadata' ;; esac
cp "$TAR" "$WORK/primero.tar.gz"
cp "$SHA" "$WORK/primero.tar.gz.sha256"
(umask 077 && run_package --output "$OUT" >/dev/null)
cmp -s "$TAR" "$WORK/primero.tar.gz" && pass 'reproducible byte a byte entre umasks' || fail 'tarball no reproducible'
setup_repo head-a; mkdir "$TEST_REPO/.git"; printf '0123456789abcdef0123456789abcdef01234567\n' > "$TEST_REPO/.git/HEAD"; HEAD_A_OUT="$WORK/head-a"; run_package --output "$HEAD_A_OUT" >/dev/null
setup_repo head-b; mkdir "$TEST_REPO/.git"; printf 'abcdef0123456789abcdef0123456789abcdef01\n' > "$TEST_REPO/.git/HEAD"; HEAD_B_OUT="$WORK/head-b"; run_package --output "$HEAD_B_OUT" >/dev/null
cmp -s "$HEAD_A_OUT/mefisto-opencode-v1.2.3.tar.gz" "$HEAD_B_OUT/mefisto-opencode-v1.2.3.tar.gz" && cmp -s "$HEAD_A_OUT/mefisto-opencode-v1.2.3.tar.gz.sha256" "$HEAD_B_OUT/mefisto-opencode-v1.2.3.tar.gz.sha256" && pass 'checkouts con HEAD distintos no afectan los assets ni invocan Git' || fail 'el HEAD afecto los assets'

CLAUDE_FIXTURE="$WORK/claude-generado"
render_claude_manifest "$FIXTURES/valid.json" 1.2.3 "$CLAUDE_FIXTURE"
DIAGNOSIS="$(bash "$EXTRACT/diagnose-installation-identity.sh" --claude-root "$CLAUDE_FIXTURE" --opencode-root "$EXTRACT")"
printf '%s' "$DIAGNOSIS" | jq -e '.status == "aligned" and .claude.version == .opencode.version and .claude.commit == .opencode.commit' >/dev/null && pass 'diagnostico alinea fixtures Claude y OpenCode generados desde la misma fuente' || fail 'diagnostico no alineo los fixtures generados'
render_claude_manifest "$FIXTURES/version-changed.json" 2.0.0 "$CLAUDE_FIXTURE"
DIAGNOSIS="$(bash "$EXTRACT/diagnose-installation-identity.sh" --claude-root "$CLAUDE_FIXTURE" --opencode-root "$EXTRACT")"
printf '%s' "$DIAGNOSIS" | jq -e '.status == "drift" and .claude.version == "2.0.0" and .opencode.version == "1.2.3" and .claude.commit == .opencode.commit' >/dev/null && pass 'diagnostico reporta ambas versiones cuando solo cambia version' || fail 'diagnostico incompleto para deriva de version'
render_claude_manifest "$FIXTURES/commit-changed.json" 1.2.3 "$CLAUDE_FIXTURE"
DIAGNOSIS="$(bash "$EXTRACT/diagnose-installation-identity.sh" --claude-root "$CLAUDE_FIXTURE" --opencode-root "$EXTRACT")"
printf '%s' "$DIAGNOSIS" | jq -e '.status == "drift" and .claude.version == .opencode.version and .claude.commit == "abcdef0123456789abcdef0123456789abcdef01" and .opencode.commit == "0123456789abcdef0123456789abcdef01234567"' >/dev/null && pass 'diagnostico reporta ambos commits cuando solo cambia commit' || fail 'diagnostico incompleto para deriva de commit'
HOME="$WORK/home integrado"; XDG_DATA_HOME="$HOME/datos"; XDG_CONFIG_HOME="$HOME/config"; export HOME XDG_DATA_HOME XDG_CONFIG_HOME
mkdir -p "$HOME"
"$EXTRACT/install.sh" install 1.2.3 >/dev/null; assert_rc "$?" 0 'instala el paquete fixture sin checkout'
"$XDG_DATA_HOME/mefisto/active/bin/mefisto-opencode" project >/dev/null; assert_rc "$?" 0 'proyecta la release instalada'
[ -L "$XDG_CONFIG_HOME/opencode/skills/mefisto-projections/SKILL.md" ] && [ -L "$XDG_CONFIG_HOME/opencode/skills/mefisto-comment-cleanup/SKILL.md" ] && grep -q '^name: mefisto-projections$' "$XDG_CONFIG_HOME/opencode/skills/mefisto-projections/SKILL.md" && [ "$(< "$XDG_CONFIG_HOME/opencode/skills/mefisto-projections/read-apis.md")" = 'recurso projections' ] && [ "$(< "$XDG_CONFIG_HOME/opencode/skills/mefisto-comment-cleanup/ejemplos.md")" = 'recurso comentarios' ] && pass 'proyeccion global abre nombres y recursos relativos de ambos Skills' || fail 'proyeccion global de Skills incompleta'
printf x >> "$TAR"; (cd "$OUT" && shasum -a 256 -c "$(basename "$SHA")" >/dev/null 2>&1); assert_rc "$?" 1 'checksum detecta tarball corrompido'

setup_repo absent; rm -rf "$TEST_REPO/dist/opencode"; NEG_OUT="$WORK/absent"; run_package --output "$NEG_OUT" >/dev/null 2>&1; assert_rc "$?" 1 'rechaza dist ausente'; assert_no_assets "$NEG_OUT" 'dist ausente no deja assets'
setup_repo empty; rm -rf "$TEST_REPO/dist/opencode"; mkdir "$TEST_REPO/dist/opencode"; NEG_OUT="$WORK/empty"; run_package --output "$NEG_OUT" >/dev/null 2>&1; assert_rc "$?" 1 'rechaza dist vacia'; assert_no_assets "$NEG_OUT" 'dist vacia no deja assets'
setup_repo stale; NEG_OUT="$WORK/stale"; GENERATOR_RC=1 run_package --output "$NEG_OUT" >/dev/null 2>&1; assert_rc "$?" 1 'rechaza dist desactualizada'; assert_no_assets "$NEG_OUT" 'dist desactualizada no deja assets'
setup_repo link; ln -s archivo "$TEST_REPO/dist/opencode/link"; NEG_OUT="$WORK/link"; run_package --output "$NEG_OUT" >/dev/null 2>&1; assert_rc "$?" 1 'rechaza symlink'; assert_no_assets "$NEG_OUT" 'symlink no deja assets'
setup_repo special; mkfifo "$TEST_REPO/dist/opencode/pipe"; NEG_OUT="$WORK/special"; run_package --output "$NEG_OUT" >/dev/null 2>&1; assert_rc "$?" 1 'rechaza archivo especial'; assert_no_assets "$NEG_OUT" 'archivo especial no deja assets'
setup_repo manifest; printf '{}' > "$TEST_REPO/dist/opencode/mefisto-manifest.json"; NEG_OUT="$WORK/manifest"; run_package --output "$NEG_OUT" >/dev/null 2>&1; assert_rc "$?" 1 'rechaza manifiesto preexistente'; assert_no_assets "$NEG_OUT" 'conflicto de manifiesto no deja assets'
setup_repo write; printf x > "$WORK/no-directorio"; run_package --output "$WORK/no-directorio" >/dev/null 2>&1; assert_rc "$?" 1 'fallo al crear output no publica assets'
setup_repo partial; PARTIAL_OUT="$WORK/partial"; mkdir -p "$PARTIAL_OUT/mefisto-opencode-v1.2.3.tar.gz.sha256"; run_package --output "$PARTIAL_OUT" >/dev/null 2>&1; assert_rc "$?" 1 'conflicto de destino aborta'; [ ! -e "$PARTIAL_OUT/mefisto-opencode-v1.2.3.tar.gz" ] && pass 'fallo de publicacion no deja tarball parcial' || fail 'fallo dejo tarball parcial'
for fixture in absent corrupt extra semver-invalido commit-invalido version-divergente; do
    setup_repo "identity-$fixture"; NEG_OUT="$WORK/identity-$fixture"
    if [ "$fixture" = absent ]; then rm "$TEST_REPO/src/published/release-identity.json"; else cp "$FIXTURES/$fixture.json" "$TEST_REPO/src/published/release-identity.json"; fi
    run_package --output "$NEG_OUT" >/dev/null 2>&1; assert_rc "$?" 1 "identidad $fixture aborta antes de empaquetar"; assert_no_assets "$NEG_OUT" "identidad $fixture no deja assets"
done

setup_repo version-change; VERSION_OUT="$WORK/version-change"; cp "$FIXTURES/version-changed.json" "$TEST_REPO/src/published/release-identity.json"; printf '{"version":"2.0.0"}\n' > "$TEST_REPO/.claude-plugin/plugin.json"; run_package --output "$VERSION_OUT" >/dev/null
VERSION_TAR="$VERSION_OUT/mefisto-opencode-v2.0.0.tar.gz"; VERSION_SHA="$VERSION_TAR.sha256"
[ -f "$VERSION_TAR" ] && ! cmp -s "$WORK/primero.tar.gz" "$VERSION_TAR" && ! cmp -s "$WORK/primero.tar.gz.sha256" "$VERSION_SHA" && tar -xOzf "$VERSION_TAR" mefisto-manifest.json | jq -e '.version == "2.0.0" and .commit == "0123456789abcdef0123456789abcdef01234567"' >/dev/null && pass 'cambiar solo version cambia manifiesto y checksum' || fail 'cambio de version no altero deterministicamente el asset'
cp "$VERSION_TAR" "$WORK/version-primera.tar.gz"; cp "$VERSION_SHA" "$WORK/version-primera.sha256"; run_package --output "$VERSION_OUT" >/dev/null
cmp -s "$VERSION_TAR" "$WORK/version-primera.tar.gz" && cmp -s "$VERSION_SHA" "$WORK/version-primera.sha256" && pass 'cambio de version permanece reproducible' || fail 'cambio de version no fue reproducible'

setup_repo commit-change; COMMIT_OUT="$WORK/commit-change"; cp "$FIXTURES/commit-changed.json" "$TEST_REPO/src/published/release-identity.json"; run_package --output "$COMMIT_OUT" >/dev/null
COMMIT_TAR="$COMMIT_OUT/mefisto-opencode-v1.2.3.tar.gz"; COMMIT_SHA="$COMMIT_TAR.sha256"
[ -f "$COMMIT_TAR" ] && ! cmp -s "$WORK/primero.tar.gz" "$COMMIT_TAR" && ! cmp -s "$WORK/primero.tar.gz.sha256" "$COMMIT_SHA" && tar -xOzf "$COMMIT_TAR" mefisto-manifest.json | jq -e '.version == "1.2.3" and .commit == "abcdef0123456789abcdef0123456789abcdef01"' >/dev/null && pass 'cambiar solo commit cambia manifiesto y checksum' || fail 'cambio de commit no altero deterministicamente el asset'
cp "$COMMIT_TAR" "$WORK/commit-primero.tar.gz"; cp "$COMMIT_SHA" "$WORK/commit-primero.sha256"; run_package --output "$COMMIT_OUT" >/dev/null
cmp -s "$COMMIT_TAR" "$WORK/commit-primero.tar.gz" && cmp -s "$COMMIT_SHA" "$WORK/commit-primero.sha256" && pass 'cambio de commit permanece reproducible' || fail 'cambio de commit no fue reproducible'

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
