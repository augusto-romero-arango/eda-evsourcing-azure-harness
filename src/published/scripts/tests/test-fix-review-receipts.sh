#!/usr/bin/env bash
# fix-review-receipts.sh con dobles de gh y repositorios Git temporales: sin red, usuario real ni LLM.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/fix-review-receipts.sh"
AUTONOMY="$REPO_ROOT/scripts/autonomy-profile.sh"
VALIDATOR="$REPO_ROOT/src/published/contract/fix-review-plan.validate.jq"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
ok() { if [ "$1" = 0 ]; then pass "$2"; else fail "$2"; fi; }
sha() { shasum -a 256 | cut -d ' ' -f 1; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fix"; BIN="$TMP/bin"; R="$TMP/consumer"
mkdir -p "$FIX/comments" "$FIX/issues" "$BIN" "$R"
HARNESS=augusto-romero-arango/eda-evsourcing-azure-harness

cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/calls.log"
case "$1 $2" in
    "repo view") printf '%s\n' "acme/demo" ;;
    "pr view") jq -cn --arg s "$(cat "$FIX/head")" '{headRefOid:$s,headRefName:"fix/demo",baseRefName:"main",state:"OPEN",url:"https://github.com/acme/demo/pull/42",isCrossRepository:false}' ;;
    "api user") cat "$FIX/user.json" ;;
    "api repos/acme/demo/pulls/comments/"*) f="$FIX/comments/${2##*/}.json"; [ -f "$f" ] && cat "$f" || exit 1 ;;
    "api repos/"*"/issues/"*) s="${2#repos/}"; s="${s%/issues/*}"; f="$FIX/issues/${s//\//_}-${2##*/}.json"; [ -f "$f" ] && cat "$f" || exit 1 ;;
    *) exit 9 ;;
esac
GH
chmod +x "$BIN/gh"
export FIX PATH="$BIN:$PATH" GH_TOKEN=sentinel-no-debe-leerse HOME="$TMP/home"

git -C "$R" init -q -b fix/demo && git -C "$R" config user.email t@example.com && git -C "$R" config user.name t
printf '.mefisto/\n' > "$R/.gitignore"; mkdir -p "$R/src" "$R/docs/adr"; printf 'a\n' > "$R/src/A.cs"; printf 'b\n' > "$R/src/B.cs"
printf 'adr\n' > "$R/docs/adr/0001.md"; printf 'adr\n' > "$R/docs/adr/0002.md"; printf 'adr\n' > "$R/docs/adr/0003.md"
git -C "$R" add . && git -C "$R" commit -qm base
S0="$(git -C "$R" rev-parse HEAD)"
PID="project-$(printf '%s' "$(cd "$R/.git" && pwd -P)" | sha | cut -c1-24)"
STATE="$R/.mefisto/pipeline/autonomy/fix-review"; mkdir -p "$STATE"

ZERO="$(printf '0%.0s' $(seq 1 64))"
CAND="$(jq -cnS --arg sha "$S0" --arg pid "$PID" --arg z "$ZERO" --arg td "$(printf 'plan' | sha)" '
    {schemaVersion:1,projectId:$pid,repoSlug:"acme/demo",prNumber:42,baseRef:"main",headRefName:"fix/demo",headRepository:"acme/demo",expectedHeadSha:$sha,
     commentSnapshot:[{id:1001,bodyDigest:$z,path:"src/A.cs",line:3,originalLine:3,inReplyToId:null},{id:1002,bodyDigest:$z,path:"src/B.cs",line:4,originalLine:4,inReplyToId:null},{id:1003,bodyDigest:$z,path:null,line:null,originalLine:null,inReplyToId:null}],
     triage:[{commentId:1001,category:"corregir",summary:"Renombrar.",edits:[{path:"src/A.cs",change:"Renombrar",impact:"Local"}]},{commentId:1002,category:"explicar",summary:"Explicar."},{commentId:1003,category:"investigar",summary:"Investigar."}],
     verification:["dotnet build","dotnet test"],planTextDigest:$td,
     secondary:{replyPolicy:"freeform-factual",consumerIssues:true,harnessDrafts:true,localImprovementClasses:["consumer-adr"]},
     limits:{drafts:1,consumerIssues:1,localFiles:2},planDigest:$z}')"
