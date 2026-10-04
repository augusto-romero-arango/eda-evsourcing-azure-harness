#!/usr/bin/env bash
# Gestion local, explicita y previa a etapas del consentimiento de autonomia.
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VALIDATOR="$SCRIPT_DIR/../src/published/contract/autonomy-profile.validate.jq"

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }
usage() { fail 'uso: autonomy-profile.sh <preview|approve|revoke|inspect> --project-root <raiz> [--expected-digest <sha256>]'; }
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d ' ' -f 1; else sha256sum "$1" | cut -d ' ' -f 1; fi; }

OPERATION="${1:-}"; [ $# -gt 0 ] && shift
PROJECT_ROOT=""; EXPECTED_DIGEST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --project-root) [ $# -ge 2 ] || usage; PROJECT_ROOT="$2"; shift 2 ;;
        --expected-digest) [ $# -ge 2 ] || usage; EXPECTED_DIGEST="$2"; shift 2 ;;
        *) usage ;;
    esac
done
case "$OPERATION" in preview|approve|revoke|inspect) ;; *) usage ;; esac
[ -n "$PROJECT_ROOT" ] || usage
[ -x "$(command -v jq 2>/dev/null || true)" ] || fail 'jq no esta instalado'
[ -f "$VALIDATOR" ] || fail 'no se encontro el validador de perfil publicado'

PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P)" || fail 'la raiz de proyecto no existe'
git -C "$PROJECT_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || fail 'la raiz indicada no es un repositorio Git'
[ ! -f "$PROJECT_ROOT/.claude-plugin/plugin.json" ] || fail 'autonomy-profile.sh es del plugin publicado y solo aplica al consumidor'
CONFIG="$PROJECT_ROOT/.mefisto/harness.config.json"
LEGACY_CONFIG="$PROJECT_ROOT/.claude/harness.config.json"
HAS_CANONICAL=0
if [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ]; then
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
COMMON_DIR="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || fail 'no se pudo resolver la identidad Git comun'
COMMON_DIR="$(cd "$COMMON_DIR" 2>/dev/null && pwd -P)" || fail 'la identidad Git comun no es accesible'
PROJECT_ID="project-$(printf '%s' "$COMMON_DIR" | (command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum) | cut -c1-24)"

if [ "$HAS_CANONICAL" -eq 1 ]; then
    PROFILE="$(jq -cS '.autonomy // null' "$CONFIG" 2>/dev/null)" || fail 'la declaracion canonica no es JSON valido'
else
    PROFILE='null'
fi
if [ "$PROFILE" = 'null' ]; then
    DIGEST="$(printf 'null' | (command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum) | cut -d ' ' -f 1)"
else
    DIGEST="$(printf '%s' "$PROFILE" | (command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum) | cut -d ' ' -f 1)"
fi
CATALOG="$(for command in "$SCRIPT_DIR/../commands"/*.md; do [ -f "$command" ] || continue; basename "$command" .md | sed 's/^mefisto://' ; done | jq -R . | jq -scS 'sort')" || fail 'no se pudo construir el catalogo publicado'

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
if [ -e "$CONSENT_PATH" ]; then
    [ -f "$CONSENT_PATH" ] && [ ! -L "$CONSENT_PATH" ] || fail 'el registro de consentimiento no es un archivo regular'
    CONSENT="$(jq -cS . "$CONSENT_PATH" 2>/dev/null)" || fail 'el registro de consentimiento no es JSON valido'
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
        ;;
    revoke)
        [ "$(printf '%s' "$RESULT" | jq -r '.status')" != conflict ] || fail "registro incompatible: $(printf '%s' "$RESULT" | jq -r '.reasonCode')"
        [ "$PROFILE" = null ] && exit 0
        PREVIEW="$(validate null)"
        [ "$(printf '%s' "$PREVIEW" | jq -r '.status')" != conflict ] || fail "declaracion invalida: $(printf '%s' "$PREVIEW" | jq -r '.reasonCode')"
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
