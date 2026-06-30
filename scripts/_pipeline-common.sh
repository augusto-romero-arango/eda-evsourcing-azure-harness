#!/usr/bin/env bash
# _pipeline-common.sh --- Funciones compartidas entre scripts de pipeline
#
# Uso: source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"
#
# No invocar directamente (prefijo _ = sourceable).

# load_harness_config [config_path]
#
# Carga la configuracion del harness desde .claude/harness.config.json del
# consumidor y exporta las variables HARNESS_* al entorno. Llamar al inicio
# de cualquier script de pipeline que necesite los tokens del proyecto.
#
# Variables exportadas:
#   HARNESS_PROJECT_NAME       - Nombre legible del proyecto (ej: ControlAsistencias)
#   HARNESS_NAMESPACE_PREFIX   - Prefijo de namespace .NET (ej: Bitakora.ControlAsistencia)
#   HARNESS_SOLUTION_FILE      - Nombre del archivo .slnx (ej: ControlAsistencias.slnx)
#   HARNESS_RG_PREFIX          - Prefijo del Resource Group de Azure (ej: rg-controlasistencias)
#   HARNESS_TFSTATE_STORAGE    - Storage account para tfstate (ej: stcatfstatedev)
#   HARNESS_SP_NAME            - Service Principal de GitHub Actions (ej: github-controlasistencias-ci)
#   HARNESS_APP_INSIGHTS_APP   - Application Insights component (ej: controlasistencias-dev-ai)
#   HARNESS_DOMAIN_LABELS      - Lista separada por espacios de labels dom:*
#   HARNESS_BC_NAME            - Nombre del Bounded Context (ej: Principal)
#   HARNESS_BC_DOMAINS         - Lista separada por espacios de dominios del BC (ej: "dominio1 dominio2")
#
# Campos opcionales del config (no se exportan via load_harness_config; se leen
# inline donde se necesitan, mismo patron que agents/planner.md):
#   repoSlug  - Slug owner/repo del fork de Mefisto a usar para drafts cross-repo
#               y mensajes de error. Default: augusto-romero-arango/eda-evsourcing-azure-harness
#
# Nota: el context map (registro de BCs externos) es trabajo diferido a futuras
# evoluciones; hoy el BC solo se nombra a si mismo via boundedContext.name y
# boundedContext.domains.
#
# Si no existe el config file, emite mensaje claro de error y retorna 1.
load_harness_config() {
    local config="${1:-.claude/harness.config.json}"

    if [ ! -f "$config" ]; then
        echo "ERROR: no se encontro $config" >&2
        echo "  El harness requiere un archivo .claude/harness.config.json en la raiz" >&2
        echo "  del proyecto consumidor con la forma:" >&2
        echo "    {" >&2
        echo "      \"projectName\": \"...\"," >&2
        echo "      \"namespacePrefix\": \"...\"," >&2
        echo "      \"solutionFile\": \"...\"," >&2
        echo "      \"infraResourceGroupPrefix\": \"...\"," >&2
        echo "      \"githubServicePrincipalName\": \"...\"," >&2
        echo "      \"appInsightsApp\": \"...\"," >&2
        echo "      \"domainLabels\": [\"...\", \"...\"]," >&2
        echo "      \"boundedContext\": { \"name\": \"<NombreBC>\", \"domains\": [\"...\"] }" >&2
        echo "    }" >&2
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: jq no esta instalado. Requerido para parsear $config" >&2
        return 1
    fi

    export HARNESS_PROJECT_NAME=$(jq -r '.projectName // ""' "$config")
    export HARNESS_NAMESPACE_PREFIX=$(jq -r '.namespacePrefix // ""' "$config")
    export HARNESS_SOLUTION_FILE=$(jq -r '.solutionFile // ""' "$config")
    export HARNESS_RG_PREFIX=$(jq -r '.infraResourceGroupPrefix // ""' "$config")
    export HARNESS_TFSTATE_STORAGE=$(jq -r '.terraformStateStorage // ""' "$config")
    export HARNESS_SP_NAME=$(jq -r '.githubServicePrincipalName // ""' "$config")
    export HARNESS_APP_INSIGHTS_APP=$(jq -r '.appInsightsApp // ""' "$config")
    export HARNESS_DOMAIN_LABELS=$(jq -r '.domainLabels // [] | join(" ")' "$config")
    export HARNESS_BC_NAME=$(jq -r '.boundedContext.name // ""' "$config")
    export HARNESS_BC_DOMAINS=$(jq -r '.boundedContext.domains // [] | join(" ")' "$config")

    local missing=()
    [ -z "$HARNESS_PROJECT_NAME" ]     && missing+=("projectName")
    [ -z "$HARNESS_NAMESPACE_PREFIX" ] && missing+=("namespacePrefix")
    [ -z "$HARNESS_SOLUTION_FILE" ]    && missing+=("solutionFile")

    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: campos obligatorios ausentes en $config: ${missing[*]}" >&2
        return 1
    fi

    # boundedContext es obligatorio (issue #131, ADR-0023).
    # Si esta ausente, emite un mensaje accionable de migracion con el shape
    # exacto a anadir y un ejemplo usando los domainLabels ya presentes.
    local bc_present
    bc_present=$(jq -r 'if has("boundedContext") then "yes" else "no" end' "$config")
    if [ "$bc_present" = "no" ]; then
        local example_domains
        example_domains=$(jq -r '.domainLabels // [] | map("\"" + . + "\"") | join(", ")' "$config")
        echo "ERROR: falta 'boundedContext' en $config (campo obligatorio, ADR-0023)." >&2
        echo "  El campo 'boundedContext' es requerido por ADR-0023 (Bounded Context)." >&2
        echo "  Anade el siguiente bloque a tu harness.config.json:" >&2
        echo "    \"boundedContext\": {" >&2
        echo "      \"name\": \"<NombreDetuBC>\",   // ej: Principal, Admin, Core" >&2
        echo "      \"domains\": [${example_domains}]" >&2
        echo "    }" >&2
        echo "  Los dominios deben ser un subconjunto de tus domainLabels existentes." >&2
        echo "  Ver /onboard para diagnostico o README seccion 'Migracion para consumidores existentes'." >&2
        return 1
    fi

    # Validar boundedContext.name: 1-63 chars, alfanumericos y guiones.
    # Coherente con Azure resource naming conventions (compatible con nombres de RG).
    if [ -z "$HARNESS_BC_NAME" ]; then
        echo "ERROR: boundedContext.name esta vacio en $config." >&2
        echo "  Debe ser un string de 1-63 caracteres alfanumericos y guiones (ej: Principal)." >&2
        return 1
    fi
    if ! printf '%s' "$HARNESS_BC_NAME" | grep -Eq '^[a-zA-Z0-9-]{1,63}$'; then
        echo "ERROR: boundedContext.name='$HARNESS_BC_NAME' no es valido en $config." >&2
        echo "  Debe tener 1-63 caracteres alfanumericos y guiones ([a-zA-Z0-9-])." >&2
        return 1
    fi

    # Validar boundedContext.domains: array no vacio, cada elemento en domainLabels.
    local bc_domains_count
    bc_domains_count=$(jq -r '.boundedContext.domains // [] | length' "$config")
    if [ "$bc_domains_count" -eq 0 ]; then
        echo "ERROR: boundedContext.domains esta vacio en $config." >&2
        echo "  Debe contener al menos un dominio presente en domainLabels." >&2
        return 1
    fi

    # Verificar que cada dominio del BC esta en domainLabels.
    local invalid_domains=()
    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        if ! printf '%s' "$HARNESS_DOMAIN_LABELS" | tr ' ' '\n' | grep -Fqx "$domain"; then
            invalid_domains+=("$domain")
        fi
    done < <(jq -r '.boundedContext.domains[]' "$config" 2>/dev/null)

    if [ ${#invalid_domains[@]} -gt 0 ]; then
        echo "ERROR: boundedContext.domains contiene dominios no declarados en domainLabels:" >&2
        printf "  '%s' no esta en domainLabels\n" "${invalid_domains[@]}" >&2
        echo "  Los dominios del BC deben ser un subconjunto de domainLabels." >&2
        return 1
    fi

    # terraformStateStorage es opcional (consumidores sin IaC lo dejan vacio),
    # pero si tiene valor debe cumplir las reglas de nombramiento de Azure Storage
    # Account: 3-24 caracteres, solo minusculas y digitos, unico globalmente.
    # Fuente: Microsoft Learn -- "Storage account overview" (reglas de naming).
    # Validar aqui evita que un nombre invalido falle tarde, en el apply de /infra.
    if [ -n "$HARNESS_TFSTATE_STORAGE" ] && \
       ! printf '%s' "$HARNESS_TFSTATE_STORAGE" | grep -Eq '^[a-z0-9]{3,24}$'; then
        echo "ERROR: terraformStateStorage='$HARNESS_TFSTATE_STORAGE' no cumple las reglas de Azure Storage Account." >&2
        echo "  Debe tener 3-24 caracteres, solo minusculas y digitos ([a-z0-9])." >&2
        echo "  Sugerencia: abrevia el prefijo del proyecto (ej. micontrolplane -> mcp -> stmcptfstatedev)." >&2
        return 1
    fi
}

# --- Helpers de naming de Azure Storage Account (tfstate backend) -------------
#
# El nombre de una Storage Account es un endpoint DNS publico
# (*.blob.core.windows.net) y por tanto unico en TODO Azure, no solo en la
# suscripcion. Estas funciones puras (sin 'az') resuelven el nombre dentro del
# limite de 24 chars y permiten anexar un sufijo de unicidad global, reutilizando
# el patron de 'random_string' que agents/domain-scaffolder.md (Paso 4) ya aplica
# a las Storage Accounts de dominio. bootstrap-backend.sh las compone con
# 'az storage account check-name' para resolver el nombre final.
# Fuente: Microsoft Learn -- "Storage account overview" (reglas de naming).

# truncate_storage_base <base> [max_total] [suffix_len]
#
# Echo de <base> truncada para que <base>+<sufijo de suffix_len> quepa en
# max_total caracteres (Azure: 24). Mismo calculo que el scaffolder
# (st + dominio + env + 6 chars de suffix <= 24). Pura (no consulta Azure).
truncate_storage_base() {
    local base="$1"
    local max_total="${2:-24}"
    local suffix_len="${3:-6}"
    local max_base=$((max_total - suffix_len))
    if [ "${#base}" -gt "$max_base" ]; then
        printf '%s' "${base:0:$max_base}"
    else
        printf '%s' "$base"
    fi
}

# gen_storage_suffix [n]
#
# Echo de n (default 6) caracteres aleatorios [a-z0-9], validos para un nombre de
# Storage Account. Equivalente en bash al 'random_string { length = 6; special =
# false; upper = false }' del scaffolder. Usa openssl si esta disponible y cae a
# $RANDOM (builtin de bash, presente en 3.2/macOS) si no. Pura.
gen_storage_suffix() {
    local n="${1:-6}"
    local out=""
    local chars="abcdefghijklmnopqrstuvwxyz0123456789"
    local i
    if command -v openssl >/dev/null 2>&1; then
        out=$(openssl rand -hex 32 2>/dev/null) || out=""
        out="${out:0:$n}"
    fi
    if [ "${#out}" -lt "$n" ]; then
        out=""
        for ((i = 0; i < n; i++)); do
            out="${out}${chars:RANDOM % ${#chars}:1}"
        done
    fi
    printf '%s' "$out"
}

# read_backend_storage_account_name <dir>
#
# Busca en <dir>/*.tf un bloque backend "azurerm" y, si existe, echo del
# storage_account_name declarado, SOLO si es un nombre de Storage Account valido
# (^[a-z0-9]{3,24}$). Permite que bootstrap-backend.sh reuse de forma idempotente
# el nombre ya escrito en backend.tf (registro versionado: es lo que usara
# 'terraform init'). Echo vacio si no hay backend o el valor no es literal/valido.
# Pura (no consulta Azure). Siempre retorna 0.
read_backend_storage_account_name() {
    local dir="$1"
    local f name
    [ -d "$dir" ] || return 0
    for f in "$dir"/*.tf; do
        [ -f "$f" ] || continue
        grep -Eq 'backend[[:space:]]*"azurerm"' "$f" || continue
        # '|| name=""' protege a un caller con 'set -e'/'pipefail' si grep no
        # encuentra la linea (pipeline -> exit 1): el nombre queda vacio igual.
        name=$(grep -E '^[[:space:]]*storage_account_name[[:space:]]*=' "$f" \
            | head -n1 \
            | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/') || name=""
        if printf '%s' "$name" | grep -Eq '^[a-z0-9]{3,24}$'; then
            printf '%s' "$name"
            return 0
        fi
    done
    return 0
}

# is_path_in_consumer_blocklist <path>
#
# Retorna 0 si el path cae en una ruta RESERVADA al plugin Mefisto y por tanto
# no debe ser tocada por un pipeline publicado corriendo en el consumidor.
# Retorna 1 si el path esta fuera del blocklist (i.e. es valido para el consumidor).
#
# Blocklist (rutas que solo deben tocarse desde el repo de Mefisto):
#   commands/         Skills publicados (viven en el plugin)
#   agents/           Agentes publicados
#   hooks/            Hooks del plugin
#   .claude-plugin/   Metadata del plugin (plugin.json, marketplace.json)
#   docs/adr/         ADRs del marco (los ADRs del proyecto consumidor deben vivir bajo
#                     docs/adr-proyecto/ u otra ruta, NO bajo docs/adr/)
is_path_in_consumer_blocklist() {
    local path="$1"
    [ -z "$path" ] && return 1

    case "$path" in
        commands/*|agents/*|hooks/*) return 0 ;;
        .claude-plugin/*) return 0 ;;
        docs/adr/*) return 0 ;;
        *) return 1 ;;
    esac
}

# validate_consumer_scope_changes <worktree_path> <base_commit>
#
# Verifica que los archivos modificados/creados en el worktree NO caen en
# rutas reservadas al plugin (ver is_path_in_consumer_blocklist).
# Llamar despues de cada stage que invoca un agente.
#
# Retorna 0 si OK, 1 si hay violaciones (las lista en stderr).
validate_consumer_scope_changes() {
    local wt="$1"
    local base="$2"

    local changed
    changed=$(
        git -C "$wt" diff --name-only "$base..HEAD" 2>/dev/null
        git -C "$wt" status --porcelain 2>/dev/null | sed 's/^...//'
    )

    local violations=()
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        if is_path_in_consumer_blocklist "$path"; then
            violations+=("$path")
        fi
    done <<< "$changed"

    if [ ${#violations[@]} -gt 0 ]; then
        local repo_slug
        repo_slug=$(jq -r '.repoSlug // empty' .claude/harness.config.json 2>/dev/null)
        [ -z "$repo_slug" ] && repo_slug="augusto-romero-arango/eda-evsourcing-azure-harness"

        echo "ERROR: el agente toco rutas reservadas al plugin Mefisto:" >&2
        printf '  - %s\n' "${violations[@]}" >&2
        echo "" >&2
        echo "Las rutas commands/, agents/, hooks/, .claude-plugin/, docs/adr/" >&2
        echo "pertenecen al plugin (repo $repo_slug)." >&2
        echo "Si necesitas modificar el plugin, abre un draft en su repo:" >&2
        echo "  gh issue create -R $repo_slug \\" >&2
        echo "    --label \"estado:borrador,tipo:tooling\" --title \"...\"" >&2
        return 1
    fi
}

# resolve_pipeline <issue_num> [override]
#
# Retorna la ruta del script de pipeline a usar para un issue dado.
# - Sin override: consulta labels del issue via gh y enruta automaticamente
# - Con override "tdd" o "tooling": retorna el pipeline forzado sin consultar labels
# - Issues tipo:infra retornan "SKIP:infra"
# - Issues sin label tipo:* retornan "SKIP:no-tipo"
resolve_pipeline() {
    local issue="$1"
    local override="${2:-}"

    if [ -n "$override" ]; then
        case "$override" in
            tdd)     echo "./scripts/tdd-pipeline.sh" ;;
            tooling) echo "./scripts/tooling-pipeline.sh" ;;
            *)       echo "ERROR: override desconocido '$override'" >&2; return 1 ;;
        esac
        return
    fi

    local labels
    labels=$(gh issue view "$issue" --json labels -q '.labels[].name' 2>/dev/null)

    _resolve_from_labels "$labels"
}

# _resolve_from_labels <labels_text>
# Funcion interna: determina el pipeline a partir de texto de labels (una por linea).
_resolve_from_labels() {
    local labels="$1"
    if echo "$labels" | grep -qE '^tipo:(feature|refactor)$'; then
        echo "./scripts/tdd-pipeline.sh"
    elif echo "$labels" | grep -q '^tipo:tooling$'; then
        echo "./scripts/tooling-pipeline.sh"
    elif echo "$labels" | grep -q '^tipo:infra$'; then
        echo "SKIP:infra"
    else
        echo "SKIP:no-tipo"
    fi
}

# resolve_pipeline_with_state <issue_num> [override]
#
# Retorna "STATE|PIPELINE" en una sola linea (ej: "OPEN|./scripts/tdd-pipeline.sh").
# Combina la consulta de estado y labels en una sola llamada a gh, reduciendo API calls.
resolve_pipeline_with_state() {
    local issue="$1"
    local override="${2:-}"

    local state_and_labels
    state_and_labels=$(gh issue view "$issue" --json state,labels \
        -q '"\(.state)|\(.labels | map(.name) | join("\n"))"' 2>/dev/null) || {
        echo "UNKNOWN|SKIP:no-tipo"
        return
    }

    local state="${state_and_labels%%|*}"
    local labels="${state_and_labels#*|}"

    if [ -n "$override" ]; then
        case "$override" in
            tdd)     echo "$state|./scripts/tdd-pipeline.sh" ;;
            tooling) echo "$state|./scripts/tooling-pipeline.sh" ;;
            *)       echo "ERROR: override desconocido '$override'" >&2; return 1 ;;
        esac
        return
    fi

    local pipeline
    pipeline=$(_resolve_from_labels "$labels")
    echo "$state|$pipeline"
}
