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

setup() {
    CASE="$1"; TEST_REPO="$WORK/$CASE"; BIN="$TEST_REPO/bin"
    mkdir -p "$BIN" "$TEST_REPO/.claude-plugin" "$TEST_REPO/src/published/scripts"
    printf '{"name":"mefisto","version":"1.2.3"}\n' > "$TEST_REPO/.claude-plugin/plugin.json"
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
  'rev-parse HEAD'|'rev-parse origin/main') printf '0123456789abcdef0123456789abcdef01234567\n' ;;
  'status --porcelain') ;;
  'tag -l') printf 'v1.2.2\n' ;;
  'show origin/main:.claude-plugin/plugin.json') cat "$TEST_REPO/.claude-plugin/plugin.json" ;;
  'rev-list --count') printf '0\n' ;;
  'fetch origin'|'push origin'|'tag -a'|'tag -d') ;;
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
  'release create') [ "${GH_CREATE_RC:-0}" = 0 ] || exit "$GH_CREATE_RC"; printf 'https://example.invalid/release\n' ;;
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
printf '{"version":"%s","commit":"%s"}\n' "${MANIFEST_VERSION:-1.2.3}" "${MANIFEST_COMMIT:-0123456789abcdef0123456789abcdef01234567}" > "$stage/mefisto-manifest.json"
tar -czf "$out/$name" -C "$stage" mefisto-manifest.json
(cd "$out" && shasum -a 256 "$name" > "$name.sha256")
[ "${CORRUPT_CHECKSUM:-0}" != 1 ] || printf x >> "$out/$name"
printf '%s\n%s\n' "$out/$name" "$out/$name.sha256"
EOF
    chmod +x "$BIN/git" "$BIN/gh" "$TEST_REPO/src/published/scripts/package-opencode-release.sh"
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
assert_contains "$EVENTS" 'git tag -a v1.2.3 -m Release v1.2.3' 'crea el tag unico tras validar assets'
assert_contains "$EVENTS" 'git push origin v1.2.3' 'sube el mismo tag SemVer'
assert_contains "$EVENTS" 'gh release create v1.2.3 --title v1.2.3 --notes-file' 'crea el release con notas'
assert_contains "$EVENTS" 'mefisto-opencode-v1.2.3.tar.gz' 'adjunta el tarball con nombre canonico'
assert_contains "$EVENTS" 'mefisto-opencode-v1.2.3.tar.gz.sha256' 'adjunta el checksum con nombre canonico'
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

setup manifest-fails; MANIFEST_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_release; rc=$?
[ "$rc" -ne 0 ] && pass 'un commit de manifiesto ajeno aborta' || fail 'el commit ajeno deberia abortar'
assert_absent "$EVENTS" 'git tag -a' 'no crea tag si el manifiesto no es HEAD/origin/main'
assert_cleaned 'limpia el temporal tras manifiesto invalido'

printf '[C] Fallo posterior al tag\n'
setup github-fails; GH_CREATE_RC=9 run_release; rc=$?
[ "$rc" -ne 0 ] && pass 'el fallo de GitHub mantiene fail-loud' || fail 'el fallo de GitHub deberia abortar'
assert_contains "$EVENTS" 'git push origin v1.2.3' 'el tag ya fue subido antes del fallo remoto'
assert_contains "$TEST_REPO/out" 'El tag ya esta pusheado' 'el diagnostico identifica el tag existente'
assert_contains "$TEST_REPO/out" 'gh release create v1.2.3' 'el diagnostico ofrece recuperacion sin reeditar version'
assert_contains "$TEST_REPO/out" 'mefisto-opencode-v1.2.3.tar.gz' 'la recuperacion nombra ambos assets'
assert_cleaned 'limpia el temporal tras fallo de GitHub'

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
