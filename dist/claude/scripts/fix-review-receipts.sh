#!/usr/bin/env bash
# Libro de recibos de /fix-review preautorizado (issue #1888, MEF-ADR-0055).
# Registra SOLO las transiciones que la corrida aprobada ya ejecuto (push, respuesta, issue, draft);
# no ejecuta ninguna accion remota, no aprueba, no repara config y no es un bypass de revision.
# Uso: fix-review-receipts.sh <record-push|record-reply|record-consumer-issue|record-harness-draft|status>
#        --project-root <raiz> --plan-id <planDigest> [--reference <id>]   (request JSON por stdin)
# Salida: JSON {schemaVersion,status:recorded|conflict|unknown|ok|none,operation,planDigest,runId,code,recovery,revision}
# Salida de proceso: 0 recorded/ok/none, 1 conflict, 2 uso o entorno, 3 unknown (recuperar con evidencia, no reintentar a ciegas).
set -uo pipefail
export LC_ALL=C
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VALIDATOR="$SCRIPT_DIR/../src/published/contract/fix-review-plan.validate.jq"
AUTONOMY="$SCRIPT_DIR/autonomy-profile.sh"
DEFAULT_HARNESS_SLUG='augusto-romero-arango/eda-evsourcing-azure-harness'
BLOCKED_FIRST='.git .github .mefisto .claude .claude-plugin .opencode infra'

OP="${1:-}"; [ $# -gt 0 ] && shift
PLAN_ID=""; PROJECT_ROOT=""; REFERENCE=""; RUN_ID=""; REVISION="null"
fail() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }
usage() { fail 'uso: fix-review-receipts.sh <record-push|record-reply|record-consumer-issue|record-harness-draft|status> --project-root <raiz> --plan-id <digest> [--reference <id>]'; }
out() { # status code [recovery]
    jq -cn --arg s "$1" --arg op "$OP" --arg pd "$PLAN_ID" --arg run "$RUN_ID" --arg c "$2" --arg rec "${3:-}" --argjson rev "$REVISION" \
        '{schemaVersion:1,status:$s,operation:$op,planDigest:(if $pd=="" then null else $pd end),runId:(if $run=="" then null else $run end),code:$c,recovery:(if $rec=="" then null else $rec end),revision:$rev}'
}
conflict() { out conflict "$1" "${2:-}"; exit 1; }
unknown() { out unknown "$1" "${2:-}"; exit 3; }
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

case "$OP" in record-push|record-reply|record-consumer-issue|record-harness-draft|status) ;; *) usage ;; esac
SEEN_R=0; SEEN_P=0; SEEN_F=0
while [ $# -gt 0 ]; do
    case "$1" in
        --project-root) [ $# -ge 2 ] && [ "$SEEN_R" -eq 0 ] || usage; PROJECT_ROOT="$2"; SEEN_R=1; shift 2 ;;
        --plan-id) [ $# -ge 2 ] && [ "$SEEN_P" -eq 0 ] || usage; PLAN_ID="$2"; SEEN_P=1; shift 2 ;;
        --reference) [ $# -ge 2 ] && [ "$SEEN_F" -eq 0 ] || usage; REFERENCE="$2"; SEEN_F=1; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$PROJECT_ROOT" ] && [ -n "$PLAN_ID" ] || usage
printf '%s' "$PLAN_ID" | grep -Eq '^[0-9a-f]{64}$' || fail 'plan-id debe ser un SHA-256 en hex minuscula'
[ -z "$REFERENCE" ] || printf '%s' "$REFERENCE" | grep -Eq '^[A-Za-z0-9:._-]{1,80}$' || fail 'reference invalida'
for tool in jq git gh; do [ -x "$(command -v "$tool" 2>/dev/null || true)" ] || fail "$tool no esta instalado"; done
[ -x "$(command -v shasum 2>/dev/null || command -v sha256sum 2>/dev/null || true)" ] || fail 'no se encontro una implementacion de SHA-256'
[ -f "$VALIDATOR" ] && [ -f "$AUTONOMY" ] || fail 'faltan el validador del plan o autonomy-profile.sh'

PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P)" || fail 'la raiz de proyecto no existe'
PROJECT_TOP="$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)" || fail 'la raiz indicada no es un repositorio Git'
PROJECT_TOP="$(cd "$PROJECT_TOP" 2>/dev/null && pwd -P)" || fail 'la raiz Git no es accesible'
[ "$PROJECT_ROOT" = "$PROJECT_TOP" ] || fail 'project-root debe ser la raiz del worktree o repositorio'
[ ! -f "$PROJECT_ROOT/.claude-plugin/plugin.json" ] || fail 'fix-review-receipts.sh es del plugin publicado y solo aplica al consumidor'
COMMON_DIR="$(git_common_dir "$PROJECT_ROOT")" || fail 'no se pudo resolver la identidad Git comun'
CALLER_TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$CALLER_TOP" ]; then
    CALLER_COMMON="$(git_common_dir "$CALLER_TOP")" || fail 'no se pudo verificar la identidad Git del caller'
    [ "$CALLER_COMMON" = "$COMMON_DIR" ] || fail 'project-root no pertenece al proyecto del worktree caller'
