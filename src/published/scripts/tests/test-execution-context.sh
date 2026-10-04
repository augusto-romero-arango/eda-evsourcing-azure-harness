#!/usr/bin/env bash
# execution-context.sh y su biblioteca con repositorios Git temporales: sin red, runtime ni LLM.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
CLI="$REPO_ROOT/scripts/execution-context.sh"
LIB="$REPO_ROOT/scripts/_execution-context.sh"
AUTONOMY="$REPO_ROOT/scripts/autonomy-profile.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (esperado '$2', obtenido '$1')"; [ -z "${DEBUG_OUT:-}" ] || printf '    %s\n' "$OUT"; fi; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" GH_TOKEN=sentinel-no-debe-leerse
mkdir -p "$HOME"

mkrepo() {
    git -C "$1" init -q -b main 2>/dev/null || { mkdir -p "$1"; git -C "$1" init -q -b main; }
    git -C "$1" config user.email t@example.com; git -C "$1" config user.name t
    printf '.mefisto/\n' > "$1/.gitignore"; git -C "$1" add . && git -C "$1" commit -qm base
}
R="$TMP/consumer"; mkdir -p "$R/.mefisto"; mkrepo "$R"
cat > "$R/.mefisto/harness.config.json" <<'JSON'
{"autonomy":{"schemaVersion":1,"id":"local","revision":1,"commands":["tooling","implement","upgrade"],"administration":[]}}
JSON
NP="$TMP/noprofile"; mkdir -p "$NP/.mefisto"; mkrepo "$NP"; printf '{}\n' > "$NP/.mefisto/harness.config.json"
W1="$TMP/wt1"; W2="$TMP/wt2"
git -C "$R" worktree add -q -b b1 "$W1"; git -C "$R" worktree add -q -b b2 "$W2"

call() { OUT="$(printf '%s' "$2" | "$CLI" $1 ${3:-} 2>/dev/null)"; RC=$?; }
j() { printf '%s' "$OUT" | jq -r "$1 // empty"; }
runs_dir="$R/.mefisto/pipeline/autonomy/runs"
prep() { # run ctx root pipeline agent stage [operation] [source] [rt]
    jq -cn --arg r "$R" --arg run "$1" --arg c "$2" --arg root "$3" --arg p "$4" --arg a "$5" --arg s "$6" --arg op "${7:-execute}" --arg src "${8:-pipeline}" --arg rt "${9:-opencode}" \
        '{schemaVersion:1,projectRoot:$r,runId:$run,contextId:$c,rootCommand:$root,source:$src,operation:$op,runtime:{id:$rt,version:"1"},leaseId:("lease-"+$c)}
         + (if $p=="" then {} else {pipelineKind:$p} end) + (if $a=="" then {} else {originalAgent:$a} end) + (if $s=="" then {} else {logicalStage:$s} end)'
}
EMPTY='{}'
rq() { # run ctx digest extra-json
    jq -cn --arg r "$R" --arg run "$1" --arg c "$2" --arg d "$3" --argjson x "${4:-$EMPTY}" '{schemaVersion:1,projectRoot:$r,runId:$run,contextId:$c,digest:$d} + $x'
}

echo "== source sin efectos y disabled antes de recursos"
SRC_OUT="$(bash -c ". '$LIB'" 2>&1)"; eq "$SRC_OUT" "" "source de la biblioteca no emite ni escribe"
call prepare "$(prep r0 c0 tooling tooling tooling-writer s1 execute pipeline claude)"
eq "$(j .status)/$RC" "disabled/0" "runtime Claude queda legacy"
call prepare "$(jq -cn --arg r "$NP" '{schemaVersion:1,projectRoot:$r,runId:"r0",contextId:"c0",rootCommand:"tooling",source:"pipeline",runtime:{id:"opencode"},leaseId:"l"}')"
eq "$(j .reasonCode)/$RC" "NO_PROFILE/0" "sin perfil queda legacy"
[ ! -e "$runs_dir" ] && [ ! -e "$NP/.mefisto/pipeline" ] && pass "disabled no crea archivos" || fail "disabled no crea archivos"
call prepare "$(prep r0 c0 tooling tooling tooling-writer s1)"
eq "$(j .reasonCode)/$RC" "CONSENT_REQUIRED/1" "sin consentimiento no se prepara"

