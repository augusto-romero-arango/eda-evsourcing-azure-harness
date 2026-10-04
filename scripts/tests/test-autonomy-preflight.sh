#!/usr/bin/env bash
# autonomy-preflight.sh contra una release copiada (sin checkout fuente), repos Git
# temporales y dobles de binarios: sin LLM, red, credenciales ni runtime real.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
FIXTURE="$REPO_ROOT/src/published/scripts/tests/fixtures/autonomy/profile.json"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); [ -z "${DEBUG_OUT:-}" ] || printf '    %s\n' "$OUT"; }
eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (esperado '$2', obtenido '$1')"; fi; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" GH_TOKEN=sentinel-no-debe-leerse
mkdir -p "$HOME"
[ -d "$REPO_ROOT/dist/opencode/scripts" ] || { echo 'falta dist/opencode (regenerar con generate-published-adapters.sh)'; exit 1; }
REL="$TMP/release"; cp -R "$REPO_ROOT/dist/opencode" "$REL"
# El empaquetado de release agrega identidad y catalogo de entrada; dist/ solo trae la clausura estatica.
cp "$REPO_ROOT/src/published/release-identity.json" "$REL/src/published/release-identity.json"
cp "$REPO_ROOT/src/published/contract/command-entry.json" "$REL/src/published/contract/command-entry.json"
PF="$REL/scripts/autonomy-preflight.sh"; PROFILE="$REL/scripts/autonomy-profile.sh"; EC="$REL/scripts/execution-context.sh"

# PATH aislado: jq/git/shasum reales, gh/dotnet/terraform como dobles que marcan si se ejecutan.
BIN="$TMP/bin"; mkdir -p "$BIN"
for b in jq git shasum sha256sum; do p="$(command -v "$b" 2>/dev/null || true)"; [ -z "$p" ] || ln -s "$p" "$BIN/$b"; done
RAN="$TMP/ran-marker"
mkstub() { printf '#!/bin/sh\necho "$0" >> "%s"\nexit 0\n' "$RAN" > "$BIN/$1"; chmod +x "$BIN/$1"; }
rmstub() { rm -f "$BIN/$1"; }
BASE_PATH="$BIN:/usr/bin:/bin"
mkstub gh

mkrepo() {
    mkdir -p "$1/.mefisto"; git -C "$1" init -q -b main
    git -C "$1" config user.email t@example.com; git -C "$1" config user.name t
    printf '.mefisto/\n' > "$1/.gitignore"; git -C "$1" add . && git -C "$1" commit -qm base
}
R="$TMP/consumer"; mkrepo "$R"; cp "$FIXTURE" "$R/.mefisto/harness.config.json"
NP="$TMP/noprofile"; mkrepo "$NP"; printf '{}\n' > "$NP/.mefisto/harness.config.json"

snap() { find "$R" "$NP" "$REL" -type f -not -path '*/.git/*' -not -path '*/pipeline/autonomy/*' -exec shasum {} + 2>/dev/null | sort | shasum | cut -d ' ' -f 1; }
plan() { # launchKind source pipelineKind... -> JSON
    local lk="$1" src="$2"; shift 2
    local i=0 issues='[]' k
    for k in "$@"; do i=$((i + 1)); issues="$(jq -c --argjson n "$i" --arg k "$k" '. + [{number:$n,pipelineKind:$k}]' <<< "$issues")"; done
    jq -cn --arg lk "$lk" --arg s "$src" --argjson i "$issues" '{schemaVersion:1,launchKind:$lk,source:$s,issues:$i,requestedOperations:[]}'
}
OUT=""; RC=0
pf() { # root runtime plan [context]
    local root="$1" rt="$2" body="$3" ctx="${4:-}" before after
    before="$(snap)"
    if [ -n "$ctx" ]; then OUT="$(cd "$root" && printf '%s' "$body" | PATH="$BASE_PATH" bash "$PF" --project-root "$root" --runtime "$rt" --context "$ctx" 2>/dev/null)"; RC=$?
    else OUT="$(cd "$root" && printf '%s' "$body" | PATH="$BASE_PATH" bash "$PF" --project-root "$root" --runtime "$rt" 2>/dev/null)"; RC=$?; fi
    after="$(snap)"
    [ "$before" = "$after" ] || fail 'el preflight modifico el consumidor o la release'
}
j() { printf '%s' "$OUT" | jq -r "$1 // empty"; }
chk() { printf '%s' "$OUT" | jq -r --arg c "$1" '[.checks[] | select(.code == $c)][0] | "\(.state)/\(.actionCode)"'; }
SEQ_TOOLING="$(plan sequential direct tooling tooling)"