fi

STATE_REL=".mefisto/pipeline/autonomy/fix-review"
STATE_DIR="$PROJECT_ROOT/$STATE_REL"
SEALED="$STATE_DIR/$PLAN_ID.json"
RECEIPTS="$STATE_DIR/$PLAN_ID.receipts.json"
no_symlinks() { # ruta absoluta bajo la raiz
    local rel="${1#"$PROJECT_ROOT"/}" current="$PROJECT_ROOT" part
    local IFS=/
    for part in $rel; do current="$current/$part"; [ ! -L "$current" ] || return 1; done
    return 0
}
no_symlinks "$SEALED" && no_symlinks "$RECEIPTS" || conflict STATE_SYMLINK

# --- Plan sellado (#1887) y su digest (#1886) ---
[ -f "$SEALED" ] && [ ! -L "$SEALED" ] || conflict PLAN_NOT_SEALED "ejecuta fix-review-prepare.sh para este plan"
PLAN="$(jq -cS '.plan // null' "$SEALED" 2>/dev/null)" || conflict PLAN_NOT_SEALED
printf '%s' "$PLAN" | jq -e 'type == "object"' >/dev/null 2>&1 || conflict PLAN_NOT_SEALED
[ "$(printf '%s' "$PLAN" | jq -r '.planDigest // ""')" = "$PLAN_ID" ] || conflict PLAN_DIGEST_MISMATCH
plan_validate() { jq -cn --argjson p "$PLAN" --argjson g "$1" --arg id "$2" '{plan:$p,grants:$g,context:{projectId:$id}}' | jq -c -f "$VALIDATOR" 2>/dev/null; }
PLAN_PROJECT="$(printf '%s' "$PLAN" | jq -r '.projectId // ""')"
VAL0="$(plan_validate null "$PLAN_PROJECT")" || conflict PLAN_VALIDATOR_FAILED
[ "$(printf '%s' "$VAL0" | jq -r '.status')" = valid ] || conflict PLAN_INVALID
[ "$(printf '%s' "$VAL0" | jq -j '.canonical' | hash_stdin)" = "$PLAN_ID" ] || conflict PLAN_DIGEST_MISMATCH
PR="$(printf '%s' "$PLAN" | jq -r '.prNumber')"
REPO_SLUG="$(printf '%s' "$PLAN" | jq -r '.repoSlug')"
HEAD_REF="$(printf '%s' "$PLAN" | jq -r '.headRefName')"
INITIAL_SHA="$(printf '%s' "$PLAN" | jq -r '.expectedHeadSha')"