echo "== prepare"
D="$(cd "$R" && "$AUTONOMY" preview --project-root "$R" | jq -r .expectedDigest)"
(cd "$R" && "$AUTONOMY" approve --project-root "$R" --expected-digest "$D" >/dev/null)
call prepare "$(prep rA cP tooling tooling tooling-writer stage-1 execute command)"
eq "$(j .status)/$RC" "ready/0" "prepare con consentimiento"
DP="$(j .digest)"; PATHP="$(j .path)"
[ -f "$PATHP" ] && [ ! -L "$PATHP" ] && pass "archivo regular en contexts/" || fail "archivo regular en contexts/"
call prepare "$(prep rA cP tooling tooling tooling-writer stage-1 execute command)"
eq "$(j .digest)" "$DP" "prepare idempotente conserva el digest"
call prepare "$(prep rA cX infra infra infra-writer s)"; eq "$(j .reasonCode)/$RC" "ROOT_COMMAND_NOT_APPROVED/1" "rootCommand no aprobado"
call prepare "$(prep rA cX tooling tdd '' s)"; eq "$(j .reasonCode)/$RC" "PIPELINE_NOT_ALLOWED/1" "pipeline ajeno"
call prepare "$(prep rA cX tooling tooling implementer s)"; eq "$(j .reasonCode)/$RC" "ROLE_NOT_ALLOWED/1" "rol ajeno"
call prepare "$(prep rA cX tooling '' '' '' maintenance)"; eq "$(j .reasonCode)/$RC" "EXECUTION_CLASS_MISMATCH/1" "clase la deriva el catalogo"
call prepare "$(prep rA cM upgrade '' '' '' maintenance)"; eq "$(j .reasonCode)/$RC" "MAINTENANCE_INSIDE_EXECUTE/1" "maintenance dentro de execute"
call prepare "$(prep rB cM upgrade '' '' '' maintenance)"; eq "$(j .status)/$RC" "ready/0" "maintenance se prepara antes de la corrida"

echo "== padre/hijos y dos worktrees"
sleep 120 & OTHER_PID=$!; disown
trap 'kill "$OTHER_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
RES1="$(rq rA cP "$DP" "$(jq -cn --arg e "$W1" '{childContextId:"cH1",reservationId:"res1",executionRoot:$e,pipelineKind:"tooling",originalAgent:"tooling-writer",logicalStage:"stage-1"}')")"
call reserve-child "$RES1"; eq "$(j .status)/$RC" "ready/0" "reserve-child anterior al dispatch"; DH1="$(j .digest)"
call reserve-child "$(rq rA cP "$DP" "$(jq -cn --arg e "$W2" '{childContextId:"cH2",reservationId:"res2",executionRoot:$e,pipelineKind:"tooling",originalAgent:"tooling-reviewer"}')")"
DH2="$(j .digest)"
eq "$(jq -r '.contract|[.projectId,.profileDigest,.release]|join(",")' "$runs_dir/rA/contexts/cH1.json")" "$(jq -r '.contract|[.projectId,.profileDigest,.release]|join(",")' "$runs_dir/rA/contexts/cH2.json")" "hijos comparten identidad comun"
[ "$(jq -r .contract.executionRoot "$runs_dir/rA/contexts/cH1.json")" != "$(jq -r .contract.executionRoot "$runs_dir/rA/contexts/cH2.json")" ] && pass "cada worktree conserva su executionRoot" || fail "cada worktree conserva su executionRoot"
call reserve-child "$RES1"; eq "$(j .digest)" "$DH1" "reserva repetida idempotente"
call reserve-child "$(rq rA cP "$DP" "$(jq -cn --arg e "$TMP" '{childContextId:"cH3",reservationId:"res3",executionRoot:$e}')")"; eq "$(j .reasonCode)" "EXECUTION_ROOT_UNREGISTERED" "worktree no registrado"
call reserve-child "$(rq rA cP "$DP" "$(jq -cn --arg e "$W1" '{childContextId:"cH3",reservationId:"res3",executionRoot:$e,originalAgent:"implementer"}')")"; eq "$(j .reasonCode)" "ROLE_NOT_ALLOWED" "el hijo no amplia roles"
call attach "$(rq rA cP "$DP" "$(jq -cn --argjson p $$ '{ownerPid:$p}')")"; eq "$(j .state)/$RC" "attached/0" "attach del padre"
call attach "$(rq rA cH1 "$DH1")" "--owner-pid $$"; eq "$(j .state)/$RC" "attached/0" "attach hijo con --owner-pid"
call attach "$(rq rA cH1 "$DH1")" "--owner-pid $$"; eq "$RC" "0" "attach idempotente"
call attach "$(rq rA cH1 "$DH1")" "--owner-pid $OTHER_PID"; eq "$(j .reasonCode)" "ALREADY_ATTACHED" "otro owner no reatacha"
call finish "$(rq rA cP "$DP" '{"outcome":"succeeded"}')"
eq "$(j .liveChildren)/$(printf "%s" "$OUT" | jq -r .leaseReleased)" "2/false" "finish del padre no libera hijos vivos"
call finish "$(rq rA cH2 "$DH2" '{"outcome":"aborted"}')"
call attach "$(rq rA cH2 "$DH2")" "--owner-pid $$"; eq "$(j .reasonCode)/$RC" "HANDOFF_LATE/1" "handoff tardio rechazado"
call reserve-child "$(rq rA cP "$DP" "$(jq -cn --arg e "$W1" '{childContextId:"cH9",reservationId:"res9",executionRoot:$e}')")"; eq "$(j .reasonCode)" "PARENT_NOT_LIVE" "padre terminado no reserva"

