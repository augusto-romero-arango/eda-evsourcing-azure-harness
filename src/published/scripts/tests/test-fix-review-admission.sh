#!/usr/bin/env bash
# fix-review-admission.sh con dobles de gh y repositorios Git temporales: sin red, usuario real ni LLM.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/fix-review-admission.sh"
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
mkdir -p "$FIX" "$BIN" "$R"

cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/calls.log"
[ ! -f "$FIX/gh-down" ] || exit 1
case "$1 $2" in
    "repo view") printf '%s\n' "acme/demo" ;;
    "pr view") jq -cn --arg s "$(cat "$FIX/head")" --arg st "$(cat "$FIX/state")" '{headRefOid:$s,headRefName:"fix/demo",baseRefName:"main",state:$st,url:"https://github.com/acme/demo/pull/42",isCrossRepository:false}' ;;
    "api repos/acme/demo/pulls/42/comments") cat "$FIX/comments.json" ;;
    *) exit 9 ;;
esac
GH
chmod +x "$BIN/gh"
export FIX PATH="$BIN:$PATH" GH_TOKEN=sentinel-no-debe-leerse HOME="$TMP/home"

git -C "$R" init -q -b fix/demo && git -C "$R" config user.email t@example.com && git -C "$R" config user.name t
printf '.mefisto/\n' > "$R/.gitignore"; mkdir -p "$R/src" "$R/docs/adr"; printf 'a\n' > "$R/src/A.cs"; printf 'b\n' > "$R/src/B.cs"; printf 'adr\n' > "$R/docs/adr/0001.md"
git -C "$R" add . && git -C "$R" commit -qm base
S0="$(git -C "$R" rev-parse HEAD)"
PID="project-$(printf '%s' "$(cd "$R/.git" && pwd -P)" | sha | cut -c1-24)"
STATE="$R/.mefisto/pipeline/autonomy/fix-review"; TEXTD="$R/.mefisto/pipeline/summaries/fix-review"; mkdir -p "$STATE" "$TEXTD"

B1=SENTINELA-CUERPO-1; B2=SENTINELA-CUERPO-2; B3=SENTINELA-CUERPO-3
cjson() { jq -cn --argjson id "$1" --arg b "$2" --arg p "${3:-}" --argjson l "${4:-null}" --argjson r "${5:-null}" \
    '{id:$id,body:$b,path:(if $p == "" then null else $p end),line:$l,original_line:$l,in_reply_to_id:$r}'; }
write_comments() { printf '[%s,%s,%s]\n' "$(cjson 1001 "$B1" src/A.cs 3)" "$(cjson 1002 "$B2" src/B.cs 4)" "$(cjson 1003 "$B3")" > "$FIX/comments.json"; }
write_comments
snap_row() { jq -cn --argjson id "$1" --arg h "$(printf '%s' "$2" | sha)" --arg p "${3:-}" --argjson l "${4:-null}" \
    '{id:$id,bodyDigest:$h,path:(if $p == "" then null else $p end),line:$l,originalLine:$l,inReplyToId:null}'; }
TD="$(printf 'plan' | sha)"
CAND="$(jq -cnS --arg sha "$S0" --arg pid "$PID" --arg z "$(printf '0%.0s' $(seq 1 64))" --arg td "$TD" \
    --argjson s1 "$(snap_row 1001 "$B1" src/A.cs 3)" --argjson s2 "$(snap_row 1002 "$B2" src/B.cs 4)" --argjson s3 "$(snap_row 1003 "$B3")" '
    {schemaVersion:1,projectId:$pid,repoSlug:"acme/demo",prNumber:42,baseRef:"main",headRefName:"fix/demo",headRepository:"acme/demo",expectedHeadSha:$sha,
     commentSnapshot:[$s1,$s2,$s3],
     triage:[{commentId:1001,category:"corregir",summary:"Renombrar.",edits:[{path:"src/A.cs",change:"Renombrar",impact:"Local"}]},{commentId:1002,category:"explicar",summary:"Explicar."},{commentId:1003,category:"investigar",summary:"Investigar."}],
     verification:["dotnet build","dotnet test"],planTextDigest:$td,
     secondary:{replyPolicy:"freeform-factual",consumerIssues:true,harnessDrafts:true,localImprovementClasses:["consumer-adr"]},
     limits:{drafts:1,consumerIssues:1,localFiles:2},planDigest:$z}')"
