#!/usr/bin/env bash
# Gestion local, explicita y previa a etapas del consentimiento de autonomia.
set -uo pipefail
export LC_ALL=C
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VALIDATOR="$SCRIPT_DIR/../src/published/contract/autonomy-profile.validate.jq"

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }
usage() { fail 'uso: autonomy-profile.sh <preview|approve|revoke|inspect|propose-max> --project-root <raiz> [--expected-digest <sha256>]'; }
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

OPERATION="${1:-}"; [ $# -gt 0 ] && shift
PROJECT_ROOT=""; EXPECTED_DIGEST=""
SEEN_PROJECT_ROOT=0; SEEN_EXPECTED_DIGEST=0
while [ $# -gt 0 ]; do
    case "$1" in
        --project-root) [ $# -ge 2 ] && [ "$SEEN_PROJECT_ROOT" -eq 0 ] || usage; PROJECT_ROOT="$2"; SEEN_PROJECT_ROOT=1; shift 2 ;;
        --expected-digest) [ $# -ge 2 ] && [ "$SEEN_EXPECTED_DIGEST" -eq 0 ] || usage; EXPECTED_DIGEST="$2"; SEEN_EXPECTED_DIGEST=1; shift 2 ;;
        *) usage ;;
    esac
done
case "$OPERATION" in preview|approve|revoke|inspect|propose-max) ;; *) usage ;; esac
[ -n "$PROJECT_ROOT" ] || usage
[ "$OPERATION" = approve ] || [ "$SEEN_EXPECTED_DIGEST" -eq 0 ] || usage
[ -x "$(command -v jq 2>/dev/null || true)" ] || fail 'jq no esta instalado'
[ -x "$(command -v shasum 2>/dev/null || command -v sha256sum 2>/dev/null || true)" ] || fail 'no se encontro una implementacion de SHA-256'
[ -f "$VALIDATOR" ] || fail 'no se encontro el validador de perfil publicado'

PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P)" || fail 'la raiz de proyecto no existe'
PROJECT_TOP="$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)" || fail 'la raiz indicada no es un repositorio Git'
PROJECT_TOP="$(cd "$PROJECT_TOP" 2>/dev/null && pwd -P)" || fail 'la raiz Git no es accesible'
[ "$PROJECT_ROOT" = "$PROJECT_TOP" ] || fail 'project-root debe ser la raiz del worktree o repositorio'
[ ! -f "$PROJECT_ROOT/.claude-plugin/plugin.json" ] || fail 'autonomy-profile.sh es del plugin publicado y solo aplica al consumidor'
CONFIG="$PROJECT_ROOT/.mefisto/harness.config.json"
LEGACY_CONFIG="$PROJECT_ROOT/.claude/harness.config.json"
HAS_CANONICAL=0
if [ -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
    [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] || fail 'la configuracion canonica no es un archivo regular propio'
    HAS_CANONICAL=1
elif [ -f "$LEGACY_CONFIG" ]; then
    # El fallback legacy se mantiene deshabilitado: no se interpreta ni migra.
    # Así un consumidor previo puede consultar sin activar un perfil por accidente.
    :
else
    fail 'no existe configuracion de consumidor legible'
fi

# El git-dir comun identifica el proyecto compartido por sus worktrees. Su hash
# evita exponer una ruta local y no depende de la rama actualmente checkout.
COMMON_DIR="$(git_common_dir "$PROJECT_ROOT")" || fail 'no se pudo resolver la identidad Git comun'
PROJECT_ID="project-$(printf '%s' "$COMMON_DIR" | hash_stdin | cut -c1-24)"

# Un lector lanzado desde un worktree solo puede consultar la raiz explicita
# del mismo repositorio comun. Esto evita heredar una raiz de estado ajena.
if [ "$OPERATION" = inspect ]; then
    CALLER_TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$CALLER_TOP" ]; then
        CALLER_COMMON="$(git_common_dir "$CALLER_TOP")" || fail 'no se pudo verificar la identidad Git del caller'
        [ "$CALLER_COMMON" = "$COMMON_DIR" ] || fail 'project-root no pertenece al proyecto del worktree caller'
    fi
fi

if [ "$HAS_CANONICAL" -eq 1 ]; then
    PROFILE="$(jq -cS 'if has("autonomy") then .autonomy else null end' "$CONFIG" 2>/dev/null)" || fail 'la declaracion canonica no es JSON valido'
else
    PROFILE='null'
fi
DIGEST="$(printf '%s' "$PROFILE" | hash_stdin)"
CATALOG="$(for command in "$SCRIPT_DIR/../commands"/*.md; do [ -f "$command" ] || continue; basename "$command" .md | sed 's/^mefisto://' ; done | jq -R . | jq -scS 'sort')" || fail 'no se pudo construir el catalogo publicado'

if [ "$OPERATION" = propose-max ]; then
    # Propone el perfil maximo (todo el catalogo, administracion preservada); no aprueba nada.
    [ "$HAS_CANONICAL" -eq 1 ] || fail 'propose-max requiere configuracion canonica en .mefisto/harness.config.json; no se migro ni se creo ningun archivo'
    CURRENT_REVISION="$(printf '%s' "$PROFILE" | jq -r 'if type == "object" and ((.revision? // null) | type) == "number" and .revision > 0 and (.revision | floor) == .revision then .revision else 0 end')"
    BUILD='{schemaVersion:1,id:"maximo",revision:$rev,commands:$catalog,administration:(if ($p | type) == "object" and (($p.administration? // null) | type) == "array" then $p.administration else [] end)}'
    SAME="$(jq -cnS --argjson p "$PROFILE" --argjson catalog "$CATALOG" --argjson rev "$CURRENT_REVISION" "$BUILD")"
    if [ "$CURRENT_REVISION" -gt 0 ] && [ "$SAME" = "$PROFILE" ]; then
        NEW_REVISION="$CURRENT_REVISION"; CHANGED=false
    else
        NEW_REVISION=$((CURRENT_REVISION + 1)); CHANGED=true
    fi
    NEW_PROFILE="$(jq -cnS --argjson p "$PROFILE" --argjson catalog "$CATALOG" --argjson rev "$NEW_REVISION" "$BUILD")" || fail 'no se pudo construir el perfil maximo'
    NEW_DIGEST="$(printf '%s' "$NEW_PROFILE" | hash_stdin)"
    if [ "$CHANGED" = true ]; then
        TMP="$(mktemp "${CONFIG}.XXXXXX")" || fail 'no se pudo preparar la escritura atomica'
        trap 'rm -f "$TMP"' EXIT
        MODE="$(stat -f '%Lp' "$CONFIG" 2>/dev/null || stat -c '%a' "$CONFIG" 2>/dev/null || true)"
        jq --argjson a "$NEW_PROFILE" '.autonomy = $a' "$CONFIG" > "$TMP" && jq empty "$TMP" >/dev/null 2>&1 || fail 'no se pudo preparar la actualizacion de la configuracion'
        [ -z "$MODE" ] || chmod "$MODE" "$TMP" 2>/dev/null || true
        mv -f "$TMP" "$CONFIG" || fail 'no se pudo sustituir atomicamente la configuracion'
        trap - EXIT
    fi
    jq -cn --arg configPath "$CONFIG" --argjson changed "$CHANGED" --argjson revision "$NEW_REVISION" --arg profileDigest "$NEW_DIGEST" '{configPath:$configPath,changed:$changed,revision:$revision,profileDigest:$profileDigest}'
    exit 0
fi

CONSENT_PATH="$PROJECT_ROOT/.mefisto/pipeline/autonomy/consent.json"
safe_consent_path() {
    local current="$PROJECT_ROOT" part
    for part in .mefisto pipeline autonomy consent.json; do
        current="$current/$part"
        [ ! -L "$current" ] || return 1
    done
    return 0
}
safe_consent_path || fail 'el destino de consentimiento atraviesa un enlace simbolico'
if [ "$OPERATION" = preview ]; then
    CONSENT='null'
elif [ -e "$CONSENT_PATH" ]; then
    [ -f "$CONSENT_PATH" ] && [ ! -L "$CONSENT_PATH" ] || fail 'el registro de consentimiento no es un archivo regular'
    CONSENT="$(jq -cS . "$CONSENT_PATH" 2>/dev/null)" || CONSENT='"invalid-consent-record"'
else
    CONSENT='null'
fi
envelope() { jq -cn --argjson p "$PROFILE" --argjson c "$1" --arg id "$PROJECT_ID" --arg digest "$DIGEST" --argjson catalog "$CATALOG" '{profile:$p,consent:$c,context:{projectId:$id,profileDigest:$digest},catalog:$catalog}'; }
validate() { envelope "$1" | jq -c -f "$VALIDATOR"; }
RESULT="$(validate "$CONSENT")" || fail 'no se pudo validar el contrato de autonomia'

case "$OPERATION" in
    inspect)
        printf '%s\n' "$RESULT"
        case "$(printf '%s' "$RESULT" | jq -r '.status')" in disabled|ready) exit 0 ;; needs-approval|conflict) exit 1 ;; *) exit 2 ;; esac
        ;;
    preview)
        PREVIEW="$(validate null)"
        if [ "$(printf '%s' "$PREVIEW" | jq -r '.status')" = conflict ]; then fail "declaracion invalida: $(printf '%s' "$PREVIEW" | jq -r '.reasonCode')"; fi
        jq -cn --argjson profile "$PROFILE" --arg projectId "$PROJECT_ID" --arg expectedDigest "$DIGEST" '{projectId:$projectId,expectedDigest:$expectedDigest,profile:$profile,administration:($profile.administration // [])}'
        exit 0
        ;;
    approve)
        printf '%s' "$EXPECTED_DIGEST" | grep -Eq '^[0-9a-f]{64}$' || fail 'expected-digest invalido'
        [ "$HAS_CANONICAL" -eq 1 ] && [ "$PROFILE" != null ] || fail 'approve requiere una declaracion canonica de autonomia'
        [ "$EXPECTED_DIGEST" = "$DIGEST" ] || fail 'el perfil cambio desde preview; no se escribio consentimiento'
        [ "$(printf '%s' "$RESULT" | jq -r '.status')" != conflict ] || fail "registro incompatible: $(printf '%s' "$RESULT" | jq -r '.reasonCode')"
        PREVIEW="$(validate null)"
        [ "$(printf '%s' "$PREVIEW" | jq -r '.status')" != conflict ] || fail "declaracion invalida: $(printf '%s' "$PREVIEW" | jq -r '.reasonCode')"
        if [ "$(printf '%s' "$RESULT" | jq -r '.status')" = ready ]; then
            printf '%s\n' "$CONSENT"
            exit 0
        fi
        ;;
    revoke)
        [ "$(printf '%s' "$RESULT" | jq -r '.status')" != conflict ] || fail "registro incompatible: $(printf '%s' "$RESULT" | jq -r '.reasonCode')"
        PREVIEW="$(validate null)"
        [ "$(printf '%s' "$PREVIEW" | jq -r '.status')" != conflict ] || fail "declaracion invalida: $(printf '%s' "$PREVIEW" | jq -r '.reasonCode')"
        if [ "$CONSENT" != null ] && [ "$(printf '%s' "$CONSENT" | jq -r '.decision // empty')" = revoked ] \
          && [ "$(printf '%s' "$CONSENT" | jq -r '.projectId // empty')" = "$PROJECT_ID" ] \
          && [ "$(printf '%s' "$CONSENT" | jq -r '.profileDigest // empty')" = "$DIGEST" ]; then
            printf '%s\n' "$CONSENT"
            exit 0
        fi
        ;;
esac

mkdir -p "${CONSENT_PATH%/*}" || fail 'no se pudo preparar el registro de consentimiento'
safe_consent_path || fail 'el destino de consentimiento atraviesa un enlace simbolico'
DECISION="$([ "$OPERATION" = approve ] && printf approved || printf revoked)"
NEW_CONSENT="$(jq -cn --arg projectId "$PROJECT_ID" --arg profileDigest "$DIGEST" --arg decision "$DECISION" --arg recordedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{schemaVersion:1,projectId:$projectId,profileDigest:$profileDigest,decision:$decision,recordedAt:$recordedAt}')"
TMP="$(mktemp "${CONSENT_PATH%/*}/.consent.XXXXXX")" || fail 'no se pudo preparar la escritura atomica'
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$NEW_CONSENT" > "$TMP" && mv -f "$TMP" "$CONSENT_PATH" || fail 'no se pudo registrar el consentimiento'
trap - EXIT
printf '%s\n' "$NEW_CONSENT"
