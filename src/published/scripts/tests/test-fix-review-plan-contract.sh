#!/usr/bin/env bash
# Contrato puro del plan preautorizado de fix-review: Bash 3.2, jq y shasum; sin red, GitHub ni LLM.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
VALIDATOR="$REPO_ROOT/src/published/contract/fix-review-plan.validate.jq"
EXAMPLE="$REPO_ROOT/src/published/contract/fix-review-plan.example.json"
PLAN_MD="$HERE/fixtures/fix-review-plan/plan.md"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

run() { # plan-json grants-json
    jq -cn --argjson p "$1" --argjson g "${2:-null}" '{plan:$p,grants:$g,context:{projectId:"proyecto-demo"}}' | jq -c -f "$VALIDATOR"
}
digest_of() { run "$1" | jq -j '.canonical' | shasum -a 256 | cut -d ' ' -f 1; }
expect() { # label plan-mutation-filter status reason
    local label="$1" filter="$2" status="$3" reason="$4" out
    out="$(run "$(jq -c "$filter" "$EXAMPLE")")"
    printf '%s' "$out" | jq -e --arg s "$status" --arg r "$reason" '.status == $s and .reasonCode == $r' >/dev/null \
        && pass "$label" || fail "$label: $(printf '%s' "$out" | jq -c 'del(.canonical)')"
}
BASE="$(jq -c . "$EXAMPLE")"

printf '[1] forma y semantica\n'
jq -n -f "$VALIDATOR" >/dev/null 2>&1 && pass 'validador compila' || fail 'validador no compila'
expect 'ejemplo valido' '.' valid PLAN_VALID
expect 'clave extra rechazada' '.extra = 1' invalid INVALID_PLAN_SHAPE
expect 'schemaVersion distinto' '.schemaVersion = 2' invalid INVALID_SCHEMA_VERSION
expect 'prNumber no positivo' '.prNumber = 0' invalid INVALID_PR_NUMBER
expect 'fork no soportado' '.headRepository = "otro/demo"' invalid FORK_NOT_SUPPORTED
expect 'SHA corto' '.expectedHeadSha = "abc123"' invalid INVALID_HEAD_SHA
expect 'SHA en mayusculas' '.expectedHeadSha |= ascii_upcase' invalid INVALID_HEAD_SHA
expect 'ref con ..' '.headRefName = "a/../b"' invalid INVALID_REF
expect 'ids duplicados en snapshot' '.commentSnapshot[1].id = 1001' invalid DUPLICATE_COMMENT_ID
expect 'fila de snapshot con body' '.commentSnapshot[0].body = "texto"' invalid INVALID_SNAPSHOT
expect 'snapshot sin campo nullable' 'del(.commentSnapshot[0].inReplyToId)' invalid INVALID_SNAPSHOT
expect 'triage sin comentario del snapshot' '.triage |= .[:2]' invalid TRIAGE_SNAPSHOT_MISMATCH
expect 'triage con id ajeno' '.triage[2].commentId = 9999' invalid TRIAGE_SNAPSHOT_MISMATCH
expect 'categoria desconocida' '.triage[1].category = "ignorar"' invalid INVALID_TRIAGE
expect 'edits en categoria no-corregir' '.triage[1].edits = [{path:"src/A.cs",change:"x",impact:"y"}]' invalid INVALID_TRIAGE
expect 'edits vacios en no-corregir' '.triage[1].edits = []' invalid INVALID_TRIAGE
expect 'corregir sin edits' '.triage[0].edits = []' invalid INVALID_TRIAGE
expect 'ruta absoluta' '.triage[0].edits[0].path = "/etc/passwd"' invalid INVALID_TRIAGE
expect 'ruta con ..' '.triage[0].edits[0].path = "src/../x.cs"' invalid INVALID_TRIAGE
expect 'edit en workflows' '.triage[0].edits[0].path = ".github/workflows/ci.yml"' invalid INVALID_TRIAGE
expect 'edit en config del harness' '.triage[0].edits[0].path = ".mefisto/harness.config.json"' invalid INVALID_TRIAGE
expect 'verificacion faltante con correccion' '.verification = []' invalid INVALID_VERIFICATION
expect 'verificacion en orden inverso' '.verification = ["dotnet test","dotnet build"]' invalid INVALID_VERIFICATION
expect 'sin correcciones la verificacion es []' '.triage[0] = {commentId:1001,category:"explicar",summary:"Solo explicar."} | .verification = []' valid PLAN_VALID
expect 'sin correcciones no admite verificacion' '.triage[0] = {commentId:1001,category:"explicar",summary:"Solo explicar."}' invalid INVALID_VERIFICATION
expect 'replyPolicy desconocida' '.secondary.replyPolicy = "libre"' invalid INVALID_SECONDARY
expect 'clase local desconocida' '.secondary.localImprovementClasses = ["production-src"]' invalid INVALID_SECONDARY
expect 'limite sin habilitar clase' '.limits.drafts = 1' invalid INVALID_LIMITS
expect 'clase habilitada sin cupo' '.secondary.harnessDrafts = true' invalid INVALID_LIMITS
expect 'limite negativo' '.limits.consumerIssues = -1' invalid INVALID_LIMITS
expect 'planDigest malformado' '.planDigest = "abc"' invalid INVALID_PLAN_DIGEST_FORMAT
expect 'token en resumen' '.triage[1].summary = "usar ghp_abcdefghijklmnopqrstuvwxyz0123456789"' invalid SENSITIVE_CONTENT
expect 'URL con credenciales' '.triage[1].summary = "ver https://user:pass@host/x"' invalid SENSITIVE_CONTENT
[ "$(printf '%s' "$BASE" | jq -c '{plan:.,grants:null,context:{projectId:"otro"}}' | jq -c -f "$VALIDATOR" | jq -r .reasonCode)" = PROJECT_MISMATCH ] \
    && pass 'proyecto distinto al de inspect' || fail 'proyecto distinto'
