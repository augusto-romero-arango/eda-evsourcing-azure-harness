#!/usr/bin/env bash
# Prepara el snapshot revisable de un PR para /fix-review (issue #1887, MEF-ADR-0055).
# Solo lee GitHub y Git: no hace checkout, no muta GitHub, no aprueba ni edita el config.
# Persiste el plan sellado y la copia redactada del Markdown bajo .mefisto/pipeline/ (ignorado).
# Uso: fix-review-prepare.sh --project-root <Git-root> --pr <n> --plan-file <json> --plan-text <md>
set -uo pipefail
export LC_ALL=C
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VALIDATOR="$SCRIPT_DIR/../src/published/contract/fix-review-plan.validate.jq"
SENSITIVE_RE='(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|[Bb][Ee][Aa][Rr][Ee][Rr][ ]+[A-Za-z0-9._~+/=-]{16,}|://[^/ ]*:[^/ ]*@|[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn][ ]*[:=]|-----BEGIN [A-Z ]*PRIVATE KEY)'
ZERO64="$(printf '0%.0s' $(seq 1 64))"

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }
usage() { fail 'uso: fix-review-prepare.sh --project-root <Git-root> --pr <numero> --plan-file <archivo> --plan-text <archivo>'; }
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

PROJECT_ROOT=""; PR=""; PLAN_FILE=""; PLAN_TEXT=""
SEEN_ROOT=0; SEEN_PR=0; SEEN_FILE=0; SEEN_TEXT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --project-root) [ $# -ge 2 ] && [ "$SEEN_ROOT" -eq 0 ] || usage; PROJECT_ROOT="$2"; SEEN_ROOT=1; shift 2 ;;
        --pr) [ $# -ge 2 ] && [ "$SEEN_PR" -eq 0 ] || usage; PR="$2"; SEEN_PR=1; shift 2 ;;
        --plan-file) [ $# -ge 2 ] && [ "$SEEN_FILE" -eq 0 ] || usage; PLAN_FILE="$2"; SEEN_FILE=1; shift 2 ;;
        --plan-text) [ $# -ge 2 ] && [ "$SEEN_TEXT" -eq 0 ] || usage; PLAN_TEXT="$2"; SEEN_TEXT=1; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$PROJECT_ROOT" ] && [ -n "$PR" ] && [ -n "$PLAN_FILE" ] && [ -n "$PLAN_TEXT" ] || usage
printf '%s' "$PR" | grep -Eq '^[1-9][0-9]{0,9}$' || fail 'pr debe ser un entero positivo'
[ -x "$(command -v jq 2>/dev/null || true)" ] || fail 'jq no esta instalado'
[ -x "$(command -v git 2>/dev/null || true)" ] || fail 'git no esta instalado'
[ -x "$(command -v gh 2>/dev/null || true)" ] || fail 'gh no esta instalado'
[ -x "$(command -v shasum 2>/dev/null || command -v sha256sum 2>/dev/null || true)" ] || fail 'no se encontro una implementacion de SHA-256'
[ -f "$VALIDATOR" ] || fail 'no se encontro el validador del plan de fix-review'

PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P)" || fail 'la raiz de proyecto no existe'
PROJECT_TOP="$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)" || fail 'la raiz indicada no es un repositorio Git'
PROJECT_TOP="$(cd "$PROJECT_TOP" 2>/dev/null && pwd -P)" || fail 'la raiz Git no es accesible'
[ "$PROJECT_ROOT" = "$PROJECT_TOP" ] || fail 'project-root debe ser la raiz del worktree o repositorio'
[ ! -f "$PROJECT_ROOT/.claude-plugin/plugin.json" ] || fail 'fix-review-prepare.sh es del plugin publicado y solo aplica al consumidor'
COMMON_DIR="$(git_common_dir "$PROJECT_ROOT")" || fail 'no se pudo resolver la identidad Git comun'
CALLER_TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$CALLER_TOP" ]; then
    CALLER_COMMON="$(git_common_dir "$CALLER_TOP")" || fail 'no se pudo verificar la identidad Git del caller'
    [ "$CALLER_COMMON" = "$COMMON_DIR" ] || fail 'project-root no pertenece al proyecto del worktree caller'
fi
PROJECT_ID="project-$(printf '%s' "$COMMON_DIR" | hash_stdin | cut -c1-24)"