RES="$(jq -cn --argjson p "$CAND" --arg id "$PID" '{plan:$p,grants:null,context:{projectId:$id}}' | jq -c -f "$VALIDATOR")"
PD="$(printf '%s' "$RES" | jq -j .canonical | sha)"
FINAL="$(printf '%s' "$CAND" | jq -cS --arg d "$PD" '.planDigest = $d')"
jq -cnS --argjson plan "$FINAL" --arg z "$ZERO" '{schemaVersion:1,plan:$plan,planTextPath:"x",commentSnapshotDigest:$z}' > "$STATE/$PD.json"
ALL_GRANTS="$(jq -cn --argjson r "$RES" --arg d "$PD" '
    {"fix-review-correct":"scope:planned-files","fix-review-reply":"scope:review-comments","fix-review-consumer-issue":"scope:consumer-issue","fix-review-harness-draft":"scope:harness-draft","fix-review-local-improvement":"scope:consumer-docs"} as $s
    | [$r.requiredActions[] | {command:"fix-review",action:.,environment:"repository",resources:["pr:42",$s[.]],planDigest:$d}]')"

CFG="$R/.mefisto/harness.config.json"
set_profile() { # grants-json
    jq -cn --argjson g "$1" '{autonomy:{schemaVersion:1,id:"demo",revision:1,commands:["fix-review"],administration:$g}}' > "$CFG"
    local d; d="$(cd "$R" && bash "$AUTONOMY" preview --project-root "$R" | jq -r .expectedDigest)"
    (cd "$R" && bash "$AUTONOMY" approve --project-root "$R" --expected-digest "$d" >/dev/null)
}
set_profile "$ALL_GRANTS"

RUN=run-0001
printf '%s' "$S0" > "$FIX/head"; printf '{"login":"bot"}' > "$FIX/user.json"
rcp() { printf '%s' "$STATE/$PD.receipts.json"; }
call() { # op json [args...]
    local op="$1" json="$2"; shift 2
    OUT="$(cd "$R" && printf '%s' "$json" | bash "$SCRIPT" "$op" --project-root "$R" --plan-id "$PD" "$@" 2>"$TMP/err")"; RC=$?
}
is() { printf '%s' "$OUT" | jq -e --arg s "$1" --arg c "${2:-}" '.status == $s and (if $c == "" then true else (.code | startswith($c)) end)' >/dev/null 2>&1; }
commit() { # mensaje archivos...; actualiza la cabeza remota simulada
    local m="$1"; shift; local f
    for f in "$@"; do mkdir -p "$R/$(dirname "$f")"; printf '%s\n' "$m" >> "$R/$f"; done
    git -C "$R" add -A . && git -C "$R" commit -qm "$m"; git -C "$R" rev-parse HEAD
}
push_json() { jq -cn --arg run "$RUN" --arg ph "$1" --arg f "$2" --arg t "$3" --arg c "${4:-}" --argjson v "${5:-null}" \
    '{schemaVersion:1,runId:$run,phase:$ph,from:$f,to:$t} + (if $c == "" then {} else {improvementClass:$c} end) + (if $v == null then {} else {verification:$v} end)'; }
VER='[{"command":"dotnet build","exitCode":0},{"command":"dotnet test","exitCode":0}]'
comment_json() { jq -cn --argjson id "$1" --argjson p "$2" --arg u "$3" '{id:$id,in_reply_to_id:$p,user:{login:$u},pull_request_url:"https://api.github.com/repos/acme/demo/pulls/42",body:"SENTINELA-CUERPO-RAW"}'; }
issue_json() { # numero estado-labels-json body
    jq -cn --argjson n "$1" --argjson l "$2" --arg b "$3" '{number:$n,state:"open",user:{login:"bot"},labels:$l,body:$b}'
}

