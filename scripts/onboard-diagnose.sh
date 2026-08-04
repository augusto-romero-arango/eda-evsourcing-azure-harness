#!/usr/bin/env bash
# onboard-diagnose.sh --- Diagnostico de onboarding del consumidor (issue #443)
#
# Extraido del heredoc `bash <<'ONBOARD'` que commands/onboard.md incrustaba
# inline: Claude Code expande la sintaxis posicional de shell ($1..$9, $*, $@,
# $#) que encuentra en el TEXTO de un slash command antes de entregarlo al
# modelo -- sin importar que ese texto vaya despues dentro de comillas simples
# de un heredoc o de un awk. El heredoc usaba esa sintaxis en 5 puntos (row(),
# 4x el $1 de awk) y, sin argumentos (la forma habitual de invocar /onboard),
# $1 llegaba al modelo sustituido por cadena vacia (ver el body del issue #443
# para la entrega real que lo evidencio). Como script en disco, este archivo
# nunca pasa por esa sustitucion: commands/onboard.md solo lo invoca por ruta.
#
# Reporta, sin tocar nada, el checklist de 9 secciones de /onboard: config,
# tokens del harness en CLAUDE.md, estructura de carpetas, labels de GitHub,
# CI hacia Azure, secretos que alimentan la siembra en Key Vault, el registro
# secrets[], la bifurcacion de dos caminos de auth (tenancy.strategy) y el
# worker de proyecciones. Las provisiones opt-in (labels, CI, tenancy,
# proyecciones) viven en los pasos 3-6 de commands/onboard.md, que invocan
# otros scripts bajo confirmacion explicita del usuario -- este script nunca
# escribe ni ejecuta ninguno de ellos.
#
# Uso: scripts/onboard-diagnose.sh (cwd = raiz del repo consumidor)
# Exit code: 0 si el diagnostico corrio (sin importar cuantos FALTA/NO VERIFICADO
# reporte -- es informativo, nunca bloqueante); 1 solo si el guard defensivo
# cwd != Mefisto aborta (mismo contrato que la pre-condicion homonima de
# commands/onboard.md: "si el bloque imprime ERROR, detente").

set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_SCRIPTS="$SCRIPT_DIR"

# _secret_present <secrets_list> <name>
#
# Retorna 0 si <name> aparece como PRIMER campo (columna del nombre) de alguna
# linea de <secrets_list> -- formato de 'gh secret list' (NAME<TAB>...UPDATED).
# awk '{print $1}' aisla esa columna antes del grep exacto, para no confundir
# "el secreto existe" con "el texto aparece en algun lugar de la linea" (p. ej.
# una fecha o un nombre que es substring de otro secreto). Extraida a funcion
# para no repetir el idioma 4 veces (MEF-ADR-0018, Rule of Three) y para poder
# testearla sin invocar gh de verdad (scripts/tests/test-onboard-diagnose.sh).
_secret_present() {
    printf '%s\n' "$1" | awk '{print $1}' | grep -Fqx "$2"
}

# row <estado> <texto...>
#
# Emisor de filas del checklist: acumula el contador correspondiente (N_OK,
# N_FALTA, N_NV) y las imprime con el formato fijo del reporte. Cualquier
# <estado> distinto de OK/FALTA cuenta y se imprime como "NO VERIFICADO".
row() {
    estado="$1"
    shift
    item="$*"
    case "$estado" in
        OK) N_OK=$((N_OK + 1)) ;;
        FALTA) N_FALTA=$((N_FALTA + 1)) ;;
        *)
            N_NV=$((N_NV + 1))
            estado="NO VERIFICADO"
            ;;
    esac
    printf '  [%-13s] %s\n' "$estado" "$item"
}

