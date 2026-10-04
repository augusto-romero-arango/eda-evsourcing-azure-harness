#!/usr/bin/env bash
# Contrato local del lifecycle de consentimiento; no usa red ni credenciales.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/autonomy-profile.sh"
FIXTURE="$REPO_ROOT/src/published/scripts/tests/fixtures/autonomy/profile.json"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

make_project() {
    local root="$1"
    mkdir -p "$root/.mefisto"
    cp "$FIXTURE" "$root/.mefisto/harness.config.json"
    git -C "$root" init -q
    git -C "$root" config user.email test@example.invalid
    git -C "$root" config user.name test
    git -C "$root" add . && git -C "$root" commit -qm inicial
}
run() { bash "$SCRIPT" "$@"; }

MAIN="$TMP/main"; make_project "$MAIN"
echo '[1] Preview, approval e inspección del proyecto principal'
PREVIEW="$(run preview --project-root "$MAIN")"; RC=$?
DIGEST="$(printf '%s' "$PREVIEW" | jq -r .expectedDigest)"
[ "$RC" -eq 0 ] && printf '%s' "$PREVIEW" | jq -e '.profile.id == "operacion-local" and (.administration | length == 1)' >/dev/null && [ ! -e "$MAIN/.mefisto/pipeline/autonomy/consent.json" ] && pass 'preview es solo lectura y muestra perfil, grants y digest' || fail "preview no cumplio el contrato: $PREVIEW"
run approve --project-root "$MAIN" --expected-digest "$DIGEST" >/dev/null; RC=$?
INSPECT="$(run inspect --project-root "$MAIN")"; IRC=$?
[ "$RC" -eq 0 ] && [ "$IRC" -eq 0 ] && printf '%s' "$INSPECT" | jq -e '.status == "ready" and .reasonCode == "CONSENT_APPROVED"' >/dev/null && pass 'approve registra exactamente el digest y inspect queda ready' || fail 'approve o inspect principal fallaron'

echo '[2] Worktree comparte identidad Git; proyecto ajeno no'
WORKTREE="$TMP/worktree"; git -C "$MAIN" worktree add -q "$WORKTREE" -b prueba-worktree
WORKTREE_INSPECT="$(cd "$WORKTREE" && run inspect --project-root "$MAIN")"; WRC=$?
OTHER="$TMP/other"; make_project "$OTHER"
OTHER_INSPECT="$(run inspect --project-root "$OTHER")"; ORC=$?
[ "$WRC" -eq 0 ] && printf '%s' "$WORKTREE_INSPECT" | jq -e '.status == "ready"' >/dev/null && [ "$ORC" -eq 1 ] && printf '%s' "$OTHER_INSPECT" | jq -e '.status == "needs-approval"' >/dev/null && pass 'worktree lee la raiz aprobada compartida y proyecto ajeno no hereda consentimiento' || fail 'aislamiento de proyecto/worktree incorrecto'

echo '[3] Cambios, repetición, revocación y registros incompatibles'
jq '.autonomy.commands += ["purge-store"]' "$MAIN/.mefisto/harness.config.json" > "$MAIN/.mefisto/harness.config.tmp" && mv "$MAIN/.mefisto/harness.config.tmp" "$MAIN/.mefisto/harness.config.json"
run approve --project-root "$MAIN" --expected-digest "$DIGEST" >/dev/null 2>&1; MRC=$?
AFTER="$(run inspect --project-root "$MAIN")"; ARC=$?
NEW_DIGEST="$(run preview --project-root "$MAIN" | jq -r .expectedDigest)"
run approve --project-root "$MAIN" --expected-digest "$NEW_DIGEST" >/dev/null; RRC=$?
run approve --project-root "$MAIN" --expected-digest "$NEW_DIGEST" >/dev/null; RRC2=$?
run revoke --project-root "$MAIN" >/dev/null; VRC=$?
REVOKED="$(run inspect --project-root "$MAIN")"; VIRC=$?
printf '{malformed' > "$MAIN/.mefisto/pipeline/autonomy/consent.json"
run approve --project-root "$MAIN" --expected-digest "$NEW_DIGEST" >/dev/null 2>&1; CRC=$?
[ "$MRC" -eq 2 ] && [ "$ARC" -eq 1 ] && printf '%s' "$AFTER" | jq -e '.status == "needs-approval"' >/dev/null && [ "$RRC" -eq 0 ] && [ "$RRC2" -eq 0 ] && [ "$VRC" -eq 0 ] && [ "$VIRC" -eq 0 ] && printf '%s' "$REVOKED" | jq -e '.status == "disabled" and .reasonCode == "CONSENT_REVOKED"' >/dev/null && [ "$CRC" -eq 2 ] && pass 'cambio exige digest nuevo, operaciones son idempotentes y registro corrupto no se sobrescribe' || fail "ciclo de cambio/revocacion incorrecto: $MRC/$ARC/$RRC/$RRC2/$VRC/$VIRC/$CRC"

echo "Resultado: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