echo '[1] Legacy: sin perfil y Claude sin adopcion'
pf "$NP" opencode "$SEQ_TOOLING"
eq "$(j .status)/$RC" 'legacy/0' 'NO_PROFILE sin contexto es legacy'
eq "$(j .admissionScope)" 'pre-dispatch' 'el sobre declara alcance previo al despacho'
pf "$R" claude "$SEQ_TOOLING"
eq "$(j .status)/$RC" 'legacy/0' 'Claude sin contexto conserva su flujo sin exigir recursos de otro runtime'

echo '[2] Consentimiento'
pf "$R" opencode "$SEQ_TOOLING"
eq "$(j .status)/$RC/$(chk PROFILE_CONSENT)" 'blocked/1/block/NEEDS_APPROVAL' 'perfil sin aprobar bloquea sin fallback'
[ ! -e "$R/.mefisto/pipeline/autonomy/consent.json" ] && pass 'el preflight no aprueba por su cuenta' || fail 'creo consentimiento'
DIGEST="$(cd "$R" && bash "$PROFILE" preview --project-root "$R" | jq -r .expectedDigest)"
(cd "$R" && bash "$PROFILE" approve --project-root "$R" --expected-digest "$DIGEST" >/dev/null)
pf "$R" opencode "$SEQ_TOOLING"
eq "$(j .status)/$RC" 'ready-to-dispatch/0' 'perfil aprobado y plan directo tooling queda ready-to-dispatch'
eq "$(chk ENTRY_ADMISSION)" 'not-applicable/DIRECT_INVOCATION' 'invocacion directa no inventa sesion interactiva'
eq "$(chk REMOTE_ACCESS)" 'deferred/REMOTE_UNVERIFIED' 'red/RBAC queda remote-unverified con owner'
eq "$(j '.resourcesDigest')" '' 'sin sesion no hay resourcesDigest'
eq "$(chk STAGE_ACTOR_GUARD)" "deferred/ACTOR_AND_PERMISSIONS_AT_STAGE" 'actor/permisos futuros se difieren al guard de etapa'
printf '%s' "$OUT" | jq -e '(.checks | all(.[]; .state != "deferred" or (.owner | test("run-published-agent|callback"))))' >/dev/null && pass 'todo deferred lleva owner concreto' || fail 'deferred sin owner'
[ ! -s "$RAN" ] && pass 'ningun binario doble fue ejecutado' || fail 'se ejecuto un binario'

echo '[3] Cambio de perfil y revocacion'
jq '.autonomy.revision = 2' "$R/.mefisto/harness.config.json" > "$TMP/c.json" && cp "$TMP/c.json" "$R/.mefisto/harness.config.json"
pf "$R" opencode "$SEQ_TOOLING"
eq "$(j .status)/$RC/$(chk PROFILE_CONSENT)" 'blocked/1/block/NEEDS_APPROVAL' 'cambio de perfil revalida y no llama approve'
cp "$FIXTURE" "$R/.mefisto/harness.config.json"
(cd "$R" && bash "$PROFILE" revoke --project-root "$R" >/dev/null)
pf "$R" opencode "$SEQ_TOOLING"
eq "$(j .status)/$RC/$(chk PROFILE_CONSENT)" 'blocked/1/block/CONSENT_REVOKED' 'CONSENT_REVOKED bloquea sin fallback'
(cd "$R" && bash "$PROFILE" approve --project-root "$R" --expected-digest "$DIGEST" >/dev/null)