STATE_REL=".mefisto/pipeline"
SUMMARIES="$PROJECT_ROOT/$STATE_REL/summaries"
SEALED_DIR="$PROJECT_ROOT/$STATE_REL/autonomy/fix-review"
TEXT_DIR="$SUMMARIES/fix-review"

HEAD_SHA=""; PLAN_DIGEST=""; SNAP_DIGEST=""; PLAN_PATH=""; GRANTS='[]'
emit() { # status diagnostics-json
    jq -cn --arg status "$1" --argjson pr "$PR" --arg sha "$HEAD_SHA" --arg pd "$PLAN_DIGEST" --arg csd "$SNAP_DIGEST" \
        --arg pp "$PLAN_PATH" --argjson grants "$GRANTS" --argjson diag "$2" \
        '{schemaVersion:1,status:$status,pr:$pr,expectedHeadSha:(if $sha=="" then null else $sha end),planDigest:(if $pd=="" then null else $pd end),commentSnapshotDigest:(if $csd=="" then null else $csd end),planPath:(if $pp=="" then null else $pp end),requiredGrants:$grants,diagnostics:$diag}'
}
conflict() { # code [detalle sin cuerpos]
    HEAD_SHA="${LIVE_SHA:-}"; PLAN_DIGEST=""; PLAN_PATH=""; GRANTS='[]'
    emit conflict "$(jq -cn --arg c "$1" --arg d "${2:-}" '[if $d == "" then $c else ($c + ": " + $d) end]')"
    exit 1
}
LIVE_SHA=""