printf '[1] push de correcciones\n'
S1="$(commit c1 src/A.cs)"; printf '%s' "$S1" > "$FIX/head"
call record-push "$(push_json corrections "$S0" "$S1" "" "$VER")"
[ "$RC" = 0 ] && is recorded; ok $? 'transicion S0->S1 registrada'
[ "$(stat -f %Lp "$(rcp)" 2>/dev/null || stat -c %a "$(rcp)")" = 600 ]; ok $? 'libro 0600'
jq -e --arg r "$RUN" '.runId == $r and .revision == 1 and (.headTransitions | length == 1)' "$(rcp)" >/dev/null; ok $? 'id de corrida fijado y revision 1'
call record-push "$(push_json corrections "$S0" "$S1" "" "$VER")"
[ "$RC" = 0 ] && is recorded REPLAY && [ "$(jq .revision "$(rcp)")" = 1 ]; ok $? 'reintento idempotente sin nueva revision'
call record-push "$(push_json corrections "$S0" "$S1" "" "$VER")" --reference "$S1"
[ "$RC" = 0 ]; ok $? 'reference coincidente'
call record-push "$(push_json corrections "$S0" "$S1" "" "$VER")" --reference "$S0"
[ "$RC" = 1 ] && is conflict REFERENCE_MISMATCH; ok $? 'reference distinta: conflicto'

S2="$(commit c2 src/B.cs)"; printf '%s' "$S2" > "$FIX/head"
call record-push "$(push_json corrections "$S1" "$S2" "" "$VER")"
[ "$RC" = 1 ] && is conflict PATH_NOT_PLANNED; ok $? 'ruta no planeada en correcciones'
call record-push "$(push_json corrections "$S0" "$S2" "" "$VER")"
[ "$RC" = 1 ] && is conflict HEAD_CHAIN_BROKEN; ok $? 'from distinto del ultimo recibido (tercero)'
git -C "$R" reset -q --hard "$S1"; S3="$(commit c3 src/A.cs)"; printf '%s' "$S2" > "$FIX/head"
call record-push "$(push_json corrections "$S1" "$S3" "" "$VER")"
[ "$RC" = 1 ] && is conflict REMOTE_HEAD_MISMATCH; ok $? 'head remoto distinto del push reportado'
printf '%s' "$S3" > "$FIX/head"
call record-push "$(push_json corrections "$S1" "$S3")"
[ "$RC" = 1 ] && is conflict VERIFICATION_NOT_DECLARED; ok $? 'sin verificaciones declaradas'
jq -e '.headTransitions | length == 1' "$(rcp)" >/dev/null; ok $? 'ningun conflicto dejo recibo'
git -C "$R" reset -q --hard "$S1"; printf '%s' "$S1" > "$FIX/head"

printf '[2] mejoras locales acotadas por clase y cupo\n'
S4="$(commit i1 docs/adr/0001.md)"; printf '%s' "$S4" > "$FIX/head"
call record-push "$(push_json improvements "$S1" "$S4" consumer-directives)"
[ "$RC" = 1 ] && is conflict CLASS_NOT_APPROVED; ok $? 'clase no aprobada'
call record-push "$(push_json improvements "$S1" "$S4" consumer-adr)"
[ "$RC" = 0 ] && is recorded; ok $? 'mejora de clase aprobada'
S5="$(commit i2 src/B.cs)"; printf '%s' "$S5" > "$FIX/head"
call record-push "$(push_json improvements "$S4" "$S5" consumer-adr)"
[ "$RC" = 1 ] && is conflict PATH_NOT_IN_CLASS; ok $? 'ruta fuera de la clase'
git -C "$R" reset -q --hard "$S4"; S6="$(commit i3 docs/adr/0002.md docs/adr/0003.md)"; printf '%s' "$S6" > "$FIX/head"
call record-push "$(push_json improvements "$S4" "$S6" consumer-adr)"
[ "$RC" = 1 ] && is conflict LOCAL_FILES_QUOTA_EXCEEDED; ok $? 'cupo de archivos locales'
git -C "$R" reset -q --hard "$S4"; printf '%s' "$S4" > "$FIX/head"
call record-push "$(push_json corrections "$S4" "$S4" "" "$VER")"
[ "$RC" = 1 ]; ok $? 'transicion vacia o fase fuera de orden'

