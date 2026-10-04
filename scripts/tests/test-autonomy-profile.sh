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
run_at() { local cwd="$1"; shift; (cd "$cwd" && bash "$SCRIPT" "$@"); }

MAIN="$TMP/main"; make_project "$MAIN"
echo '[1] Preview, approval e inspección del proyecto principal'
PREVIEW="$(run_at "$MAIN" preview --project-root "$MAIN")"; RC=$?
DIGEST="$(printf '%s' "$PREVIEW" | jq -r .expectedDigest)"
[ "$RC" -eq 0 ] && printf '%s' "$PREVIEW" | jq -e '.profile.id == "operacion-local" and (.administration | length == 1)' >/dev/null && [ ! -e "$MAIN/.mefisto/pipeline/autonomy/consent.json" ] && pass 'preview es solo lectura y muestra perfil, grants y digest' || fail "preview no cumplio el contrato: $PREVIEW"
run_at "$MAIN" approve --project-root "$MAIN" --expected-digest "$DIGEST" >/dev/null; RC=$?
INSPECT="$(run_at "$MAIN" inspect --project-root "$MAIN")"; IRC=$?
[ "$RC" -eq 0 ] && [ "$IRC" -eq 0 ] && printf '%s' "$INSPECT" | jq -e '.status == "ready" and .reasonCode == "CONSENT_APPROVED"' >/dev/null && pass 'approve registra exactamente el digest y inspect queda ready' || fail 'approve o inspect principal fallaron'

echo '[2] Worktree comparte identidad Git; proyecto ajeno no'
WORKTREE="$TMP/worktree"; git -C "$MAIN" worktree add -q "$WORKTREE" -b prueba-worktree
WORKTREE_INSPECT="$(run_at "$WORKTREE" inspect --project-root "$MAIN")"; WRC=$?
OTHER="$TMP/other"; make_project "$OTHER"
OTHER_INSPECT="$(run_at "$OTHER" inspect --project-root "$OTHER")"; ORC=$?
run_at "$OTHER" inspect --project-root "$MAIN" >/dev/null 2>&1; XRC=$?
mkdir -p "$OTHER/.mefisto/pipeline/autonomy"
cp "$MAIN/.mefisto/pipeline/autonomy/consent.json" "$OTHER/.mefisto/pipeline/autonomy/consent.json"
FOREIGN_INSPECT="$(run_at "$OTHER" inspect --project-root "$OTHER")"; FRC=$?
LEGACY="$TMP/legacy"; mkdir -p "$LEGACY/.claude"; printf '{}' > "$LEGACY/.claude/harness.config.json"; git -C "$LEGACY" init -q
LEGACY_INSPECT="$(run_at "$LEGACY" inspect --project-root "$LEGACY")"; LRC=$?
[ "$WRC" -eq 0 ] && printf '%s' "$WORKTREE_INSPECT" | jq -e '.status == "ready"' >/dev/null \
  && [ "$ORC" -eq 1 ] && printf '%s' "$OTHER_INSPECT" | jq -e '.status == "needs-approval"' >/dev/null \
  && [ "$XRC" -eq 2 ] && [ "$FRC" -eq 1 ] && printf '%s' "$FOREIGN_INSPECT" | jq -e '.status == "conflict" and .reasonCode == "PROJECT_MISMATCH"' >/dev/null \
  && [ "$LRC" -eq 0 ] && printf '%s' "$LEGACY_INSPECT" | jq -e '.status == "disabled" and .reasonCode == "NO_PROFILE"' >/dev/null \
  && pass 'worktree verifica la raiz aprobada, proyecto ajeno entra en conflicto y legacy queda deshabilitado' || fail 'aislamiento de proyecto/worktree incorrecto'

