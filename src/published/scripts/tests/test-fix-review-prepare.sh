#!/usr/bin/env bash
# fix-review-prepare.sh con dobles de gh y repositorios Git temporales: sin red, usuario real ni LLM.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/fix-review-prepare.sh"
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
n() { local c="$FIX/$1.count"; local v=0; [ -f "$c" ] && v="$(cat "$c")"; printf '%s' "$((v + 1))" > "$c"; printf '%s' "$v"; }
case "$1 $2" in
    "repo view") printf '%s\n' "acme/demo" ;;
    "pr view") v="$(n pr)"; if [ "$v" -ge 1 ] && [ -f "$FIX/pr2.json" ]; then cat "$FIX/pr2.json"; else cat "$FIX/pr.json"; fi ;;
    "api repos/acme/demo/pulls/42/comments")
        v="$(n api)"; d="$FIX/pages"; if [ "$v" -ge 1 ] && [ -d "$FIX/pages2" ]; then d="$FIX/pages2"; fi
        cat "$d"/*.json ;;
    *) exit 9 ;;
esac
GH
chmod +x "$BIN/gh"
export FIX PATH="$BIN:$PATH" GH_TOKEN=sentinel-no-debe-leerse HOME="$TMP/home"

git -C "$R" init -q -b fix/demo && git -C "$R" config user.email t@example.com && git -C "$R" config user.name t
printf '.mefisto/\n' > "$R/.gitignore"; mkdir -p "$R/src"; printf 'a\n' > "$R/src/A.cs"
git -C "$R" add . && git -C "$R" commit -qm base
SHA="$(git -C "$R" rev-parse HEAD)"
PID="project-$(printf '%s' "$(cd "$R/.git" && pwd -P)" | sha | cut -c1-24)"
SUM="$R/.mefisto/pipeline/summaries"; mkdir -p "$SUM"

mk_pr() { jq -cn --arg sha "$1" --arg state "${2:-OPEN}" --argjson x "${3:-false}" --arg ref "${4:-fix/demo}" \
    '{headRefOid:$sha,headRefName:$ref,baseRefName:"main",state:$state,url:"https://github.com/acme/demo/pull/42",isCrossRepository:$x}'; }
# 35 comentarios en dos paginas; el 1035 es respuesta al 1001
mk_comments() { # dir sufijo-de-body-del-1002
    rm -rf "$1"; mkdir -p "$1"
    jq -cn --arg s "${2:-}" '[range(1001;1036) | {id:., body:("SENTINELA-CUERPO-RAW " + (.|tostring) + (if . == 1002 then $s else "" end)), path:"src/A.cs", line:(. - 990), original_line:(. - 990), in_reply_to_id:(if . == 1035 then 1001 else null end)}]' \
      | jq -c '.[:30]' > "$1/p1.json"
    jq -cn --arg s "${2:-}" '[range(1001;1036) | {id:., body:("SENTINELA-CUERPO-RAW " + (.|tostring) + (if . == 1002 then $s else "" end)), path:"src/A.cs", line:(. - 990), original_line:(. - 990), in_reply_to_id:(if . == 1035 then 1001 else null end)}]' \
      | jq -c '.[30:]' > "$1/p2.json"
}
mk_plan() { # sufijo-body-1002
    mk_comments "$FIX/live"
    jq -cn --arg pid "$PID" --arg sha "$SHA" --argjson snap "$(for i in $(seq 1001 1035); do
        h="$(printf '%s' "SENTINELA-CUERPO-RAW $i${1:-}" | sha)"; [ "$i" = 1002 ] || h="$(printf '%s' "SENTINELA-CUERPO-RAW $i" | sha)"
        if [ "$i" = 1035 ]; then r=1001; else r=null; fi
        jq -cn --argjson i "$i" --arg h "$h" --argjson l "$((i - 990))" --argjson r "$r" '{id:$i,bodyDigest:$h,path:"src/A.cs",line:$l,originalLine:$l,inReplyToId:$r}'
      done | jq -s .)" \
      '{schemaVersion:1,projectId:$pid,repoSlug:"acme/demo",prNumber:42,baseRef:"main",headRefName:"fix/demo",headRepository:"acme/demo",expectedHeadSha:$sha,commentSnapshot:$snap,
        triage:([$snap[] | {commentId:.id,category:"explicar",summary:"Explicar la razon."}] | .[0] = {commentId:1001,category:"corregir",summary:"Renombrar.",edits:[{path:"src/A.cs",change:"Renombrar",impact:"Local"}]}),
        verification:["dotnet build","dotnet test"],
        secondary:{replyPolicy:"freeform-factual",consumerIssues:false,harnessDrafts:false,localImprovementClasses:[]},limits:{drafts:0,consumerIssues:0,localFiles:0}}'
}
reset() {
    rm -rf "$FIX/pr.count" "$FIX/api.count" "$FIX/pr2.json" "$FIX/pages2" "$R/.mefisto/pipeline/autonomy"
    rm -rf "$SUM/fix-review"; mk_pr "$SHA" > "$FIX/pr.json"; mk_comments "$FIX/pages"
    mk_plan > "$SUM/plan.json"; printf '# Plan PR 42\n\n- 1001: corregir y verificar con dotnet.\nNOTA-HUMANA-SENTINELA\n' > "$SUM/plan.md"
    git -C "$R" checkout -q -- . 2>/dev/null
}
run() { (cd "$R" && bash "$SCRIPT" --project-root "$R" --pr 42 --plan-file "${1:-.mefisto/pipeline/summaries/plan.json}" --plan-text "${2:-.mefisto/pipeline/summaries/plan.md}" 2>"$TMP/err"); }
status_is() { printf '%s' "$1" | jq -e --arg s "$2" --arg d "${3:-}" '.status == $s and (if $d == "" then true else (.diagnostics | join(" ") | contains($d)) end)' >/dev/null 2>&1; }
no_artifacts() { [ ! -e "$R/.mefisto/pipeline/autonomy/fix-review" ] ; }

printf '[1] guardas previas: abortan sin artefacto, checkout ni mutaciones\n'
reset; mk_pr "$SHA" CLOSED > "$FIX/pr.json"; OUT="$(run)"; status_is "$OUT" conflict PR_NOT_OPEN && no_artifacts; ok $? 'PR cerrado'
reset; mk_pr "$SHA" OPEN true > "$FIX/pr.json"; OUT="$(run)"; status_is "$OUT" conflict FORK_NOT_SUPPORTED && no_artifacts; ok $? 'fork ajeno'
reset; mk_pr "ffffffffffffffffffffffffffffffffffffffff" > "$FIX/pr.json"; OUT="$(run)"; status_is "$OUT" conflict WORKTREE_HEAD_MISMATCH && no_artifacts; ok $? 'HEAD de otro commit'
reset; mk_pr "$SHA" OPEN false otra/rama > "$FIX/pr.json"; OUT="$(run)"; status_is "$OUT" conflict WORKTREE_BRANCH_MISMATCH && no_artifacts; ok $? 'rama distinta'
reset; printf 'b\n' >> "$R/src/A.cs"; OUT="$(run)"; status_is "$OUT" conflict WORKTREE_DIRTY && no_artifacts; ok $? 'worktree sucio'
git -C "$R" checkout -q -- .
reset; cp "$SUM/plan.json" "$TMP/fuera.json"; OUT="$(run "$TMP/fuera.json")"; status_is "$OUT" conflict PLAN_FILE_NOT_OWN && no_artifacts; ok $? 'plan fuera de summaries/'
reset; ln -s "$TMP/fuera.json" "$SUM/enlace.json"; OUT="$(run .mefisto/pipeline/summaries/enlace.json)"; status_is "$OUT" conflict PLAN_FILE_NOT_OWN; ok $? 'plan como symlink'
[ -s "$FIX/calls.log" ] && ! grep -Ev '^(repo view --json nameWithOwner -q \.nameWithOwner|pr view 42 --repo acme/demo --json [A-Za-z,]+|api repos/acme/demo/pulls/42/comments --paginate)$' "$FIX/calls.log"; ok $? 'solo lecturas GH, sin checkout'
[ "$(git -C "$R" rev-parse HEAD)" = "$SHA" ] && [ "$(git -C "$R" symbolic-ref --short HEAD)" = fix/demo ]; ok $? 'HEAD y rama intactos'

printf '[2] snapshot paginado completo\n'
reset; OUT="$(run)"; RC=$?
[ "$RC" = 0 ] && status_is "$OUT" prepared; ok $? 'preparado con 35 comentarios en 2 paginas'
PD="$(printf '%s' "$OUT" | jq -r .planDigest)"; SEALED="$R/.mefisto/pipeline/autonomy/fix-review/$PD.json"
jq -e '.plan.commentSnapshot | length == 35 and any(.[]; .id == 1035 and .inReplyToId == 1001) and all(.[]; .line != null and .path == "src/A.cs")' "$SEALED" >/dev/null; ok $? 'incluye reply preexistente, rutas y lineas'
printf '%s' "$OUT" | jq -e --arg d "$PD" '.pr == 42 and .expectedHeadSha != null and (.commentSnapshotDigest | test("^[0-9a-f]{64}$")) and .planPath == (".mefisto/pipeline/autonomy/fix-review/" + $d + ".json") and (.requiredGrants | map(.action) == ["fix-review-correct","fix-review-reply"]) and .diagnostics == []' >/dev/null; ok $? 'respuesta compacta con grants de #1886'
reset; mk_comments "$FIX/pages2" " editado"; OUT="$(run)"; status_is "$OUT" conflict COMMENTS_CHANGED_DURING_READ && no_artifacts; ok $? 'comentario cambia durante la lectura'
reset; mk_pr "ffffffffffffffffffffffffffffffffffffffff" > "$FIX/pr2.json"; OUT="$(run)"; status_is "$OUT" conflict HEAD_CHANGED_DURING_READ && no_artifacts; ok $? 'cabeza cambia durante la lectura'
reset; jq -c '.commentSnapshot |= .[1:] | .triage |= .[1:]' "$SUM/plan.json" > "$SUM/p.json" && OUT="$(run .mefisto/pipeline/summaries/p.json)"; status_is "$OUT" conflict "omitido 1001" && no_artifacts; ok $? 'comentario omitido del plan'
reset; jq -c '.commentSnapshot += [.commentSnapshot[0] | .id = 2000] | .triage += [.triage[1] | .commentId = 2000]' "$SUM/plan.json" > "$SUM/p.json" && OUT="$(run .mefisto/pipeline/summaries/p.json)"; status_is "$OUT" conflict "sobrante 2000"; ok $? 'comentario sobrante en el plan'
reset; jq -c '.commentSnapshot[3].bodyDigest = ("1" * 64)' "$SUM/plan.json" > "$SUM/p.json" && OUT="$(run .mefisto/pipeline/summaries/p.json)"; status_is "$OUT" conflict "editado 1004"; ok $? 'body hash editado'
reset; jq -c '.commentSnapshot[3].line = 5' "$SUM/plan.json" > "$SUM/p.json" && OUT="$(run .mefisto/pipeline/summaries/p.json)"; status_is "$OUT" conflict "editado 1004"; ok $? 'linea editada'
reset; jq -c '.triage |= .[1:]' "$SUM/plan.json" > "$SUM/p.json" && OUT="$(run .mefisto/pipeline/summaries/p.json)"; status_is "$OUT" conflict TRIAGE_SNAPSHOT_MISMATCH && no_artifacts; ok $? 'triaje omitido'

printf '[3] digest reproducible y sensible a cada cambio\n'
reset; OUT1="$(run)"; B1="$(cat "$SEALED")"; OUT2="$(run)"; RC=$?
[ "$RC" = 0 ] && [ "$OUT1" = "$OUT2" ] && [ "$B1" = "$(cat "$SEALED")" ]; ok $? 'reintento: misma respuesta y mismos bytes'
reset; jq -c '.triage[0].edits[0].change = "Otro cambio"' "$SUM/plan.json" > "$SUM/p.json"; OUT3="$(run .mefisto/pipeline/summaries/p.json)"
[ "$(printf '%s' "$OUT3" | jq -r .planDigest)" != "$PD" ] && status_is "$OUT3" prepared; ok $? 'una accion distinta cambia planDigest'
reset; printf 'Texto humano distinto\n' > "$SUM/plan.md"; OUT4="$(run)"
[ "$(printf '%s' "$OUT4" | jq -r .planDigest)" != "$PD" ] && status_is "$OUT4" prepared; ok $? 'texto humano distinto cambia planDigest'
reset; jq -c '.secondary.localImprovementClasses=["consumer-adr"] | .limits.localFiles=2' "$SUM/plan.json" > "$SUM/p.json"; OUT5="$(run .mefisto/pipeline/summaries/p.json)"
printf '%s' "$OUT5" | jq -e '.requiredGrants | map(.action) | index("fix-review-local-improvement") != null' >/dev/null; ok $? 'clases/cupos opcionales exigen su grant'
reset; jq -c '.planDigest = ("5" * 64)' "$SUM/plan.json" > "$SUM/p.json"; OUT="$(run .mefisto/pipeline/summaries/p.json)"; status_is "$OUT" conflict PLAN_DIGEST_MISMATCH; ok $? 'planDigest declarado distinto: conflicto'

printf '[4] estado propio, permisos y sin fuga\n'
reset; OUT="$(run)"; PD="$(printf '%s' "$OUT" | jq -r .planDigest)"; SEALED="$R/.mefisto/pipeline/autonomy/fix-review/$PD.json"; MD="$SUM/fix-review/$PD.md"
mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
[ "$(mode "$SEALED")" = 600 ] && [ "$(mode "$MD")" = 600 ] && [ "$(mode "$(dirname "$SEALED")")" = 700 ] && [ "$(mode "$(dirname "$MD")")" = 700 ]; ok $? 'permisos 0600/0700'
git -C "$R" check-ignore -q "$SEALED" && git -C "$R" check-ignore -q "$MD" && [ -z "$(git -C "$R" status --porcelain)" ]; ok $? 'artefactos ignorados por Git'
jq -e --arg d "$PD" '.planTextPath == (".mefisto/pipeline/summaries/fix-review/" + $d + ".md")' "$SEALED" >/dev/null \
  && [ "$(sha < "$MD")" = "$(jq -r .plan.planTextDigest "$SEALED")" ]; ok $? 'copia del Markdown con path propio y hash comprobable'
! printf '%s' "$OUT$(cat "$TMP/err")" | grep -q 'SENTINELA-CUERPO-RAW\|NOTA-HUMANA-SENTINELA'; ok $? 'ni stdout/stderr filtran cuerpos ni Markdown'
! grep -q 'SENTINELA-CUERPO-RAW\|NOTA-HUMANA-SENTINELA' "$SEALED"; ok $? 'el JSON sellado no incluye cuerpos ni Markdown'
! grep -rq 'sentinel-no-debe-leerse' "$R/.mefisto" "$TMP/err" && ! printf '%s' "$OUT" | grep -q 'sentinel-no-debe-leerse'; ok $? 'sin tokens en estado ni salida'
reset; printf 'usar ghp_abcdefghijklmnopqrstuvwxyz0123456789\n' > "$SUM/plan.md"; OUT="$(run)"; status_is "$OUT" conflict PLAN_TEXT_SENSITIVE && no_artifacts && ! printf '%s' "$OUT$(cat "$TMP/err")" | grep -q ghp_; ok $? 'Markdown sensible exige redaccion'
reset; mkdir -p "$R/.mefisto/pipeline" "$TMP/ajeno"; ln -s "$TMP/ajeno" "$R/.mefisto/pipeline/autonomy"; OUT="$(run)"; status_is "$OUT" conflict STATE_SYMLINK && [ -z "$(ls -A "$TMP/ajeno")" ]; ok $? 'symlink en el estado: no escribe'
rm -f "$R/.mefisto/pipeline/autonomy"
reset; mkdir -p "$R/.mefisto/pipeline/autonomy/fix-review"; OUT="$(run)"; PD="$(printf '%s' "$OUT" | jq -r .planDigest)"; printf 'otro\n' > "$R/.mefisto/pipeline/autonomy/fix-review/$PD.json"; rm -rf "$SUM/fix-review"; OUT="$(run)"; status_is "$OUT" conflict STATE_EXISTS_DIFFERENT; ok $? 'registro previo con otros bytes: conflicto'
! grep -Eq 'autonomy-profile\.sh (approve|revoke)' "$SCRIPT" || grep -v '^ *printf\|^#' "$SCRIPT" | grep -Eq 'autonomy-profile\.sh (approve|revoke)'; [ $? -ne 0 ]; ok $? 'el script nunca invoca approve/revoke'

printf '[5] empaquetado en ambos adaptadores\n'
for runtime in claude opencode; do
    cmp -s "$REPO_ROOT/scripts/fix-review-prepare.sh" "$REPO_ROOT/dist/$runtime/scripts/fix-review-prepare.sh" \
        && jq -e 'any(.assets[]; .destination == "scripts/fix-review-prepare.sh")' "$REPO_ROOT/dist/$runtime/.mefisto-generated-assets.json" >/dev/null; ok $? "$runtime empaqueta fix-review-prepare.sh"
done
grep -q 'fix-review-prepare.sh|0755' "$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"; ok $? 'clausura del generador lo registra'
grep -q 'fix-review-prepare.sh' "$REPO_ROOT/src/published/contract/README.md"; ok $? 'README documenta el handoff de operador'

printf '\nPASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