echo '[4] Plan estricto y protocolo'
bad() { OUT="$(cd "$R" && printf '%s' "$2" | PATH="$BASE_PATH" bash "$PF" --project-root "$R" --runtime "${3:-opencode}" ${4:-} 2>/dev/null)"; RC=$?; eq "$RC" 2 "$1"; }
bad 'ids duplicados' '{"schemaVersion":1,"launchKind":"sequential","source":"direct","issues":[{"number":1,"pipelineKind":"tdd"},{"number":1,"pipelineKind":"tdd"}],"requestedOperations":[]}'
bad 'id no positivo' '{"schemaVersion":1,"launchKind":"sequential","source":"direct","issues":[{"number":0,"pipelineKind":"tdd"}],"requestedOperations":[]}'
bad 'pipelineKind desconocido' '{"schemaVersion":1,"launchKind":"sequential","source":"direct","issues":[{"number":1,"pipelineKind":"nube"}],"requestedOperations":[]}'
bad 'pipelineKind inconsistente con el catalogo' '{"schemaVersion":1,"launchKind":"sequential","source":"direct","issues":[{"number":1,"pipelineKind":"scaffold"}],"requestedOperations":[]}'
bad 'requestedOperations no vacio' '{"schemaVersion":1,"launchKind":"sequential","source":"direct","issues":[{"number":1,"pipelineKind":"tdd"}],"requestedOperations":["purge-store"]}'
bad 'clave extra' '{"schemaVersion":1,"launchKind":"sequential","source":"direct","issues":[{"number":1,"pipelineKind":"tdd"}],"requestedOperations":[],"policy":{}}'
bad 'JSON invalido' 'no-json'
bad 'source:command sin contexto' "$(plan sequential command tdd)"
bad 'source:direct con contexto' "$SEQ_TOOLING" opencode "--context $TMP/x.json"
bad 'runtime sin adaptador' "$SEQ_TOOLING" runtime-inexistente

echo '[5] Binarios y fuentes por rol'
SEQ_TDD="$(plan sequential direct tdd)"
pf "$R" opencode "$SEQ_TDD"
eq "$(j .status)/$RC/$(chk BINARY_dotnet)" 'incomplete/1/block/BINARY_MISSING' 'dotnet requerido y ausente es incomplete'
eq "$(chk SOURCE_domain-scaffolder_nuget-version)" 'deferred/SOURCE_CAPABILITY_UNVERIFIED' 'NuGet sin dotnet no se marca pass'
mkstub dotnet
pf "$R" opencode "$SEQ_TDD"
eq "$(j .status)/$RC/$(chk SOURCE_domain-scaffolder_nuget-version)" 'ready-to-dispatch/0/deferred/CONDITIONAL_SOURCE_AT_STAGE' 'NuGet condicional con dotnet disponible se difiere, no se consulta ni se pasa'
[ ! -s "$RAN" ] && pass 'dotnet nunca se ejecuto' || fail 'se ejecuto dotnet'
SEQ_IAC="$(plan sequential direct iac)"
pf "$R" opencode "$SEQ_IAC"
eq "$(j .status)/$RC/$(chk BINARY_terraform)" 'incomplete/1/block/BINARY_MISSING' 'terraform ausente es incomplete'
eq "$(chk SOURCE_infra-writer_provider-pin)" 'deferred/SOURCE_CAPABILITY_UNVERIFIED' 'infra-writer sin MCP externo ni via web real no recibe pass'
rmstub dotnet