# --- Recibos existentes ---
load_receipts() {
    RCP='null'
    [ -e "$RECEIPTS" ] || [ -L "$RECEIPTS" ] || return 0
    [ -f "$RECEIPTS" ] && [ ! -L "$RECEIPTS" ] || conflict RECEIPTS_NOT_REGULAR
    [ "$(perm_of "$RECEIPTS")" = 600 ] || conflict RECEIPTS_INSECURE "el libro debe ser 0600; no se reutiliza"
    RCP="$(jq -cS . "$RECEIPTS" 2>/dev/null)" || conflict RECEIPTS_CORRUPT
    printf '%s' "$RCP" | jq -e --arg pd "$PLAN_ID" --arg pid "$PLAN_PROJECT" --argjson pr "$PR" \
        'type == "object" and .schemaVersion == 1 and .planDigest == $pd and .projectId == $pid and .prNumber == $pr
         and (.revision | type == "number") and (.runId | type == "string")
         and (.headTransitions | type == "array") and (.replies | type == "array") and (.issues | type == "array")' >/dev/null 2>&1 || conflict RECEIPTS_CORRUPT
    REVISION="$(printf '%s' "$RCP" | jq '.revision')"
}

if [ "$OP" = status ]; then
    load_receipts
    if [ "$RCP" = null ]; then out none NO_RECEIPTS "sin recibos: una accion remota sin recibo requiere confirmar con evidencia, una sola vez"; exit 0; fi
    RUN_ID="$(printf '%s' "$RCP" | jq -r '.runId')"
    out ok "RECEIPTS_PRESENT transitions=$(printf '%s' "$RCP" | jq '.headTransitions | length') replies=$(printf '%s' "$RCP" | jq '.replies | length') issues=$(printf '%s' "$RCP" | jq '.issues | length')"
    exit 0
fi

# --- Request versionado (sin payload de respuesta) ---
REQ="$(head -c 65537)"
[ "${#REQ}" -le 65536 ] || conflict REQUEST_TOO_LARGE
case "$OP" in
    record-push) ALLOWED='["from","improvementClass","phase","runId","schemaVersion","to","verification"]'; REQUIRED='["from","phase","runId","schemaVersion","to"]' ;;
    record-reply) ALLOWED='["replyId","runId","schemaVersion"]'; REQUIRED='["replyId","runId","schemaVersion"]' ;;
    *) ALLOWED='["issueNumber","origin","repo","runId","schemaVersion"]'; REQUIRED='["issueNumber","origin","repo","runId","schemaVersion"]' ;;
esac
printf '%s' "$REQ" | jq -e --argjson a "$ALLOWED" --argjson r "$REQUIRED" \
    'type == "object" and .schemaVersion == 1 and ((keys - $a) == []) and (($r - keys) == [])' >/dev/null 2>&1 || conflict REQUEST_INVALID
req() { printf '%s' "$REQ" | jq -r --arg k "$1" '.[$k] // "" | tostring'; }
RUN_ID="$(req runId)"
printf '%s' "$RUN_ID" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' || { RUN_ID=""; conflict REQUEST_INVALID "runId invalido"; }
check_reference() { [ -z "$REFERENCE" ] || [ "$REFERENCE" = "$1" ] || conflict REFERENCE_MISMATCH; }

# --- Accion requerida y consentimiento vigente (sin depender del guard posterior) ---
case "$OP" in
    record-push) [ "$(req phase)" = improvements ] && ACTION=fix-review-local-improvement || ACTION=fix-review-correct ;;
    record-reply) ACTION=fix-review-reply ;;
    record-consumer-issue) ACTION=fix-review-consumer-issue ;;
    record-harness-draft) ACTION=fix-review-harness-draft ;;
esac
if [ "$OP" = record-push ]; then
    case "$(req phase)" in corrections|improvements) ;; *) conflict REQUEST_INVALID "phase invalida" ;; esac
fi
INSPECT="$(bash "$AUTONOMY" inspect --project-root "$PROJECT_ROOT" 2>/dev/null)" || true
printf '%s' "$INSPECT" | jq -e 'type == "object"' >/dev/null 2>&1 || conflict CONSENT_UNREADABLE
[ "$(printf '%s' "$INSPECT" | jq -r '.status')" = ready ] || conflict CONSENT_NOT_READY "$(printf '%s' "$INSPECT" | jq -r '.reasonCode // "UNKNOWN"')"
PROJECT_ID="$(printf '%s' "$INSPECT" | jq -r '.projectId')"
PROFILE_DIGEST="$(printf '%s' "$INSPECT" | jq -r '.profileDigest')"
[ "$PLAN_PROJECT" = "$PROJECT_ID" ] || conflict PLAN_PROJECT_MISMATCH
VAL="$(plan_validate "$(printf '%s' "$INSPECT" | jq -c '.profile.administration // []')" "$PROJECT_ID")" || conflict PLAN_VALIDATOR_FAILED
printf '%s' "$VAL" | jq -e --arg a "$ACTION" '.status == "valid" and (.requiredActions | index($a)) != null and ((.authorization.missing // []) | index($a)) == null' >/dev/null 2>&1 \
    || conflict ACTION_NOT_GRANTED "el plan o el perfil no aprueban $ACTION"