echo "== validate, autoedicion y reanudacion"
call prepare "$(prep rC cA tooling tooling tooling-writer stage-1 execute command)"; DA="$(j .digest)"
call attach "$(rq rC cA "$DA" "$(jq -cn --argjson p $$ '{ownerPid:$p}')")"; NONCE="$(jq -r .contract.nonce "$runs_dir/rC/contexts/cA.json")"
FA="$runs_dir/rC/contexts/cA.json"; cp "$FA" "$TMP/cA.bak"
NEWC="$(jq -cS '.contract.allowedRoles += ["implementer"]' "$FA")"
NEWD="$(printf '%s' "$NEWC" | jq -cS .contract | tr -d '\n' | shasum -a 256 | cut -d ' ' -f 1)"
printf '%s' "$NEWC" | jq -c --arg d "$NEWD" '.contractDigest=$d' > "$FA"
call validate "$(rq rC cA "$DA")"; eq "$(j .reasonCode)/$RC" "CONTRACT_DIGEST_MISMATCH/1" "autoedicion con checksum propio no valida"
cp "$TMP/cA.bak" "$FA"
call validate "$(rq rC cA "$DA")"; eq "$(j .status)/$RC" "ready/0" "validate del contexto integro"
call bind-session "$(rq rC cA "$DA" '{"sessionID":"ses-1","role":"tooling-writer","stage":"stage-1"}')"; eq "$RC" "0" "bind-session"
call prepare "$(prep rC cB tooling tooling tooling-writer stage-1)"; DB="$(j .digest)"
call bind-session "$(rq rC cB "$DB" '{"sessionID":"ses-1","mode":"resume"}')"; eq "$(j .status)/$RC" "ready/0" "resume mismo stage con nonce nuevo"
call prepare "$(prep rC cD tooling tooling tooling-reviewer stage-2)"; DD="$(j .digest)"
call bind-session "$(rq rC cD "$DD" '{"sessionID":"ses-1","mode":"resume"}')"; eq "$(j .reasonCode)/$RC" "STAGE_MISMATCH/1" "resume de otro stage falla"
call bind-session "$(rq rC cB "$DB" '{"sessionID":"ses-x","mode":"resume"}')"; eq "$(j .reasonCode)" "SESSION_UNKNOWN" "sesion desconocida no es fresh start"
call bind-session "$(rq rC cB "$DB" '{"sessionID":"ses-1","mode":"resume","release":"9.9.9"}')"; eq "$(j .reasonCode)" "RELEASE_MISMATCH" "otra release falla"

