#!/usr/bin/env bash
# Gate de consulta de admision de /fix-review preautorizado (issue #1889, MEF-ADR-0055).
# Solo lee: no publica, no edita, no aprueba/revoca ni muta el contexto. Responde si la SIGUIENTE accion
# esta dentro del plan aprobado (#1886), el snapshot sellado (#1887) y los recibos propios (#1888).
# Uso: fix-review-admission.sh check --project-root <approved-root> --pr <N> --plan-id <planDigest>
#        --phase <pre-edit|pre-push|pre-reply|pre-improvement|finish> [--comment-id <id>] [--action <categoria>]
# Salida: JSON {schemaVersion:1,status:authorized|blocked|incomplete,phase,projectId,planDigest,currentHead,allowedActions,diagnostics:[{code,actionCode}]}
# Proceso: 0 authorized, 1 blocked/incomplete, 2 protocolo. Sin cuerpos de comentarios, texto del plan ni secretos en la salida.
# La politica es cooperativa (no sandbox) y no distingue permisos remotos de GitHub de la politica local.
set -uo pipefail
export LC_ALL=C
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VALIDATOR="$SCRIPT_DIR/../src/published/contract/fix-review-plan.validate.jq"
AUTONOMY="$SCRIPT_DIR/autonomy-profile.sh"
BLOCKED_FIRST='.git .github .mefisto .claude .claude-plugin .opencode infra'
MAX_COMMENTS=30

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }
usage() { fail 'uso: fix-review-admission.sh check --project-root <raiz> --pr <N> --plan-id <digest> --phase <pre-edit|pre-push|pre-reply|pre-improvement|finish> [--comment-id <id>] [--action <categoria>]'; }
hash_stdin() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d ' ' -f 1
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d ' ' -f 1
    else fail 'no se encontro una implementacion de SHA-256'
    fi
}
git_common_dir() {
    local root="$1" common
    common="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || return 1
    case "$common" in
        /*) cd "$common" 2>/dev/null && pwd -P ;;
        *) cd "$root/$common" 2>/dev/null && pwd -P ;;
    esac
}
perm_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }

[ "${1:-}" = check ] || usage
shift
PROJECT_ROOT=""; PR=""; PLAN_ID=""; PHASE=""; COMMENT_ID=""; ACTION=""
S_R=0; S_P=0; S_I=0; S_H=0; S_C=0; S_A=0
while [ $# -gt 0 ]; do
    case "$1" in
        --project-root) [ $# -ge 2 ] && [ "$S_R" -eq 0 ] || usage; PROJECT_ROOT="$2"; S_R=1; shift 2 ;;
        --pr) [ $# -ge 2 ] && [ "$S_P" -eq 0 ] || usage; PR="$2"; S_P=1; shift 2 ;;
        --plan-id) [ $# -ge 2 ] && [ "$S_I" -eq 0 ] || usage; PLAN_ID="$2"; S_I=1; shift 2 ;;
        --phase) [ $# -ge 2 ] && [ "$S_H" -eq 0 ] || usage; PHASE="$2"; S_H=1; shift 2 ;;
        --comment-id) [ $# -ge 2 ] && [ "$S_C" -eq 0 ] || usage; COMMENT_ID="$2"; S_C=1; shift 2 ;;
        --action) [ $# -ge 2 ] && [ "$S_A" -eq 0 ] || usage; ACTION="$2"; S_A=1; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$PROJECT_ROOT" ] && [ -n "$PR" ] && [ -n "$PLAN_ID" ] && [ -n "$PHASE" ] || usage
printf '%s' "$PR" | grep -Eq '^[1-9][0-9]{0,9}$' || fail 'pr debe ser un entero positivo'
printf '%s' "$PLAN_ID" | grep -Eq '^[0-9a-f]{64}$' || fail 'plan-id debe ser un SHA-256 en hex minuscula'
case "$PHASE" in pre-edit|pre-push|pre-reply|pre-improvement|finish) ;; *) fail 'phase invalida' ;; esac
[ -z "$COMMENT_ID" ] || printf '%s' "$COMMENT_ID" | grep -Eq '^[1-9][0-9]{0,15}$' || fail 'comment-id invalido'
[ -z "$ACTION" ] || printf '%s' "$ACTION" | grep -Eq '^[a-z0-9][a-z0-9-]{0,60}$' || fail 'action invalida'
[ "$PHASE" != pre-reply ] || [ -n "$COMMENT_ID" ] || fail 'pre-reply requiere --comment-id'
[ "$PHASE" != pre-improvement ] || [ -n "$ACTION" ] || fail 'pre-improvement requiere --action'
for tool in jq git gh; do [ -x "$(command -v "$tool" 2>/dev/null || true)" ] || fail "$tool no esta instalado"; done
[ -x "$(command -v shasum 2>/dev/null || command -v sha256sum 2>/dev/null || true)" ] || fail 'no se encontro una implementacion de SHA-256'
[ -f "$VALIDATOR" ] && [ -f "$AUTONOMY" ] || fail 'faltan el validador del plan o autonomy-profile.sh'

PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P)" || fail 'la raiz de proyecto no existe'
PROJECT_TOP="$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)" || fail 'la raiz indicada no es un repositorio Git'
PROJECT_TOP="$(cd "$PROJECT_TOP" 2>/dev/null && pwd -P)" || fail 'la raiz Git no es accesible'
[ "$PROJECT_ROOT" = "$PROJECT_TOP" ] || fail 'project-root debe ser la raiz del worktree o repositorio'
[ ! -f "$PROJECT_ROOT/.claude-plugin/plugin.json" ] || fail 'fix-review-admission.sh es del plugin publicado y solo aplica al consumidor'
COMMON_DIR="$(git_common_dir "$PROJECT_ROOT")" || fail 'no se pudo resolver la identidad Git comun'
CALLER_TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$CALLER_TOP" ]; then
    CALLER_COMMON="$(git_common_dir "$CALLER_TOP")" || fail 'no se pudo verificar la identidad Git del caller'
    [ "$CALLER_COMMON" = "$COMMON_DIR" ] || fail 'project-root no pertenece al proyecto del worktree caller'
fi
LOCAL_PROJECT_ID="project-$(printf '%s' "$COMMON_DIR" | hash_stdin | cut -c1-24)"

# --- Salida ---
PROJECT_ID=""; OUT_PLAN=""; CURRENT_HEAD=""; ALLOWED='[]'; DIAGS='[]'
emit() { # status
    jq -cn --arg s "$1" --arg ph "$PHASE" --arg pid "$PROJECT_ID" --arg pd "$OUT_PLAN" --arg h "$CURRENT_HEAD" --argjson a "$ALLOWED" --argjson d "$DIAGS" \
        '{schemaVersion:1,status:$s,phase:$ph,projectId:(if $pid=="" then null else $pid end),planDigest:(if $pd=="" then null else $pd end),currentHead:(if $h=="" then null else $h end),allowedActions:$a,diagnostics:$d}'
}
add_diag() { DIAGS="$(printf '%s' "$DIAGS" | jq -c --arg c "$1" --arg a "$2" '. + [{code:$c,actionCode:$a}]')"; }
stop() { # status code actionCode
    ALLOWED='[]'; add_diag "$2" "${3:-stop-and-report}"; emit "$1"; exit 1
}
blocked() { stop blocked "$1" "${2:-stop-and-report}"; }
incomplete() { stop incomplete "$1" "${2:-retry-read-once}"; }

STATE_REL=".mefisto/pipeline"
SEALED="$PROJECT_ROOT/$STATE_REL/autonomy/fix-review/$PLAN_ID.json"
RECEIPTS="$PROJECT_ROOT/$STATE_REL/autonomy/fix-review/$PLAN_ID.receipts.json"
TEXT_REL="$STATE_REL/summaries/fix-review/$PLAN_ID.md"
TEXT_FILE="$PROJECT_ROOT/$TEXT_REL"
no_symlinks() {
    local rel="${1#"$PROJECT_ROOT"/}" current="$PROJECT_ROOT" part
    local IFS=/
    for part in $rel; do current="$current/$part"; [ ! -L "$current" ] || return 1; done
    return 0
}

# --- 1. Plan sellado propio con digest recomputado ---
no_symlinks "$SEALED" && no_symlinks "$RECEIPTS" && no_symlinks "$TEXT_FILE" || blocked STATE_SYMLINK
[ -f "$SEALED" ] && [ ! -L "$SEALED" ] || incomplete PLAN_NOT_SEALED reprepare-outside-batch
SEALED_JSON="$(jq -cS . "$SEALED" 2>/dev/null)" || blocked PLAN_SEALED_CORRUPT reprepare-outside-batch
PLAN="$(printf '%s' "$SEALED_JSON" | jq -cS '.plan // null')"
printf '%s' "$PLAN" | jq -e 'type == "object"' >/dev/null 2>&1 || blocked PLAN_SEALED_CORRUPT reprepare-outside-batch
[ "$(printf '%s' "$PLAN" | jq -r '.planDigest // ""')" = "$PLAN_ID" ] || blocked PLAN_DIGEST_MISMATCH reprepare-outside-batch
plan_validate() { jq -cn --argjson p "$PLAN" --argjson g "$1" --arg id "$2" '{plan:$p,grants:$g,context:{projectId:$id}}' | jq -c -f "$VALIDATOR" 2>/dev/null; }
PLAN_PROJECT="$(printf '%s' "$PLAN" | jq -r '.projectId // ""')"
VAL0="$(plan_validate null "$PLAN_PROJECT")" || blocked PLAN_VALIDATOR_FAILED reprepare-outside-batch
[ "$(printf '%s' "$VAL0" | jq -r '.status')" = valid ] || blocked PLAN_INVALID reprepare-outside-batch
[ "$(printf '%s' "$VAL0" | jq -j '.canonical' | hash_stdin)" = "$PLAN_ID" ] || blocked PLAN_DIGEST_MISMATCH reprepare-outside-batch
PROJECT_ID="$PLAN_PROJECT"
[ "$PLAN_PROJECT" = "$LOCAL_PROJECT_ID" ] || blocked PROJECT_MISMATCH reprepare-outside-batch
OUT_PLAN="$PLAN_ID"
[ "$(printf '%s' "$PLAN" | jq -r '.prNumber')" = "$PR" ] || blocked PR_MISMATCH reprepare-outside-batch
REPO_SLUG="$(printf '%s' "$PLAN" | jq -r '.repoSlug')"
HEAD_REF="$(printf '%s' "$PLAN" | jq -r '.headRefName')"
INITIAL_SHA="$(printf '%s' "$PLAN" | jq -r '.expectedHeadSha')"
REQUIRED="$(printf '%s' "$VAL0" | jq -c '.requiredActions')"

# Copia Markdown propia (#1887): ausente o alterada -> incomplete antes de cualquier edicion.
[ "$(printf '%s' "$SEALED_JSON" | jq -r '.planTextPath // ""')" = "$TEXT_REL" ] || blocked PLAN_TEXT_PATH_INVALID reprepare-outside-batch
[ -f "$TEXT_FILE" ] && [ ! -L "$TEXT_FILE" ] || incomplete PLAN_TEXT_MISSING reprepare-outside-batch
[ "$(hash_stdin < "$TEXT_FILE")" = "$(printf '%s' "$PLAN" | jq -r '.planTextDigest // ""')" ] || incomplete PLAN_TEXT_ALTERED reprepare-outside-batch

# --- 2. Consentimiento vigente via inspect (no se aprueba ni se repara aqui) ---
INSPECT="$(bash "$AUTONOMY" inspect --project-root "$PROJECT_ROOT" 2>/dev/null)" || true
printf '%s' "$INSPECT" | jq -e 'type == "object"' >/dev/null 2>&1 || blocked CONSENT_UNREADABLE request-new-approval-outside-batch
if ! printf '%s' "$INSPECT" | jq -e '.status == "ready" and .reasonCode == "CONSENT_APPROVED"' >/dev/null 2>&1; then
    blocked "CONSENT_$(printf '%s' "$INSPECT" | jq -r '.reasonCode // "UNKNOWN"' | tr -c 'A-Za-z0-9\n' '_' | cut -c1-40)" request-new-approval-outside-batch
fi
[ "$(printf '%s' "$INSPECT" | jq -r '.projectId')" = "$PLAN_PROJECT" ] || blocked PROJECT_MISMATCH request-new-approval-outside-batch
PROFILE_DIGEST="$(printf '%s' "$INSPECT" | jq -r '.profileDigest // ""')"
GRANTS="$(printf '%s' "$INSPECT" | jq -c '.profile.administration // []')"
VALG="$(plan_validate "$GRANTS" "$PLAN_PROJECT")" || blocked PLAN_VALIDATOR_FAILED reprepare-outside-batch
SCOPE_OF='{"fix-review-correct":"scope:planned-files","fix-review-reply":"scope:review-comments","fix-review-consumer-issue":"scope:consumer-issue","fix-review-harness-draft":"scope:harness-draft","fix-review-local-improvement":"scope:consumer-docs"}'
need_grant() { # accion: grant exacto (command/environment/resources/planDigest) y accion requerida por el plan
    printf '%s' "$REQUIRED" | jq -e --arg a "$1" 'index($a) != null' >/dev/null 2>&1 || blocked "ACTION_NOT_PLANNED:$1" stop-and-report
    printf '%s' "$VALG" | jq -e --arg a "$1" '.status == "valid" and ((.authorization.missing // []) | index($a)) == null' >/dev/null 2>&1 \
        || blocked "GRANT_MISSING:$1" request-new-approval-outside-batch
    printf '%s' "$GRANTS" | jq -e --arg a "$1" --arg pd "$PLAN_ID" --arg pr "pr:$PR" --argjson s "$SCOPE_OF" '
        any(.[]; .command == "fix-review" and .action == $a and .environment == "repository" and (.planDigest // "") == $pd
                 and ((.resources // []) | sort) == ([$pr, $s[$a]] | sort))' >/dev/null 2>&1 \
        || blocked "GRANT_NOT_EXACT:$1" request-new-approval-outside-batch
}

# --- 3. Recibos propios (#1888) ---
RCP='null'
if [ -e "$RECEIPTS" ] || [ -L "$RECEIPTS" ]; then
    [ -f "$RECEIPTS" ] && [ ! -L "$RECEIPTS" ] || blocked RECEIPTS_NOT_REGULAR
    [ "$(perm_of "$RECEIPTS")" = 600 ] || blocked RECEIPTS_INSECURE
    RCP="$(jq -cS . "$RECEIPTS" 2>/dev/null)" || blocked RECEIPTS_CORRUPT
    printf '%s' "$RCP" | jq -e --arg pd "$PLAN_ID" --arg pid "$PLAN_PROJECT" --argjson pr "$PR" \
        'type == "object" and .schemaVersion == 1 and .planDigest == $pd and .projectId == $pid and .prNumber == $pr
         and (.headTransitions | type == "array") and (.replies | type == "array") and (.issues | type == "array")' >/dev/null 2>&1 || blocked RECEIPTS_CORRUPT
    [ "$(printf '%s' "$RCP" | jq -r '.profileDigest // ""')" = "$PROFILE_DIGEST" ] || blocked PROFILE_DIGEST_MISMATCH request-new-approval-outside-batch
else
    RCP="$(jq -cn --arg i "$INITIAL_SHA" '{headTransitions:[],replies:[],issues:[],initialHeadSha:$i}')"
fi
# La cadena de recibos debe partir del head sellado y encadenarse sin huecos (un libro editado a mano no acredita pushes).
printf '%s' "$RCP" | jq -e --arg i "$INITIAL_SHA" --arg repo "$REPO_SLUG" --arg ref "$HEAD_REF" '
    ((.initialHeadSha // $i) == $i) and ((.repoSlug // $repo) == $repo) and ((.headRefName // $ref) == $ref)
    and (.headTransitions as $t | all(range(0; $t | length);
        ($t[.].to | type == "string" and test("^[0-9a-f]{40}$"))
        and $t[.].from == (if . == 0 then $i else $t[. - 1].to end)))' >/dev/null 2>&1 || blocked HEAD_CHAIN_BROKEN reprepare-outside-batch
EXPECTED_HEAD="$(printf '%s' "$RCP" | jq -r --arg i "$INITIAL_SHA" '(.headTransitions | last | .to) // $i')"
HAS_TRANSITIONS="$(printf '%s' "$RCP" | jq '.headTransitions | length > 0')"

# --- 4. Estado remoto (solo lecturas; sin credenciales propias) ---
SLUG="$(cd "$PROJECT_ROOT" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || incomplete GH_REPO_UNREADABLE retry-read-once
[ "$SLUG" = "$REPO_SLUG" ] || blocked REPO_MISMATCH stop-and-report
PRJ="$(cd "$PROJECT_ROOT" && gh pr view "$PR" --repo "$REPO_SLUG" --json headRefOid,headRefName,state,url,isCrossRepository 2>/dev/null)" \
    && printf '%s' "$PRJ" | jq -e 'type == "object"' >/dev/null 2>&1 || incomplete GH_PR_UNREADABLE retry-read-once
printf '%s' "$PRJ" | jq -e '.state == "OPEN"' >/dev/null 2>&1 || blocked PR_NOT_OPEN stop-and-report
printf '%s' "$PRJ" | jq -e --arg ref "$HEAD_REF" --arg url "https://github.com/$REPO_SLUG/pull/$PR" '.headRefName == $ref and .url == $url and .isCrossRepository == false' >/dev/null 2>&1 || blocked PR_IDENTITY_MISMATCH stop-and-report
REMOTE_HEAD="$(printf '%s' "$PRJ" | jq -r '.headRefOid // ""')"
printf '%s' "$REMOTE_HEAD" | grep -Eq '^[0-9a-f]{40}$' || incomplete GH_PR_UNREADABLE retry-read-once
CURRENT_HEAD="$REMOTE_HEAD"
[ "$REMOTE_HEAD" = "$EXPECTED_HEAD" ] || blocked HEAD_NOT_IN_OWN_CHAIN reprepare-outside-batch

RAW="$(cd "$PROJECT_ROOT" && gh api "repos/$REPO_SLUG/pulls/$PR/comments" --paginate 2>/dev/null)" || incomplete GH_COMMENTS_UNREADABLE retry-read-once
RAW="$(printf '%s' "$RAW" | jq -s -c '[.[] | if type == "array" then .[] else . end]' 2>/dev/null)" || incomplete GH_COMMENTS_UNREADABLE retry-read-once
printf '%s' "$RAW" | jq -e 'all(.[]; type == "object" and (.id | type == "number"))' >/dev/null 2>&1 || incomplete GH_COMMENTS_AMBIGUOUS retry-read-once
LIVE="$(printf '%s' "$RAW" | jq -c '[.[] | {id:.id,body:(.body // ""),path:(.path // null),line:(.line // null),originalLine:(.original_line // null),inReplyToId:(.in_reply_to_id // null)}] | unique_by(.id)')"
# El limite aplica a los comentarios ajenos: las respuestas propias con recibo no consumen cupo.
[ "$(printf '%s' "$LIVE" | jq --argjson r "$RCP" '[.[] | select(.id as $i | $r.replies | any(.[]; .replyId == $i) | not)] | length')" -le "$MAX_COMMENTS" ] \
    || blocked COMMENTS_OVER_LIMIT reprepare-outside-batch
# bodyDigest de los comentarios vivos (solo hashes llegan a la comparacion)
LIVE_H='[]'
for id in $(printf '%s' "$LIVE" | jq -r '.[].id'); do
    h="$(printf '%s' "$LIVE" | jq -j --argjson i "$id" 'map(select(.id == $i))[0].body' | hash_stdin)"
    LIVE_H="$(jq -cn --argjson l "$LIVE_H" --argjson c "$(printf '%s' "$LIVE" | jq -c --argjson i "$id" --arg h "$h" 'map(select(.id == $i))[0] | del(.body) + {bodyDigest:$h}')" '$l + [$c]')"
done
SNAPSHOT="$(printf '%s' "$PLAN" | jq -c '.commentSnapshot')"
CMP="$(jq -rn --argjson live "$LIVE_H" --argjson snap "$SNAPSHOT" --argjson rcp "$RCP" --argjson lenient "$HAS_TRANSITIONS" '
    ($snap | map({key:(.id|tostring),value:.}) | from_entries) as $s
    | ($rcp.replies | map({key:(.replyId|tostring),value:.}) | from_entries) as $r
    | ($live | map({key:(.id|tostring),value:.}) | from_entries) as $l
    | [ ($s | keys[] | select($l[.] == null) | "COMMENT_REMOVED"),
        ($s | keys[] | select($l[.] != null) | . as $k
            | ($s[$k]) as $a | ($l[$k]) as $b
            | select($a.bodyDigest != $b.bodyDigest or $a.path != $b.path or $a.originalLine != $b.originalLine
                     or $a.inReplyToId != $b.inReplyToId or ((($lenient) | not) and $a.line != $b.line)) | "COMMENT_MODIFIED"),
        ($l | keys[] | select($s[.] == null and $r[.] == null) | . as $k | if ($s[($l[$k].inReplyToId // 0) | tostring] != null) then "UNRECORDED_REPLY" else "NEW_EXTERNAL_COMMENT" end),
        ($r | keys[] | select($l[.] == null) | "REPLY_RECEIPT_WITHOUT_REMOTE") ] | unique | first // ""')"
case "$CMP" in
    "") ;;
    UNRECORDED_REPLY) blocked UNRECORDED_REPLY record-receipt-with-evidence ;;
    *) blocked "$CMP" reprepare-outside-batch ;;
esac

# --- 5. Reglas por fase ---
in_snapshot() { printf '%s' "$SNAPSHOT" | jq -e --argjson i "$1" 'any(.[]; .id == $i)' >/dev/null 2>&1; }
local_state_ok() { # worktree propio en la rama del PR, limpio y en la cabeza vigente
    [ "$(git -C "$PROJECT_ROOT" symbolic-ref --short -q HEAD 2>/dev/null || true)" = "$HEAD_REF" ] || blocked WORKTREE_BRANCH_MISMATCH stop-and-report
    [ -z "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ] || blocked WORKTREE_DIRTY stop-and-report
}
safe_path() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._@+-]+(/[A-Za-z0-9._@+-]+)*$' || return 1
    case "/$1/" in */./*|*/../*) return 1 ;; esac
    local first="${1%%/*}" b
    for b in $BLOCKED_FIRST; do [ "$first" != "$b" ] || return 1; done
    case "${1##*/}" in harness.config.json|.env*) return 1 ;; esac
    return 0
}
path_in_class() {
    case "$1" in
        consumer-adr) case "$2" in docs/adr/*.md) return 0 ;; esac; return 1 ;;
        consumer-directives) [ "$2" = AGENTS.md ] || [ "$2" = CLAUDE.md ] ;;
        consumer-test-helper) printf '%s' "$2" | grep -Eq '^(tests?/|(.*/)?[A-Za-z0-9._-]+\.Tests?/).*(Helper|Builder|Fixture|Fake|Support|Testing)[A-Za-z0-9._-]*\.cs$' ;;
        *) return 1 ;;
    esac
}
class_of_action() { # accion -> clase local; vacio para las acciones fix-review-* (no son clases)
    case "$1" in fix-review-*) printf '' ;; *) printf '%s' "$1" ;; esac
}
HAS_CORREGIR="$(printf '%s' "$PLAN" | jq '[.triage[] | select(.category == "corregir")] | length > 0')"
PLANNED_PATHS="$(printf '%s' "$PLAN" | jq -c '[.triage[] | select(.category == "corregir") | .edits[].path]')"

