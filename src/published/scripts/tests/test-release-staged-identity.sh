#!/usr/bin/env bash
# La identidad de la release se lee de mefisto-manifest.json: desde una release OpenCode
# empaquetada (sin src/published/release-identity.json) los scripts de ejecucion deben operar.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
WORK="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq() { [ "$1" = "$2" ] && pass "$3" || fail "$3 (esperado '$2', obtenido '$1')"; }

[ -d "$REPO_ROOT/dist/opencode/scripts" ] || { echo 'falta dist/opencode'; exit 1; }
SRC="$WORK/repo"; mkdir -p "$SRC/src/published" "$SRC/dist" "$SRC/.claude-plugin"
cp -R "$REPO_ROOT/src/published/scripts" "$SRC/src/published/scripts"
cp "$REPO_ROOT/src/published/release-identity.json" "$SRC/src/published/"
cp "$REPO_ROOT/.claude-plugin/plugin.json" "$SRC/.claude-plugin/"
cp -R "$REPO_ROOT/dist/opencode" "$SRC/dist/opencode"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SRC/src/published/scripts/generate-published-adapters.sh"
chmod +x "$SRC/src/published/scripts/generate-published-adapters.sh"

OUT="$WORK/out"
MEFISTO_PACKAGE_REPO_ROOT="$SRC" bash "$SRC/src/published/scripts/package-opencode-release.sh" --output "$OUT" >/dev/null 2>&1 || { echo 'fallo el empaquetado'; exit 1; }
REL="$WORK/release"; mkdir -p "$REL"; tar -xzf "$OUT"/mefisto-opencode-v*.tar.gz -C "$REL"
[ -f "$REL/mefisto-manifest.json" ] || { [ "$(ls "$REL" | wc -l)" -eq 1 ] && REL="$REL/$(ls "$REL")"; }
VERSION="$(jq -r .version "$REL/mefisto-manifest.json")"
[ ! -e "$REL/src/published/release-identity.json" ] && pass 'la release staged no trae release-identity.json' || fail 'la release trae release-identity.json'
mkdir -p "$REL/src/published/contract"
[ -f "$REL/src/published/contract/command-entry.json" ] || cp "$REPO_ROOT/src/published/contract/command-entry.json" "$REL/src/published/contract/"

echo '[1] execution-context desde la release staged'
FN="$(sed -n '/^release_id()/,/^}/p' "$REL/scripts/execution-context.sh")"
RID="$(RELEASE_FILE="$REL/mefisto-manifest.json"; eval "$FN"; release_id)"
eq "$RID" "$VERSION" 'release_id coincide con la version del manifiesto'
RID_BAD="$(RELEASE_FILE="$WORK/no-existe.json"; eval "$FN"; release_id 2>&1)"
case "$RID_BAD" in *mefisto-manifest.json*) pass 'release_id sin manifiesto: error explicito que lo nombra' ;; *) fail "release_id sin manifiesto no nombra el manifiesto: $RID_BAD" ;; esac
grep -q 'PACKAGE_ROOT/mefisto-manifest.json' "$REL/scripts/execution-context.sh" && pass 'RELEASE_FILE apunta al manifiesto del paquete' || fail 'RELEASE_FILE no apunta al manifiesto'

echo '[2] preflight desde la release staged'
C="$WORK/consumer"; mkdir -p "$C/.mefisto"; git -C "$C" init -q -b main
git -C "$C" config user.email t@example.com; git -C "$C" config user.name t
printf '.mefisto/\n' > "$C/.gitignore"; printf '{}\n' > "$C/.mefisto/harness.config.json"; git -C "$C" add . && git -C "$C" commit -qm base
PLAN='{"schemaVersion":1,"launchKind":"sequential","source":"direct","issues":[{"number":1,"pipelineKind":"tooling"}],"requestedOperations":[]}'
PO="$(cd "$C" && printf '%s' "$PLAN" | bash "$REL/scripts/autonomy-preflight.sh" --project-root "$C" --runtime opencode 2>"$WORK/err")"; RC=$?
[ "$RC" -ne 2 ] && pass "no aborta por contratos (exit $RC)" || fail "aborto con exit 2: $(cat "$WORK/err")"
printf '%s' "$PO" | jq -e '.status' >/dev/null 2>&1 && pass 'reporta el estado del perfil' || fail 'sin sobre de estado'

echo '[3] manifiesto ausente o invalido'
for mode in absent sinversion; do
    if [ "$mode" = absent ]; then rm -f "$REL/mefisto-manifest.json"; else printf '{"schemaVersion":1}\n' > "$REL/mefisto-manifest.json"; fi
    (cd "$C" && printf '%s' "$PLAN" | bash "$REL/scripts/autonomy-preflight.sh" --project-root "$C" --runtime opencode >/dev/null 2>"$WORK/err"); RC=$?
    eq "$RC" 2 "preflight $mode: exit 2"
    grep -q 'mefisto-manifest.json' "$WORK/err" && pass "preflight $mode: nombra el manifiesto" || fail "preflight $mode: no nombra el manifiesto"
done


printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
