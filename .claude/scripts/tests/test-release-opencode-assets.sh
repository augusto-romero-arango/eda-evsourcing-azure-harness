#!/usr/bin/env bash
# test-release-opencode-assets.sh -- Publicacion atomica de assets OpenCode (#1089).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd -P)"
RELEASE="$REPO_ROOT/src/internal/scripts/mefisto-release.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_contains() { grep -qF "$2" "$1" && pass "$3" || fail "$3"; }
assert_absent() { ! grep -qF "$2" "$1" && pass "$3" || fail "$3"; }
assert_order() {
    local first second first_line second_line
    first="$2"; second="$3"
    first_line="$(grep -nF "$first" "$1" | cut -d: -f1 | tail -n1)"
    second_line="$(grep -nF "$second" "$1" | cut -d: -f1 | head -n1)"
    [ -n "$first_line" ] && [ -n "$second_line" ] && [ "$first_line" -lt "$second_line" ] \
        && pass "$4" || fail "$4"
}

setup() {
    CASE="$1"; TEST_REPO="$WORK/$CASE"; BIN="$TEST_REPO/bin"
    mkdir -p "$BIN" "$TEST_REPO/.claude-plugin" "$TEST_REPO/src/published/scripts" "$TEST_REPO/dist/claude"
    printf '{"name":"mefisto","version":"1.2.3"}\n' > "$TEST_REPO/.claude-plugin/plugin.json"
    printf '{"schemaVersion":1,"version":"1.2.3","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}\n' > "$TEST_REPO/src/published/release-identity.json"
    printf '{"schemaVersion":1,"runtime":"claude","version":"1.2.3","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}\n' > "$TEST_REPO/mefisto-manifest.json"
    cp "$TEST_REPO/mefisto-manifest.json" "$TEST_REPO/dist/claude/mefisto-manifest.json"
    cat > "$TEST_REPO/CHANGELOG.md" <<'EOF'
## [1.2.3] - 2026-09-08

### Changed
- Notas completas de prueba.

[Unreleased]: https://example.invalid
EOF
    cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "${EVENTS:?}"
case "$1 ${2:-}" in
  'rev-parse --show-toplevel') printf '%s\n' "$TEST_REPO" ;;
  'rev-parse --abbrev-ref') printf 'main\n' ;;
   'rev-parse HEAD') printf '%s\n' "${HEAD_COMMIT:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
   'rev-parse origin/main') printf '%s\n' "${ORIGIN_MAIN_COMMIT:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
   'rev-parse HEAD^') printf '%s\n' "${HEAD_PARENT:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}" ;;
  'status --porcelain') ;;
  'tag -l') printf 'v1.2.2\n' ;;
  'show origin/main:.claude-plugin/plugin.json') cat "$TEST_REPO/.claude-plugin/plugin.json" ;;
   'rev-list --count') printf '0\n' ;;
   'diff --name-status')
     if [ -n "${DELTA_PATH:-}" ]; then printf 'M\t%s\n' "$DELTA_PATH"; else
       printf '%s\n' 'M	CHANGELOG.md' 'M	.claude-plugin/plugin.json' 'M	src/published/release-identity.json' 'A	mefisto-manifest.json' 'M	dist/claude/mefisto-manifest.json' 'M	dist/claude/.mefisto-generated-assets.json'
     fi ;;
  'fetch origin'|'tag -a'|'tag -d') ;;
  'push origin') [ "${PUSH_RC:-0}" = 0 ] || exit "$PUSH_RC" ;;
  *) printf 'git falso no esperaba: %s\n' "$*" >&2; exit 64 ;;
esac
EOF
    cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "${EVENTS:?}"
case "$1 ${2:-}" in
  'repo view') printf 'owner/mefisto\n' ;;
  'auth status') ;;
  'release view') exit 1 ;;
  'release create')
    [ "$#" -eq 9 ] || { printf 'release create recibio %s argumentos, no 9\n' "$#" >&2; exit 65; }
    [ "$(basename "$8")" = 'mefisto-opencode-v1.2.3.tar.gz' ] || exit 66
    [ "$(basename "$9")" = 'mefisto-opencode-v1.2.3.tar.gz.sha256' ] || exit 67
    grep -qF -- '- Notas completas de prueba.' "$7" || exit 68
    printf 'notes-ok\n' >> "${EVENTS:?}"
    [ "${GH_CREATE_RC:-0}" = 0 ] || exit "$GH_CREATE_RC"
    printf 'https://example.invalid/release\n'
    ;;
  *) printf 'gh falso no esperaba: %s\n' "$*" >&2; exit 64 ;;