echo "== entryAdmission, observations y recibos"
EA='{"entryAdmission":{"sessionID":"ses-1","commandId":"tooling","release":"'"$(jq -r .version "$REPO_ROOT/src/published/release-identity.json")"'","permissionImageDigest":"'"$(printf x | shasum -a 256 | cut -d ' ' -f 1)"'","policyResult":"allowed","revision":1}}'
call record-entry-admission "$(rq rC cA "$DA" "$(printf '%s' "$EA" | jq -c --arg n wrong '. + {controllerNonce:$n}')")"; eq "$(j .reasonCode)" "ENTRY_ADMISSION_UNAUTHORIZED" "nonce ajeno no fabrica veredicto"
call record-entry-admission "$(rq rC cA "$DA" "$(printf '%s' "$EA" | jq -c --arg n "$NONCE" '. + {controllerNonce:$n}')")"; eq "$(j .reasonCode)/$RC" "ENTRY_ADMISSION_RECORDED/0" "entryAdmission verificable"
call record-entry-admission "$(rq rC cA "$DA" "$(printf '%s' "$EA" | jq -c --arg n "$NONCE" '. + {controllerNonce:$n} | .entryAdmission.prompt="x"')")"; eq "$RC" "2" "claves no acotadas se rechazan"
call record-entry-admission "$(rq rA cH1 "$DH1" "$(printf '%s' "$EA" | jq -c --arg n "$(jq -r .contract.nonce "$runs_dir/rA/contexts/cH1.json")" '. + {controllerNonce:$n}')")"; eq "$(j .reasonCode)" "ENTRY_ADMISSION_UNAUTHORIZED" "hijo no registra success propio"
eq "$(jq -r '.state.entryAdmission|has("prompt")' "$FA")" "false" "entryAdmission sin prompts"
IMG="$(printf img | shasum -a 256 | cut -d ' ' -f 1)"
call prepare "$(prep rE cE tooling tooling tooling-writer s)"; DE="$(j .digest)"
call attach "$(rq rE cE "$DE" "$(jq -cn --argjson p $$ --arg i "$IMG" '{ownerPid:$p,observations:{resourcesDigest:"a",permissionBase:"b",permissionImageDigest:$i,projection:"p"}}')")"
NE="$(jq -r .contract.nonce "$runs_dir/rE/contexts/cE.json")"
call refresh-observations "$(rq rE cE "$DE" "$(jq -cn --arg n "$NE" --arg i "$IMG" '{controllerNonce:$n,observations:{resourcesDigest:"c",permissionBase:"b",permissionImageDigest:$i,projection:"p2"}}')")"; eq "$RC" "0" "refresh con misma imagen de permisos"
call refresh-observations "$(rq rE cE "$DE" "$(jq -cn --arg n "$NE" '{controllerNonce:$n,observations:{resourcesDigest:"c",permissionBase:"b",permissionImageDigest:"z",projection:"p2"}}')")"; eq "$(j .reasonCode)" "READMISSION_REQUIRED" "otra politica exige nueva admision"
call validate "$(rq rE cE "$DE")"; eq "$RC" "0" "refresh no cambia contrato"
call finish "$(rq rE cE "$DE" '{"outcome":"failed"}')"; eq "$(j .recovery)" "unknown" "cobertura de descendencia sin probar queda unknown"
call prepare "$(prep rE cHo tooling tooling tooling-writer s)"; DHO="$(j .digest)"
call finish "$(rq rE cHo "$DHO" '{"outcome":"held"}')"; eq "$(printf "%s" "$OUT" | jq -r .leaseReleased)/$RC" "false/0" "hold conserva la referencia del parent-run"
mkdir "$runs_dir/rE/contexts/cE.json.lock"; call finish "$(rq rE cE "$DE" '{"outcome":"failed"}')"; eq "$RC" "0" "finish repetido es idempotente"
call prepare "$(prep rE cL tooling tooling tooling-writer s)"; DL="$(j .digest)"
mkdir "$runs_dir/rE/contexts/cL.json.lock"
call attach "$(rq rE cL "$DL" "$(jq -cn --argjson p $$ '{ownerPid:$p}')")"; eq "$RC" "75" "lock ajeno devuelve busy sin limpieza por TTL"
[ -d "$runs_dir/rE/contexts/cL.json.lock" ] && pass "el lock no se roba por antiguedad" || fail "el lock no se roba por antiguedad"