printf '[3] respuestas\n'
comment_json 5001 1001 bot > "$FIX/comments/5001.json"; comment_json 5002 1002 bot > "$FIX/comments/5002.json"
comment_json 5003 1001 bot > "$FIX/comments/5003.json"; comment_json 5004 9999 bot > "$FIX/comments/5004.json"
comment_json 5005 1002 reviewer > "$FIX/comments/5005.json"
rj() { jq -cn --arg run "$RUN" --argjson i "$1" '{schemaVersion:1,runId:$run,replyId:$i}'; }
call record-reply "$(rj 5001)"; [ "$RC" = 0 ] && is recorded; ok $? 'respuesta al padre 1001'
call record-reply "$(rj 5002)" --reference 5002; [ "$RC" = 0 ] && is recorded; ok $? 'respuesta al padre 1002'
call record-reply "$(rj 5001)"; [ "$RC" = 0 ] && is recorded REPLAY; ok $? 'repetir 5001 es idempotente'
call record-reply "$(rj 5003)"; [ "$RC" = 1 ] && is conflict DUPLICATE_REPLY; ok $? 'segunda respuesta al mismo padre'
call record-reply "$(rj 5004)"; [ "$RC" = 1 ] && is conflict REPLY_PARENT_NOT_APPROVED; ok $? 'padre fuera del plan'
call record-reply "$(rj 5005)"; [ "$RC" = 1 ] && is conflict REPLY_AUTHOR_MISMATCH; ok $? 'comentario nuevo del reviewer'
call record-reply "$(rj 1003)"; [ "$RC" = 1 ] && is conflict REPLY_IS_SNAPSHOT_COMMENT; ok $? 'comentario del snapshot no es respuesta'
call record-reply "$(rj 5006)"; [ "$RC" = 3 ] && is unknown REPLY_UNCONFIRMED && printf '%s' "$OUT" | jq -e '.recovery | test("no reintentes")' >/dev/null; ok $? 'API falla: unknown con recuperacion, sin recibo'
jq -e '.replies | length == 2' "$(rcp)" >/dev/null; ok $? 'solo dos respuestas registradas'

printf '[4] issues del consumidor y drafts del harness\n'
ij() { jq -cn --arg run "$RUN" --arg o "$1" --argjson n "$2" --arg r "$3" '{schemaVersion:1,runId:$run,origin:$o,issueNumber:$n,repo:$r}'; }
LB='[{"name":"estado:borrador"},{"name":"tipo:tooling"}]'
issue_json 77 '[]' 'Gap detectado en el PR #42' > "$FIX/issues/acme_demo-77.json"
issue_json 78 '[]' 'Sin referencia' > "$FIX/issues/acme_demo-78.json"
issue_json 91 "$LB" "Origen acme/demo#42" > "$FIX/issues/${HARNESS//\//_}-91.json"
issue_json 92 '[{"name":"estado:listo"},{"name":"tipo:tooling"}]' "Origen acme/demo#42" > "$FIX/issues/${HARNESS//\//_}-92.json"
call record-consumer-issue "$(ij comment:1002 77 acme/demo)"; [ "$RC" = 1 ] && is conflict ORIGIN_NOT_INVESTIGAR; ok $? 'solo comentarios investigar'
call record-consumer-issue "$(ij comment:1003 77 "$HARNESS")"; [ "$RC" = 1 ] && is conflict REPO_NOT_ALLOWED; ok $? 'issue de consumidor no va al harness'
call record-consumer-issue "$(ij comment:1003 78 acme/demo)"; [ "$RC" = 1 ] && is conflict ISSUE_MISSING_PR_REFERENCE; ok $? 'issue sin referencia al PR'
call record-consumer-issue "$(ij comment:1003 79 acme/demo)"; [ "$RC" = 3 ] && is unknown ISSUE_UNCONFIRMED; ok $? 'issue inexistente o API falla: unknown'
call record-consumer-issue "$(ij comment:1003 77 acme/demo)"; [ "$RC" = 0 ] && is recorded; ok $? 'issue por comentario investigar'
call record-consumer-issue "$(ij improvement:gap-1 78 acme/demo)"; [ "$RC" = 1 ] && is conflict QUOTA_EXCEEDED; ok $? 'cupo de issues agotado'
call record-harness-draft "$(ij improvement:gap-1 92 "$HARNESS")"; [ "$RC" = 1 ] && is conflict DRAFT_LABELS_INVALID; ok $? 'draft con estado distinto de borrador'
call record-harness-draft "$(ij improvement:gap-1 91 acme/demo)"; [ "$RC" = 1 ]; ok $? 'draft al repo consumidor rechazado'
call record-harness-draft "$(ij improvement:gap-1 91 "$HARNESS")"; [ "$RC" = 0 ] && is recorded; ok $? 'draft borrador/tooling al harness'
jq -e '.issues | length == 2 and all(.[]; .pr == 42 and (.origin | test("^(comment|improvement):")))' "$(rcp)" >/dev/null; ok $? 'recibos con origen y PR'