esac
EOF
    cat > "$TEST_REPO/src/published/scripts/package-opencode-release.sh" <<'EOF'
#!/usr/bin/env bash
set -u
[ "$1" = '--output' ] && [ -n "${2:-}" ] || exit 64
out="$2"; printf '%s\n' "$out" > "${PACKAGE_OUTPUT:?}"; printf 'package\n' >> "${EVENTS:?}"
[ "${PACKAGE_RC:-0}" = 0 ] || exit "$PACKAGE_RC"
name='mefisto-opencode-v1.2.3.tar.gz'; stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
    printf '{"version":"%s","commit":"%s"}\n' "${MANIFEST_VERSION:-1.2.3}" "${MANIFEST_COMMIT:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}" > "$stage/mefisto-manifest.json"
tar -czf "$out/$name" -C "$stage" mefisto-manifest.json
(cd "$out" && shasum -a 256 "$name" > "$name.sha256")
[ "${CORRUPT_CHECKSUM:-0}" != 1 ] || printf x >> "$out/$name"
printf '%s\n%s\n' "$out/$name" "$out/$name.sha256"
EOF
    cat > "$TEST_REPO/src/published/scripts/generate-published-adapters.sh" <<'EOF'
#!/usr/bin/env bash
exit "${GENERATOR_RC:-0}"
EOF
    chmod +x "$BIN/git" "$BIN/gh" "$TEST_REPO/src/published/scripts/package-opencode-release.sh" "$TEST_REPO/src/published/scripts/generate-published-adapters.sh"
    EVENTS="$TEST_REPO/events"; PACKAGE_OUTPUT="$TEST_REPO/package-output"
    export TEST_REPO EVENTS PACKAGE_OUTPUT
}

run_release() {
    (cd "$TEST_REPO" && PATH="$BIN:$PATH" "$RELEASE") > "$TEST_REPO/out" 2>&1
    return $?
}
assert_cleaned() {
    local path; path="$(< "$PACKAGE_OUTPUT")"
    [ ! -e "$path" ] && pass "$1" || fail "$1"
}

printf '[A] Publicacion correcta\n'
setup success; run_release; rc=$?
[ "$rc" -eq 0 ] && pass 'publica con falsos sin efectos remotos' || fail 'la publicacion correcta falla'
assert_contains "$EVENTS" 'package' 'empaqueta antes del tag'
assert_order "$EVENTS" 'package' 'git tag -a' 'el packager termina antes de crear el tag'
assert_contains "$EVENTS" 'git tag -a v1.2.3 -m Release v1.2.3' 'crea el tag unico tras validar assets'
assert_order "$EVENTS" 'git tag -a' 'git push origin' 'crea el tag antes de subirlo'
assert_contains "$EVENTS" 'git push origin v1.2.3' 'sube el mismo tag SemVer'
assert_order "$EVENTS" 'git push origin' 'gh release create' 'sube el tag antes de crear el release'
assert_contains "$EVENTS" 'gh release create v1.2.3 --title v1.2.3 --notes-file' 'crea el release con notas'
assert_contains "$EVENTS" 'mefisto-opencode-v1.2.3.tar.gz' 'adjunta el tarball con nombre canonico'
assert_contains "$EVENTS" 'mefisto-opencode-v1.2.3.tar.gz.sha256' 'adjunta el checksum con nombre canonico'
assert_contains "$EVENTS" 'notes-ok' 'conserva las notas completas y adjunta exactamente dos assets'
assert_cleaned 'limpia el temporal de assets al publicar'

printf '[B] Fallos previos al tag\n'
setup package-fails; PACKAGE_RC=7 run_release; rc=$?
[ "$rc" -ne 0 ] && pass 'el fallo del packager aborta' || fail 'el fallo del packager deberia abortar'
assert_absent "$EVENTS" 'git tag -a' 'no crea tag si falla el packager'
assert_absent "$EVENTS" 'gh release create' 'no crea release si falla el packager'
assert_cleaned 'limpia el temporal tras fallo del packager'