# --- Utilidades de verificacion remota (solo lecturas) ---
SNAP_IDS="$(printf '%s' "$PLAN" | jq -c '[.commentSnapshot[].id]')"
in_snapshot() { printf '%s' "$SNAP_IDS" | jq -e --argjson i "$1" 'index($i) != null' >/dev/null 2>&1; }
ME=""
whoami_gh() {
    [ -n "$ME" ] && return 0
    ME="$(cd "$PROJECT_ROOT" && gh api user 2>/dev/null | jq -r '.login // ""' 2>/dev/null)" || ME=""
    printf '%s' "$ME" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$'
}
harness_slug() {
    local s
    s="$(jq -r '.repoSlug // empty' "$PROJECT_ROOT/.mefisto/harness.config.json" 2>/dev/null)" || s=""
    printf '%s' "${s:-$DEFAULT_HARNESS_SLUG}"
}
safe_path() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._@+-]+(/[A-Za-z0-9._@+-]+)*$' || return 1
    case "/$1/" in */./*|*/../*) return 1 ;; esac
    local first="${1%%/*}" b
    for b in $BLOCKED_FIRST; do [ "$first" != "$b" ] || return 1; done
    case "${1##*/}" in harness.config.json|.env*) return 1 ;; esac
    return 0
}
path_in_class() { # clase ruta
    case "$1" in
        consumer-adr) case "$2" in docs/adr/*.md) return 0 ;; esac; return 1 ;;
        consumer-directives) [ "$2" = AGENTS.md ] || [ "$2" = CLAUDE.md ] ;;
        consumer-test-helper) printf '%s' "$2" | grep -Eq '^(tests?/|(.*/)?[A-Za-z0-9._-]+\.Tests?/).*(Helper|Builder|Fixture|Fake|Support|Testing)[A-Za-z0-9._-]*\.cs$' ;;
        *) return 1 ;;
    esac
}

# --- Bloqueo y escritura atomica con CAS ---
LOCK="$RECEIPTS.lock"; HAVE_LOCK=0
acquire_lock() {
    local i
    mkdir -p "$STATE_DIR" 2>/dev/null || conflict STATE_NOT_WRITABLE
    no_symlinks "$STATE_DIR" || conflict STATE_SYMLINK
    chmod 700 "$PROJECT_ROOT/.mefisto" "$PROJECT_ROOT/.mefisto/pipeline" "$PROJECT_ROOT/.mefisto/pipeline/autonomy" "$STATE_DIR" 2>/dev/null || true
    for i in $(seq 1 50); do
        if mkdir "$LOCK" 2>/dev/null; then HAVE_LOCK=1; trap 'rm -rf "$LOCK"' EXIT; return 0; fi
        sleep 0.1
    done
    conflict LOCK_HELD "otro proceso escribe el libro; si no hay ninguno, elimina el directorio .lock tras verificarlo"
}
git -C "$PROJECT_ROOT" check-ignore -q "$STATE_REL/$PLAN_ID.receipts.json" 2>/dev/null || conflict STATE_NOT_IGNORED ".mefisto/ debe estar ignorado por Git"
acquire_lock
load_receipts
BASE_REV="$REVISION"
if [ "$RCP" != null ]; then
    [ "$(printf '%s' "$RCP" | jq -r '.runId')" = "$RUN_ID" ] || conflict RUN_ID_MISMATCH "el id de corrida queda fijado en la primera transicion"
    [ "$(printf '%s' "$RCP" | jq -r '.profileDigest')" = "$PROFILE_DIGEST" ] || conflict PROFILE_DIGEST_MISMATCH "el perfil cambio desde la primera transicion"
