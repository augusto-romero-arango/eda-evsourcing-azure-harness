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
# directivas canónicas en AGENTS.md y su puente CLAUDE.md, estructura de carpetas, labels de GitHub,
# CI hacia Azure, secretos que alimentan la siembra en Key Vault, el registro
# secrets[], la bifurcacion de dos caminos de auth (tenancy.strategy) y el
# worker de proyecciones. Las provisiones opt-in (directivas, labels, CI,
# tenancy, proyecciones) viven en los pasos 3-7 de commands/onboard.md e invocan
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

# _mefisto_pipeline_ignored [repo_root]
# Consulta git, sin modificar el consumidor, con un hijo representativo del
# directorio que debe quedar no versionado. Tambien exige que el config sibling
# siga siendo versionable, para no aceptar por error un ignore amplio de
# .mefisto/ completo.
_mefisto_pipeline_ignored() {
    local repo_root="${1:-.}"
    git -C "$repo_root" check-ignore -q -- .mefisto/pipeline/.onboard-probe &&
        ! git -C "$repo_root" check-ignore -q -- .mefisto/harness.config.json
}

# _has_contract_heading <file> <heading>
# Reconoce solamente los encabezados Markdown de las secciones contractuales.
_has_contract_heading() {
    grep -Eq "^[[:space:]]*#{1,6}[[:space:]]+$2([[:space:]]*\\([^)]*\\))?[[:space:]]*$" "$1"
}

# _contract_section_has_token <file> <token>
# Limita la búsqueda a "Tokens del harness": una ocurrencia incidental en otra
# sección no completa el contrato de esa sección.
_contract_section_has_token() {
    awk -v token="$2" '
        /^[[:space:]]*#{1,6}[[:space:]]+/ {
            heading = $0
            sub(/^[[:space:]]*#{1,6}[[:space:]]+/, "", heading)
            sub(/[[:space:]]+$/, "", heading)
            if (heading ~ /^Tokens del harness([[:space:]]*\([^)]*\))?$/) {
                in_tokens = 1
                next
            }
            if (in_tokens) in_tokens = 0
        }
        in_tokens && index($0, "**" token "**") { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$1"
}

