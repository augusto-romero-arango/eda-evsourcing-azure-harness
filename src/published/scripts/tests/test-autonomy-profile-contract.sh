#!/usr/bin/env bash
# Contrato puro de perfil/consentimiento: Bash 3.2, jq y shasum.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
VALIDATOR="$REPO_ROOT/src/published/contract/autonomy-profile.validate.jq"
FIXTURES="$HERE/fixtures/autonomy"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_result() {
    local label="$1" input="$2" status="$3" reason="$4" output rc
    output="$(printf '%s' "$input" | jq -c -f "$VALIDATOR")"; rc=$?
    [ "$rc" -eq 0 ] && printf '%s' "$output" | jq -e --arg s "$status" --arg r "$reason" \
      'keys == ["profile", "profileDigest", "projectId", "reasonCode", "schemaVersion", "status"] and .schemaVersion == 1 and .status == $s and .reasonCode == $r' >/dev/null \
      && pass "$label" || fail "$label: $output"
}

printf '[pre] sintaxis, catalogo y normalizacion\n'
jq -n -f "$VALIDATOR" >/dev/null 2>&1 && pass 'validador compila' || fail 'validador no compila'
CATALOG="$(for command in "$REPO_ROOT"/src/published/commands/*.md; do basename "$command" .md; done | jq -R . | jq -sc .)"
[ "$(printf '%s' "$CATALOG" | jq 'length')" -eq 27 ] && pass 'catalogo generado contiene los 27 comandos publicados' || fail 'catalogo publicado inesperado'
DIGEST="$(jq -cS '.autonomy' "$FIXTURES/profile.json" | shasum -a 256 | cut -d ' ' -f 1)"
EXPECTED_DIGEST='2cb548af944f8656bdceb0ecb8ece37fda2238f67180102437b2a868b178b07d'
[ "$DIGEST" = "$EXPECTED_DIGEST" ] && pass 'normalizacion compacta ordenada tiene hash estable' || fail "hash estable divergente: $DIGEST"
EXTRA_DIGEST="$(jq -cS '.autonomy' "$FIXTURES/profile.json" | shasum -a 256 | cut -d ' ' -f 1)"
REVISION_DIGEST="$(jq -cS '.autonomy' "$FIXTURES/profile-revision-2.json" | shasum -a 256 | cut -d ' ' -f 1)"
COMMANDS_DIGEST="$(jq -cS '.autonomy.commands += ["purge-store"]' "$FIXTURES/profile.json" | shasum -a 256 | cut -d ' ' -f 1)"
GRANTS_DIGEST="$(jq -cS '.autonomy.administration[0].resources += ["record:audit"]' "$FIXTURES/profile.json" | shasum -a 256 | cut -d ' ' -f 1)"
[ "$DIGEST" = "$EXTRA_DIGEST" ] && [ "$DIGEST" != "$REVISION_DIGEST" ] && [ "$DIGEST" != "$COMMANDS_DIGEST" ] && [ "$DIGEST" != "$GRANTS_DIGEST" ] && pass 'dato ajeno no cambia digest y revision, comandos y grants si' || fail 'normalizacion no aisla autonomy'

PROFILE="$(jq -c '.autonomy' "$FIXTURES/profile.json")"
CONTEXT="$(jq -cn --arg d "$DIGEST" '{projectId:"proyecto-demo",profileDigest:$d}')"
BASE="$(jq -cn --argjson p "$PROFILE" --argjson x "$CONTEXT" --argjson c "$CATALOG" '{profile:$p,consent:null,context:$x,catalog:$c}')"
assert_result 'perfil sin grants administrativos sigue siendo valido' "$(printf '%s' "$BASE" | jq '.profile.administration=[]')" needs-approval CONSENT_REQUIRED
assert_result 'perfil valido sin consentimiento requiere aprobacion' "$BASE" needs-approval CONSENT_REQUIRED
APPROVED="$(printf '%s' "$BASE" | jq --arg d "$DIGEST" '.consent={schemaVersion:1,projectId:"proyecto-demo",profileDigest:$d,decision:"approved",recordedAt:"2026-10-03T12:00:00Z"}')"
assert_result 'aprobacion coincidente queda lista' "$APPROVED" ready CONSENT_APPROVED
REVOKED="$(printf '%s' "$APPROVED" | jq '.consent.decision="revoked"')"
assert_result 'revocacion coincidente deshabilita' "$REVOKED" disabled CONSENT_REVOKED
assert_result 'ausencia de declaracion deshabilita' "$(printf '%s' "$BASE" | jq '.profile=null')" disabled NO_PROFILE
assert_result 'digest de consentimiento antiguo requiere aprobacion' "$(printf '%s' "$APPROVED" | jq '.consent.profileDigest="0000000000000000000000000000000000000000000000000000000000000000"')" needs-approval CONSENT_DIGEST_MISMATCH
assert_result 'proyecto ajeno entra en conflicto' "$(printf '%s' "$APPROVED" | jq '.consent.projectId="otro-proyecto"')" conflict PROJECT_MISMATCH
assert_result 'consentimiento malformado entra en conflicto' "$(printf '%s' "$APPROVED" | jq 'del(.consent.recordedAt)')" conflict INVALID_CONSENT
assert_result 'perfil malformado entra en conflicto' "$(printf '%s' "$BASE" | jq '.profile.revision=0')" conflict INVALID_PROFILE
assert_result 'comando desconocido entra en conflicto' "$(printf '%s' "$BASE" | jq '.profile.commands=["inexistente"]')" conflict INVALID_PROFILE
assert_result 'grant fuera de comandos entra en conflicto' "$(printf '%s' "$BASE" | jq '.profile.administration[0].command="sequential" | .profile.commands=["bitacora"]')" conflict INVALID_PROFILE
assert_result 'digest de plan invalido entra en conflicto' "$(printf '%s' "$BASE" | jq '.profile.administration[0].planDigest="corto"')" conflict INVALID_PROFILE
assert_result 'clave cruda no integra el perfil' "$(printf '%s' "$BASE" | jq '.profile.runtimePermission="allow-all"')" conflict INVALID_PROFILE
assert_result 'catalogo malformado entra en conflicto' "$(printf '%s' "$BASE" | jq '.catalog=["sequential","sequential"]')" conflict INVALID_CATALOG
assert_result 'envelope con campo extra entra en conflicto' "$(printf '%s' "$BASE" | jq '.extra=true')" conflict INVALID_ENVELOPE

exit "$FAIL"