case "$PHASE" in
pre-edit)
    if [ "$HAS_CORREGIR" != true ]; then ALLOWED='[]'; emit authorized; exit 0; fi
    need_grant fix-review-correct
    local_state_ok
    [ "$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null)" = "$REMOTE_HEAD" ] || blocked WORKTREE_HEAD_MISMATCH stop-and-report
    [ "$HAS_TRANSITIONS" = false ] || printf '%s' "$RCP" | jq -e 'all(.headTransitions[]; .phase != "corrections")' >/dev/null 2>&1 || blocked CORRECTIONS_ALREADY_APPLIED stop-and-report
    ALLOWED="$(printf '%s' "$PLANNED_PATHS" | jq -c 'map("edit:" + .)')"
    ;;
pre-push)
    CLASS="$(class_of_action "${ACTION:-fix-review-correct}")"
    if [ -n "$CLASS" ] || [ "${ACTION:-}" = fix-review-local-improvement ]; then
        [ -n "$CLASS" ] || blocked ACTION_NOT_PLANNED:class-required stop-and-report
        printf '%s' "$PLAN" | jq -e --arg c "$CLASS" '.secondary.localImprovementClasses | index($c) != null' >/dev/null 2>&1 || blocked CLASS_NOT_APPROVED stop-and-report
        need_grant fix-review-local-improvement
        KIND=improvements
    else
        [ "$HAS_CORREGIR" = true ] || blocked NO_CORRECTIONS_PLANNED stop-and-report
        need_grant fix-review-correct
        KIND=corrections
    fi
    local_state_ok
    LOCAL_HEAD="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null)" || blocked WORKTREE_HEAD_MISMATCH stop-and-report
    [ "$LOCAL_HEAD" != "$REMOTE_HEAD" ] || blocked NO_CODE_CHANGES stop-and-report
    git -C "$PROJECT_ROOT" cat-file -e "$REMOTE_HEAD^{commit}" 2>/dev/null && git -C "$PROJECT_ROOT" merge-base --is-ancestor "$REMOTE_HEAD" "$LOCAL_HEAD" 2>/dev/null || blocked NOT_DESCENDANT stop-and-report
    [ -z "$(git -C "$PROJECT_ROOT" rev-list --merges "$REMOTE_HEAD..$LOCAL_HEAD" 2>/dev/null)" ] || blocked MERGE_COMMITS stop-and-report
    if git -C "$PROJECT_ROOT" diff --raw --no-renames "$REMOTE_HEAD" "$LOCAL_HEAD" 2>/dev/null | awk '$1 ~ /120000/ || $2 ~ /120000/ {f=1} END {exit !f}'; then blocked SYMLINK_CHANGE stop-and-report; fi
    PATHS="$(git -C "$PROJECT_ROOT" -c core.quotepath=off diff --name-only --no-renames "$REMOTE_HEAD" "$LOCAL_HEAD" 2>/dev/null)" || incomplete DIFF_UNREADABLE retry-read-once
    [ -n "$PATHS" ] || blocked NO_CODE_CHANGES stop-and-report
    PATHS_JSON='[]'
    while IFS= read -r p; do
        safe_path "$p" || blocked PATH_NOT_ALLOWED stop-and-report
        if [ "$KIND" = improvements ]; then path_in_class "$CLASS" "$p" || blocked PATH_NOT_IN_CLASS stop-and-report; fi
        PATHS_JSON="$(printf '%s' "$PATHS_JSON" | jq -c --arg p "$p" '. + [$p]')"
    done <<EOF