echo '[6] Contexto de entrada (source:command)'
CMD_PLAN="$(plan sequential command tooling)"
prep="$(jq -cn --arg r "$R" '{schemaVersion:1,projectRoot:$r,runId:"run1",contextId:"ctx1",rootCommand:"sequential",source:"command",runtime:{id:"opencode",version:"1"},leaseId:"lease-1"}')"
D="$(printf '%s' "$prep" | PATH="$BASE_PATH" bash "$EC" prepare | jq -r .digest)"
CTX="$R/.mefisto/pipeline/autonomy/runs/run1/contexts/ctx1.json"
pf "$R" opencode "$CMD_PLAN" "$CTX"
eq "$(j .status)/$RC/$(chk ENTRY_ADMISSION)" 'incomplete/1/block/ENTRY_ADMISSION_MISSING' 'sin entryAdmission de la sesion iniciadora es incomplete'
ecall() { printf '%s' "$2" | PATH="$BASE_PATH" bash "$EC" $1 >/dev/null; }
base="$(jq -cn --arg r "$R" --arg d "$D" '{schemaVersion:1,projectRoot:$r,runId:"run1",contextId:"ctx1",digest:$d}')"
ecall attach "$(jq -c --argjson p $$ '. + {ownerPid:$p}' <<< "$base")"
ecall bind-session "$(jq -c '. + {sessionID:"sess1"}' <<< "$base")"
NONCE="$(jq -r .contract.nonce "$CTX")"
admit() { ecall record-entry-admission "$(jq -c --arg n "$NONCE" --arg p "$1" '. + {controllerNonce:$n,entryAdmission:{sessionID:"sess1",commandId:"sequential",release:"'"$(jq -r .version "$REL/src/published/release-identity.json")"'",permissionImageDigest:"img1",resourcesDigest:"res1",policyResult:$p,ownership:"projected"}}' <<< "$base")"; }
admit denied
pf "$R" opencode "$CMD_PLAN" "$CTX"
eq "$(j .status)/$RC/$(chk ENTRY_ADMISSION)" 'blocked/1/block/ENTRY_POLICY_DENIED' 'politica denegada bloquea'
admit allowed
pf "$R" opencode "$CMD_PLAN" "$CTX"
eq "$(j .status)/$RC/$(chk ENTRY_ADMISSION)" 'ready-to-dispatch/0/pass/NONE' 'entrada admitida y ligada a la sesion queda ready'
eq "$(j .resourcesDigest)" 'res1' 'resourcesDigest sale de la evidencia de entrada'
RID="$REL/src/published/release-identity.json"; cp "$RID" "$TMP/rid.json"
jq '.version = "9.9.9-otra"' "$TMP/rid.json" > "$RID"
pf "$R" opencode "$CMD_PLAN" "$CTX"
eq "$(j .status)/$RC/$(chk CONTEXT_VALID)" 'blocked/1/block/RELEASE_CHANGED' 'cambio de release revalida el contexto y bloquea'
cp "$TMP/rid.json" "$RID"
pf "$R" claude "$CMD_PLAN" "$CTX"
eq "$(j .status)/$RC/$(chk CONTEXT_RUNTIME)" 'blocked/1/block/CONTEXT_RUNTIME_MISMATCH' 'Claude con contexto de otro runtime falla visiblemente'
mkdir -p "$TMP/ext"; cp "$CTX" "$TMP/ext/ctx1.json"
pf "$R" opencode "$CMD_PLAN" "$TMP/ext/ctx1.json"
eq "$(j .status)/$RC/$(chk CONTEXT_ORIGIN)" 'blocked/1/block/CONTEXT_ORIGIN_MISMATCH' 'contexto externo no es autoridad'
pf "$R" opencode "$(plan parallel command tooling)" "$CTX"
eq "$(j .status)/$RC/$(chk CONTEXT_SCOPE)" 'blocked/1/block/CONTEXT_SCOPE_MISMATCH' 'comando raiz fuera del contexto bloquea'
pf "$NP" opencode "$CMD_PLAN" "$CTX"
eq "$RC" '1' 'contexto previo incompatible con proyecto sin perfil no cae a legacy'
printf '%s' "$OUT" | grep -q "$HOME" && fail 'el diagnostico expone rutas del usuario' || pass 'diagnosticos sin datos sensibles'

echo
echo "Resultado: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