main() {
    CONFIG=".claude/harness.config.json"
    N_OK=0
    N_FALTA=0
    N_NV=0
    ACTIONS=""
    # Flags para el bloque de cierre "Proximos pasos" (CA-1): se fijan junto a cada row()
    # correspondiente, para no re-diagnosticar nada al construir el bloque en la seccion 10.
    # PA_AUTH_PATH (issue #341) no acompana un FALTA -- se fija cuando el camino declarado es (A) crecer.
    PA_CONFIG_FALTA=0
    PA_TOKENS_FALTA=0
    PA_LABELS_FALTA=0
    PA_CI_FALTA=0
    PA_INFRA_BASE_MISSING=0
    PA_AUTH_PATH=0
    PA_PROJECTIONS_MISSING=0

    # Guard defensivo (cwd != Mefisto), por si el script se invoca aislado.
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo "ERROR: no estas en un repositorio git"
        return 1
    }
    if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
        echo "ERROR: /onboard no aplica al repo de Mefisto."
        # Segunda linea con el fraseo canonico del resto de los scripts publicados
        # (setup-github-labels.sh, setup-github-ci.sh, seed-secret.sh, ...): es lo que
        # verifica el bloque C2 de scripts/tests/test-guards.sh, que EJECUTA cada script
        # publicado dentro de Mefisto y exige exit 1 mas ese mensaje. La primera linea se
        # conserva verbatim porque es la que /onboard le pide al modelo reconocer
        # ("si el bloque imprime ERROR, detente").
        echo "       scripts/onboard-diagnose.sh es del plugin publicado y solo aplica al consumidor."
        return 1
    fi

    echo "===================================================================="
    echo "  /onboard - diagnostico del harness (solo lectura)"
    echo "===================================================================="
    echo ""

    # --- 1. Configuracion: reusa load_harness_config (#78 = fuente de verdad) ---
    echo "Configuracion (.claude/harness.config.json):"
    COMMON="$SCRIPT_DIR/_pipeline-common.sh"
    if [ -f "$COMMON" ]; then
        source "$COMMON" >/dev/null 2>&1
        LHC_TMP=$(mktemp 2>/dev/null || echo "/tmp/onboard-lhc.$$")
        load_harness_config >/dev/null 2>"$LHC_TMP"
        LHC_RC=$?
        LHC_ERR=$(cat "$LHC_TMP" 2>/dev/null)
        rm -f "$LHC_TMP"
        if [ "$LHC_RC" -eq 0 ]; then
            row OK "el archivo existe y parsea con jq"
            row OK "campos requeridos presentes (projectName, namespacePrefix, solutionFile)"
            if [ -n "${HARNESS_BC_NAME:-}" ]; then
                row OK "boundedContext declarado: name='${HARNESS_BC_NAME}' domains='${HARNESS_BC_DOMAINS}'"
            else
                row FALTA "boundedContext ausente o invalido (campo obligatorio, MEF-ADR-0023)"
                PA_CONFIG_FALTA=1
                ACTIONS="${ACTIONS}  - Falta 'boundedContext' en .claude/harness.config.json. Añade:
    \"boundedContext\": { \"name\": \"<NombreDetuBC>\", \"domains\": [<tus domainLabels>] }
  Los dominios deben ser un subconjunto de domainLabels. Ver README seccion 'Migracion para consumidores existentes'.
"
            fi
            if [ -n "${HARNESS_TFSTATE_STORAGE:-}" ]; then
                row OK "terraformStateStorage valido: ${HARNESS_TFSTATE_STORAGE}"
            else
                row OK "terraformStateStorage vacio (consumidor sin IaC; valido)"
            fi
        else
            row FALTA "configuracion invalida o incompleta"
            PA_CONFIG_FALTA=1
            printf '%s\n' "$LHC_ERR" | while IFS= read -r l; do [ -n "$l" ] && echo "                  $l"; done
            ACTIONS="${ACTIONS}  - Corrige .claude/harness.config.json segun el detalle de arriba (README, seccion \"Configurar el consumidor\").
"
        fi
    else
        row NV "no se hallo load_harness_config del plugin (config sin validar)"
        if [ -f "$CONFIG" ]; then echo "                  (el archivo $CONFIG si existe)"; else echo "                  (el archivo $CONFIG no existe)"; fi
        ACTIONS="${ACTIONS}  - No se pudo resolver el plugin para reusar load_harness_config; reinstala mefisto o reabre la sesion (hook SessionStart).
