#!/usr/bin/env bash
# seed-secret.sh -- registra un secreto nuevo post-greenfield (issue #256).
#
# Agrega/actualiza, de forma idempotente, una entrada en
# .claude/harness.config.json > secrets[] (que el step de siembra data-driven de
# infra-cd.yml itera en runtime -- agents/infra-base-scaffolder.md, Paso 2b) y localiza
# el archivo Terraform del dominio consumidor (infra/environments/<env>/dominio-{kebab}.tf,
# la fuente de verdad que ya genero domain-scaffolder). Este script NO edita HCL: imprime
# el app setting + la referencia @Microsoft.KeyVault(...) a cablear, para que el skill
# commands/seed-secret.md (Read + Edit) los inserte de forma idempotente -- mismo criterio
# que domain-scaffolder.md, que tampoco edita HCL con sed/awk.
#
# Uso:
#   scripts/seed-secret.sh <nombre> --domain <dominio> \
#       (--from-output <output-de-terraform> | --from-github-secret <NOMBRE_GITHUB_SECRET>) \
#       [--env <env>]
#
#   <nombre>              nombre del secreto en el Key Vault del BC (kebab-case recomendado)
#   --domain <dominio>    dominio consumidor; acepta kebab o PascalCase (calculo-horas o CalculoHoras)
#   --from-output         un 'terraform output' derivable (source.type=output, D2)
#   --from-github-secret  un GitHub secret no derivable (source.type=github-secret, D2)
#   --env <env>           ambiente Terraform (default: dev)
#
# Ejemplo:
#   scripts/seed-secret.sh stripe-api-key --domain facturacion --from-github-secret STRIPE_API_KEY
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"

# Guard defensivo: este script es del lado publicado y solo aplica al consumidor (ADR-0019).
_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$_REPO_TOP/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/seed-secret.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Mefisto no tiene harness.config.json ni dominios de negocio que sembrar." >&2
    exit 1
fi
unset _REPO_TOP

usage() {
    echo "Uso: $0 <nombre> --domain <dominio> (--from-output <output> | --from-github-secret <NOMBRE>) [--env <env>]" >&2
    echo "Ejemplo: $0 stripe-api-key --domain facturacion --from-github-secret STRIPE_API_KEY" >&2
}

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

NAME="$1"
shift

DOMAIN=""
FROM_OUTPUT=""
FROM_GITHUB_SECRET=""
ENV="dev"

while [ $# -gt 0 ]; do
    case "$1" in
        --domain)
            DOMAIN="${2:-}"
            shift 2
            ;;
        --from-output)
            FROM_OUTPUT="${2:-}"
            shift 2
            ;;
        --from-github-secret)
            FROM_GITHUB_SECRET="${2:-}"
            shift 2
            ;;
        --env)
            ENV="${2:-}"
            shift 2
            ;;
        *)
            echo "ERROR: argumento desconocido '$1'" >&2
            usage
            exit 1
            ;;
    esac
done

if [ -z "$NAME" ]; then
    echo "ERROR: falta <nombre> del secreto." >&2
    usage
    exit 1
fi

if [ -z "$DOMAIN" ]; then
    echo "ERROR: falta --domain <dominio>." >&2
    usage
    exit 1
fi

# D2 (fijado por el mantenedor): fuente explicita, sin heuristica por nombre -- exactamente
# uno de los dos flags.
if [ -n "$FROM_OUTPUT" ] && [ -n "$FROM_GITHUB_SECRET" ]; then
    echo "ERROR: pasa exactamente uno de --from-output o --from-github-secret, no ambos." >&2
    exit 1
fi
if [ -z "$FROM_OUTPUT" ] && [ -z "$FROM_GITHUB_SECRET" ]; then
    echo "ERROR: pasa uno de --from-output <output> o --from-github-secret <NOMBRE> (D2: fuente explicita, sin heuristica por nombre)." >&2
    exit 1
fi

load_harness_config || exit 1

# --- Resolver el dominio ------------------------------------------------------
#
# La fuente de verdad es el archivo Terraform que ya genero domain-scaffolder
# (infra/environments/<env>/dominio-{kebab}.tf, issue #234): este script NUNCA crea un
# dominio, solo cablea un secreto en uno que ya existe. Compara formas 'aplanadas' (sin
# guiones, minusculas) para aceptar --domain en kebab o en PascalCase.
flatten() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '-'; }

DOMAIN_FLAT=$(flatten "$DOMAIN")
DOMAIN_TF_FILE=""
DOMAIN_KEBAB=""

for f in "infra/environments/$ENV"/dominio-*.tf; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    kebab="${base#dominio-}"
    kebab="${kebab%.tf}"
    if [ "$(flatten "$kebab")" = "$DOMAIN_FLAT" ]; then
        DOMAIN_TF_FILE="$f"
        DOMAIN_KEBAB="$kebab"
        break
    fi
