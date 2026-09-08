#!/usr/bin/env bash
# Pruebas del diagnostico de identidad: fixtures locales, Bash 3.2 y jq.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
DIAGNOSTIC="$REPO_ROOT/src/published/scripts/diagnose-installation-identity.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_status() {
    local output="$1" expected="$2" label="$3"
    [ "$(printf '%s' "$output" | jq -r .status 2>/dev/null)" = "$expected" ] && pass "$label" || fail "$label"
}
make_manifest() {
    local root="$1" runtime="$2" version="$3" commit="$4"
    mkdir -p "$root"
    jq -n --arg runtime "$runtime" --arg version "$version" --arg commit "$commit" \
        '{schemaVersion:1, runtime:$runtime, version:$version, commit:$commit}' > "$root/mefisto-manifest.json"
}
run_diagnostic() { bash "$DIAGNOSTIC" --claude-root "$1" --opencode-root "$2"; }

CLAUDE="$WORK/claude"; OPENCODE="$WORK/opencode"
COMMIT_A='0123456789abcdef0123456789abcdef01234567'
COMMIT_B='abcdef0123456789abcdef0123456789abcdef01'

printf '[pre] sintaxis y contrato JSON\n'
bash -n "$DIAGNOSTIC" && pass 'diagnostico Bash valido' || fail 'diagnostico Bash invalido'

make_manifest "$CLAUDE" claude 1.2.3 "$COMMIT_A"; make_manifest "$OPENCODE" opencode 1.2.3 "$COMMIT_A"
OUT="$(run_diagnostic "$CLAUDE" "$OPENCODE")"; assert_status "$OUT" aligned 'identidades identicas quedan alineadas sin degradacion'
[ "$(printf '%s' "$OUT" | jq -r '.message // empty')" = '' ] && pass 'caso sano no emite mensaje visible' || fail 'caso sano no debio emitir mensaje visible'

make_manifest "$OPENCODE" opencode 2.0.0 "$COMMIT_A"
OUT="$(run_diagnostic "$CLAUDE" "$OPENCODE")"; assert_status "$OUT" drift 'version divergente se distingue como deriva'
printf '%s' "$OUT" | jq -e --arg commit "$COMMIT_A" '.claude.version == "1.2.3" and .opencode.version == "2.0.0" and .claude.commit == $commit and .opencode.commit == $commit and .actions.claude == "actualizar el plugin Claude" and (.actions.opencode | contains("activar la release OpenCode")) and (.message | contains("actualice el plugin Claude") and contains("active la release OpenCode"))' >/dev/null && pass 'deriva de version nombra ambas identidades y acciones' || fail 'deriva de version no informa valores y acciones'

make_manifest "$OPENCODE" opencode 1.2.3 "$COMMIT_B"
OUT="$(run_diagnostic "$CLAUDE" "$OPENCODE")"; assert_status "$OUT" drift 'commit divergente se distingue como deriva'
printf '%s' "$OUT" | jq -e --arg first "$COMMIT_A" --arg second "$COMMIT_B" '.claude.commit == $first and .opencode.commit == $second' >/dev/null && pass 'deriva de commit conserva ambos commits' || fail 'deriva de commit no conserva ambos commits'

rm -rf "$OPENCODE"
OUT="$(run_diagnostic "$CLAUDE" "$OPENCODE")"; assert_status "$OUT" claude_only 'una sola instalacion no es falso positivo de deriva'

mkdir -p "$OPENCODE"
OUT="$(run_diagnostic "$CLAUDE" "$OPENCODE")"; assert_status "$OUT" metadata_missing 'metadata ausente se distingue de una instalacion ausente'
printf '%s' "$OUT" | jq -e '.opencode.state == "metadata_missing"' >/dev/null && pass 'metadata ausente tiene estado propio' || fail 'metadata ausente no tiene estado propio'

printf '{corrupta\n' > "$OPENCODE/mefisto-manifest.json"
OUT="$(run_diagnostic "$CLAUDE" "$OPENCODE")"; assert_status "$OUT" metadata_invalid 'metadata corrupta se distingue de deriva y metadata ausente'
printf '%s' "$OUT" | jq -e '.opencode.state == "metadata_invalid"' >/dev/null && pass 'metadata corrupta tiene estado propio' || fail 'metadata corrupta no tiene estado propio'

rm "$OPENCODE/mefisto-manifest.json"; ln -s "$CLAUDE/mefisto-manifest.json" "$OPENCODE/mefisto-manifest.json"
OUT="$(run_diagnostic "$CLAUDE" "$OPENCODE")"; assert_status "$OUT" metadata_invalid 'metadata no regular se reporta invalida, no ausente'

rm -rf "$CLAUDE" "$OPENCODE"
OUT="$(run_diagnostic "$CLAUDE" "$OPENCODE")"; assert_status "$OUT" none_available 'ausencia total se distingue de metadata ausente'
printf '%s' "$OUT" | jq -e '.schemaVersion == 1 and (.claude.runtime == "claude") and (.opencode.runtime == "opencode")' >/dev/null && pass 'salida es estable y parseable' || fail 'salida no respeta el contrato JSON'

run_diagnostic "$CLAUDE" "$OPENCODE" >/dev/null; [ "$?" -eq 0 ] && pass 'estados de diagnostico no son fallos fatales' || fail 'un estado informativo produjo fallo fatal'

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