"
    fi

    # --- 2. Tokens del harness en CLAUDE.md (contrato punto 2) ---
    echo ""
    echo "Tokens del harness (seccion \"Tokens del harness\" en CLAUDE.md raiz):"
    CLAUDE_MD="CLAUDE.md"
    if [ -r "$CLAUDE_MD" ]; then
        MISSING_TOKENS=""
        for tok in RootNamespace SolutionFile ProjectDisplayName BoundedContext BoundedContextDomains; do
            grep -Eq "\*\*${tok}\*\*" "$CLAUDE_MD" || MISSING_TOKENS="$MISSING_TOKENS $tok"
        done
        if [ -z "$MISSING_TOKENS" ]; then
            row OK "los 5 tokens estan presentes (RootNamespace, SolutionFile, ProjectDisplayName, BoundedContext, BoundedContextDomains)"
        else
            row FALTA "faltan tokens en CLAUDE.md:$MISSING_TOKENS"
            PA_TOKENS_FALTA=1
            ACTIONS="${ACTIONS}  - Completa la seccion \"Tokens del harness\" de tu CLAUDE.md raiz con los tokens faltantes ($MISSING_TOKENS). Ver CLAUDE.md del harness, seccion \"Contrato con el proyecto consumidor\" punto 2, para el formato exacto.
"
        fi
    else
        row NV "no se hallo un CLAUDE.md legible en la raiz del proyecto"
        ACTIONS="${ACTIONS}  - Crea CLAUDE.md en la raiz del proyecto con la seccion \"Tokens del harness\" (ver CLAUDE.md del harness, seccion \"Contrato con el proyecto consumidor\" punto 2).
"
    fi

    # --- 3. Estructura de carpetas esperada (contrato punto 3, informativo) ---
    echo ""
    echo "Estructura de carpetas esperada (informativo, no bloqueante):"
    for dir in src tests infra/environments; do
        if [ -d "$dir" ]; then
            row OK "$dir/ existe"
        else
            row NV "$dir/ no existe todavia (normal en greenfield antes del primer /scaffold o /infra-base; no bloqueante)"
            [ "$dir" = "infra/environments" ] && PA_INFRA_BASE_MISSING=1
        fi
    done

    # --- 4. Labels de GitHub (MEF-ADR-0007) ---
    echo ""
    echo "Labels de GitHub (esquema del harness - MEF-ADR-0007):"
    EXISTING=$(gh label list --json name -q '.[].name' 2>/dev/null)
    GH_RC=$?
    if [ "$GH_RC" -ne 0 ]; then
        row NV "no se pudieron listar los labels (gh no autenticado / sin repo / version antigua)"
        ACTIONS="${ACTIONS}  - Autentica gh (\"gh auth login\") y reintenta para diagnosticar los labels.
"
    else
        MISSING=""
        for lbl in tipo:feature tipo:infra tipo:refactor tipo:tooling tipo:projection estado:borrador estado:listo bug bloqueado; do
            printf '%s\n' "$EXISTING" | grep -Fqx "$lbl" || MISSING="$MISSING $lbl"
        done
        if [ -n "${HARNESS_DOMAIN_LABELS:-}" ]; then
            for dom in $HARNESS_DOMAIN_LABELS; do
                printf '%s\n' "$EXISTING" | grep -Fqx "dom:$dom" || MISSING="$MISSING dom:$dom"
            done
        fi
        if [ -z "$MISSING" ]; then
            row OK "esquema completo (tipo:*, estado:*, dom:*, bug, bloqueado)"
        else
            row FALTA "faltan labels:$MISSING"
            PA_LABELS_FALTA=1
            ACTIONS="${ACTIONS}  - Faltan labels del esquema. /onboard puede crearlos en el paso de provision opt-in (te lo ofrece tras el diagnostico, bajo confirmacion: el script borra los labels default de GitHub y recrea el esquema). O ejecutalo tu mismo: \"$PLUGIN_SCRIPTS/setup-github-labels.sh\".
"
        fi
        if [ -z "${HARNESS_DOMAIN_LABELS:-}" ]; then
            echo "                  (dom:* no verificado - domainLabels vacio o config no cargada)"
        fi
    fi

    # --- 5. CI hacia Azure (MEF-ADR-0022) ---
    echo ""
    echo "CI hacia Azure (OIDC / Service Principal - MEF-ADR-0022):"
    if ! command -v az >/dev/null 2>&1; then
        row NV "Service Principal de CI (Azure CLI no instalado)"
        ACTIONS="${ACTIONS}  - Instala Azure CLI y ejecuta \"az login\" para verificar el Service Principal del CI.