else
    BASE_REV=0
    RCP="$(jq -cn --arg pd "$PLAN_ID" --arg pid "$PROJECT_ID" --argjson pr "$PR" --arg repo "$REPO_SLUG" --arg ref "$HEAD_REF" --arg run "$RUN_ID" --arg prof "$PROFILE_DIGEST" --arg init "$INITIAL_SHA" \
        '{schemaVersion:1,planDigest:$pd,projectId:$pid,prNumber:$pr,repoSlug:$repo,headRefName:$ref,runId:$run,profileDigest:$prof,initialHeadSha:$init,revision:0,headTransitions:[],replies:[],issues:[]}')"
fi
commit_receipts() { # nuevo-json
    local new tmp cur
    new="$(printf '%s' "$1" | jq -cS --argjson r "$((BASE_REV + 1))" '.revision = $r')"
    if [ -e "$RECEIPTS" ] || [ -L "$RECEIPTS" ]; then
        [ -f "$RECEIPTS" ] && [ ! -L "$RECEIPTS" ] || conflict RECEIPTS_NOT_REGULAR
        cur="$(jq '.revision' "$RECEIPTS" 2>/dev/null)" || conflict RECEIPTS_CORRUPT
        [ "$cur" = "$BASE_REV" ] || conflict RECEIPTS_CAS_FAILED "otro escritor avanzo la revision; repite la consulta"
    else
        [ "$BASE_REV" = 0 ] || conflict RECEIPTS_CAS_FAILED
    fi
    tmp="$(mktemp "$STATE_DIR/.receipts.XXXXXX")" || conflict STATE_NOT_WRITABLE
    if printf '%s\n' "$new" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$RECEIPTS"; then
        REVISION="$((BASE_REV + 1))"
        return 0
    fi
    rm -f "$tmp"; conflict STATE_NOT_WRITABLE
}
recorded() { out recorded "${1:-RECORDED}"; exit 0; }

# --- Repositorio activo y PR ---
active_repo_check() {
    local slug
    slug="$(cd "$PROJECT_ROOT" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || unknown GH_REPO_UNREADABLE "gh no pudo leer el repositorio; confirma con evidencia"
    [ "$slug" = "$REPO_SLUG" ] || conflict REPO_MISMATCH
}

