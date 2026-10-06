#!/usr/bin/env bash
# La identidad de la release se lee de mefisto-manifest.json: desde una release OpenCode
# empaquetada (sin src/published/release-identity.json) los scripts de ejecucion deben operar.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
WORK="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
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

mkrepo() {
    mkdir -p "$1/.mefisto"; git -C "$1" init -q -b main
    git -C "$1" config user.email t@example.com; git -C "$1" config user.name t
    printf '.mefisto/\n' > "$1/.gitignore"; git -C "$1" add . && git -C "$1" commit -qm base
}
C="$WORK/consumer"; mkrepo "$C"; printf '{}\n' > "$C/.mefisto/harness.config.json"
P="$WORK/profiled"; mkrepo "$P"; cp "$REPO_ROOT/src/published/scripts/tests/fixtures/autonomy/profile.json" "$P/.mefisto/harness.config.json"
EC="$REL/scripts/execution-context.sh"; PROFILE="$REL/scripts/autonomy-profile.sh"
DIGEST="$(cd "$P" && bash "$PROFILE" preview --project-root "$P" | jq -r .expectedDigest)"
(cd "$P" && bash "$PROFILE" approve --project-root "$P" --expected-digest "$DIGEST" >/dev/null)
prep() { jq -cn --arg r "$P" --arg c "$1" '{schemaVersion:1,projectRoot:$r,runId:"run1",contextId:$c,rootCommand:"sequential",source:"command",runtime:{id:"opencode",version:"1"},leaseId:"lease-1"}'; }

echo '[1] execution-context desde la release staged'
PO="$(prep ctx1 | bash "$EC" prepare 2>"$WORK/err")"; RC=$?
eq "$RC" 0 "prepare desde la release staged (err: $(cat "$WORK/err"))"
eq "$(jq -r .contract.release "$P/.mefisto/pipeline/autonomy/runs/run1/contexts/ctx1.json" 2>/dev/null)" "$VERSION" 'release_id coincide con la version del manifiesto'

echo '[2] preflight desde la release staged'
PLAN='{"schemaVersion":1,"launchKind":"sequential","source":"direct","issues":[{"number":1,"pipelineKind":"tooling"}],"requestedOperations":[]}'
PO="$(cd "$C" && printf '%s' "$PLAN" | bash "$REL/scripts/autonomy-preflight.sh" --project-root "$C" --runtime opencode 2>"$WORK/err")"; RC=$?
eq "$(printf '%s' "$PO" | jq -r .status 2>/dev/null)/$RC" 'legacy/0' "sin perfil ni contexto: flujo legacy, no exit 2 por contratos ($(cat "$WORK/err"))"
CTX="$C/.mefisto/pipeline/autonomy/runs/run1/contexts/ctx1.json"
CPLAN='{"schemaVersion":1,"launchKind":"sequential","source":"command","issues":[{"number":1,"pipelineKind":"tooling"}],"requestedOperations":[]}'
PO="$(cd "$C" && printf '%s' "$CPLAN" | bash "$REL/scripts/autonomy-preflight.sh" --project-root "$C" --runtime opencode --context "$CTX" 2>"$WORK/err")"; RC=$?
eq "$(printf '%s' "$PO" | jq -r '.status + "/" + ([.checks[] | select(.code == "PROFILE_CONSENT")][0].actionCode // "")' 2>/dev/null)/$RC" 'blocked/NO_PROFILE_WITH_CONTEXT/1' "sin perfil con contexto: reporta el estado del perfil ($(cat "$WORK/err"))"

echo '[3] manifiesto ausente o invalido'
for mode in absent sinversion; do
    if [ "$mode" = absent ]; then rm -f "$REL/mefisto-manifest.json"; else printf '{"schemaVersion":1}\n' > "$REL/mefisto-manifest.json"; fi
    PO="$(prep "ctx-$mode" | bash "$EC" prepare 2>"$WORK/err")"; RC=$?
    eq "$(printf '%s' "$PO" | jq -r .reasonCode 2>/dev/null)/$RC" 'RELEASE_UNKNOWN/2' "execution-context $mode: falla con RELEASE_UNKNOWN"
    grep -q 'mefisto-manifest.json' "$WORK/err" && pass "execution-context $mode: nombra el manifiesto" || fail "execution-context $mode: no nombra el manifiesto"
    (cd "$C" && printf '%s' "$PLAN" | bash "$REL/scripts/autonomy-preflight.sh" --project-root "$C" --runtime opencode >/dev/null 2>"$WORK/err"); RC=$?
    eq "$RC" 2 "preflight $mode: exit 2"
    grep -q 'mefisto-manifest.json' "$WORK/err" && pass "preflight $mode: nombra el manifiesto" || fail "preflight $mode: no nombra el manifiesto"
done


printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