setup checksum-fails; CORRUPT_CHECKSUM=1 run_release; rc=$?
[ "$rc" -ne 0 ] && pass 'el checksum corrupto aborta' || fail 'el checksum corrupto deberia abortar'
assert_absent "$EVENTS" 'git tag -a' 'no crea tag si falla la revalidacion externa'
assert_cleaned 'limpia el temporal tras checksum invalido'

setup manifest-fails; MANIFEST_COMMIT=cccccccccccccccccccccccccccccccccccccccc run_release; rc=$?
[ "$rc" -ne 0 ] && pass 'un commit de manifiesto ajeno aborta' || fail 'el commit ajeno deberia abortar'
assert_absent "$EVENTS" 'git tag -a' 'no crea tag si el manifiesto no coincide con la identidad fuente'
assert_cleaned 'limpia el temporal tras manifiesto invalido'

setup version-fails; MANIFEST_VERSION=1.2.4 run_release; rc=$?
[ "$rc" -ne 0 ] && pass 'una version de manifiesto distinta aborta' || fail 'la version de manifiesto distinta deberia abortar'
assert_absent "$EVENTS" 'git tag -a' 'no crea tag si el manifiesto no coincide con plugin.json'
assert_cleaned 'limpia el temporal tras version de manifiesto invalida'

setup parent-fails; HEAD_PARENT=cccccccccccccccccccccccccccccccccccccccc run_release; rc=$?
[ "$rc" -ne 0 ] && pass 'un padre distinto del commit fuente aborta' || fail 'el padre distinto deberia abortar'
assert_absent "$EVENTS" 'git tag -a' 'no crea tag con merge no squash'

setup main-advanced; ORIGIN_MAIN_COMMIT=cccccccccccccccccccccccccccccccccccccccc run_release; rc=$?
[ "$rc" -ne 0 ] && pass 'un main avanzado aborta' || fail 'main avanzado deberia abortar'
assert_absent "$EVENTS" 'git tag -a' 'no crea tag si HEAD ya no es origin/main'

setup delta-fails; DELTA_PATH=scripts/intruso.sh run_release; rc=$?
[ "$rc" -ne 0 ] && pass 'un path fuera de allowlist aborta' || fail 'path fuera de allowlist deberia abortar'
assert_absent "$EVENTS" 'git tag -a' 'no crea tag con delta fuera de allowlist'

setup push-fails; PUSH_RC=8 run_release; rc=$?
[ "$rc" -ne 0 ] && pass 'el fallo al subir el tag aborta' || fail 'el fallo al subir el tag deberia abortar'
assert_contains "$EVENTS" 'git tag -d v1.2.3' 'revierte el tag local si falla el push'
assert_absent "$EVENTS" 'gh release create' 'no crea release si no pudo subir el tag'
assert_cleaned 'limpia el temporal tras fallo al subir el tag'

printf '[C] Fallo posterior al tag\n'
setup github-fails; GH_CREATE_RC=9 run_release; rc=$?
[ "$rc" -ne 0 ] && pass 'el fallo de GitHub mantiene fail-loud' || fail 'el fallo de GitHub deberia abortar'
assert_contains "$EVENTS" 'git push origin v1.2.3' 'el tag ya fue subido antes del fallo remoto'
assert_contains "$TEST_REPO/out" 'El tag ya esta pusheado' 'el diagnostico identifica el tag existente'
assert_contains "$TEST_REPO/out" 'gh release create "v1.2.3"' 'el diagnostico ofrece recuperacion sin reeditar version'
assert_contains "$TEST_REPO/out" 'mefisto-opencode-v1.2.3.tar.gz' 'la recuperacion nombra ambos assets'
assert_contains "$TEST_REPO/out" 'package-opencode-release.sh --output' 'la recuperacion reconstruye los assets ya limpiados'
assert_contains "$TEST_REPO/out" "trap 'rm -rf" 'la recuperacion tambien protege sus temporales'
assert_cleaned 'limpia el temporal tras fallo de GitHub'

printf '[D] Aislamiento de prepare\n'
publish_line="$(grep -nF '# FASE PUBLISH' "$RELEASE" | cut -d: -f1 | head -n1)"
package_line="$(grep -nF '"$OPENCODE_PACKAGER" --output "$ASSETS_DIR"' "$RELEASE" | cut -d: -f1 | head -n1)"
[ -n "$publish_line" ] && [ -n "$package_line" ] && [ "$package_line" -gt "$publish_line" ] \
    && pass 'el packager solo se invoca dentro de publish' || fail 'prepare no debe invocar el packager'

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
