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
#   HARNESS_SB_INTERNAL_SECRET    - Nombre del secreto de Key Vault de la cadena del ASB
#                                   propio del BC (alias reservado INTERNO). Vacio si el
#                                   config no declara serviceBus (ADR-0024, opcional).
#   HARNESS_SB_EXTERNAL_ALIASES   - Lista separada por espacios de los alias declarados en
#                                   serviceBus.external (ej: "COSMOS FACTURACION"). Vacia
#                                   si serviceBus/external esta ausente.
#   HARNESS_SB_EXTERNAL_ALCANCES  - Lista separada por espacios, MISMO ORDEN posicional
#                                   que HARNESS_SB_EXTERNAL_ALIASES, con el alcance de cada
#                                   entrada (compartido|externo).
#   HARNESS_SB_EXTERNAL_SECRETS   - Lista separada por espacios, MISMO ORDEN posicional que
#                                   HARNESS_SB_EXTERNAL_ALIASES, con el nombre del secreto de
#                                   Key Vault de cada entrada.
#   HARNESS_SECRETS_NAMES      - Lista separada por espacios de 'name' de cada entrada de
#                                 secrets[] (issue #256). Vacia si el config no declara 'secrets'.
#   HARNESS_SECRETS_TYPES      - Lista separada por espacios, MISMO ORDEN posicional que
#                                 HARNESS_SECRETS_NAMES, con 'source.type' de cada entrada
#                                 (output|github-secret|composite).
#   HARNESS_SECRETS_VALUES     - Lista separada por espacios, MISMO ORDEN posicional que
#                                 HARNESS_SECRETS_NAMES, con 'source.value' de cada entrada.
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
# serviceBus (opcional, ADR-0024 decision #1 y #6): registro de los ASB que el
# BC toca, clasificados por alcance (propio/compartido/externo), con el nombre
# del secreto de Key Vault de cada cadena (nunca la cadena en claro). El patron
# oficial del app setting de cada cadena es SERVICE_BUS_CONNECTION_<ALIAS> (con
# INTERNO como alias reservado del ASB propio del BC); la clave de broker de
# Wolverine es el mismo alias. serviceBus.external es opcional (un BC puede no
# consumir/publicar publico todavia); su ausencia no aborta la carga de config.
# El alcance verdaderamente externo se declara pero su wiring queda diferido
# (ADR-0024 decision #5, default-off).
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

    # serviceBus es opcional (ADR-0024): un consumidor que aun no provisiona el
    # backbone compartido/externos, o que aun no tiene Key Vault, no declara
    # este registro. Ausente por completo -> exports vacios, sin error.
    export HARNESS_SB_INTERNAL_SECRET=""
    export HARNESS_SB_EXTERNAL_ALIASES=""
    export HARNESS_SB_EXTERNAL_ALCANCES=""
    export HARNESS_SB_EXTERNAL_SECRETS=""

    local sb_present
    sb_present=$(jq -r 'if has("serviceBus") then "yes" else "no" end' "$config")
    if [ "$sb_present" = "yes" ]; then
        HARNESS_SB_INTERNAL_SECRET=$(jq -r '.serviceBus.internal.secretName // ""' "$config")
        if [ -z "$HARNESS_SB_INTERNAL_SECRET" ]; then
            echo "ERROR: serviceBus.internal.secretName esta vacio o ausente en $config (ADR-0024)." >&2
            echo "  Si declaras 'serviceBus', el secreto de Key Vault de la cadena del ASB" >&2
            echo "  propio del BC (alias reservado INTERNO) es obligatorio. Nunca la cadena" >&2
            echo "  en claro (ADR-0024 decision #6). Anade:" >&2
            echo "    \"serviceBus\": { \"internal\": { \"secretName\": \"<nombre-secreto-kv>\" } }" >&2
            return 1
        fi
        export HARNESS_SB_INTERNAL_SECRET

        local ext_count
        ext_count=$(jq -r '.serviceBus.external // [] | length' "$config")

        local invalid_entries=() aliases=() alcances=() secrets=()
        local i entry_alias entry_alcance entry_secret entry_alias_upper is_dup existing
        for ((i = 0; i < ext_count; i++)); do
            entry_alias=$(jq -r ".serviceBus.external[$i].alias // \"\"" "$config")
            entry_alcance=$(jq -r ".serviceBus.external[$i].alcance // \"\"" "$config")
            entry_secret=$(jq -r ".serviceBus.external[$i].secretName // \"\"" "$config")

            if [ -z "$entry_alias" ]; then
                invalid_entries+=("entrada #$i: 'alias' vacio o ausente")
                continue
            fi

            entry_alias_upper=$(printf '%s' "$entry_alias" | tr '[:lower:]' '[:upper:]')
            if [ "$entry_alias_upper" = "INTERNO" ]; then
                invalid_entries+=("entrada #$i: alias '$entry_alias' es el alias reservado INTERNO (ASB propio del BC)")
                continue
            fi

            if [ "$entry_alcance" != "compartido" ] && [ "$entry_alcance" != "externo" ]; then
                invalid_entries+=("entrada #$i (alias '$entry_alias'): alcance '$entry_alcance' invalido, debe ser 'compartido' o 'externo'")
                continue
            fi

            if [ -z "$entry_secret" ]; then
                invalid_entries+=("entrada #$i (alias '$entry_alias'): 'secretName' vacio o ausente")
                continue
            fi

            is_dup="no"
            if [ ${#aliases[@]} -gt 0 ]; then
                for existing in "${aliases[@]}"; do
                    if [ "$(printf '%s' "$existing" | tr '[:lower:]' '[:upper:]')" = "$entry_alias_upper" ]; then
                        is_dup="yes"
                        break
                    fi
                done
            fi
            if [ "$is_dup" = "yes" ]; then
                invalid_entries+=("entrada #$i: alias '$entry_alias' duplicado")
                continue
            fi

            aliases+=("$entry_alias")
            alcances+=("$entry_alcance")
            secrets+=("$entry_secret")
        done

        if [ ${#invalid_entries[@]} -gt 0 ]; then
            echo "ERROR: serviceBus.external mal formado en $config (ADR-0024):" >&2
            printf '  - %s\n' "${invalid_entries[@]}" >&2
            echo "  Cada entrada requiere: 'alias' no vacio y distinto de INTERNO (reservado)," >&2
            echo "  'alcance' en {compartido, externo}, y 'secretName' no vacio (nombre del" >&2
            echo "  secreto de Key Vault; nunca la cadena en claro)." >&2
            return 1
        fi

        if [ ${#aliases[@]} -gt 0 ]; then
            HARNESS_SB_EXTERNAL_ALIASES="${aliases[*]}"
            HARNESS_SB_EXTERNAL_ALCANCES="${alcances[*]}"
            HARNESS_SB_EXTERNAL_SECRETS="${secrets[*]}"
        fi
        export HARNESS_SB_EXTERNAL_ALIASES HARNESS_SB_EXTERNAL_ALCANCES HARNESS_SB_EXTERNAL_SECRETS
    fi

    # secrets es opcional (issue #256): registro declarativo de todo secreto del BC que
    # el step de siembra data-driven de infra-cd.yml itera en runtime (agents/infra-base-scaffolder.md,
    # Paso 2b), en vez de tener una linea hardcodeada por secreto. Cada entrada declara 'name'
    # (el secreto en Key Vault) y 'source.type'/'source.value' (de donde CI toma el valor a
    # sembrar): 'output' (un unico terraform output, derivable), 'github-secret' (un unico
    # GitHub secret, no derivable) o 'composite' (formula fija reservada para marten-connection --
    # el unico secreto compuesto de varios outputs + un GitHub secret; solo infra-base-scaffolder
    # la escribe, /seed-secret nunca emite 'composite'). Ausente por completo -> exports vacios,
    # sin error (greenfield antes del primer /infra-base).
    export HARNESS_SECRETS_NAMES=""
    export HARNESS_SECRETS_TYPES=""
    export HARNESS_SECRETS_VALUES=""

    local secrets_present
    secrets_present=$(jq -r 'if has("secrets") then "yes" else "no" end' "$config")
    if [ "$secrets_present" = "yes" ]; then
        local secrets_type
        secrets_type=$(jq -r '.secrets | type' "$config")
        if [ "$secrets_type" != "array" ]; then
            echo "ERROR: 'secrets' en $config debe ser un array (issue #256)." >&2
            return 1
        fi

        local sec_count
        sec_count=$(jq -r '.secrets | length' "$config")

        local sec_invalid=() sec_names=() sec_types=() sec_values=()
        local j sec_name sec_type sec_value is_dup_sec existing_name
        for ((j = 0; j < sec_count; j++)); do
            sec_name=$(jq -r ".secrets[$j].name // \"\"" "$config")
            sec_type=$(jq -r ".secrets[$j].source.type // \"\"" "$config")
            sec_value=$(jq -r ".secrets[$j].source.value // \"\"" "$config")

            if [ -z "$sec_name" ]; then
                sec_invalid+=("entrada #$j: 'name' vacio o ausente")
                continue
            fi

            if [ "$sec_type" != "output" ] && [ "$sec_type" != "github-secret" ] && [ "$sec_type" != "composite" ]; then
                sec_invalid+=("entrada #$j (name '$sec_name'): source.type '$sec_type' invalido, debe ser 'output', 'github-secret' o 'composite'")
                continue
            fi

            if [ -z "$sec_value" ]; then
                sec_invalid+=("entrada #$j (name '$sec_name'): 'source.value' vacio o ausente")
                continue
            fi

            is_dup_sec="no"
            if [ ${#sec_names[@]} -gt 0 ]; then
                for existing_name in "${sec_names[@]}"; do
                    if [ "$existing_name" = "$sec_name" ]; then
                        is_dup_sec="yes"
                        break
                    fi
                done
            fi
            if [ "$is_dup_sec" = "yes" ]; then
                sec_invalid+=("entrada #$j: name '$sec_name' duplicado")
                continue
            fi

            sec_names+=("$sec_name")
            sec_types+=("$sec_type")
            sec_values+=("$sec_value")
        done

        if [ ${#sec_invalid[@]} -gt 0 ]; then
            echo "ERROR: 'secrets' mal formado en $config (issue #256):" >&2
            printf '  - %s\n' "${sec_invalid[@]}" >&2
            echo "  Cada entrada requiere: 'name' no vacio y unico, y 'source.type' en" >&2
            echo "  {output, github-secret, composite} con 'source.value' no vacio." >&2
            return 1
        fi

        if [ ${#sec_names[@]} -gt 0 ]; then
            HARNESS_SECRETS_NAMES="${sec_names[*]}"
            HARNESS_SECRETS_TYPES="${sec_types[*]}"
            HARNESS_SECRETS_VALUES="${sec_values[*]}"
        fi
        export HARNESS_SECRETS_NAMES HARNESS_SECRETS_TYPES HARNESS_SECRETS_VALUES
    fi
}

# upsert_harness_secret <name> <source_type> <source_value> [config_path]
#
# Inserta o actualiza, de forma idempotente, una entrada de harness.config.json > secrets[]
# (issue #256): busca por 'name' (match exacto) y sobreescribe su 'source' si ya existe, o
# agrega la entrada al final del array si no. Crea el array 'secrets' si el config todavia
# no lo declara. Escribe con jq a un temporal y hace 'mv' atomico, para no dejar el config
# a medio escribir si el proceso se interrumpe. La usan infra-base-scaffolder (registro de
# los secretos fijos del BC) y scripts/seed-secret.sh (registro de secretos nuevos).
#
# <source_type> debe ser 'output', 'github-secret' o 'composite' -- no se revalida aqui
# (el caller ya restringe los valores que pasa; load_harness_config valida el resultado
# final la proxima vez que se cargue el config).
#
# Retorna 0 si escribio bien, 1 si el config no existe o jq falla.
upsert_harness_secret() {
    local name="$1"
    local source_type="$2"
    local source_value="$3"
    local config="${4:-.claude/harness.config.json}"

    if [ ! -f "$config" ]; then
        echo "ERROR: no se encontro $config" >&2
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: jq no esta instalado. Requerido para actualizar $config" >&2
        return 1
    fi

    local tmp
    tmp=$(mktemp) || return 1

    if ! jq \
        --arg name "$name" \
        --arg type "$source_type" \
        --arg value "$source_value" \
        '
        (.secrets // []) as $existing
        | .secrets = (
            if ($existing | map(.name) | index($name)) != null then
              $existing | map(if .name == $name then {name: $name, source: {type: $type, value: $value}} else . end)
            else
              $existing + [{name: $name, source: {type: $type, value: $value}}]
            end
          )
        ' "$config" > "$tmp"; then
        echo "ERROR: jq fallo al actualizar 'secrets' en $config" >&2
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$config"
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

# _pc_script_dir
#
# Retorna el directorio absoluto donde vive este archivo (scripts/ del plugin),
# derivado de BASH_SOURCE -- indiferente al cwd desde el que se invoque. Fuente
# unica que usa el resolver de pipelines para devolver rutas absolutas (issue
# #289): batch-pipeline.sh y parallel-pipeline.sh hacen 'cd "$REPO_ROOT"' (cwd =
# raiz del consumidor) antes de ejecutar la ruta devuelta tal cual, y el plugin
# ya no vive dentro del repo del consumidor, asi que una ruta relativa como
# "./scripts/tdd-pipeline.sh" no existe alli.
_pc_script_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

# resolve_pipeline <issue_num> [override]
#
# Retorna la ruta ABSOLUTA (al plugin) del script de pipeline a usar para un
# issue dado.
# - Sin override: consulta labels del issue via gh y enruta automaticamente
# - Con override "tdd" o "tooling": retorna el pipeline forzado sin consultar labels
# - Issues tipo:infra retornan "SKIP:infra"
# - Issues sin label tipo:* retornan "SKIP:no-tipo"
resolve_pipeline() {
    local issue="$1"
    local override="${2:-}"
    local sd
    sd="$(_pc_script_dir)"

    if [ -n "$override" ]; then
        case "$override" in
            tdd)     echo "$sd/tdd-pipeline.sh" ;;
            tooling) echo "$sd/tooling-pipeline.sh" ;;
            *)       echo "ERROR: override desconocido '$override'" >&2; return 1 ;;
        esac
        return
    fi

    local labels
    labels=$(gh issue view "$issue" --json labels -q '.labels[].name' 2>/dev/null)

    _resolve_from_labels "$labels"
}

# _resolve_from_labels <labels_text>
# Funcion interna: determina el pipeline (ruta absoluta) a partir de texto de
# labels (una por linea). Los sentinels SKIP:* se retornan sin alterar.
_resolve_from_labels() {
    local labels="$1"
    local sd
    sd="$(_pc_script_dir)"
    if echo "$labels" | grep -qE '^tipo:(feature|refactor)$'; then
        echo "$sd/tdd-pipeline.sh"
    elif echo "$labels" | grep -q '^tipo:tooling$'; then
        echo "$sd/tooling-pipeline.sh"
    elif echo "$labels" | grep -q '^tipo:infra$'; then
        echo "SKIP:infra"
    else
        echo "SKIP:no-tipo"
    fi
}

# resolve_pipeline_with_state <issue_num> [override]
#
# Retorna "STATE|PIPELINE" en una sola linea (ej: "OPEN|/ruta/absoluta/al/plugin/scripts/tdd-pipeline.sh").
# Combina la consulta de estado y labels en una sola llamada a gh, reduciendo API calls.
#
# El override se evalua SIEMPRE (incluso si gh falla), igual que resolve_pipeline
# (issue #291): un override invalido retorna error sin importar gh, y un override
# valido se honra aunque el estado no se haya podido verificar (queda UNKNOWN,
# nunca se finge OPEN -- los llamadores siguen pudiendo saltar issues no
# verificables).
resolve_pipeline_with_state() {
    local issue="$1"
    local override="${2:-}"
    local sd
    sd="$(_pc_script_dir)"

    local state_and_labels state labels
    if state_and_labels=$(gh issue view "$issue" --json state,labels \
        -q '"\(.state)|\(.labels | map(.name) | join("\n"))"' 2>/dev/null); then
        state="${state_and_labels%%|*}"
        labels="${state_and_labels#*|}"
    else
        state="UNKNOWN"
        labels=""
    fi

    if [ -n "$override" ]; then
        case "$override" in
            tdd)     echo "$state|$sd/tdd-pipeline.sh" ;;
            tooling) echo "$state|$sd/tooling-pipeline.sh" ;;
            *)       echo "ERROR: override desconocido '$override'" >&2; return 1 ;;
        esac
        return
    fi

    echo "$state|$(_resolve_from_labels "$labels")"
}