echo '[3] Cambios, repetición, revocación y registros incompatibles'
jq '.autonomy.commands += ["purge-store"]' "$MAIN/.mefisto/harness.config.json" > "$MAIN/.mefisto/harness.config.tmp" && mv "$MAIN/.mefisto/harness.config.tmp" "$MAIN/.mefisto/harness.config.json"
run_at "$MAIN" approve --project-root "$MAIN" --expected-digest "$DIGEST" >/dev/null 2>&1; MRC=$?
AFTER="$(run_at "$MAIN" inspect --project-root "$MAIN")"; ARC=$?
NEW_DIGEST="$(run_at "$MAIN" preview --project-root "$MAIN" | jq -r .expectedDigest)"
run_at "$MAIN" approve --project-root "$MAIN" --expected-digest "$NEW_DIGEST" >/dev/null; RRC=$?
CONSENT_BEFORE_REPEAT="$(jq -cS . "$MAIN/.mefisto/pipeline/autonomy/consent.json")"
run_at "$MAIN" approve --project-root "$MAIN" --expected-digest "$NEW_DIGEST" >/dev/null; RRC2=$?
CONSENT_AFTER_REPEAT="$(jq -cS . "$MAIN/.mefisto/pipeline/autonomy/consent.json")"
run_at "$MAIN" revoke --project-root "$MAIN" >/dev/null; VRC=$?
REVOKED_RECORD="$(jq -cS . "$MAIN/.mefisto/pipeline/autonomy/consent.json")"
run_at "$MAIN" revoke --project-root "$MAIN" >/dev/null; VRC2=$?
REVOKED_RECORD_2="$(jq -cS . "$MAIN/.mefisto/pipeline/autonomy/consent.json")"
REVOKED="$(run_at "$MAIN" inspect --project-root "$MAIN")"; VIRC=$?
printf '{malformed' > "$MAIN/.mefisto/pipeline/autonomy/consent.json"
CORRUPT_INSPECT="$(run_at "$MAIN" inspect --project-root "$MAIN")"; CIRC=$?
CORRUPT_PREVIEW="$(run_at "$MAIN" preview --project-root "$MAIN")"; CPRC=$?
run_at "$MAIN" approve --project-root "$MAIN" --expected-digest "$NEW_DIGEST" >/dev/null 2>&1; CRC=$?
[ "$MRC" -eq 2 ] && [ "$ARC" -eq 1 ] && printf '%s' "$AFTER" | jq -e '.status == "needs-approval"' >/dev/null \
  && [ "$RRC" -eq 0 ] && [ "$RRC2" -eq 0 ] && [ "$CONSENT_BEFORE_REPEAT" = "$CONSENT_AFTER_REPEAT" ] \
  && [ "$VRC" -eq 0 ] && [ "$VRC2" -eq 0 ] && [ "$REVOKED_RECORD" = "$REVOKED_RECORD_2" ] \
  && [ "$VIRC" -eq 0 ] && printf '%s' "$REVOKED" | jq -e '.status == "disabled" and .reasonCode == "CONSENT_REVOKED"' >/dev/null \
  && [ "$CIRC" -eq 1 ] && printf '%s' "$CORRUPT_INSPECT" | jq -e '.status == "conflict" and .reasonCode == "INVALID_CONSENT"' >/dev/null \
  && [ "$CPRC" -eq 0 ] && printf '%s' "$CORRUPT_PREVIEW" | jq -e '.expectedDigest == $digest' --arg digest "$NEW_DIGEST" >/dev/null \
  && [ "$CRC" -eq 2 ] && pass 'cambio exige digest nuevo, escrituras son idempotentes y registro corrupto no se sobrescribe' || fail "ciclo de cambio/revocacion incorrecto: $MRC/$ARC/$RRC/$RRC2/$VRC/$VRC2/$VIRC/$CIRC/$CPRC/$CRC"

echo '[4] Declaraciones invalidas, symlinks y clausura publicada'
INVALID="$TMP/invalid"; make_project "$INVALID"
jq '.autonomy=false' "$INVALID/.mefisto/harness.config.json" > "$INVALID/.mefisto/config.tmp" && mv "$INVALID/.mefisto/config.tmp" "$INVALID/.mefisto/harness.config.json"
INVALID_RESULT="$(run_at "$INVALID" inspect --project-root "$INVALID")"; IRC=$?
SYMLINKED="$TMP/symlinked"; make_project "$SYMLINKED"
mv "$SYMLINKED/.mefisto" "$SYMLINKED/state"
ln -s state "$SYMLINKED/.mefisto"
run_at "$SYMLINKED" approve --project-root "$SYMLINKED" --expected-digest "$DIGEST" >/dev/null 2>&1; SRC=$?
PACKAGED=1
for runtime in claude opencode; do
    cmp -s "$SCRIPT" "$REPO_ROOT/dist/$runtime/scripts/autonomy-profile.sh" || PACKAGED=0
    cmp -s "$REPO_ROOT/src/published/contract/autonomy-profile.validate.jq" "$REPO_ROOT/dist/$runtime/src/published/contract/autonomy-profile.validate.jq" || PACKAGED=0
    jq -e '.assets[] | select(.destination == "scripts/autonomy-profile.sh")' "$REPO_ROOT/dist/$runtime/.mefisto-generated-assets.json" >/dev/null || PACKAGED=0
done
[ "$IRC" -eq 1 ] && printf '%s' "$INVALID_RESULT" | jq -e '.status == "conflict" and .reasonCode == "INVALID_PROFILE"' >/dev/null \
  && [ "$SRC" -eq 2 ] && [ ! -e "$SYMLINKED/state/pipeline/autonomy/consent.json" ] && [ "$PACKAGED" -eq 1 ] \
  && pass 'perfil falso no se trata como ausente, symlink no escapa y ambos adaptadores contienen la clausura' || fail 'validacion, symlink o packaging incorrecto'

echo "Resultado: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