echo "== biblioteca"
LIBOUT="$(bash -c ". '$LIB'; MEFISTO_EXECUTION_CONTEXT='$runs_dir/rC/contexts/cA.json' MEFISTO_EXECUTION_DIGEST='$DA' MEFISTO_RUNTIME=opencode; export MEFISTO_EXECUTION_CONTEXT MEFISTO_EXECUTION_DIGEST MEFISTO_RUNTIME; published_execution_open tooling '$W1' '$REPO_ROOT'; echo \"rc=\$? en=\$MEFISTO_EXECUTION_ENABLED\"; published_execution_close succeeded; echo closed=\$?" 2>&1)"
eq "$LIBOUT" "$(printf 'rc=0 en=1\nclosed=0')" "open valida contexto transportado contra la raiz aprobada"
LIBOUT="$(bash -c ". '$LIB'; MEFISTO_EXECUTION_CONTEXT='$runs_dir/rC/contexts/cA.json' MEFISTO_EXECUTION_DIGEST='$(printf 0 | shasum -a 256 | cut -d ' ' -f 1)'; export MEFISTO_EXECUTION_CONTEXT MEFISTO_EXECUTION_DIGEST; published_execution_open tooling '$W1' '$REPO_ROOT'; echo \"rc=\$? en=\$MEFISTO_EXECUTION_ENABLED\"" 2>&1)"
eq "$LIBOUT" "rc=1 en=0" "contexto transportado invalido no vuelve a legacy"
LIBOUT="$(env -u MEFISTO_EXECUTION_CONTEXT -u MEFISTO_EXECUTION_DIGEST MEFISTO_RUNTIME=claude bash -c ". '$LIB'; published_execution_open tooling '$R' '$REPO_ROOT'; echo \"rc=\$? en=\$MEFISTO_EXECUTION_ENABLED\"" 2>&1)"
eq "$LIBOUT" "rc=0 en=0" "sin contexto y runtime Claude conserva legacy"
LIBOUT="$(env -u MEFISTO_EXECUTION_CONTEXT -u MEFISTO_EXECUTION_DIGEST MEFISTO_RUNTIME=opencode bash -c ". '$LIB'; published_execution_open tooling '$R' '$REPO_ROOT'; echo \"rc=\$? en=\$MEFISTO_EXECUTION_ENABLED\"; published_execution_close succeeded; echo closed=\$?" 2>&1)"
eq "$LIBOUT" "$(printf 'rc=0 en=1\nclosed=0')" "raiz standalone prepara, adjunta y cierra solo su uso"
LIBOUT="$(env -u MEFISTO_EXECUTION_CONTEXT -u MEFISTO_EXECUTION_DIGEST MEFISTO_RUNTIME=opencode bash -c ". '$LIB'; published_execution_open tooling '$NP' '$REPO_ROOT'; echo \"rc=\$? en=\$MEFISTO_EXECUTION_ENABLED\"" 2>&1)"
eq "$LIBOUT" "rc=0 en=0" "sin perfil conserva legacy"

echo "== revocacion y secretos"
(cd "$R" && "$AUTONOMY" revoke --project-root "$R" >/dev/null)
call validate "$(rq rC cA "$DA")"; eq "$(j .reasonCode)/$RC" "CONSENT_REVOKED/1" "revocacion impide nuevas admisiones"
call bind-session "$(rq rC cB "$DB" '{"sessionID":"ses-1","mode":"resume"}')"; eq "$RC" "1" "resume revocado falla antes del modelo"
if grep -rq "sentinel-no-debe-leerse" "$R/.mefisto" 2>/dev/null; then fail "sin secretos en contextos"; else pass "sin secretos en contextos"; fi
[ ! -e "$R/.claude" ] && pass "sin escrituras legacy" || fail "sin escrituras legacy"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