# _check_consumer_directives [agents_md] [claude_md]
# Diagnóstico sourceable para que main() y las pruebas consuman la misma lógica
# sin invocar gh, az o jq. Deja estados, detalles y señales en DIRECTIVES_*.
_check_consumer_directives() {
    local agents_md="${1:-AGENTS.md}" claude_md="${2:-CLAUDE.md}"
    local missing="" token has_import=0 has_legacy=0
    AGENTS_DIRECTIVES_STATE=""; AGENTS_DIRECTIVES_DETAIL=""
    CLAUDE_BRIDGE_STATE=""; CLAUDE_BRIDGE_DETAIL=""
    CLAUDE_BRIDGE_HAS_IMPORT=0; CLAUDE_BRIDGE_HAS_LEGACY=0

    if [ ! -e "$agents_md" ]; then
        AGENTS_DIRECTIVES_STATE="FALTA"
        AGENTS_DIRECTIVES_DETAIL="AGENTS.md no existe: crea las secciones \"Tokens del harness\" y \"Verificación de fuentes\" con los 5 tokens obligatorios"
    elif [ ! -r "$agents_md" ]; then
        AGENTS_DIRECTIVES_STATE="NV"
        AGENTS_DIRECTIVES_DETAIL="AGENTS.md existe pero no es legible"
    else
        _has_contract_heading "$agents_md" "Tokens del harness" || missing=" encabezado \"Tokens del harness\""
        _has_contract_heading "$agents_md" "Verificación de fuentes" || missing="${missing} encabezado \"Verificación de fuentes\""
        for token in RootNamespace SolutionFile ProjectDisplayName BoundedContext BoundedContextDomains; do
            _contract_section_has_token "$agents_md" "$token" || missing="${missing} ${token}"
        done
        if [ -z "$missing" ]; then
            AGENTS_DIRECTIVES_STATE="OK"
            AGENTS_DIRECTIVES_DETAIL="AGENTS.md contiene las dos secciones obligatorias y los 5 tokens"
        else
            AGENTS_DIRECTIVES_STATE="FALTA"
            AGENTS_DIRECTIVES_DETAIL="AGENTS.md esta incompleto; faltan:${missing}"
        fi
    fi

    if [ ! -e "$claude_md" ]; then
        CLAUDE_BRIDGE_STATE="FALTA"
        CLAUDE_BRIDGE_DETAIL="CLAUDE.md no existe: crea el puente con una linea independiente @AGENTS.md"
    elif [ ! -r "$claude_md" ]; then
        CLAUDE_BRIDGE_STATE="NV"
        CLAUDE_BRIDGE_DETAIL="CLAUDE.md existe pero no es legible"
    else
        grep -Eq '^[[:space:]]*@AGENTS\.md[[:space:]]*$' "$claude_md" && has_import=1
        if _has_contract_heading "$claude_md" "Tokens del harness" || _has_contract_heading "$claude_md" "Verificación de fuentes"; then has_legacy=1; fi
        CLAUDE_BRIDGE_HAS_IMPORT=$has_import
        CLAUDE_BRIDGE_HAS_LEGACY=$has_legacy
        if [ "$has_import" -eq 1 ] && [ "$has_legacy" -eq 0 ]; then
            CLAUDE_BRIDGE_STATE="OK"
            CLAUDE_BRIDGE_DETAIL="CLAUDE.md contiene el puente exacto @AGENTS.md sin secciones contractuales duplicadas"
        elif [ "$has_import" -eq 0 ] && [ "$has_legacy" -eq 1 ]; then
            CLAUDE_BRIDGE_STATE="FALTA"
            CLAUDE_BRIDGE_DETAIL="CLAUDE.md legacy legible: faltan el puente exacto @AGENTS.md y la limpieza manual de las secciones contractuales duplicadas"
        elif [ "$has_import" -eq 0 ]; then
            CLAUDE_BRIDGE_STATE="FALTA"
            CLAUDE_BRIDGE_DETAIL="CLAUDE.md no contiene una linea independiente @AGENTS.md; agrega el puente hacia AGENTS.md"
        else
            CLAUDE_BRIDGE_STATE="FALTA"
            CLAUDE_BRIDGE_DETAIL="CLAUDE.md contiene @AGENTS.md pero conserva secciones contractuales legacy duplicadas; eliminalas manualmente"
        fi
    fi
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
    CONFIG=""
    CONFIG_VALID=0
    N_OK=0
    N_FALTA=0
    N_NV=0
    ACTIONS=""
    DIRECTIVE_ACTIONS=""
    # Flags para el bloque de cierre "Proximos pasos" (CA-1): se fijan junto a cada row()
    # correspondiente, para no re-diagnosticar nada al construir el bloque en la seccion 10.
    # PA_AUTH_PATH (issue #341) no acompana un FALTA -- se fija cuando el camino declarado es (A) crecer.
    PA_CONFIG_FALTA=0
    PA_AGENTS_FALTA=0
    PA_AGENTS_NV=0
    PA_CLAUDE_IMPORT_FALTA=0
    PA_CLAUDE_LEGACY_DUPLICATED=0
    PA_CLAUDE_NV=0
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
    echo "Configuracion (harness.config.json efectivo):"
    COMMON="$SCRIPT_DIR/_pipeline-common.sh"
    if [ -f "$COMMON" ]; then
        source "$COMMON" >/dev/null 2>&1
        LHC_TMP=$(mktemp 2>/dev/null || echo "/tmp/onboard-lhc.$$")
        load_harness_config >/dev/null 2>"$LHC_TMP"
        LHC_RC=$?
        LHC_ERR=$(cat "$LHC_TMP" 2>/dev/null)
        rm -f "$LHC_TMP"
        if [ "$LHC_RC" -eq 0 ]; then
            CONFIG="$HARNESS_CONFIG_PATH"
            CONFIG_VALID=1
            row OK "config efectivo $CONFIG existe y parsea con jq"
            row OK "campos requeridos presentes (projectName, namespacePrefix, solutionFile)"
            if [ -n "${HARNESS_BC_NAME:-}" ]; then
                row OK "boundedContext declarado: name='${HARNESS_BC_NAME}' domains='${HARNESS_BC_DOMAINS}'"
            else
                row FALTA "boundedContext ausente o invalido (campo obligatorio, MEF-ADR-0023)"
                PA_CONFIG_FALTA=1
                ACTIONS="${ACTIONS}  - Falta 'boundedContext' en $CONFIG. Añade:
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
            ACTIONS="${ACTIONS}  - Corrige el config canonico .mefisto/harness.config.json (o el fallback legacy efectivo que muestra el error) segun el detalle de arriba (README, seccion \"Configurar el consumidor\").
"
        fi
    else
        row NV "no se hallo load_harness_config del plugin (config sin validar)"
        if [ -f ".mefisto/harness.config.json" ]; then echo "                  (el config canonico .mefisto/harness.config.json si existe)"; elif [ -f ".claude/harness.config.json" ]; then echo "                  (solo existe el fallback legacy .claude/harness.config.json)"; else echo "                  (no existe config canonico ni fallback legacy)"; fi
        ACTIONS="${ACTIONS}  - No se pudo resolver el plugin para reusar load_harness_config; reinstala mefisto o reabre la sesion (hook SessionStart).
"
    fi

    # --- 2. Directivas canónicas y puente Claude (MEF-ADR-0049/0053) ---
    echo ""
    echo "Directivas del consumidor (AGENTS.md canónico y puente CLAUDE.md):"
    _check_consumer_directives "AGENTS.md" "CLAUDE.md"
    row "$AGENTS_DIRECTIVES_STATE" "$AGENTS_DIRECTIVES_DETAIL"
    if [ "$AGENTS_DIRECTIVES_STATE" = "FALTA" ]; then
        PA_AGENTS_FALTA=1
        DIRECTIVE_ACTIONS="${DIRECTIVE_ACTIONS}  - Completa primero AGENTS.md: debe contener \"Tokens del harness\", \"Verificación de fuentes\" y los 5 tokens obligatorios dentro de la sección de tokens. Es la fuente canónica para todos los runtimes.
"
    elif [ "$AGENTS_DIRECTIVES_STATE" = "NV" ]; then
        PA_AGENTS_NV=1
        DIRECTIVE_ACTIONS="${DIRECTIVE_ACTIONS}  - Restaura permiso de lectura sobre AGENTS.md y vuelve a ejecutar /onboard para verificar la fuente canónica.
"
    fi
    row "$CLAUDE_BRIDGE_STATE" "$CLAUDE_BRIDGE_DETAIL"
    if [ "$CLAUDE_BRIDGE_STATE" = "NV" ]; then
        PA_CLAUDE_NV=1
        DIRECTIVE_ACTIONS="${DIRECTIVE_ACTIONS}  - Restaura permiso de lectura sobre CLAUDE.md y vuelve a ejecutar /onboard para verificar el puente @AGENTS.md.
"
    else
        if [ "$CLAUDE_BRIDGE_HAS_IMPORT" -eq 0 ]; then
            PA_CLAUDE_IMPORT_FALTA=1
            DIRECTIVE_ACTIONS="${DIRECTIVE_ACTIONS}  - Deja CLAUDE.md como puente hacia AGENTS.md con una linea independiente @AGENTS.md.
"
        fi
        if [ "$CLAUDE_BRIDGE_HAS_LEGACY" -eq 1 ]; then
            PA_CLAUDE_LEGACY_DUPLICATED=1
            DIRECTIVE_ACTIONS="${DIRECTIVE_ACTIONS}  - Limpia manualmente de CLAUDE.md las secciones contractuales legacy \"Tokens del harness\" y/o \"Verificación de fuentes\" que aún conserve; el diagnóstico no copia, borra ni reescribe doctrina.
"
        fi
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

    echo ""
    echo "Estado operativo de Mefisto (MEF-ADR-0053):"
    if _mefisto_pipeline_ignored "$REPO_ROOT"; then
        row OK ".mefisto/pipeline/ esta excluido por .gitignore"
    else
        row FALTA ".mefisto/pipeline/ no esta excluido por .gitignore"
        ACTIONS="${ACTIONS}  - Agrega exactamente '.mefisto/pipeline/' a .gitignore. No ignores '.mefisto/' completo: .mefisto/harness.config.json debe versionarse.\n"
    fi

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
            row OK "aplicacion de Entra \"$HARNESS_SP_NAME\" existe"
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
    if [ "$CONFIG_VALID" -eq 1 ] && jq -e 'has("secrets")' "$CONFIG" >/dev/null 2>&1; then
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
    elif [ "$CONFIG_VALID" -eq 1 ]; then
        row NV "secrets[] no declarado todavia (normal antes del primer /infra-base)"
    else
        row NV "secrets[] no verificado porque el config efectivo no pudo cargarse (revisa la seccion Configuracion)"
    fi

    # --- 8. Bifurcacion de dos caminos de auth (tenancy.strategy, MEF-ADR-0028, issue #323 + #341, informativo) ---
    echo ""
    echo "Bifurcacion de dos caminos de auth -- (A) crecer / (B) POC (tenancy.strategy, MEF-ADR-0028):"
    if [ "$CONFIG_VALID" -eq 1 ]; then
        TENANCY_STRATEGY=$(jq -r '.tenancy.strategy // ""' "$CONFIG")
        case "$TENANCY_STRATEGY" in
            "") row NV "tenancy.strategy ausente -- camino (B) POC por defecto (etapa a, mono-tenant-transitorio, valido, no bloqueante)" ;;
            mono-tenant-transitorio) row OK "tenancy.strategy = mono-tenant-transitorio -- camino (B) POC: sin autenticacion (etapa a)" ;;
            multi-tenant-header)
                row OK "tenancy.strategy = multi-tenant-header -- camino (A) crecer: autenticacion orquestada desde el inicio (etapa b)"
                PA_AUTH_PATH=1
                ;;
            *) row NV "tenancy.strategy tiene un valor no reconocido: '$TENANCY_STRATEGY' (esperado mono-tenant-transitorio | multi-tenant-header)" ;;
        esac
    else
        row NV "tenancy.strategy no verificado porque el config efectivo no pudo cargarse (revisa la seccion Configuracion)"
    fi

    # --- 9. Worker de proyecciones (projections.enabled, MEF-ADR-0034, issue #369, informativo) ---
    echo ""
    echo "Worker de proyecciones (projections.enabled, MEF-ADR-0034):"
    PROJECTIONS_ENABLED="${HARNESS_PROJECTIONS_ENABLED:-}"
    NS_PREFIX="${HARNESS_NAMESPACE_PREFIX:-}"
    if [ "$CONFIG_VALID" -ne 1 ]; then
        row NV "projections.enabled no verificado porque el config efectivo no pudo cargarse (revisa la seccion Configuracion)"
    elif [ -z "$NS_PREFIX" ]; then
        row NV "projections.enabled no verificado: falta 'namespacePrefix' para derivar la ruta del worker (revisa la seccion Configuracion)"
    else
        PROJ_RAW=$(jq -r 'if (.projections | type) == "object" and (.projections | has("enabled")) then .projections.enabled else "__AUSENTE__" end' "$CONFIG")
        if [ "$PROJ_RAW" = "false" ]; then
            row OK "projections.enabled=false -- opt-out explicito de proyecciones (valido)"
        elif [ "$PROJ_RAW" = "__AUSENTE__" ] || [ "$PROJ_RAW" = "null" ]; then
            row NV "projections.enabled ausente -- BC no declara proyecciones (opt-in, valido, no bloqueante)"
        elif [ "$PROJECTIONS_ENABLED" != "true" ]; then
            row NV "projections.enabled no es el booleano true ni false (opt-in no verificable, valido, no bloqueante)"
        else
            WORKER_CSPROJ="src/${NS_PREFIX}.Projections/${NS_PREFIX}.Projections.csproj"
            if [ -f "$WORKER_CSPROJ" ]; then
                row OK "projections.enabled=true -- worker ${NS_PREFIX}.Projections presente"
            else
                row NV "projections.enabled=true, pero el worker ${NS_PREFIX}.Projections no existe todavia (corre /scaffold-projections)"
                PA_PROJECTIONS_MISSING=1
            fi
        fi
    fi

    # --- 10. Acciones y resumen ---
    echo ""
    if [ -n "$DIRECTIVE_ACTIONS$ACTIONS" ]; then
        echo "Acciones sugeridas (el diagnostico no ejecuta ninguna; los labels faltantes y el CI los pueden provisionar los pasos opt-in, bajo tu confirmacion):"
        printf '%s' "$DIRECTIVE_ACTIONS"
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
    PA_STEP=0
    if [ "$PA_AGENTS_NV" -eq 1 ]; then
        PA_STEP=$((PA_STEP + 1))
        echo "  $PA_STEP. Restaura permiso de lectura sobre AGENTS.md y repite /onboard para verificar la fuente canónica."
    fi
    if [ "$PA_CLAUDE_NV" -eq 1 ]; then
        PA_STEP=$((PA_STEP + 1))
        echo "  $PA_STEP. Restaura permiso de lectura sobre CLAUDE.md y repite /onboard para verificar el puente @AGENTS.md."
    fi
    if [ "$N_FALTA" -eq 0 ]; then
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
        if [ "$PA_AGENTS_FALTA" -eq 1 ]; then
            PA_STEP=$((PA_STEP + 1))
            echo "  $PA_STEP. Completa AGENTS.md como fuente canónica: las secciones \"Tokens del harness\" y \"Verificación de fuentes\" (detalle arriba)."
        fi
        if [ "$PA_CLAUDE_IMPORT_FALTA" -eq 1 ]; then
            PA_STEP=$((PA_STEP + 1))
            echo "  $PA_STEP. Deja CLAUDE.md como puente hacia AGENTS.md con una linea independiente @AGENTS.md."
        fi
        if [ "$PA_CLAUDE_LEGACY_DUPLICATED" -eq 1 ]; then
            PA_STEP=$((PA_STEP + 1))
            echo "  $PA_STEP. Limpia manualmente de CLAUDE.md las secciones contractuales legacy duplicadas (detalle arriba)."
        fi
        if [ "$PA_CONFIG_FALTA" -eq 1 ]; then
            PA_STEP=$((PA_STEP + 1))
            echo "  $PA_STEP. Corrige el config efectivo indicado arriba (canonico .mefisto/harness.config.json o fallback legacy)."
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