"
    elif ! az account show >/dev/null 2>&1; then
        row NV "Service Principal de CI (sin sesion de Azure)"
        ACTIONS="${ACTIONS}  - Ejecuta \"az login\" para que /onboard pueda verificar el Service Principal del CI.
"
    elif [ -z "${HARNESS_SP_NAME:-}" ]; then
        row NV "Service Principal de CI (githubServicePrincipalName ausente en el config)"
    else
        APP_ID=$(az ad app list --display-name "$HARNESS_SP_NAME" --query "[0].appId" -o tsv 2>/dev/null)
        if [ -n "$APP_ID" ] && [ "$APP_ID" != "None" ]; then
            row OK "aplicacion de Entra \"$HARNESS_SP_NAME\" existe (appId $APP_ID)"
        else
            row FALTA "aplicacion de Entra \"$HARNESS_SP_NAME\" no encontrada"
            PA_CI_FALTA=1
            ACTIONS="${ACTIONS}  - Falta la app de Entra del CI. /onboard puede configurarlo en el paso de provision opt-in (te lo ofrece tras el diagnostico, bajo confirmacion: crea recursos reales en Azure -- app de Entra, role assignments y federated credential OIDC, MEF-ADR-0022 -- y debe correr DESPUES de bootstrap-backend.sh). O ejecutalo tu mismo: \"$PLUGIN_SCRIPTS/setup-github-ci.sh <subscription-id>\".
"
        fi
    fi

    # Secrets OIDC del repo (lectura tolerante; requiere admin del repo)
    SECRETS=$(gh secret list 2>/dev/null)
    GS_RC=$?
    if [ "$GS_RC" -ne 0 ]; then
        row NV "secrets OIDC en GitHub (no se pudieron listar; requiere permisos de admin del repo)"
    else
        MISS_S=""
        for s in AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID; do
            _secret_present "$SECRETS" "$s" || MISS_S="$MISS_S $s"
        done
        if [ -z "$MISS_S" ]; then
            row OK "secrets OIDC presentes (AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID)"
        else
            row FALTA "faltan secrets OIDC:$MISS_S"
            PA_CI_FALTA=1
            ACTIONS="${ACTIONS}  - Copia los tres secrets OIDC (AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID) que imprime \"$PLUGIN_SCRIPTS/setup-github-ci.sh <subscription-id>\" a Settings > Secrets and variables > Actions. El script (y el paso de provision opt-in de /onboard) NO los sube: pegalos a mano. No hay client secret que expire (OIDC, MEF-ADR-0022).