done

if [ -z "$DOMAIN_TF_FILE" ]; then
    echo "ERROR: no se encontro infra/environments/$ENV/dominio-*.tf para el dominio '$DOMAIN'." >&2
    echo "       Verifica que el dominio ya este scaffoldeado (/scaffold $DOMAIN) antes de sembrar un secreto en el." >&2
    exit 1
fi

# Chequeo secundario (no bloqueante): corrobora que la Function App del dominio existe
# en src/. El archivo Terraform de arriba ya es la fuente de verdad para el cableado.
DOMAIN_SRC_DIR=""
for d in "src/${HARNESS_NAMESPACE_PREFIX}."*/; do
    [ -d "$d" ] || continue
    base=$(basename "$d")
    candidate="${base#"${HARNESS_NAMESPACE_PREFIX}".}"
    if [ "$(flatten "$candidate")" = "$DOMAIN_FLAT" ]; then
        DOMAIN_SRC_DIR="$d"
        break
    fi
done

if [ -z "$DOMAIN_SRC_DIR" ]; then
    echo "ADVERTENCIA: se encontro $DOMAIN_TF_FILE pero no src/${HARNESS_NAMESPACE_PREFIX}.<Dominio>/ correspondiente." >&2
    echo "             continua igual: el archivo Terraform es la fuente de verdad para el cableado." >&2
fi

# --- Registrar la entrada en secrets[] (idempotente, CA-5) --------------------
if [ -n "$FROM_OUTPUT" ]; then
    SOURCE_TYPE="output"
    SOURCE_VALUE="$FROM_OUTPUT"
else
    SOURCE_TYPE="github-secret"
    SOURCE_VALUE="$FROM_GITHUB_SECRET"
fi

upsert_harness_secret "$NAME" "$SOURCE_TYPE" "$SOURCE_VALUE" || {
    echo "ERROR: no se pudo registrar '$NAME' en .claude/harness.config.json > secrets[]." >&2
    exit 1
}
echo "OK: '$NAME' registrado en .claude/harness.config.json > secrets[] (source: ${SOURCE_TYPE}:${SOURCE_VALUE})."

# --- CA-8: si el valor no es derivable, valida/recuerda el GitHub secret ------
if [ "$SOURCE_TYPE" = "github-secret" ]; then
    GH_LIST_TMP=$(mktemp 2>/dev/null || echo "/tmp/seed-secret-gh-list.$$")
    if command -v gh >/dev/null 2>&1 && gh secret list >"$GH_LIST_TMP" 2>/dev/null; then
        if awk '{print $1}' "$GH_LIST_TMP" | grep -Fqx "$SOURCE_VALUE"; then
            echo "OK: el GitHub secret '$SOURCE_VALUE' ya existe en el repo."
        else
            echo "RECORDATORIO: crea el GitHub secret '$SOURCE_VALUE' (Settings > Secrets and variables > Actions)"
            echo "              antes del proximo apply que deba sembrar '$NAME' -- si no, ese apply fallara"
            echo "              al no encontrar el valor (ver agents/infra-base-scaffolder.md, Paso 2b)."
        fi
    else
        echo "RECORDATORIO: no se pudo verificar con 'gh secret list' (sin gh instalado o sin sesion)."
        echo "              Confirma manualmente que el GitHub secret '$SOURCE_VALUE' existe antes del proximo apply."
    fi
    rm -f "$GH_LIST_TMP"
fi

# --- Imprimir el cableado pendiente en el archivo Terraform del dominio -------
#
# Este script no edita HCL: el skill (Read + Edit) inserta esto de forma idempotente,
# reusando el patron ya establecido por domain-scaffolder.md (CA-6: nunca duplica un
# app setting ni un role assignment ya presente).
APP_SETTING_KEY=$(printf '%s' "$NAME" | tr '[:lower:]-' '[:upper:]_')

echo ""
echo "Cableado pendiente en $DOMAIN_TF_FILE (module \"function_app_*\" > app_settings):"
echo "  $APP_SETTING_KEY = \"@Microsoft.KeyVault(SecretUri=\${module.key_vault.uri}secrets/$NAME)\""
echo ""
echo "Rol de lectura (Key Vault Secrets User) de la managed identity de este dominio:"
echo "  ya lo emite domain-scaffolder al crear el dominio (azurerm_role_assignment"
echo "  function_app_${DOMAIN_KEBAB//-/_}_kv_secrets_user, scope = module.key_vault.id) -- cubre"
echo "  TODOS los secretos del vault, incluido este (CA-6: no dupliques ese role assignment)."
echo "  Verifica que el bloque exista en $DOMAIN_TF_FILE; si por alguna razon faltara, agregalo"
echo "  (ver agents/domain-scaffolder.md)."