printf '[5] consentimiento, corrida y almacenamiento\n'
call record-reply "$(jq -cn '{schemaVersion:1,runId:"otra-corrida",replyId:5001}')"; [ "$RC" = 1 ] && is conflict RUN_ID_MISMATCH; ok $? 'id de corrida distinto'
call record-reply "$(jq -cn --arg r "$RUN" '{schemaVersion:1,runId:$r,replyId:5001,body:"texto libre"}')"; [ "$RC" = 1 ] && is conflict REQUEST_INVALID; ok $? 'el request no admite payload extra'
set_profile "$(printf '%s' "$ALL_GRANTS" | jq -c 'map(select(.action != "fix-review-reply"))')"
call record-reply "$(rj 5001)"; [ "$RC" = 1 ] && is conflict ACTION_NOT_GRANTED; ok $? 'grants de otra categoria no autorizan la respuesta'
(cd "$R" && bash "$AUTONOMY" revoke --project-root "$R" >/dev/null)
call record-consumer-issue "$(ij comment:1003 77 acme/demo)"; [ "$RC" = 1 ] && is conflict CONSENT_NOT_READY; ok $? 'consentimiento revocado'
set_profile "$ALL_GRANTS"
call record-consumer-issue "$(ij comment:1003 77 acme/demo)"; [ "$RC" = 0 ] && is recorded REPLAY; ok $? 'mismo perfil reaprobado: la corrida continua'
jq -c '.autonomy.revision = 2' "$CFG" > "$TMP/cfg2" && mv "$TMP/cfg2" "$CFG"
(cd "$R" && bash "$AUTONOMY" approve --project-root "$R" --expected-digest "$(cd "$R" && bash "$AUTONOMY" preview --project-root "$R" | jq -r .expectedDigest)" >/dev/null)
call record-consumer-issue "$(ij comment:1003 77 acme/demo)"; [ "$RC" = 1 ] && is conflict PROFILE_DIGEST_MISMATCH; ok $? 'perfil distinto del fijado en la corrida'
set_profile "$ALL_GRANTS"
chmod 644 "$(rcp)"; call record-reply "$(rj 5001)"; [ "$RC" = 1 ] && is conflict RECEIPTS_INSECURE; ok $? 'libro con permisos abiertos'
chmod 600 "$(rcp)"; cp "$(rcp)" "$TMP/orig.json"; mv "$(rcp)" "$TMP/real.json"; ln -s "$TMP/real.json" "$(rcp)"
call record-reply "$(rj 5001)"; [ "$RC" = 1 ] && is conflict STATE_SYMLINK; ok $? 'libro como symlink'
rm -f "$(rcp)"; cp "$TMP/orig.json" "$(rcp)"; chmod 600 "$(rcp)"
call status ""; [ "$RC" = 0 ] && is ok && printf '%s' "$OUT" | jq -e '.code | contains("transitions=2 replies=2 issues=2")' >/dev/null; ok $? 'status diagnostica sin contenido'
rm -f "$(rcp)"; call status ""; [ "$RC" = 0 ] && is none; ok $? 'sin recibo: diagnostico, no consentimiento'
cp "$TMP/orig.json" "$(rcp)"; chmod 600 "$(rcp)"
! grep -rq 'SENTINELA\|sentinel-no-debe-leerse\|texto libre' "$STATE" "$TMP/err" 2>/dev/null; ok $? 'sin cuerpos ni secretos en persistencia'
[ ! -e "$(rcp).lock" ]; ok $? 'sin lock residual'
[ -s "$FIX/calls.log" ] && ! grep -Eq -- '(-X|--method|-f |-F |--field| POST|issue create|pr comment|pr edit)' "$FIX/calls.log"; ok $? 'solo lecturas de gh'
[ "$(git -C "$R" symbolic-ref --short HEAD)" = fix/demo ]; ok $? 'rama intacta'

printf '\nPASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