"
        fi
    fi

    # --- 6. Secretos que alimentan la siembra en Key Vault (MEF-ADR-0025, informativo) ---
    echo ""
    echo "Secretos que alimentan la siembra en Key Vault (MEF-ADR-0025 -- la siembra la hace CI tras el apply):"
    if [ "$GS_RC" -ne 0 ]; then
        row NV "no se pudieron listar los secrets (mismo motivo que la seccion anterior)"
    else
        _secret_present "$SECRETS" "TF_VAR_POSTGRESQL_ADMIN_PASSWORD" \
            && row OK "TF_VAR_POSTGRESQL_ADMIN_PASSWORD presente (alimenta marten-connection, MEF-ADR-0025 decision #9)" \
            || row NV "TF_VAR_POSTGRESQL_ADMIN_PASSWORD no encontrado (crealo cuando provisiones Postgres -- MEF-ADR-0025 decision #9)"
        if [ -n "${HARNESS_SB_EXTERNAL_ALIASES:-}" ]; then
            for alias in $HARNESS_SB_EXTERNAL_ALIASES; do
                SECNAME="SB_EXTERNAL_${alias}_CONNECTION_STRING"
                _secret_present "$SECRETS" "$SECNAME" \
                    && row OK "$SECNAME presente" \
                    || row NV "$SECNAME no encontrado (uno por alias de serviceBus.external[] -- MEF-ADR-0025 decision #10)"
            done
        fi
    fi

    # --- 7. Registro secrets[] (issue #256, informativo) ---
    echo ""
    echo "Registro harness.config.json > secrets[] (siembra data-driven -- MEF-ADR-0025, issue #256):"
    if [ -n "${HARNESS_SECRETS_NAMES:-}" ]; then
        read -ra SEC_NAMES <<<"$HARNESS_SECRETS_NAMES"
        read -ra SEC_TYPES <<<"$HARNESS_SECRETS_TYPES"
        read -ra SEC_VALUES <<<"$HARNESS_SECRETS_VALUES"
        row OK "secrets[] registra ${#SEC_NAMES[@]} entrada(s)"
        if [ "$GS_RC" -ne 0 ]; then
            row NV "no se pudo verificar la existencia de los GitHub secrets que referencian (mismo motivo que la seccion CI)"
        else
            for ((si = 0; si < ${#SEC_NAMES[@]}; si++)); do
                if [ "${SEC_TYPES[$si]}" = "github-secret" ]; then
                    _secret_present "$SECRETS" "${SEC_VALUES[$si]}" \
                        && row OK "secrets[].name='${SEC_NAMES[$si]}': GitHub secret '${SEC_VALUES[$si]}' presente" \
                        || row NV "secrets[].name='${SEC_NAMES[$si]}': GitHub secret '${SEC_VALUES[$si]}' no encontrado (crealo antes del proximo apply que lo siembre)"
                fi
            done
        fi
    else
        row NV "secrets[] no declarado todavia (normal antes del primer /infra-base o si el config es invalido -- ver seccion Configuracion)"
    fi

    # --- 8. Bifurcacion de dos caminos de auth (tenancy.strategy, MEF-ADR-0028, issue #323 + #341, informativo) ---
    echo ""
    echo "Bifurcacion de dos caminos de auth -- (A) crecer / (B) POC (tenancy.strategy, MEF-ADR-0028):"
    TENANCY_STRATEGY=$(jq -r '.tenancy.strategy // ""' "$CONFIG" 2>/dev/null)
    case "$TENANCY_STRATEGY" in
        "")
            row NV "tenancy.strategy ausente -- camino (B) POC por defecto (etapa a, mono-tenant-transitorio, valido, no bloqueante)"
            ;;
        mono-tenant-transitorio)
            row OK "tenancy.strategy = mono-tenant-transitorio -- camino (B) POC: sin autenticacion (etapa a)"
            ;;
        multi-tenant-header)
            row OK "tenancy.strategy = multi-tenant-header -- camino (A) crecer: autenticacion orquestada desde el inicio (etapa b)"
            PA_AUTH_PATH=1
            ;;
        *)
            row NV "tenancy.strategy tiene un valor no reconocido: '$TENANCY_STRATEGY' (esperado mono-tenant-transitorio | multi-tenant-header)"
            ;;
    esac

    # --- 9. Worker de proyecciones (projections.enabled, MEF-ADR-0034, issue #369, informativo) ---
    echo ""
    echo "Worker de proyecciones (projections.enabled, MEF-ADR-0034):"
    # Fuente preferida: la variable derivada de load_harness_config. Pero esa funcion aborta
    # (return 1, sin exportar nada) cuando el config es invalido -- p. ej. sin 'boundedContext',
    # el estado exacto de un consumidor a medio migrar -- y ni siquiera corre cuando no se hallo
    # el _pipeline-common.sh del plugin. En ambos casos la variable queda vacia, y reportar por eso
    # "token ausente" seria FALSO: ademas apagaria en silencio el paso opt-in 6 (CA-4). Por eso, si
    # no llego exportada, se re-deriva inline con jq desde $CONFIG -- mismo patron que la seccion 8
    # (tenancy.strategy) y que los consumidores inline del token (infra-base-scaffolder,
    # /scaffold-projections). Sin operador '//': en jq 'false' es falsy, asi que 'false // X'
    # devuelve X y confundiria "deshabilitado" con "ausente".
    PROJECTIONS_ENABLED="${HARNESS_PROJECTIONS_ENABLED:-}"
    NS_PREFIX="${HARNESS_NAMESPACE_PREFIX:-}"
    if [ -z "$PROJECTIONS_ENABLED" ]; then
        PROJ_RAW=$(jq -r '.projections.enabled' "$CONFIG" 2>/dev/null)
        if [ "$PROJ_RAW" = "true" ]; then PROJECTIONS_ENABLED="true"; else PROJECTIONS_ENABLED="false"; fi
    fi
    [ -z "$NS_PREFIX" ] && NS_PREFIX=$(jq -r '.namespacePrefix // ""' "$CONFIG" 2>/dev/null)
    if [ "$PROJECTIONS_ENABLED" != "true" ]; then
        row NV "projections.enabled ausente o en false -- BC no adopta proyecciones (opt-in, valido, no bloqueante)"
    elif [ -z "$NS_PREFIX" ]; then
        row NV "projections.enabled=true, pero falta 'namespacePrefix' para derivar la ruta del worker (revisa la seccion Configuracion)"
    else
        WORKER_CSPROJ="src/${NS_PREFIX}.Projections/${NS_PREFIX}.Projections.csproj"
        if [ -f "$WORKER_CSPROJ" ]; then
            row OK "projections.enabled=true -- worker ${NS_PREFIX}.Projections presente"
        else
            row NV "projections.enabled=true, pero el worker ${NS_PREFIX}.Projections no existe todavia (corre /scaffold-projections)"
            PA_PROJECTIONS_MISSING=1
        fi
    fi

    # --- 10. Acciones y resumen ---
    echo ""
    if [ -n "$ACTIONS" ]; then
        echo "Acciones sugeridas (el diagnostico no ejecuta ninguna; los labels faltantes y el CI los pueden provisionar los pasos opt-in, bajo tu confirmacion):"
        printf '%s' "$ACTIONS"
        echo ""
    fi
    echo "===================================================================="
    echo "  Resumen: $N_OK OK | $N_FALTA FALTA | $N_NV NO VERIFICADO"
    if [ "$N_FALTA" -eq 0 ] && [ "$N_NV" -eq 0 ]; then
        echo "  Estado: LISTO - el harness esta configurado."
    elif [ "$N_FALTA" -eq 0 ]; then
        echo "  Estado: LISTO con salvedades - revisa los NO VERIFICADO."
    else
        echo "  Estado: INCOMPLETO - resuelve los FALTA antes de usar los pipelines."
    fi
    echo "===================================================================="
    echo ""
    echo "Proximos pasos (informativo -- no ejecuta nada; los comandos abajo son los que tu corres o confirmas):"
    if [ "$N_FALTA" -eq 0 ]; then
        PA_STEP=0
        if [ "$PA_INFRA_BASE_MISSING" -eq 1 ]; then
            PA_STEP=$((PA_STEP + 1))
            echo "  $PA_STEP. Genera la infraestructura base: /mefisto:infra-base dev"
        else
            PA_STEP=$((PA_STEP + 1))
            echo "  $PA_STEP. El harness esta configurado: arranca (o continua) el dominio con /mefisto:scaffold <dominio>,"
            echo "     luego /mefisto:draft y /mefisto:implement para tu primer ciclo TDD."
            PA_STEP=$((PA_STEP + 1))
            echo "  $PA_STEP. Recordatorio recurrente: la siembra de secretos en Key Vault la hace CI (infra-cd.yml),"
            echo "     iterando harness.config.json > secrets[] -- MEF-ADR-0025, issue #256. Tu unica accion manual"
            echo "     es crear/verificar los GitHub secrets que alimentan cada entrada github-secret"
            echo "     (TF_VAR_POSTGRESQL_ADMIN_PASSWORD, un SB_EXTERNAL_<ALIAS>_CONNECTION_STRING por alias, o el"
            echo "     que declares con /seed-secret) en Settings > Secrets and variables > Actions."
        fi
        if [ "$PA_AUTH_PATH" -eq 1 ]; then
            PA_STEP=$((PA_STEP + 1))
            echo "  $PA_STEP. Camino auth elegido (tenancy.strategy = multi-tenant-header, MEF-ADR-0028): tras"
            echo "     /mefisto:infra-base y /mefisto:scaffold <dominio>, corre /install-auth para instalar WorkOS+APIM"
            echo "     (MEF-ADR-0032): encadena /install-workos y /install-apim con el gate humano en medio."
        fi
        if [ "$PA_PROJECTIONS_MISSING" -eq 1 ]; then
            PA_STEP=$((PA_STEP + 1))
            echo "  $PA_STEP. El BC declara projections.enabled=true pero el worker de proyecciones no existe:"
            echo "     corre /scaffold-projections para generarlo (MEF-ADR-0034), o confirma el paso opt-in que"
            echo "     te ofrece este mismo /onboard."
        fi
    else
        PA_STEP=0
        if [ "$PA_CONFIG_FALTA" -eq 1 ]; then
            PA_STEP=$((PA_STEP + 1))
            echo "  $PA_STEP. Corrige .claude/harness.config.json (detalle en \"Acciones sugeridas\" arriba)."
        fi
        if [ "$PA_TOKENS_FALTA" -eq 1 ]; then
            PA_STEP=$((PA_STEP + 1))
            echo "  $PA_STEP. Completa la seccion \"Tokens del harness\" en tu CLAUDE.md raiz (detalle arriba)."
        fi
        if [ "$PA_LABELS_FALTA" -eq 1 ]; then
            PA_STEP=$((PA_STEP + 1))
            echo "  $PA_STEP. Provisiona los labels de GitHub: \"$PLUGIN_SCRIPTS/setup-github-labels.sh\""
            echo "     (o confirma el paso opt-in que te ofrece este mismo /onboard)."
        fi
        if [ "$PA_CI_FALTA" -eq 1 ]; then
            PA_STEP=$((PA_STEP + 1))
            echo "  $PA_STEP. Configura el CI hacia Azure: \"$PLUGIN_SCRIPTS/setup-github-ci.sh <subscription-id>\""
            echo "     (o confirma el paso opt-in). Corre DESPUES de \"bootstrap-backend.sh\" (MEF-ADR-0022)."
        fi
        if [ "$PA_INFRA_BASE_MISSING" -eq 1 ]; then
            PA_STEP=$((PA_STEP + 1))
            echo "  $PA_STEP. Genera la infraestructura base: /mefisto:infra-base dev"
        fi
        if [ "$PA_AUTH_PATH" -eq 1 ]; then
            PA_STEP=$((PA_STEP + 1))
            echo "  $PA_STEP. Camino auth elegido (tenancy.strategy = multi-tenant-header, MEF-ADR-0028): una vez"
            echo "     resueltos los FALTA de arriba, con infra base y al menos un dominio scaffoldeado, corre"
            echo "     /install-auth para instalar WorkOS+APIM (MEF-ADR-0032): encadena /install-workos y"
            echo "     /install-apim con el gate humano en medio."
        fi
        if [ "$PA_PROJECTIONS_MISSING" -eq 1 ]; then
            PA_STEP=$((PA_STEP + 1))
            echo "  $PA_STEP. El BC declara projections.enabled=true pero el worker de proyecciones no existe:"
            echo "     corre /scaffold-projections para generarlo (MEF-ADR-0034), o confirma el paso opt-in que"
            echo "     te ofrece este mismo /onboard."
        fi
        if [ "$PA_STEP" -eq 0 ]; then
            echo "  Resuelve primero los \"NO VERIFICADO\" de arriba (instala/autentica lo que falte) para que"
            echo "  /onboard pueda indicarte el siguiente comando exacto."
        fi
    fi
    echo ""
    QUICKSTART_URL="https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/blob/main/docs/greenfield-quickstart.md"
    if [ -f "${PLUGIN_ROOT%/}/.claude-plugin/plugin.json" ] && command -v jq >/dev/null 2>&1; then
        HOMEPAGE=$(jq -r '.homepage // empty' "${PLUGIN_ROOT%/}/.claude-plugin/plugin.json" 2>/dev/null)
        [ -n "$HOMEPAGE" ] && QUICKSTART_URL="${HOMEPAGE%/}/blob/main/docs/greenfield-quickstart.md"
    fi
    echo "Guia narrativa completa del arranque greenfield (10 pasos, roles admin/infra vs dev ongoing):"
    echo "  $QUICKSTART_URL"
    echo "===================================================================="
}

# Sourceable (scripts/tests/test-onboard-diagnose.sh la sourcea para testear
# row() y _secret_present() sin correr el diagnostico completo -- que invoca
# gh/az/jq reales) y a la vez ejecutable directo, mismo patron sugerido en el
# body del issue #443.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main
    exit $?
fi