case "$OP" in
record-push)
    PHASE="$(req phase)"; FROM="$(req from)"; TO="$(req to)"; CLASS="$(req improvementClass)"
    check_reference "$TO"
    printf '%s' "$FROM" | grep -Eq '^[0-9a-f]{40}$' && printf '%s' "$TO" | grep -Eq '^[0-9a-f]{40}$' || conflict REQUEST_INVALID "from/to deben ser SHA completos"
    if printf '%s' "$RCP" | jq -e --arg f "$FROM" --arg t "$TO" --arg p "$PHASE" 'any(.headTransitions[]; .from == $f and .to == $t and .phase == $p)' >/dev/null; then recorded REPLAY; fi
    LAST="$(printf '%s' "$RCP" | jq -r --arg i "$INITIAL_SHA" '(.headTransitions | last | .to) // $i')"
    [ "$FROM" = "$LAST" ] || conflict HEAD_CHAIN_BROKEN "from no es el ultimo head recibido: posible cambio de un tercero"
    [ "$FROM" != "$TO" ] || conflict EMPTY_TRANSITION
    if [ "$PHASE" = corrections ] && printf '%s' "$RCP" | jq -e 'any(.headTransitions[]; .phase == "improvements")' >/dev/null; then conflict PHASE_ORDER "las correcciones preceden a las mejoras"; fi
    active_repo_check
    LOCAL_BRANCH="$(git -C "$PROJECT_ROOT" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    [ "$LOCAL_BRANCH" = "$HEAD_REF" ] || conflict BRANCH_MISMATCH
    [ "$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null)" = "$TO" ] || conflict LOCAL_HEAD_MISMATCH
    [ -z "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ] || conflict WORKTREE_DIRTY
    PRJ="$(cd "$PROJECT_ROOT" && gh pr view "$PR" --repo "$REPO_SLUG" --json headRefOid,headRefName,state,url,isCrossRepository 2>/dev/null)" \
        && printf '%s' "$PRJ" | jq -e 'type == "object"' >/dev/null 2>&1 || unknown GH_PR_UNREADABLE "no se pudo leer el PR; confirma el push con evidencia y repite una vez"
    printf '%s' "$PRJ" | jq -e --arg t "$TO" --arg ref "$HEAD_REF" --arg url "https://github.com/$REPO_SLUG/pull/$PR" \
        '.headRefOid == $t and .headRefName == $ref and .state == "OPEN" and .url == $url and .isCrossRepository == false' >/dev/null 2>&1 || conflict REMOTE_HEAD_MISMATCH "el head remoto no es el push reportado"
    git -C "$PROJECT_ROOT" cat-file -e "$FROM^{commit}" 2>/dev/null || conflict FROM_UNKNOWN
    git -C "$PROJECT_ROOT" merge-base --is-ancestor "$FROM" "$TO" 2>/dev/null || conflict NOT_DESCENDANT
    [ -z "$(git -C "$PROJECT_ROOT" rev-list --merges "$FROM..$TO" 2>/dev/null)" ] || conflict MERGE_COMMITS "no se cotejan merges contra el plan"
    if git -C "$PROJECT_ROOT" diff --raw --no-renames "$FROM" "$TO" 2>/dev/null | awk '$1 ~ /120000/ || $2 ~ /120000/ {f=1} END {exit !f}'; then conflict SYMLINK_CHANGE; fi
    PATHS="$(git -C "$PROJECT_ROOT" -c core.quotepath=off diff --name-only --no-renames "$FROM" "$TO" 2>/dev/null)" || conflict DIFF_UNREADABLE
    [ -n "$PATHS" ] || conflict EMPTY_TRANSITION
    PATHS_JSON='[]'
    while IFS= read -r p; do
        safe_path "$p" || conflict PATH_NOT_ALLOWED "ruta fuera de las clases seguras"
        PATHS_JSON="$(printf '%s' "$PATHS_JSON" | jq -c --arg p "$p" '. + [$p]')"
    done <<EOF
$PATHS
EOF
    if [ "$PHASE" = corrections ]; then
        printf '%s' "$PLAN" | jq -e --argjson ch "$PATHS_JSON" '([.triage[] | select(.category == "corregir") | .edits[].path]) as $ok | ($ch - $ok) == []' >/dev/null 2>&1 \
            || conflict PATH_NOT_PLANNED "el diff toca rutas fuera de los edits exactos del triaje"
        printf '%s' "$REQ" | jq -e --argjson plan "$(printf '%s' "$PLAN" | jq -c '.verification')" \
            '(.verification // []) as $v | $plan | all(.[]; . as $c | any($v[]?; type == "object" and .command == $c and .exitCode == 0))' >/dev/null 2>&1 \
            || conflict VERIFICATION_NOT_DECLARED "faltan las verificaciones declaradas del plan con exitCode 0"
        CLASS=""
    else
        printf '%s' "$PLAN" | jq -e --arg c "$CLASS" '.secondary.localImprovementClasses | index($c) != null' >/dev/null 2>&1 || conflict CLASS_NOT_APPROVED
        while IFS= read -r p; do path_in_class "$CLASS" "$p" || conflict PATH_NOT_IN_CLASS "una ruta no pertenece a la clase aprobada"; done <<EOF
$PATHS
EOF
        TOTAL="$(jq -n --argjson r "$RCP" --argjson n "$PATHS_JSON" '([$r.headTransitions[] | select(.phase == "improvements") | .paths[]] + $n) | unique | length')"
        LIMIT="$(printf '%s' "$PLAN" | jq '.limits.localFiles')"
        [ "$TOTAL" -le "$LIMIT" ] || conflict LOCAL_FILES_QUOTA_EXCEEDED
    fi
    NEW="$(printf '%s' "$RCP" | jq -c --arg ph "$PHASE" --arg f "$FROM" --arg t "$TO" --arg c "$CLASS" --argjson paths "$PATHS_JSON" \
        '.headTransitions += [{seq:(.headTransitions | length + 1),phase:$ph,from:$f,to:$t,class:(if $c == "" then null else $c end),paths:$paths}]')"
    commit_receipts "$NEW"; recorded
    ;;
record-reply)
    RID="$(req replyId)"
    printf '%s' "$RID" | grep -Eq '^[1-9][0-9]{0,15}$' || conflict REQUEST_INVALID "replyId invalido"
    check_reference "$RID"
    if printf '%s' "$RCP" | jq -e --argjson r "$RID" 'any(.replies[]; .replyId == $r)' >/dev/null; then recorded REPLAY; fi
    printf '%s' "$PLAN" | jq -e '.secondary.replyPolicy == "freeform-factual"' >/dev/null || conflict REPLY_POLICY_NONE
    in_snapshot "$RID" && conflict REPLY_IS_SNAPSHOT_COMMENT "es un comentario previo del plan, no una respuesta nueva"
    active_repo_check
    whoami_gh || unknown GH_USER_UNREADABLE "no se pudo identificar al autor; no repitas el POST: confirma con evidencia una sola vez"
    CMT="$(cd "$PROJECT_ROOT" && gh api "repos/$REPO_SLUG/pulls/comments/$RID" 2>/dev/null)" \
        && printf '%s' "$CMT" | jq -e 'type == "object"' >/dev/null 2>&1 || unknown REPLY_UNCONFIRMED "la respuesta no se pudo confirmar; no reintentes el POST a ciegas: confirma una sola vez con evidencia y repite el registro"
    printf '%s' "$CMT" | jq -e --argjson id "$RID" --arg url "https://api.github.com/repos/$REPO_SLUG/pulls/$PR" '.id == $id and .pull_request_url == $url' >/dev/null 2>&1 || conflict REPLY_WRONG_PR
    printf '%s' "$CMT" | jq -e --arg me "$ME" '.user.login == $me' >/dev/null 2>&1 || conflict REPLY_AUTHOR_MISMATCH "la respuesta no es de la identidad de la corrida"
    PARENT="$(printf '%s' "$CMT" | jq -r '.in_reply_to_id // ""')"
    printf '%s' "$PARENT" | grep -Eq '^[1-9][0-9]*$' && in_snapshot "$PARENT" || conflict REPLY_PARENT_NOT_APPROVED "el padre no pertenece a los comentarios aprobados"
    if printf '%s' "$RCP" | jq -e --argjson p "$PARENT" 'any(.replies[]; .parentId == $p)' >/dev/null; then conflict DUPLICATE_REPLY "ya hay una respuesta para ese padre en esta corrida"; fi
    NEW="$(printf '%s' "$RCP" | jq -c --argjson r "$RID" --argjson p "$PARENT" '.replies += [{replyId:$r,parentId:$p}]')"
    commit_receipts "$NEW"; recorded
    ;;