[ "$(printf '[]' | jq -c -f "$VALIDATOR" | jq -r .reasonCode)" = INVALID_ENVELOPE ] && pass 'envelope malformado' || fail 'envelope malformado'

printf '[2] digest canonico\n'
D0="$(digest_of "$BASE")"
[ "$D0" = "$(jq -r .planDigest "$EXAMPLE")" ] && pass 'planDigest del ejemplo coincide con el canonico' || fail "planDigest divergente: $D0"
differs() {
    local label="$1" filter="$2" d
    d="$(digest_of "$(jq -c "$filter" "$EXAMPLE")")"
    [ -n "$d" ] && [ "$d" != "$D0" ] && pass "cambia digest: $label" || fail "no cambia digest: $label"
}
differs 'head sha' '.expectedHeadSha = "ffffffffffffffffffffffffffffffffffffffff"'
differs 'headRefName' '.headRefName = "fix/otra"'
differs 'digest de body' '.commentSnapshot[0].bodyDigest = ("1" * 64)'
differs 'path del comentario' '.commentSnapshot[0].path = "src/Otro.cs"'
differs 'line' '.commentSnapshot[0].line = 13'
differs 'categoria' '.triage[1].category = "investigar"'
differs 'edit' '.triage[0].edits[0].change = "Otro cambio"'
differs 'planTextDigest' '.planTextDigest = ("2" * 64)'
differs 'secundarios' '.secondary.replyPolicy = "none"'
differs 'limites' '.limits.consumerIssues = 2'
SAME="$(digest_of "$(jq -c '.commentSnapshot |= reverse | .triage |= reverse | .planDigest = ("3" * 64)' "$EXAMPLE")")"
[ "$SAME" = "$D0" ] && pass 'comentarios reordenados con ids iguales: mismo digest' || fail 'reorden altera digest'
KEYS="$(jq -c 'to_entries | reverse | from_entries' "$EXAMPLE")"
[ "$(digest_of "$KEYS")" = "$D0" ] && pass 'orden de claves irrelevante' || fail 'orden de claves altera digest'
run "$BASE" | jq -e '.canonical | contains("\"planDigest\"") | not' >/dev/null && pass 'el canonico excluye planDigest' || fail 'canonico incluye planDigest'

printf '[3] plan Markdown y sanitizacion\n'
[ "$(printf '%s' "$(cat "$PLAN_MD")" | shasum -a 256 | cut -d ' ' -f 1)" = "$(jq -r .planTextDigest "$EXAMPLE")" ] \
    && pass 'planTextDigest coincide con el plan Markdown' || fail 'plan Markdown y digest divergen'