$PATHS
EOF
    if [ "$KIND" = corrections ]; then
        printf '%s' "$PATHS_JSON" | jq -e --argjson ok "$PLANNED_PATHS" '(. - $ok) == []' >/dev/null 2>&1 || blocked PATH_NOT_PLANNED reprepare-outside-batch
        ALLOWED='["push:fix-review-correct","verify-before-push"]'
    else
        USED="$(jq -n --argjson r "$RCP" --argjson n "$PATHS_JSON" '([$r.headTransitions[] | select(.phase == "improvements") | .paths[]] + $n) | unique | length')"
        [ "$USED" -le "$(printf '%s' "$PLAN" | jq '.limits.localFiles')" ] || blocked LOCAL_FILES_QUOTA_EXCEEDED stop-and-report
        ALLOWED="$(jq -cn --arg c "$CLASS" '["push:fix-review-local-improvement:" + $c,"verify-before-push"]')"
    fi
    ;;
pre-reply)
    need_grant fix-review-reply
    printf '%s' "$PLAN" | jq -e '.secondary.replyPolicy == "freeform-factual"' >/dev/null 2>&1 || blocked REPLY_POLICY_NONE stop-and-report
    in_snapshot "$COMMENT_ID" || blocked COMMENT_NOT_IN_SNAPSHOT stop-and-report
    printf '%s' "$RCP" | jq -e --argjson i "$COMMENT_ID" 'any(.replies[]; .parentId == $i)' >/dev/null 2>&1 && blocked DUPLICATE_REPLY stop-and-report
    ALLOWED="$(jq -cn --arg i "$COMMENT_ID" '["reply:" + $i + ":factual-no-resolve"]')"
    ;;