record-consumer-issue|record-harness-draft)
    ORIGIN="$(req origin)"; NUM="$(req issueNumber)"; REPO="$(req repo)"
    check_reference "$NUM"
    printf '%s' "$NUM" | grep -Eq '^[1-9][0-9]{0,9}$' || conflict REQUEST_INVALID "issueNumber invalido"
    printf '%s' "$ORIGIN" | grep -Eq '^(comment:[1-9][0-9]{0,15}|improvement:[a-z0-9][a-z0-9-]{0,40})$' || conflict REQUEST_INVALID "origin invalido"
    if [ "$OP" = record-consumer-issue ]; then KIND=consumer; EXPECT_REPO="$REPO_SLUG"; LIMKEY=consumerIssues; else KIND=harness; EXPECT_REPO="$(harness_slug)"; LIMKEY=drafts; fi
    printf '%s' "$EXPECT_REPO" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || conflict REQUEST_INVALID "slug de destino invalido"
    [ "$KIND" = consumer ] || [ "$EXPECT_REPO" != "$REPO_SLUG" ] || conflict REPO_NOT_HARNESS
    [ "$REPO" = "$EXPECT_REPO" ] || conflict REPO_NOT_ALLOWED "el destino de esta accion es $KIND"
    case "$ORIGIN" in
        comment:*)
            CID="${ORIGIN#comment:}"
            in_snapshot "$CID" || conflict ORIGIN_NOT_IN_PLAN
            if [ "$KIND" = consumer ]; then
                printf '%s' "$PLAN" | jq -e --argjson c "$CID" 'any(.triage[]; .commentId == $c and .category == "investigar")' >/dev/null || conflict ORIGIN_NOT_INVESTIGAR "solo comentarios investigar abren un issue del consumidor"
            fi ;;
    esac
    if printf '%s' "$RCP" | jq -e --arg k "$KIND" --arg o "$ORIGIN" --argjson n "$NUM" 'any(.issues[]; .type == $k and .origin == $o and .number == $n)' >/dev/null; then recorded REPLAY; fi
    if printf '%s' "$RCP" | jq -e --arg k "$KIND" --arg o "$ORIGIN" --argjson n "$NUM" 'any(.issues[]; .type == $k and (.origin == $o or .number == $n))' >/dev/null; then conflict DUPLICATE_ISSUE "origen o numero ya registrados"; fi
    USED="$(printf '%s' "$RCP" | jq --arg k "$KIND" '[.issues[] | select(.type == $k)] | length')"
    QUOTA="$(printf '%s' "$PLAN" | jq --arg k "$LIMKEY" '.limits[$k]')"
    [ "$USED" -lt "$QUOTA" ] || conflict QUOTA_EXCEEDED "cupo agotado para $KIND"
    active_repo_check
    whoami_gh || unknown GH_USER_UNREADABLE "no se pudo identificar al autor; confirma con evidencia una sola vez"
    ISS="$(cd "$PROJECT_ROOT" && gh api "repos/$EXPECT_REPO/issues/$NUM" 2>/dev/null)" \
        && printf '%s' "$ISS" | jq -e 'type == "object"' >/dev/null 2>&1 || unknown ISSUE_UNCONFIRMED "el issue no se pudo confirmar; no lo vuelvas a crear: confirma una sola vez con evidencia"
    printf '%s' "$ISS" | jq -e --argjson n "$NUM" --arg me "$ME" '.number == $n and (has("pull_request") | not) and .state == "open" and .user.login == $me' >/dev/null 2>&1 || conflict ISSUE_INVALID "el objeto remoto no es un issue abierto de la identidad de la corrida"
    if [ "$KIND" = consumer ]; then
        printf '%s' "$ISS" | jq -e --arg pr "$PR" --arg url "https://github.com/$REPO_SLUG/pull/$PR" '(.body // "") as $b | ($b | contains($url)) or ($b | test("(^|[^0-9A-Za-z])#" + $pr + "([^0-9]|$)"))' >/dev/null 2>&1 || conflict ISSUE_MISSING_PR_REFERENCE
    else
        printf '%s' "$ISS" | jq -e --arg ref "$REPO_SLUG#$PR" --arg url "https://github.com/$REPO_SLUG/pull/$PR" '(.body // "") as $b | ($b | contains($url)) or ($b | contains($ref))' >/dev/null 2>&1 || conflict ISSUE_MISSING_PR_REFERENCE
        printf '%s' "$ISS" | jq -e '[.labels[]? | if type == "object" then .name else . end] as $l | ($l | index("tipo:tooling")) != null and ([$l[] | select(startswith("estado:"))] == ["estado:borrador"])' >/dev/null 2>&1 || conflict DRAFT_LABELS_INVALID "solo estado:borrador y tipo:tooling"
    fi
    NEW="$(printf '%s' "$RCP" | jq -c --arg k "$KIND" --arg r "$EXPECT_REPO" --argjson n "$NUM" --arg o "$ORIGIN" --argjson pr "$PR" '.issues += [{type:$k,repo:$r,number:$n,origin:$o,pr:$pr}]')"
    commit_receipts "$NEW"; recorded
    ;;
esac