[ "$(jq '[.. | strings] | map(select(length > 280)) | length' "$EXAMPLE")" -eq 0 ] && pass 'sin textos largos (no hay bodies)' || fail 'texto largo en el ejemplo'
grep -Eiq 'ghp_|github_pat_|bearer |BEGIN [A-Z ]*PRIVATE' "$EXAMPLE" "$PLAN_MD" && fail 'secreto en fixtures' || pass 'fixtures sin secretos'

printf '[4] grants\n'
PD="$(jq -r .planDigest "$EXAMPLE")"
grant() { jq -cn --arg a "$1" --arg d "$PD" --arg s "$2" '{command:"fix-review",action:$a,environment:"repository",resources:["pr:42",$s],planDigest:$d}'; }
GOOD="$(jq -cn --argjson a "$(grant fix-review-correct scope:planned-files)" --argjson b "$(grant fix-review-reply scope:review-comments)" --argjson c "$(grant fix-review-consumer-issue scope:consumer-issue)" '[$a,$b,$c]')"
auth() { run "$1" "$2" | jq -r '.authorization.status + ":" + (.authorization.missing | join(","))'; }
[ "$(run "$BASE" | jq -c .requiredActions)" = '["fix-review-correct","fix-review-reply","fix-review-consumer-issue"]' ] && pass 'acciones requeridas segun triage/secondary' || fail 'acciones requeridas'
[ "$(auth "$BASE" "$GOOD")" = 'authorized:' ] && pass 'grants separados autorizan' || fail "grants: $(auth "$BASE" "$GOOD")"
[ "$(auth "$BASE" "$(printf '%s' "$GOOD" | jq -c '.[2:]')")" = 'unauthorized:fix-review-correct,fix-review-reply' ] && pass 'grant faltante no autoriza' || fail 'grant faltante'
[ "$(auth "$BASE" "$(printf '%s' "$GOOD" | jq -c 'map(del(.planDigest))')")" != 'authorized:' ] && pass 'grant sin planDigest no autoriza' || fail 'sin planDigest'
[ "$(auth "$BASE" "$(printf '%s' "$GOOD" | jq -c 'map(.planDigest = ("4" * 64))')")" != 'authorized:' ] && pass 'planDigest ajeno no autoriza' || fail 'planDigest ajeno'
[ "$(auth "$BASE" "$(printf '%s' "$GOOD" | jq -c 'map(.resources[0] = "pr:43")')")" != 'authorized:' ] && pass 'otro PR no autoriza' || fail 'otro PR'
[ "$(auth "$BASE" "$(printf '%s' "$GOOD" | jq -c 'map(.environment = "dev")')")" != 'authorized:' ] && pass 'otro entorno no autoriza' || fail 'otro entorno'
[ "$(auth "$BASE" "$(printf '%s' "$GOOD" | jq -c 'map(.command = "sequential")')")" != 'authorized:' ] && pass 'otro comando no autoriza' || fail 'otro comando'
[ "$(auth "$BASE" "$(printf '%s' "$GOOD" | jq -c 'map(.resources[1] = "scope:harness-draft")')")" != 'authorized:' ] && pass 'scope equivocado no autoriza' || fail 'scope equivocado'
ALL="$(jq -cn --arg d "$PD" '[{command:"fix-review",action:"fix-review-all",environment:"repository",resources:["pr:42","scope:planned-files","scope:review-comments","scope:consumer-issue"],planDigest:$d}]')"
[ "$(auth "$BASE" "$ALL")" != 'authorized:' ] && pass 'fix-review-all nunca se acepta' || fail 'fix-review-all aceptado'
PLAN_DRAFT="$(jq -c '.secondary.harnessDrafts = true | .limits.drafts = 1' "$EXAMPLE")"
run "$PLAN_DRAFT" "$GOOD" | jq -e '.authorization.missing == ["fix-review-harness-draft"]' >/dev/null && pass 'harness-draft exige su propio grant' || fail 'harness-draft'
PLAN_LOCAL="$(jq -c '.secondary.localImprovementClasses = ["consumer-adr"] | .limits.localFiles = 2' "$EXAMPLE")"
run "$PLAN_LOCAL" "$(printf '%s' "$GOOD" | jq -c --argjson g "$(grant fix-review-local-improvement scope:consumer-docs)" '. + [$g]')" | jq -e '.authorization.status == "authorized"' >/dev/null && pass 'local-improvement exige su digest propio' || fail 'local-improvement'

printf '\nPASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