pre-improvement)
    case "$ACTION" in
        fix-review-consumer-issue)
            need_grant fix-review-consumer-issue
            printf '%s' "$PLAN" | jq -e '.secondary.consumerIssues == true' >/dev/null 2>&1 || blocked ACTION_OUT_OF_SCOPE stop-and-report
            USED="$(printf '%s' "$RCP" | jq '[.issues[] | select(.type == "consumer")] | length')"
            [ "$USED" -lt "$(printf '%s' "$PLAN" | jq '.limits.consumerIssues')" ] || blocked QUOTA_EXCEEDED stop-and-report
            if [ -n "$COMMENT_ID" ]; then
                printf '%s' "$PLAN" | jq -e --argjson c "$COMMENT_ID" 'any(.triage[]; .commentId == $c and .category == "investigar")' >/dev/null 2>&1 || blocked ORIGIN_NOT_INVESTIGAR stop-and-report
            fi ;;
        fix-review-harness-draft)
            need_grant fix-review-harness-draft
            printf '%s' "$PLAN" | jq -e '.secondary.harnessDrafts == true' >/dev/null 2>&1 || blocked ACTION_OUT_OF_SCOPE stop-and-report
            USED="$(printf '%s' "$RCP" | jq '[.issues[] | select(.type == "harness")] | length')"
            [ "$USED" -lt "$(printf '%s' "$PLAN" | jq '.limits.drafts')" ] || blocked QUOTA_EXCEEDED stop-and-report ;;
        fix-review-local-improvement|fix-review-correct|fix-review-reply) blocked ACTION_OUT_OF_SCOPE stop-and-report ;;
        *)
            printf '%s' "$PLAN" | jq -e --arg c "$ACTION" '.secondary.localImprovementClasses | index($c) != null' >/dev/null 2>&1 || blocked ACTION_OUT_OF_SCOPE stop-and-report
            need_grant fix-review-local-improvement
            USED="$(printf '%s' "$RCP" | jq '[.headTransitions[] | select(.phase == "improvements") | .paths[]] | unique | length')"
            [ "$USED" -lt "$(printf '%s' "$PLAN" | jq '.limits.localFiles')" ] || blocked QUOTA_EXCEEDED stop-and-report
            local_state_ok
            [ "$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null)" = "$REMOTE_HEAD" ] || blocked WORKTREE_HEAD_MISMATCH stop-and-report ;;
    esac
    ALLOWED="$(jq -cn --arg a "$ACTION" '["improve:" + $a]')"
    ;;