# Ruta propia: bajo la raiz, sin '..' ni enlaces simbolicos en ningun componente.
no_symlinks_from_root() { # ruta-absoluta
    local rel="${1#"$PROJECT_ROOT"/}" current="$PROJECT_ROOT" part
    local IFS=/
    for part in $rel; do
        current="$current/$part"
        [ ! -L "$current" ] || return 1
    done
    return 0
}
resolve_own_file() { # ruta -> imprime ruta absoluta bajo summaries/
    local p="$1" abs
    case "$p" in /*) abs="$p" ;; *) abs="$PROJECT_ROOT/$p" ;; esac
    case "$abs" in *..*) return 1 ;; esac
    case "$abs" in "$SUMMARIES"/*) ;; *) return 1 ;; esac
    no_symlinks_from_root "$abs" || return 1
    [ -f "$abs" ] || return 1
    printf '%s' "$abs"
}
PLAN_FILE_ABS="$(resolve_own_file "$PLAN_FILE")" || conflict PLAN_FILE_NOT_OWN "plan-file debe ser un archivo regular bajo $STATE_REL/summaries/"
PLAN_TEXT_ABS="$(resolve_own_file "$PLAN_TEXT")" || conflict PLAN_TEXT_NOT_OWN "plan-text debe ser un archivo regular bajo $STATE_REL/summaries/"

# 1. Repositorio consumidor activo y PR (solo lectura)
REPO_SLUG="$(cd "$PROJECT_ROOT" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || conflict GH_REPO_UNREADABLE
printf '%s' "$REPO_SLUG" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || conflict GH_REPO_UNREADABLE
read_pr() { (cd "$PROJECT_ROOT" && gh pr view "$PR" --repo "$REPO_SLUG" --json headRefOid,headRefName,baseRefName,state,url,isCrossRepository 2>/dev/null); }
PR_JSON="$(read_pr)" || conflict GH_PR_UNREADABLE
printf '%s' "$PR_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 || conflict GH_PR_UNREADABLE
pr_field() { printf '%s' "$PR_JSON" | jq -r --arg k "$1" '.[$k] // ""'; }
LIVE_SHA="$(pr_field headRefOid)"; HEAD_REF="$(pr_field headRefName)"; BASE_REF="$(pr_field baseRefName)"
[ "$(pr_field state)" = OPEN ] || conflict PR_NOT_OPEN
[ "$(pr_field url)" = "https://github.com/$REPO_SLUG/pull/$PR" ] || conflict PR_NOT_IN_ACTIVE_REPO
[ "$(printf '%s' "$PR_JSON" | jq -r '.isCrossRepository')" = false ] || conflict FORK_NOT_SUPPORTED "la cabeza del PR esta en otro repositorio; diagnostico sin push"
printf '%s' "$LIVE_SHA" | grep -Eq '^[0-9a-f]{40}$' || conflict GH_PR_UNREADABLE

# 2. Worktree propio, en la rama del PR, limpio (sin checkout ni cambios)
LOCAL_BRANCH="$(git -C "$PROJECT_ROOT" symbolic-ref --short -q HEAD 2>/dev/null || true)"
[ -n "$LOCAL_BRANCH" ] && [ "$LOCAL_BRANCH" = "$HEAD_REF" ] || conflict WORKTREE_BRANCH_MISMATCH "prepara un worktree en la rama del PR (git worktree add <ruta> <rama>) y repite"
[ "$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null)" = "$LIVE_SHA" ] || conflict WORKTREE_HEAD_MISMATCH "el worktree no esta en el commit cabeza del PR; actualizalo manualmente"
[ -z "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ] || conflict WORKTREE_DIRTY "hay cambios versionados sin confirmar"

# 3. Comentarios de revision (todas las paginas), solo hashes
snapshot() {
    local raw ids id h rows="" sep=""
    raw="$(cd "$PROJECT_ROOT" && gh api "repos/$REPO_SLUG/pulls/$PR/comments" --paginate 2>/dev/null)" || return 1
    raw="$(printf '%s' "$raw" | jq -s -c '[.[] | if type == "array" then .[] else . end]' 2>/dev/null)" || return 1
    printf '%s' "$raw" | jq -e 'all(.[]; type == "object" and (.id | type == "number"))' >/dev/null 2>&1 || return 1
    ids="$(printf '%s' "$raw" | jq -r 'map(.id) | sort | .[]')"
    for id in $ids; do
        h="$(printf '%s' "$raw" | jq -j --argjson id "$id" 'map(select(.id == $id))[0].body // ""' | hash_stdin)"
        rows="$rows$sep$(printf '%s' "$raw" | jq -c --argjson id "$id" --arg h "$h" 'map(select(.id == $id))[0] | {id:.id,bodyDigest:$h,path:(.path // null),line:(.line // null),originalLine:(.original_line // null),inReplyToId:(.in_reply_to_id // null)}')"
        sep=","
    done
    printf '[%s]' "$rows" | jq -cS 'unique_by(.id)'
}
SNAP="$(snapshot)" || conflict GH_COMMENTS_UNREADABLE
[ "$(printf '%s' "$SNAP" | jq 'length')" -gt 0 ] || conflict NO_REVIEW_COMMENTS "el PR no tiene comentarios de revision"
SNAP_DIGEST="$(printf '%s' "$SNAP" | hash_stdin)"

# 4. Repetir cabeza y comentarios antes de sellar
PR_JSON="$(read_pr)" || conflict GH_PR_UNREADABLE
[ "$(pr_field headRefOid)" = "$LIVE_SHA" ] || conflict HEAD_CHANGED_DURING_READ
SNAP2="$(snapshot)" || conflict GH_COMMENTS_UNREADABLE
[ "$SNAP2" = "$SNAP" ] || conflict COMMENTS_CHANGED_DURING_READ
[ "$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null)" = "$LIVE_SHA" ] || conflict WORKTREE_HEAD_MISMATCH

# 5. Plan JSON (#1886) contra la lectura verificada
PLAN="$(jq -cS . "$PLAN_FILE_ABS" 2>/dev/null)" || conflict PLAN_FILE_INVALID
printf '%s' "$PLAN" | jq -e 'type == "object"' >/dev/null 2>&1 || conflict PLAN_FILE_INVALID
plan_eq() { printf '%s' "$PLAN" | jq -e --arg k "$1" --argjson v "$2" '.[$k] == $v' >/dev/null 2>&1; }
plan_eq prNumber "$PR" || conflict PLAN_PR_MISMATCH
plan_eq repoSlug "$(jq -cn --arg v "$REPO_SLUG" '$v')" || conflict PLAN_REPO_MISMATCH
plan_eq headRepository "$(jq -cn --arg v "$REPO_SLUG" '$v')" || conflict PLAN_REPO_MISMATCH
plan_eq expectedHeadSha "$(jq -cn --arg v "$LIVE_SHA" '$v')" || conflict PLAN_HEAD_MISMATCH
plan_eq headRefName "$(jq -cn --arg v "$HEAD_REF" '$v')" || conflict PLAN_REF_MISMATCH
plan_eq baseRef "$(jq -cn --arg v "$BASE_REF" '$v')" || conflict PLAN_REF_MISMATCH
plan_eq projectId "$(jq -cn --arg v "$PROJECT_ID" '$v')" || conflict PLAN_PROJECT_MISMATCH
PLAN_SNAP="$(printf '%s' "$PLAN" | jq -cS '(.commentSnapshot // null) | if type == "array" then sort_by(.id? // 0) else . end' 2>/dev/null)" || conflict PLAN_SNAPSHOT_MISMATCH
if [ "$PLAN_SNAP" != "$SNAP" ]; then
    DIFF_IDS="$(jq -rn --argjson live "$SNAP" --argjson plan "$PLAN_SNAP" '
        def idx(a): (a // []) | if type == "array" then map(select(type == "object") | {key: ((.id // 0) | tostring), value: .}) | from_entries else {} end;
        (idx($live)) as $l | (idx($plan)) as $p
        | ([($l | keys[]) | select($p[.] == null)] | map("omitido " + .)) + ([($p | keys[]) | select($l[.] == null)] | map("sobrante " + .))
          + ([($l | keys[]) | select($p[.] != null and $p[.] != $l[.])] | map("editado " + .)) | join(", ")' 2>/dev/null)"
    conflict PLAN_SNAPSHOT_MISMATCH "$DIFF_IDS"
fi

# 6. Markdown propio: sin material sensible, huella comprobable
[ "$(wc -c < "$PLAN_TEXT_ABS" | tr -d ' ')" -le 65536 ] || conflict PLAN_TEXT_TOO_LARGE
TEXT="$(cat "$PLAN_TEXT_ABS")"
[ -n "$TEXT" ] || conflict PLAN_TEXT_EMPTY
printf '%s' "$TEXT" | grep -Eq "$SENSITIVE_RE" && conflict PLAN_TEXT_SENSITIVE "redacta el Markdown antes de prepararlo"
TEXT_DIGEST="$(printf '%s' "$TEXT" | hash_stdin)"

# 7. Digest del plan con el contrato de #1886 (sin reimplementar su validacion)
GIVEN_TEXT_DIGEST="$(printf '%s' "$PLAN" | jq -r '.planTextDigest // ""')"
[ -z "$GIVEN_TEXT_DIGEST" ] || [ "$GIVEN_TEXT_DIGEST" = "$TEXT_DIGEST" ] || conflict PLAN_TEXT_DIGEST_MISMATCH
GIVEN_PLAN_DIGEST="$(printf '%s' "$PLAN" | jq -r '.planDigest // ""')"
CANDIDATE="$(printf '%s' "$PLAN" | jq -cS --arg td "$TEXT_DIGEST" --arg z "$ZERO64" '.planTextDigest = $td | .planDigest = (.planDigest // $z)')"
validate() { jq -cn --argjson p "$1" --argjson g "$2" --arg id "$PROJECT_ID" '{plan:$p,grants:$g,context:{projectId:$id}}' | jq -c -f "$VALIDATOR" 2>/dev/null; }
RESULT="$(validate "$CANDIDATE" null)" || conflict PLAN_VALIDATOR_FAILED
[ "$(printf '%s' "$RESULT" | jq -r '.status')" = valid ] || conflict "PLAN_INVALID" "$(printf '%s' "$RESULT" | jq -r '.reasonCode')"
PLAN_DIGEST="$(printf '%s' "$RESULT" | jq -j '.canonical' | hash_stdin)"
[ -z "$GIVEN_PLAN_DIGEST" ] || [ "$GIVEN_PLAN_DIGEST" = "$PLAN_DIGEST" ] || conflict PLAN_DIGEST_MISMATCH
FINAL="$(printf '%s' "$CANDIDATE" | jq -cS --arg d "$PLAN_DIGEST" '.planDigest = $d')"

# 8. Grants exactos que el operador debe incorporar al perfil (#1886)
GRANTS="$(jq -cn --argjson r "$RESULT" --arg d "$PLAN_DIGEST" --arg pr "pr:$PR" '
    {"fix-review-correct":"scope:planned-files","fix-review-reply":"scope:review-comments","fix-review-consumer-issue":"scope:consumer-issue","fix-review-harness-draft":"scope:harness-draft","fix-review-local-improvement":"scope:consumer-docs"} as $s
    | [$r.requiredActions[] | {command:"fix-review",action:.,environment:"repository",resources:[$pr,$s[.]],planDigest:$d}]')"
FINAL_RESULT="$(validate "$FINAL" "$GRANTS")" || conflict PLAN_VALIDATOR_FAILED
[ "$(printf '%s' "$FINAL_RESULT" | jq -r '.authorization.status')" = authorized ] || conflict GRANTS_CONTRACT_DRIFT

# 9. Persistencia propia, ignorada por Git, atomica e idempotente
PLAN_PATH="$STATE_REL/autonomy/fix-review/$PLAN_DIGEST.json"
TEXT_REL="$STATE_REL/summaries/fix-review/$PLAN_DIGEST.md"
no_symlinks_from_root "$SEALED_DIR/$PLAN_DIGEST.json" || conflict STATE_SYMLINK
no_symlinks_from_root "$TEXT_DIR/$PLAN_DIGEST.md" || conflict STATE_SYMLINK
git -C "$PROJECT_ROOT" check-ignore -q "$PLAN_PATH" 2>/dev/null && git -C "$PROJECT_ROOT" check-ignore -q "$TEXT_REL" 2>/dev/null || conflict STATE_NOT_IGNORED ".mefisto/ debe estar ignorado por Git"
mkdir -p "$SEALED_DIR" "$TEXT_DIR" 2>/dev/null || conflict STATE_NOT_WRITABLE
no_symlinks_from_root "$SEALED_DIR/$PLAN_DIGEST.json" || conflict STATE_SYMLINK
no_symlinks_from_root "$TEXT_DIR/$PLAN_DIGEST.md" || conflict STATE_SYMLINK
for d in "$PROJECT_ROOT/.mefisto" "$PROJECT_ROOT/$STATE_REL" "$PROJECT_ROOT/$STATE_REL/autonomy" "$SEALED_DIR" "$SUMMARIES" "$TEXT_DIR"; do chmod 700 "$d" 2>/dev/null || true; done

SEALED="$(jq -cnS --argjson plan "$FINAL" --arg tp "$TEXT_REL" --arg csd "$SNAP_DIGEST" '{schemaVersion:1,plan:$plan,planTextPath:$tp,commentSnapshotDigest:$csd}')"
write_idempotent() { # destino contenido
    local dest="$1" content="$2" tmp
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        [ -f "$dest" ] && [ ! -L "$dest" ] || return 1
        [ "$(cat "$dest")" = "$content" ] && return 0
        return 1
    fi
    tmp="$(mktemp "${dest%/*}/.prepare.XXXXXX")" || return 1
    if printf '%s\n' "$content" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$dest"; then return 0; fi
    rm -f "$tmp"; return 1
}
write_idempotent "$TEXT_DIR/$PLAN_DIGEST.md" "$TEXT" || conflict STATE_EXISTS_DIFFERENT "la copia del Markdown ya existe con otros bytes"
write_idempotent "$SEALED_DIR/$PLAN_DIGEST.json" "$SEALED" || conflict STATE_EXISTS_DIFFERENT "el plan sellado ya existe con otros bytes"
chmod 600 "$TEXT_DIR/$PLAN_DIGEST.md" "$SEALED_DIR/$PLAN_DIGEST.json" 2>/dev/null || true

HEAD_SHA="$LIVE_SHA"
emit prepared '[]'
{
    printf '\nPlan preparado; NO esta aprobado ni se ejecuto fix-review. Para el operador:\n'
    printf '  1. Revisa y corrige: %s\n' "$TEXT_REL"
    printf '  2. Incorpora estos grants a autonomy.administration[] del perfil versionado (PR del consumidor):\n'
    printf '%s' "$GRANTS" | jq '.' | sed 's/^/     /'
    printf '  3. Fuera de la etapa del lote: autonomy-profile.sh preview --project-root <raiz>, y tras revisarlo\n'
    printf '     autonomy-profile.sh approve --project-root <raiz> --expected-digest <digest del preview>.\n'
    printf '  planDigest=%s (huella del plan, no es consentimiento humano)\n' "$PLAN_DIGEST"
} >&2
exit 0