RES="$(jq -cn --argjson p "$CAND" --arg id "$PID" '{plan:$p,grants:null,context:{projectId:$id}}' | jq -c -f "$VALIDATOR")"
PD="$(printf '%s' "$RES" | jq -j .canonical | sha)"
FINAL="$(printf '%s' "$CAND" | jq -cS --arg d "$PD" '.planDigest = $d')"
TREL=".mefisto/pipeline/summaries/fix-review/$PD.md"
printf 'plan' > "$R/$TREL"
jq -cnS --argjson plan "$FINAL" --arg tp "$TREL" '{schemaVersion:1,plan:$plan,planTextPath:$tp,commentSnapshotDigest:"x"}' > "$STATE/$PD.json"
grants_for() { jq -cn --argjson r "$RES" --arg d "$1" --arg pr "$2" '
    {"fix-review-correct":"scope:planned-files","fix-review-reply":"scope:review-comments","fix-review-consumer-issue":"scope:consumer-issue","fix-review-harness-draft":"scope:harness-draft","fix-review-local-improvement":"scope:consumer-docs"} as $s
    | [$r.requiredActions[] | {command:"fix-review",action:.,environment:"repository",resources:[$pr,$s[.]],planDigest:$d}]'; }
ALL_GRANTS="$(grants_for "$PD" pr:42)"
CFG="$R/.mefisto/harness.config.json"
set_profile() {
    jq -cn --argjson g "$1" '{autonomy:{schemaVersion:1,id:"demo",revision:1,commands:["fix-review"],administration:$g}}' > "$CFG"
    local d; d="$(cd "$R" && bash "$AUTONOMY" preview --project-root "$R" | jq -r .expectedDigest)"
    (cd "$R" && bash "$AUTONOMY" approve --project-root "$R" --expected-digest "$d" >/dev/null 2>&1) || true
}
set_profile "$ALL_GRANTS"
printf '%s' "$S0" > "$FIX/head"; printf 'OPEN' > "$FIX/state"
RCPF="$STATE/$PD.receipts.json"
write_receipts() { # transitions-json replies-json
    jq -cn --arg pd "$PD" --arg pid "$PID" --arg prof "$(cd "$R" && bash "$AUTONOMY" inspect --project-root "$R" | jq -r .profileDigest)" --arg s0 "$S0" --argjson t "$1" --argjson r "$2" \
        '{schemaVersion:1,planDigest:$pd,projectId:$pid,prNumber:42,repoSlug:"acme/demo",headRefName:"fix/demo",runId:"run-1",profileDigest:$prof,initialHeadSha:$s0,revision:1,headTransitions:$t,replies:$r,issues:[]}' > "$RCPF"
    chmod 600 "$RCPF"
}
chk() { # fase [args...]
    local ph="$1"; shift
    OUT="$(cd "$R" && bash "$SCRIPT" check --project-root "$R" --pr 42 --plan-id "${PLAN:-$PD}" --phase "$ph" "$@" 2>"$TMP/err")"; RC=$?
}
is() { printf '%s' "$OUT" | jq -e --arg s "$1" --arg c "${2:-}" '.status == $s and (if $c == "" then true else any(.diagnostics[]; .code | startswith($c)) end)' >/dev/null 2>&1; }
auth() { [ "$RC" = 0 ] && is authorized; }
blk() { [ "$RC" = 1 ] && is "${2:-blocked}" "$1"; }

printf '[1] plan, consentimiento y grants\n'
chk pre-edit; auth; ok $? 'pre-edit autorizado con grants exactos'
printf '%s' "$OUT" | jq -e --arg pd "$PD" '.schemaVersion == 1 and .planDigest == $pd and .currentHead != null and (.allowedActions | index("edit:src/A.cs")) != null' >/dev/null; ok $? 'JSON con digest, cabeza y acciones'
PLAN=$(printf 'f%.0s' $(seq 1 64)) chk pre-edit; blk PLAN_NOT_SEALED incomplete; ok $? 'plan-id no sellado: incomplete'
set_profile "$(grants_for "$PD" pr:43)"; chk pre-edit; blk GRANT_MISSING; ok $? 'grant de otro PR: bloqueado'
set_profile "$(grants_for "$(printf '1%.0s' $(seq 1 64))" pr:42)"; chk pre-edit; blk GRANT; ok $? 'grant con otro planDigest: bloqueado'
set_profile "$(printf '%s' "$ALL_GRANTS" | jq -c 'map(del(.planDigest))')"; chk pre-edit; blk CONSENT_ || blk GRANT; ok $? 'grant sin planDigest: bloqueado'
set_profile "$(printf '%s' "$ALL_GRANTS" | jq -c 'map(.environment = "dev")')"; chk pre-edit; [ "$RC" = 1 ]; ok $? 'otro entorno: bloqueado'
rm -f "$CFG"; chk pre-edit; blk CONSENT_ ; ok $? 'sin perfil: bloqueado'
set_profile "$ALL_GRANTS"; chk pre-edit; auth; ok $? 'perfil reaprobado: autorizado'
(cd "$R" && bash "$AUTONOMY" revoke --project-root "$R" >/dev/null 2>&1); chk pre-edit; blk CONSENT_; ok $? 'consentimiento revocado'
set_profile "$ALL_GRANTS"
mv "$R/$TREL" "$TMP/t.md"; chk pre-edit; blk PLAN_TEXT_MISSING incomplete; ok $? 'copia Markdown ausente: incomplete'
printf 'otro' > "$R/$TREL"; chk pre-edit; blk PLAN_TEXT_ALTERED incomplete; ok $? 'copia Markdown alterada: incomplete'
printf 'plan' > "$R/$TREL"

printf '[2] pre-edit y pre-push\n'
chk pre-edit; auth; ok $? 'pre-edit de nuevo autorizado'
printf 'x\n' >> "$R/src/A.cs"; chk pre-edit; blk WORKTREE_DIRTY; ok $? 'worktree sucio'
git -C "$R" checkout -q -- src/A.cs
chk pre-push; blk NO_CODE_CHANGES; ok $? 'pre-push sin cambios'
printf 'c\n' >> "$R/src/A.cs"; git -C "$R" commit -qam c1; S1="$(git -C "$R" rev-parse HEAD)"
chk pre-push; auth && printf '%s' "$OUT" | jq -e '.allowedActions | index("verify-before-push") != null' >/dev/null; ok $? 'pre-push con diff planeado'
printf 'c\n' >> "$R/src/B.cs"; git -C "$R" commit -qam c2
chk pre-push; blk PATH_NOT_PLANNED; ok $? 'pre-push con ruta fuera del plan'
git -C "$R" reset -q --hard "$S0"

printf '[3] pre-reply y pre-improvement\n'
chk pre-reply --comment-id 1002; auth; ok $? 'pre-reply en id del snapshot'
chk pre-reply --comment-id 9999; blk COMMENT_NOT_IN_SNAPSHOT; ok $? 'pre-reply en id ajeno al plan'
chk pre-improvement --action consumer-adr; auth; ok $? 'mejora de clase aprobada'
chk pre-improvement --action production-src; blk ACTION_OUT_OF_SCOPE; ok $? 'accion fuera de scope: no-admision'
chk pre-improvement --action fix-review-harness-draft; auth; ok $? 'draft del harness autorizado'
chk pre-improvement --action fix-review-consumer-issue --comment-id 1002; blk ORIGIN_NOT_INVESTIGAR; ok $? 'issue solo desde investigar'
chk pre-improvement --action consumer-directives; blk ACTION_OUT_OF_SCOPE; ok $? 'clase no aprobada'

printf '[4] deriva de comentarios y cabeza\n'
printf '[%s,%s,%s]\n' "$(cjson 1001 "editado" src/A.cs 3)" "$(cjson 1002 "$B2" src/B.cs 4)" "$(cjson 1003 "$B3")" > "$FIX/comments.json"
chk pre-reply --comment-id 1002; blk COMMENT_MODIFIED; ok $? 'comentario editado'
write_comments
printf '[%s,%s,%s,%s]\n' "$(cjson 1001 "$B1" src/A.cs 3)" "$(cjson 1002 "$B2" src/B.cs 4)" "$(cjson 1003 "$B3")" "$(cjson 2000 "NUEVO" src/A.cs 9)" > "$FIX/comments.json"
chk pre-reply --comment-id 1002; blk NEW_EXTERNAL_COMMENT; ok $? 'comentario nuevo de un tercero'
printf '[%s,%s,%s,%s]\n' "$(cjson 1001 "$B1" src/A.cs 3)" "$(cjson 1002 "$B2" src/B.cs 4)" "$(cjson 1003 "$B3")" "$(cjson 5001 "respuesta" "" null 1002)" > "$FIX/comments.json"
chk pre-reply --comment-id 1001; blk UNRECORDED_REPLY; ok $? 'respuesta sin recibo'
write_receipts '[]' '[{"replyId":5001,"parentId":1002}]'
chk pre-reply --comment-id 1001; auth; ok $? 'respuesta con recibo: revalida sin reaprobar'
chk pre-reply --comment-id 1002; blk DUPLICATE_REPLY; ok $? 'segunda respuesta al mismo id'
rm -f "$RCPF"; write_comments
jq -cn '[range(0;31) | {id:(3000+.),body:"x",path:null,line:null,original_line:null,in_reply_to_id:null}]' > "$FIX/comments.json"
chk pre-reply --comment-id 1001; blk COMMENTS_OVER_LIMIT; ok $? 'mas de 30 comentarios'
write_comments
S9="$(printf '9%.0s' $(seq 1 40))"; printf '%s' "$S9" > "$FIX/head"
chk pre-reply --comment-id 1001; blk HEAD_NOT_IN_OWN_CHAIN; ok $? 'head externo'
write_receipts "$(jq -cn --arg f "$S0" --arg t "$S9" '[{seq:1,phase:"corrections",from:$f,to:$t,class:null,paths:["src/A.cs"]}]')" '[]'
chk pre-reply --comment-id 1001; auth && printf '%s' "$OUT" | jq -e --arg h "$S9" '.currentHead == $h' >/dev/null; ok $? 'cadena propia de pushes registrados'
rm -f "$RCPF"; printf '%s' "$S0" > "$FIX/head"
printf 'CLOSED' > "$FIX/state"; chk pre-reply --comment-id 1001; blk PR_NOT_OPEN; ok $? 'PR cerrado'
printf 'OPEN' > "$FIX/state"
: > "$FIX/gh-down"; chk pre-reply --comment-id 1001; blk GH_REPO_UNREADABLE incomplete; ok $? 'GitHub caido: incomplete recuperable'
rm -f "$FIX/gh-down"

printf '[5] finish y confidencialidad\n'
chk finish; [ "$RC" = 1 ] && is incomplete PARTIAL_CODE_NOT_APPLIED && printf '%s' "$OUT" | jq -e 'any(.diagnostics[]; .code == "PARTIAL_REPLIES_PENDING") and any(.diagnostics[]; .code == "PARTIAL_FOLLOWUP_NOT_RECORDED")' >/dev/null; ok $? 'finish marca resultados parciales'
chk pre-edit --bogus 2>/dev/null; [ "$RC" = 2 ]; ok $? 'protocolo: opcion desconocida'
OUT="$(cd "$R" && bash "$SCRIPT" check --project-root "$R" --pr 42 --plan-id "$PD" --phase pre-reply 2>&1)"; RC=$?; [ "$RC" = 2 ]; ok $? 'protocolo: pre-reply sin comment-id'
chk pre-edit; ALLOUT="$OUT$(cat "$TMP/err")"
! printf '%s' "$ALLOUT" | grep -q 'SENTINELA\|sentinel-no-debe-leerse'; ok $? 'sin cuerpos ni secretos en la salida'
[ -s "$FIX/calls.log" ] && ! grep -Eq -- '(-X|--method|-f |-F |--field| POST|issue create|pr comment|pr edit|api user)' "$FIX/calls.log"; ok $? 'solo lecturas de gh'
[ "$(git -C "$R" symbolic-ref --short HEAD)" = fix/demo ] && [ "$(git -C "$R" rev-parse HEAD)" = "$S0" ]; ok $? 'repositorio intacto'

printf '\nPASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