finish)
    ALLOWED='[]'
    N_PUSH="$(printf '%s' "$RCP" | jq '[.headTransitions[] | select(.phase == "corrections")] | length')"
    if [ "$HAS_CORREGIR" = true ] && [ "$N_PUSH" -eq 0 ]; then add_diag PARTIAL_CODE_NOT_APPLIED report-as-partial; fi
    PENDING_REPLIES="$(jq -rn --argjson p "$PLAN" --argjson r "$RCP" '[$p.triage[] | select(.category != "corregir") | .commentId | select(. as $c | $r.replies | any(.[]; .parentId == $c) | not)] | length')"
    if [ "$(printf '%s' "$PLAN" | jq -r '.secondary.replyPolicy')" = freeform-factual ] && [ "$PENDING_REPLIES" -gt 0 ]; then add_diag PARTIAL_REPLIES_PENDING report-as-partial; fi
    PENDING_ISSUES="$(jq -rn --argjson p "$PLAN" --argjson r "$RCP" '[$p.triage[] | select(.category == "investigar") | .commentId | select(. as $c | $r.issues | any(.[]; .origin == ("comment:" + ($c | tostring))) | not)] | length')"
    if [ "$(printf '%s' "$PLAN" | jq -r '.secondary.consumerIssues')" = true ] && [ "$PENDING_ISSUES" -gt 0 ]; then add_diag PARTIAL_FOLLOWUP_NOT_RECORDED report-as-partial; fi
    if [ "$(printf '%s' "$DIAGS" | jq 'length')" -gt 0 ]; then emit incomplete; exit 1; fi
    ;;
esac
emit authorized
exit 0
