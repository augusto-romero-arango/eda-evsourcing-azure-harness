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
#   HARNESS_APP_INSIGHTS_APP   - Application Insights component (ej: appi-cplane-dev-eus2-001)
#   HARNESS_DOMAIN_LABELS      - Lista separada por espacios de labels dom:*
#   HARNESS_BC_NAME            - Nombre del Bounded Context (ej: Principal)
#   HARNESS_BC_DOMAINS         - Lista separada por espacios de dominios del BC (ej: "dominio1 dominio2")
#   HARNESS_SB_INTERNAL_SECRET    - Nombre del secreto de Key Vault de la cadena del ASB
#                                   propio del BC (alias reservado INTERNO). Vacio si el
#                                   config no declara serviceBus (MEF-ADR-0024, opcional).
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
#   HARNESS_PROJECTIONS_ENABLED - "true" si projections.enabled es exactamente el booleano
#                                 true; "false" en cualquier otro caso (ausente, null, false,
#                                 o un tipo/valor invalido -- issue #369, MEF-ADR-0034). Nunca
#                                 aborta la carga: es un token opt-in, retrocompatible.
#   HARNESS_AZURE_REGION_SHORT - Valor de azureRegionShort (ej. "eus2"), componente {region}
#                                 del estandar de nombramiento de recursos (MEF-ADR-0045,
#                                 issue #729). Vacio si el campo esta ausente -- nunca aborta
#                                 la carga (token opt-in, retrocompatible).
#   HARNESS_RESOURCE_SEQUENCE  - Valor de resourceSequence (ej. "001"), componente {seq} del
#                                 mismo estandar (MEF-ADR-0045). "001" si el campo esta
#                                 ausente o vacio -- nunca aborta la carga.
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
# serviceBus (opcional, MEF-ADR-0024 decision #1 y #6): registro de los ASB que el
# BC toca, clasificados por alcance (propio/compartido/externo), con el nombre
# del secreto de Key Vault de cada cadena (nunca la cadena en claro). El patron
# oficial del app setting de cada cadena es SERVICE_BUS_CONNECTION_<ALIAS> (con
# INTERNO como alias reservado del ASB propio del BC); la clave de broker de
# Wolverine es el mismo alias. serviceBus.external es opcional (un BC puede no
# consumir/publicar publico todavia); su ausencia no aborta la carga de config.
# El alcance verdaderamente externo se declara pero su wiring queda diferido
# (MEF-ADR-0024 decision #5, default-off).
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

    # boundedContext es obligatorio (issue #131, MEF-ADR-0023).
    # Si esta ausente, emite un mensaje accionable de migracion con el shape
    # exacto a anadir y un ejemplo usando los domainLabels ya presentes.
    local bc_present
    bc_present=$(jq -r 'if has("boundedContext") then "yes" else "no" end' "$config")
    if [ "$bc_present" = "no" ]; then
        local example_domains
        example_domains=$(jq -r '.domainLabels // [] | map("\"" + . + "\"") | join(", ")' "$config")
        echo "ERROR: falta 'boundedContext' en $config (campo obligatorio, MEF-ADR-0023)." >&2
        echo "  El campo 'boundedContext' es requerido por MEF-ADR-0023 (Bounded Context)." >&2
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

    # serviceBus es opcional (MEF-ADR-0024): un consumidor que aun no provisiona el
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
            echo "ERROR: serviceBus.internal.secretName esta vacio o ausente en $config (MEF-ADR-0024)." >&2
            echo "  Si declaras 'serviceBus', el secreto de Key Vault de la cadena del ASB" >&2
            echo "  propio del BC (alias reservado INTERNO) es obligatorio. Nunca la cadena" >&2
            echo "  en claro (MEF-ADR-0024 decision #6). Anade:" >&2
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
            echo "ERROR: serviceBus.external mal formado en $config (MEF-ADR-0024):" >&2
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

    # projections es opcional (issue #369, MEF-ADR-0034): token opt-in que declara si el BC
    # adopta el worker de proyecciones. Ausente, null, false, o cualquier valor/tipo distinto
    # del booleano true equivale a deshabilitado -- retrocompatible, nunca aborta la carga
    # (mismo criterio ya usado inline por infra-base-scaffolder/projections-scaffolder).
    # La asignacion lleva `|| true` (mismo motivo que extract_test_count) porque los 9 callers
    # reales corren bajo `set -euo pipefail`: si 'projections' no es un objeto -- el typo
    # `"projections": true` en vez de `{ "enabled": true }` --, jq no puede indexarlo y sale con
    # 5, y sin el `|| true` esa asignacion abortaria TODO el pipeline aqui, con el error de jq ya
    # tragado por el 2>/dev/null: una muerte silenciosa, y justo lo contrario del contrato
    # ("nunca aborta la carga por este campo"). Con `|| true`, proj_raw queda vacio -> "false".
    local proj_raw
    proj_raw=$(jq -r '.projections.enabled // false' "$config" 2>/dev/null) || true
    if [ "$proj_raw" = "true" ]; then
        export HARNESS_PROJECTIONS_ENABLED="true"
    else
        export HARNESS_PROJECTIONS_ENABLED="false"
    fi

    # azureRegionShort/resourceSequence son opcionales (issue #729, MEF-ADR-0045): componentes
    # {region}/{seq} del estandar de nombramiento de recursos. Mismo patron exacto que
    # projections.enabled -- declarar la local aparte y asignar con `|| true` -- para que un
    # config malformado en estos campos no aborte TODO el pipeline bajo `set -euo pipefail`.
    # Un `export VAR=$(...)` de una sola linea NO sirve como proteccion: el builtin enmascara
    # el exit code de la sustitucion (SC2155), asi que el `|| true` de esa forma es codigo
    # muerto. Ausencia o valor invalido degradan a los defaults retrocompatibles ("" y "001"),
    # nunca a un error de carga.
    local region_raw seq_raw
    region_raw=$(jq -r '.azureRegionShort // ""' "$config" 2>/dev/null) || true
    seq_raw=$(jq -r '.resourceSequence // ""' "$config" 2>/dev/null) || true
    export HARNESS_AZURE_REGION_SHORT="${region_raw:-}"
    export HARNESS_RESOURCE_SEQUENCE="${seq_raw:-001}"
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

# --- Asignacion de modelo por stage (--models, issue #708) -------------------
#
# Mecanismo de experimentos A/B de desempeno del harness (calidad/velocidad/costo
# por modelo): permite sobreescribir, por invocacion del pipeline, el modelo que
# corre cada stage sin tocar el default hardcodeado en el `case` de run_agent().
# Requisito invariante del issue: sin el flag --models, el comportamiento es
# byte a byte el actual -- por eso resolve_stage_model() cae siempre al default
# del caller cuando no hay override, y parse_stage_models() con spec vacio deja
# PIPELINE_STAGE_MODELS vacio (ninguna resolucion encuentra match).
#
# Formato interno de PIPELINE_STAGE_MODELS: pares "agente=modelo" separados por
# salto de linea -- no un array asociativo, porque bash 3.2 (macOS, ver notas de
# bash 3.2 en tmux-pipeline.sh) no lo soporta.

# parse_stage_models <spec>
#
# Parsea el valor crudo del flag --models ('agente=modelo[,agente=modelo...]')
# y lo deja en la variable global PIPELINE_STAGE_MODELS para que
# resolve_stage_model() lo consulte. El caller debe invocarla ANTES de crear el
# worktree (CA-1): una entrada malformada debe abortar temprano, no a mitad de
# Stage 1 con un worktree ya creado.
#
# No valida el NOMBRE del modelo (alias como 'sonnet'/'opus' o un id completo
# como 'claude-opus-5[1m]' son ambos pass-through, sin allowlist propia -- los
# alias evolucionan con el CLI; ver Notas tecnicas del issue #708): solo la
# forma 'clave=valor' de cada entrada y que ninguna clave de agente se repita.
# Un modelo invalido lo delata el patron de error existente del stream
# (result.is_error, ya clasificado por run_agent()).
#
# En caso de entrada malformada, retorna 1 y deja el motivo en
# PIPELINE_STAGE_MODELS_ERROR (un mensaje de una linea, listo para pasarle a
# abort()) -- no imprime nada por si misma, para que todo pipeline que la
# invoque controle el formato exacto del error (mismo criterio que el resto de
# los helpers de este archivo, p. ej. upsert_harness_secret).
#
# Con spec vacio (flag no pasado), deja PIPELINE_STAGE_MODELS vacio y retorna 0
# sin error: es el camino "sin --models", el que debe preservar el
# comportamiento byte a byte actual.
parse_stage_models() {
    local spec="$1"
    PIPELINE_STAGE_MODELS=""
    PIPELINE_STAGE_MODELS_ERROR=""
    [ -z "$spec" ] && return 0

    local entries=() entry agent model seen=$'\n'
    IFS=',' read -ra entries <<< "$spec"
    for entry in "${entries[@]}"; do
        [ -z "$entry" ] && continue
        case "$entry" in
            *=*) ;;
            *)
                PIPELINE_STAGE_MODELS_ERROR="entrada '$entry' no tiene la forma agente=modelo"
                return 1
                ;;
        esac
        agent="${entry%%=*}"
        model="${entry#*=}"
        if [ -z "$agent" ] || [ -z "$model" ]; then
            PIPELINE_STAGE_MODELS_ERROR="entrada '$entry': agente y modelo no pueden estar vacios"
            return 1
        fi
        case "$seen" in
            *$'\n'"$agent"$'\n'*)
                PIPELINE_STAGE_MODELS_ERROR="el agente '$agent' esta repetido"
                return 1
                ;;
        esac
        seen="${seen}${agent}"$'\n'
        PIPELINE_STAGE_MODELS="${PIPELINE_STAGE_MODELS}${PIPELINE_STAGE_MODELS:+$'\n'}${agent}=${model}"
    done
    return 0
}

# resolve_stage_model <agente> <default>
#
# Imprime por stdout el modelo a usar para <agente>: el override de
# PIPELINE_STAGE_MODELS (poblado por parse_stage_models) si <agente> tiene una
# entrada de clave EXACTA en el mapa, o <default> si no hay mapa cargado o
# <agente> no aparece en el. Pura -- no valida ni aborta, ese trabajo ya lo hizo
# parse_stage_models(). Siempre retorna 0.
resolve_stage_model() {
    local agent="$1" default="$2"
    local line
    if [ -n "${PIPELINE_STAGE_MODELS:-}" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            if [ "${line%%=*}" = "$agent" ]; then
                echo "${line#*=}"
                return 0
            fi
        done <<< "$PIPELINE_STAGE_MODELS"
    fi
    echo "$default"
    return 0
}

# format_stage_models_for_log
#
# Imprime por stdout una representacion de una linea de PIPELINE_STAGE_MODELS
# ("agente=modelo, agente=modelo") lista para log()/eventos (CA-4:
# auditabilidad del mapa de overrides aplicado). Cadena vacia si no hay mapa
# cargado (sin --models). Siempre retorna 0.
format_stage_models_for_log() {
    [ -z "${PIPELINE_STAGE_MODELS:-}" ] && return 0
    echo "$PIPELINE_STAGE_MODELS" | tr '\n' ',' | sed 's/,/, /g; s/, $//'
    return 0
}

# --- Modo --variant: corridas paralelas del mismo issue (issue #710) --------
#
# Segunda pieza del mecanismo de experimentos por modelo (la primera es
# --models, issue #708): correr el MISMO issue N veces en paralelo, cada
# corrida en su propio worktree/rama, para comparar calidad/velocidad/costo
# entre variantes. Sin este modo, dos corridas simultaneas del mismo issue
# colisionan porque worktree y rama derivan solo del numero de issue.
#
# validate_variant_label() es la unica pieza de este mecanismo que vive aqui:
# el resto (sufijar worktree/rama/logs con el label, suprimir push/PR/
# comentario al issue) es codigo lineal propio de tooling-pipeline.sh, sin
# logica compartida que valga la pena extraer.

# validate_variant_label <label>
#
# Valida el label de --variant (CA-1): slug de minusculas, digitos y guiones
# ([a-z0-9-]), longitud 1-40 -- el mismo tope que ya usa el slug del titulo
# del issue en tooling-pipeline.sh (`cut -c1-40`), para que
# "worktree-issue-<N>-<slug>-<label>" no dispare el nombre de rama/carpeta
# mas alla de lo practico. El caller debe invocarla ANTES de crear el
# worktree: un label malformado debe abortar temprano, igual que
# parse_stage_models con --models.
#
# Retorna 0 si valido. Retorna 1 y deja el motivo en
# PIPELINE_VARIANT_LABEL_ERROR (una linea, lista para abort()) si no --
# mismo contrato que PIPELINE_STAGE_MODELS_ERROR.
validate_variant_label() {
    local label="$1"
    PIPELINE_VARIANT_LABEL_ERROR=""

    if [ -z "$label" ]; then
        PIPELINE_VARIANT_LABEL_ERROR="el label de --variant no puede estar vacio"
        return 1
    fi
    if [ "${#label}" -gt 40 ]; then
        PIPELINE_VARIANT_LABEL_ERROR="el label de --variant '$label' supera 40 caracteres"
        return 1
    fi
    if ! printf '%s' "$label" | grep -Eq '^[a-z0-9-]+$'; then
        PIPELINE_VARIANT_LABEL_ERROR="el label de --variant '$label' es invalido: solo minusculas, digitos y guiones ([a-z0-9-])"
        return 1
    fi
    return 0
}

# --- Helpers de tests, compartidos por los gates de tdd-pipeline.sh, ---------
# --- tooling-pipeline.sh y pr-sync.sh (issue #305) ----------------------------
#
# Consolida run_tests_projects y extract_test_count, que hasta el issue #305
# vivian duplicadas byte-a-byte en tdd-pipeline.sh y tooling-pipeline.sh — y
# ausentes en pr-sync.sh, que corria `dotnet test --solution` y por tanto
# incluia los proyectos *.SmokeTests en su gate post-merge (401/ServiceBus no
# configurado en runs locales sin credenciales de entorno). Una sola
# definicion evita que un fix futuro (como #302) tenga que aplicarse mas de
# una vez.

# extract_test_count <dotnet_test_output>
#
# Extrae el conteo de tests pasando del resumen de dotnet test. Soporta MTP
# ("correcto: N") y VSTest clasico ("Superado: N" / "Passed: N").
#
# Suma los N de TODAS las lineas de resumen del output combinado (una por cada
# proyecto de test que corre run_tests_projects), no solo el primero: con
# --project por proyecto el output trae una linea de resumen por cada uno.
# Sumar la suite completa evita un falso "se perdieron tests" en el gate de
# refactoring cuando un refactor mueve tests entre proyectos sin cambiar el
# total (issue #80).
#
# Contratos preservados:
#   - Sentinela "?": si no hubo ninguna linea parseable, awk imprime "?" en su
#     bloque END (NR==0), no 0 — para que el gate lo trate como "no comparable"
#     y no aborte por una suma vacia interpretada como 0.
#   - Salida entera limpia: imprime un unico entero (la suma) para la comparacion
#     `-lt` de bash del gate.
#   - La asignacion lleva `|| true` porque, bajo `set -euo pipefail`, los grep sin
#     match retornan != 0 y el pipefail abortaria el script antes de leer el "?".
extract_test_count() {
    local count
    count=$(echo "$1" | grep -oiE '(correcto|correctas|passed|superado):[[:space:]]+[0-9]+' \
        | grep -oE '[0-9]+' \
        | awk '{ s += $1 } END { if (NR == 0) print "?"; else print s }') || true
    echo "${count:-?}"
}

# run_tests_projects <worktree_path> [flags-extra-de-dotnet-test...]
#
# Ejecuta dotnet test solo sobre los proyectos *.Tests/ (unit + contratos) de
# <worktree_path>, excluyendo *.SmokeTests/. Los smoke tests son black-box
# contra el entorno dev desplegado (endpoints AuthorizationLevel.Function,
# dependencias reales de ServiceBus/Postgres); incluirlos en un gate local que
# corre sin credenciales de entorno los hace fallar con 401/404 aunque el
# codigo este bien. Los smoke tests siguen cubiertos post-deploy via
# smoke-tests-dominio.yml (MEF-ADR-0013).
#
# Imprime: stdout combinado de todos los proyectos.
# Exit code: 0 si todos pasan, primer codigo de fallo (!= 0 y != 8) si alguno
# falla, 8 si NINGUN proyecto tenia tests para ejecutar.
run_tests_projects() {
    local worktree="$1"
    shift
    local combined_output=""
    local combined_rc=0
    local any_tests_ran=false
    local proj proj_rc proj_output
    for proj in "$worktree"/tests/${HARNESS_NAMESPACE_PREFIX}.*.Tests/; do
        [ -d "$proj" ] || continue
        proj_rc=0
        proj_output=$(dotnet test --project "$proj" "$@" 2>&1) || proj_rc=$?
        combined_output+="$proj_output"$'\n'
        if [ "$proj_rc" -ne 8 ]; then
            any_tests_ran=true
        fi
        if [ "$proj_rc" -ne 0 ] && [ "$proj_rc" -ne 8 ] && [ "$combined_rc" -eq 0 ]; then
            combined_rc=$proj_rc
        fi
    done
    printf "%s" "$combined_output"
    if [ "$combined_rc" -eq 0 ] && [ "$any_tests_ran" = false ]; then
        return 8
    fi
    return $combined_rc
}

# --- Captura de traza stream-json de las invocaciones `claude -p` (issue #645) -

# derive_stage_log_from_stream <stream_file> <stderr_file> <out_file>
#
# Deriva el log legible de un stage (patron portado de
# .claude/scripts/_mefisto-common.sh, issue #431) a partir del stream JSON
# crudo que `claude -p --output-format stream-json --verbose` escribe en
# <stream_file>: una linea por bloque de texto del asistente y una linea
# "[tool] <nombre>" por cada tool_use, en el orden del stream. Anexa
# <stderr_file> tal cual al final. Sobreescribe <out_file> si ya existia.
#
# El evento `result` con `is_error == true` tambien se deriva, prefijado con
# "API Error: <status>" cuando el CLI reporta api_error_status: en una
# corrida fallida ese texto no siempre llega por stderr, y run_agent() de
# tdd-pipeline.sh clasifica fallos con `grep "API Error: 5"`/`"API Error: 4"`
# sobre <out_file> -- sin esta linea esos greps nunca matchean y un 5xx se
# clasificaria como CLI_ERROR generico en vez de API_ERROR_SERVER.
#
# El nombre y la ruta de <out_file> NO cambian (sigue siendo el mismo .log de
# siempre): los greps de clasificacion de tdd-pipeline.sh lo siguen leyendo
# sin saberlo.
#
# Tolera un stream truncado (proceso muerto a mitad de escritura, p. ej. por
# el watchdog de timeout) o vacio via `fromjson?`. Sin jq en el PATH, deja una
# nota explicita y de todos modos anexa <stderr_file>. Nunca aborta: retorna
# siempre 0.
derive_stage_log_from_stream() {
    local stream_file="$1" stderr_file="$2" out_file="$3"

    : > "$out_file" 2>/dev/null || return 0

    if [ -s "$stream_file" ]; then
        if command -v jq >/dev/null 2>&1; then
            jq -R -r '
                fromjson?
                | select(type == "object")
                | if .type == "assistant" then
                      (.message.content // [])[]?
                      | if .type == "text" then (.text // "")
                        elif .type == "tool_use" then "[tool] " + (.name // "?")
                        else empty end
                  elif .type == "result" and .is_error == true then
                      (if (.api_error_status // null) != null
                         then "API Error: " + (.api_error_status | tostring) + " "
                         else "" end)
                      + ((.result // .error // .terminal_reason // .subtype // "error") | tostring)
                  else empty end
            ' "$stream_file" >> "$out_file" 2>/dev/null || true
        else
            echo "(jq no disponible: no se pudo derivar texto legible del stream crudo -- ver $stream_file)" >> "$out_file"
        fi
    fi

    if [ -s "$stderr_file" ]; then
        [ -s "$out_file" ] && echo "" >> "$out_file"
        cat "$stderr_file" >> "$out_file" 2>/dev/null || true
    fi

    return 0
}

# --- Metricas por stage a partir de la traza stream-json (issue #646, porte -
# --- publicado de compute_stage_metrics/build_agents_history_json del interno
# --- #426, sobre la traza que ya captura derive_stage_log_from_stream arriba) -

# compute_stage_metrics <stream_file>
#
# Deriva las metricas de un stage a partir del stream JSON crudo que
# tdd-pipeline.sh ya captura con `claude -p --output-format stream-json
# --verbose` (issue #645): turnos, duraciones (total/API/no-API), costo,
# tokens desglosados, modelo, motivo de fin y un histograma de tool calls por
# nombre (count + tiempo atribuido, suma y mediana, via emparejamiento
# tool_use.id <-> tool_use_id, ambos fechados por el `timestamp` ISO-8601 de
# nivel superior de cada evento). Porte esencialmente literal del interno
# (.claude/scripts/_mefisto-common.sh) -- mismo parseo tolerante y mismas
# notas tecnicas, sin cambios de comportamiento.
#
# Imprime por stdout un JSON compacto de una sola linea, o el literal "null"
# si no hay nada que derivar. Nunca aborta y siempre retorna 0 (CA-4): sin
# jq, con el stream vacio, o si el evento `result` no aparece (stage matado
# a mitad de corrida por el watchdog, sin chance de escribirlo), degrada a
# "null".
compute_stage_metrics() {
    local stream_file="$1"

    if ! command -v jq >/dev/null 2>&1; then
        echo "null"
        return 0
    fi
    if [ ! -s "$stream_file" ]; then
        echo "null"
        return 0
    fi

    local out
    out=$(jq -R -s -c '
        def parse_ts:
            if . == null or (type != "string") then null
            else
                ((capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.(?<frac>[0-9]+))?Z$")) // null) as $c
                | if $c == null then null
                  else
                      (($c.base + "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $sec
                      | $sec * 1000 + (if $c.frac then (($c.frac + "000") | .[0:3] | tonumber) else 0 end)
                  end
            end;

        def median:
            sort as $s
            | ($s | length) as $n
            | if $n == 0 then null
              elif ($n % 2) == 1 then $s[($n - 1) / 2]
              else ($s[$n / 2 - 1] + $s[$n / 2]) / 2
              end;

        (split("\n") | map(select(length > 0)) | map(try fromjson catch empty) | map(select(type == "object"))) as $events
        | ($events | map(select(.type == "result")) | last) as $result
        | if $result == null then null
          else
              ($events | map(select(.type == "system" and .subtype == "init")) | first | .model) as $model_from_init
            | ($events | map(select(.type == "assistant")) | first | .message.model) as $model_from_assistant
            | (
                [ $events[] | select(.type == "assistant") | . as $ev
                  | ($ev.message.content // [])[]?
                  | select(.type == "tool_use")
                  | {id: .id, name: .name, ts: (try ($ev.timestamp | parse_ts) catch null)}
                ]
              ) as $tool_uses
            | (
                [ $events[] | select(.type == "user") | . as $ev
                  | ($ev.message.content // [])[]?
                  | select(.type == "tool_result")
                  | {id: .tool_use_id, ts: (try ($ev.timestamp | parse_ts) catch null)}
                ]
              ) as $tool_results
            | ($tool_results | INDEX(.id)) as $results_by_id
            | (
                $tool_uses
                | group_by(.name)
                | map(
                    . as $group
                    | ($group | map(
                        . as $u
                        # `// ""` y no `[$u.id]` a secas: en jq indexar un
                        # objeto con null es un error DURO (no algo que `try`
                        # local atrape aqui), y ese error tumba la expresion
                        # entera -- un unico tool_use sin `id` dejaria el
                        # stage sin NINGUNA metrica, aunque el evento
                        # `result` viniera completo. Con la clave vacia el
                        # lookup solo devuelve null: la tool call sigue
                        # contando en `count` y las demas no se pierden.
                        | ($results_by_id[$u.id // ""]) as $r
                        | select($r != null and $u.ts != null and $r.ts != null)
                        | ($r.ts - $u.ts)
                      )) as $durations
                    | {
                        name: $group[0].name,
                        count: ($group | length),
                        duration_ms_sum: (if ($durations | length) > 0 then ($durations | add) else null end),
                        duration_ms_median: (if ($durations | length) > 0 then ($durations | median) else null end)
                      }
                  )
                | sort_by(.name)
              ) as $tool_calls
            | {
                turns: $result.num_turns,
                duration_ms: $result.duration_ms,
                duration_api_ms: $result.duration_api_ms,
                non_api_ms: (if ($result.duration_ms != null and $result.duration_api_ms != null) then ($result.duration_ms - $result.duration_api_ms) else null end),
                cost_usd: $result.total_cost_usd,
                tokens: {
                    input: $result.usage.input_tokens,
                    output: $result.usage.output_tokens,
                    cache_read: $result.usage.cache_read_input_tokens,
                    cache_creation: $result.usage.cache_creation_input_tokens
                },
                model: ($model_from_init // $model_from_assistant),
                is_error: $result.is_error,
                stop_reason: $result.stop_reason,
                terminal_reason: $result.terminal_reason,
                ttft_ms: $result.ttft_ms,
                permission_denials: (if ($result.permission_denials | type) == "array" then ($result.permission_denials | length) else null end),
                rate_limit_events: ($events | map(select(.type == "rate_limit_event")) | length),
                tool_calls: $tool_calls
              }
          end
    ' "$stream_file" 2>/dev/null) || out=""

    if [ -n "$out" ]; then
        echo "$out"
    else
        echo "null"
    fi
    return 0
}

# build_agents_history_json <key1> <agent1> <dur1> <metrics1> [<key2> <agent2> <dur2> <metrics2> ...]
#
# Construye el objeto JSON "agents" de una entrada de pipeline-history.jsonl,
# generalizado a N stages (issue #646) -- a diferencia del interno (#426,
# especifico a writer/reviewer), tdd-pipeline.sh tiene hasta 7 claves
# variables (test-writer/implementer/smoke-test-writer/reviewer/scaffolder/
# patch-test-writer/patch-implementer; coverage-gate se compone aparte, ver
# nota en tdd-pipeline.sh). Cada grupo de 4 argumentos agrega una clave
# <key1> con {duration: <dur1>, metrics: <metrics1>}: <dur1> vacio o "null"
# serializa `duration: null` (stage no corrido, CA-1: la clave sigue
# presente); <metrics1> vacio o "null" serializa `metrics: null` igual.
#
# <agent1> es el nombre REAL del agente despachado bajo esa clave (distingue
# projection-test-writer de test-writer bajo la misma clave "test-writer") y
# se inyecta como agents.<key1>.metrics.agent -- CA-1 describe el campo como
# parte del esquema de metrics, no como hermano de duration/metrics. Por eso
# solo se agrega cuando <metrics1> parseo a un objeto real: si la traza no
# trajo `result` (stage matado por el watchdog antes de escribirlo, o
# instrumentacion fallida) metrics ya es null y no hay donde anidar el campo
# -- se pierde la atribucion de agente en ese caso puntual, degradacion
# aceptable frente a inventar un objeto {agent: ...} sin el resto de las
# cifras del interno. <agent1> vacio omite el campo aunque metrics si sea un
# objeto.
#
# Con jq: una sola invocacion via --args, sin necesidad de --argjson por
# grupo (el numero de grupos varia por caller). Sin jq -- o si esa
# invocacion fallara por cualquier motivo -- degrada a un objeto plano con
# SOLO "duration" por clave (sin "metrics" ni "agent"), construido con
# bash/printf. Nunca aborta y siempre imprime un objeto JSON valido.
#
# Los argumentos van pegados a `--args` SIN el separador `--`: verificado en
# jq 1.7.1, tras `--args` todo lo que sigue entra a $ARGS.positional aunque
# empiece con guion, asi que el separador no aporta nada aqui. En cambio su
# manejo cambio entre versiones de jq (en 1.7 se consume como fin de
# opciones); un jq que lo tratara como un posicional literal "--" correria un
# lugar TODOS los grupos y produciria un objeto "agents" corrupto -- que es
# peor que no tener metricas, porque igual se escribe al historial. Sin el
# separador el resultado es el mismo en toda version que soporte `--args`.
build_agents_history_json() {
    if command -v jq >/dev/null 2>&1; then
        local built
        built=$(jq -n -c '
            def to_num: if . == "" or . == "null" then null else (try tonumber catch null) end;
            def to_json: if . == "" or . == "null" then null else (try fromjson catch null) end;
            ($ARGS.positional) as $a
            | reduce range(0; ($a | length); 4) as $i
                ({};
                 . + {
                   ($a[$i]): {
                     duration: ($a[$i + 2] | to_num),
                     metrics: (
                       ($a[$i + 3] | to_json) as $m
                       | if $m == null then null
                         elif ($a[$i + 1] // "") == "" then $m
                         else ($m + {agent: $a[$i + 1]})
                         end
                     )
                   }
                 }
                )
        ' --args "$@" 2>/dev/null) || built=""
        if [ -n "$built" ]; then
            echo "$built"
            return 0
        fi
    fi

    local out="{" first=true key dur
    while [ "$#" -ge 4 ]; do
        key="$1"
        dur="$3"
        [ -z "$dur" ] && dur="null"
        [ "$first" = true ] || out="${out},"
        out="${out}\"${key}\":{\"duration\":${dur}}"
        first=false
        shift 4
    done
    out="${out}}"
    echo "$out"
    return 0
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
#
# Si <suffix_len> supera <max_total> (posible desde el issue #732: el "sufijo"
# pasa a ser el largo de los componentes fijos del patron CAF, que crecen con
# env/region/seq) el espacio disponible se satura en 0 y el echo es vacio, en vez
# de caer en el substring negativo de bash (${base:0:-N} recorta por la derecha y
# devolveria una base MAS larga que el limite, silenciosamente invalida). Queda a
# cargo del caller validar el nombre final contra ^[a-z0-9]{3,24}$.
truncate_storage_base() {
    local base="$1"
    local max_total="${2:-24}"
    local suffix_len="${3:-6}"
    local max_base=$((max_total - suffix_len))
    if [ "$max_base" -lt 0 ]; then
        max_base=0
    fi
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

# read_backend_resource_group_name <dir>
#
# Gemelo de read_backend_storage_account_name: busca en <dir>/*.tf un bloque
# backend "azurerm" y, si existe, echo del resource_group_name declarado (sin
# validar charset -- el de un Resource Group es mucho mas laxo que el de Storage).
# Permite que bootstrap-backend.sh reuse el RG ya escrito en backend.tf (registro
# versionado) en vez de recomputarlo con la formula CAF vigente (MEF-ADR-0045,
# issue #732): sin este helper, un consumidor con backend viejo que despues
# declara azureRegionShort veria el script calcular un RG nuevo que no coincide
# con el ya escrito en backend.tf, rompiendo la idempotencia (CA-3). Echo vacio
# si no hay backend o el valor no es literal. Pura (no consulta Azure). Siempre
# retorna 0.
read_backend_resource_group_name() {
    local dir="$1"
    local f name
    [ -d "$dir" ] || return 0
    for f in "$dir"/*.tf; do
        [ -f "$f" ] || continue
        grep -Eq 'backend[[:space:]]*"azurerm"' "$f" || continue
        name=$(grep -E '^[[:space:]]*resource_group_name[[:space:]]*=' "$f" \
            | head -n1 \
            | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/') || name=""
        if printf '%s' "$name" | grep -Eq '^[a-zA-Z0-9._()-]{1,90}$'; then
            printf '%s' "$name"
            return 0
        fi
    done
    return 0
}

# compose_tfstate_resource_group_name <rg_prefix> <env> <region_short> <seq>
#
# Compone el nombre del Resource Group del backend de Terraform. Si
# <region_short> esta vacio, devuelve el nombre legacy "<rg_prefix>-tfstate"
# (retrocompatible -- MEF-ADR-0045 seccion 5, CA-4). Si esta declarado, devuelve
# la forma canonica CAF "rg-tfstate-{app}-{env}-{region}-{seq}" (MEF-ADR-0045
# seccion 1: abrev-tipo "rg", uso fijo "tfstate", {app} = <rg_prefix> sin el
# prefijo "rg-" que infraResourceGroupPrefix ya lleva). Pura (no consulta Azure).
compose_tfstate_resource_group_name() {
    local rg_prefix="$1" env="$2" region_short="$3" seq="$4"
    if [ -z "$region_short" ]; then
        printf '%s' "${rg_prefix}-tfstate"
    else
        printf '%s' "rg-tfstate-${rg_prefix#rg-}-${env}-${region_short}-${seq}"
    fi
}

# tfstate_storage_app_slug <rg_prefix>
#
# Echo del componente {app} del nombre sin guiones de la Storage Account del
# tfstate: <rg_prefix> sin el prefijo "rg-" que infraResourceGroupPrefix ya lleva
# y sin guiones/guiones-bajos (charset de Storage: solo minusculas y digitos,
# MEF-ADR-0045 seccion 4). Fuente unica del slug para compose_tfstate_storage_
# account_base y para el aviso de truncado de bootstrap-backend.sh -- ninguno de
# los dos lo re-deriva por su cuenta. Pura (no consulta Azure).
tfstate_storage_app_slug() {
    printf '%s' "${1#rg-}" | tr -d -- '-_'
}

# compose_tfstate_storage_account_base <rg_prefix> <env> <region_short> <seq> <legacy_base> [max_total]
#
# Compone el nombre BASE de la Storage Account del backend de Terraform. Si
# <region_short> esta vacio, devuelve <legacy_base> tal cual (retrocompatible:
# bootstrap-backend.sh sigue anexandole el sufijo aleatorio de unicidad global,
# MEF-ADR-0045 CA-4). Si esta declarado, compone la forma canonica CAF sin
# guiones "sttfstate{app}{env}{region}{seq}" (seccion 1: abrev-tipo "st", uso fijo
# "tfstate") -- este nombre YA es el candidato final, sin sufijo aleatorio
# (seccion 2: unicidad estructural via app+env+region+seq). {app} sale de
# <rg_prefix> sin el prefijo "rg-" y sin guiones/guiones-bajos (charset de Storage:
# solo minusculas y digitos), truncado con truncate_storage_base si hace falta
# para respetar <max_total> (default 24) -- regla de truncado de la seccion 4:
# se trunca {app}, nunca el resto de componentes. Pura (no consulta Azure).
compose_tfstate_storage_account_base() {
    local rg_prefix="$1" env="$2" region_short="$3" seq="$4" legacy_base="$5"
    local max_total="${6:-24}"
    if [ -z "$region_short" ]; then
        printf '%s' "$legacy_base"
        return 0
    fi
    local app fixed_prefix fixed_suffix fixed_len app_truncated
    app=$(tfstate_storage_app_slug "$rg_prefix")
    fixed_prefix="sttfstate"
    fixed_suffix="${env}${region_short}${seq}"
    fixed_len=$((${#fixed_prefix} + ${#fixed_suffix}))
    app_truncated=$(truncate_storage_base "$app" "$max_total" "$fixed_len")
    printf '%s' "${fixed_prefix}${app_truncated}${fixed_suffix}"
}

# is_path_in_consumer_blocklist <path>
#
# Retorna 0 si el path cae en una ruta RESERVADA al plugin Mefisto y por tanto
# no debe ser tocada por un pipeline publicado corriendo en el consumidor.
# Retorna 1 si el path esta fuera del blocklist (i.e. es valido para el consumidor).
#
# Blocklist (rutas que solo deben tocarse desde el repo de Mefisto):
#   commands/         Skills publicados como slash command (viven en el plugin)
#   skills/           Agent Skills publicados del plugin (MEF-ADR-0033)
#   agents/           Agentes publicados
#   hooks/            Hooks del plugin
#   .claude-plugin/   Metadata del plugin (plugin.json, marketplace.json)
#   docs/adr/mef-adr-*  ADRs del marco -- MEF-ADR-0030 decision #3 fija su filename
#                     en minuscula (mef-adr-NNNN-slug.md). El resto de docs/adr/ es
#                     del consumidor: MEF-ADR-0030 descarta reubicarlo bajo
#                     docs/adr-proyecto/ u otra ruta (su Alt 2, descartada) y declara
#                     valido que un consumidor conserve docs/adr/ sin migrar (decision #4).
#
# NO incluye .claude/settings.json (issue #522): en el repo del consumidor esa
# ruta es de sus propios hooks/config, no una ruta reservada del plugin. Ese
# registro solo existe en is_path_in_mefisto_scope de .claude/scripts/_mefisto-common.sh.
#
# Mismo criterio, y por el mismo motivo, aplica a .mcp.json (issue #763): en el
# repo del consumidor esa ruta es su propia configuracion MCP de proyecto, no
# una ruta reservada del plugin. Tampoco se agrega aqui; solo esta registrada
# en is_path_in_mefisto_scope.
is_path_in_consumer_blocklist() {
    local path="$1"
    [ -z "$path" ] && return 1

    case "$path" in
        commands/*|skills/*|agents/*|hooks/*) return 0 ;;
        .claude-plugin/*) return 0 ;;
        docs/adr/mef-adr-*) return 0 ;;
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

        local branch
        branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
        [ -z "$branch" ] && branch="la rama del worktree $wt"

        echo "ERROR: el agente toco rutas reservadas al plugin Mefisto:" >&2
        printf '  - %s\n' "${violations[@]}" >&2
        echo "" >&2
        echo "Las rutas commands/, skills/, agents/, hooks/, .claude-plugin/ y los archivos" >&2
        echo "docs/adr/mef-adr-* pertenecen al plugin (repo $repo_slug)." >&2
        echo "" >&2
        echo "El resto del trabajo del agente NO se perdio: ya quedo commiteado en '$branch'." >&2
        echo "Para recuperarlo, revierte ahi los archivos listados arriba y abre el PR a mano." >&2
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

# get_harness_version
#
# Imprime por stdout el '.version' de .claude-plugin/plugin.json del propio
# plugin Mefisto (issue #660), para estampar con que version corrio cada
# pipeline en pipeline-history.jsonl -- a diferencia de
# .claude/pipeline/.plugin-root (que el hook SessionStart sobreescribe en
# cada arranque de sesion), este valor se calcula una vez y viaja pegado a la
# entrada, permitiendo reconstruir la version de corridas historicas.
#
# Ubica plugin.json relativo a este mismo archivo via _pc_script_dir (el
# directorio scripts/ del plugin, sea cual sea la version del cache donde
# este instalado), no al cwd del pipeline (la raiz del consumidor).
#
# Con jq disponible, lee '.version' via jq -r. Sin jq en PATH, degrada a una
# extraccion con sed sobre la linea '"version": "X.Y.Z"' (mismo espiritu que
# compute_stage_metrics). Si plugin.json no existe, o ninguna extraccion
# produce un valor, imprime cadena vacia -- nunca aborta y siempre retorna 0.
get_harness_version() {
    # Los tres pipelines corren con `set -euo pipefail` y toman el valor por
    # sustitucion de comando en su prologo, asi que un estado != 0 que se
    # escape de aqui mataria la corrida entera antes del primer stage: ningun
    # paso de abajo puede propagarlo.
    local script_dir plugin_json
    script_dir="$(_pc_script_dir 2>/dev/null)" || script_dir=""
    plugin_json="$script_dir/../.claude-plugin/plugin.json"

    if [ ! -f "$plugin_json" ]; then
        echo ""
        return 0
    fi

    local version=""
    if command -v jq >/dev/null 2>&1; then
        version=$(jq -r '.version // ""' "$plugin_json" 2>/dev/null) || true
        [ "$version" = "null" ] && version=""
    else
        # '|| true' y no '|| version=""': con pipefail heredado del caller,
        # head -n1 cierra el pipe apenas lee la linea y sed puede morir de
        # SIGPIPE DESPUES de haber emitido la version -- reasignar ahi
        # borraria un valor ya capturado.
        version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$plugin_json" 2>/dev/null | head -n1) || true
    fi

    echo "$version"
    return 0
}

# resolve_pipeline <issue_num> [override]
#
# Retorna la ruta ABSOLUTA (al plugin) del script de pipeline a usar para un
# issue dado.
# - Sin override: consulta labels del issue via gh y enruta automaticamente
# - Con override "tdd" o "tooling": retorna el pipeline forzado sin consultar labels
# - Issues tipo:feature, tipo:refactor o tipo:projection retornan tdd-pipeline.sh
#   (tipo:projection despacha a la rama read-side dentro de tdd-pipeline.sh --
#   issue #371, MEF-ADR-0034/0035)
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
#
# tipo:projection enruta a tdd-pipeline.sh (issue #372): ese script ya trae la
# rama read-side (issue #371) que detecta el label internamente y despacha
# projection-test-writer/projection-implementer en vez de test-writer/implementer.
_resolve_from_labels() {
    local labels="$1"
    local sd
    sd="$(_pc_script_dir)"
    if echo "$labels" | grep -qE '^tipo:(feature|refactor|projection)$'; then
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
# Es una vista de dos campos sobre resolve_issue_facts (abajo), que hace esa unica
# llamada; los llamadores que ademas necesitan saber si el issue es tipo:projection
# usan esa funcion directamente en vez de sumar una segunda consulta.
#
# El override se evalua SIEMPRE (incluso si gh falla), igual que resolve_pipeline
# (issue #291): un override invalido retorna error sin importar gh, y un override
# valido se honra aunque el estado no se haya podido verificar (queda UNKNOWN,
# nunca se finge OPEN -- los llamadores siguen pudiendo saltar issues no
# verificables).
resolve_pipeline_with_state() {
    local facts state
    facts=$(resolve_issue_facts "$@") || return 1
    state="${facts%%|*}"
    # facts = "STATE|IS_PROJECTION|PIPELINE": descarta el campo del medio.
    facts="${facts#*|}"
    echo "$state|${facts#*|}"
}

# resolve_issue_facts <issue_num> [override]
#
# Retorna "STATE|IS_PROJECTION|PIPELINE" en una sola linea (ej:
# "OPEN|false|/ruta/absoluta/al/plugin/scripts/tdd-pipeline.sh"), con
# IS_PROJECTION en "true"/"false". Misma semantica de estado y override que
# resolve_pipeline_with_state (que delega en esta funcion), sumando la deteccion de
# tipo:projection que parallel-pipeline.sh necesita para serializar (issue #372)
# SIN una segunda llamada a gh: el JSON que esta funcion ya descarga trae los
# labels, igual que la deteccion del label dentro de tdd-pipeline.sh reusa el
# JSON que el pipeline ya tenia (issue #371).
#
# Con override, IS_PROJECTION se reporta igual (sale de los labels, no del
# pipeline resuelto): forzar --pipeline no cambia que archivos del worker de
# proyecciones toca el issue, asi que la serializacion se mantiene.
resolve_issue_facts() {
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

    local is_projection="false"
    _is_tipo_projection_from_labels "$labels" && is_projection="true"

    if [ -n "$override" ]; then
        case "$override" in
            tdd)     echo "$state|$is_projection|$sd/tdd-pipeline.sh" ;;
            tooling) echo "$state|$is_projection|$sd/tooling-pipeline.sh" ;;
            *)       echo "ERROR: override desconocido '$override'" >&2; return 1 ;;
        esac
        return
    fi

    echo "$state|$is_projection|$(_resolve_from_labels "$labels")"
}

# --- Serializacion de issues tipo:projection dentro de un lote paralelo ------
#
# Todas las proyecciones de un mismo Bounded Context comparten los archivos del
# worker de proyecciones (Projections/Program.cs, ConfiguracionMartenProjections
# -- MEF-ADR-0034): dos issues tipo:projection corriendo a la vez en
# parallel-pipeline.sh producirian dos PRs read-side editando el mismo archivo,
# con el conflicto de merge resuelto por el segundo en llegar. El contrato de un
# solo Bounded Context por repo (MEF-ADR-0023) mas la homogeneidad de repo que
# parallel-pipeline.sh ya exige hacen innecesaria cualquier deteccion de BC: dentro
# de una misma invocacion, CUALQUIER par de issues tipo:projection es incompatible
# entre si (issue #372).

# _is_tipo_projection_from_labels <labels_text>
#
# Funcion interna pura: determina si el texto de labels (una por linea, mismo
# formato que _resolve_from_labels) incluye el label EXACTO tipo:projection (no
# un prefijo como tipo:projection-experimental). La consume resolve_issue_facts,
# que ya tiene los labels a mano; si gh no pudo resolverlos, el texto llega vacio
# y el issue simplemente no se trata como projection (mismo fallo silencioso que
# _resolve_from_labels, que cae a SKIP:no-tipo).
_is_tipo_projection_from_labels() {
    echo "$1" | grep -qx 'tipo:projection'
}

# can_launch_now <max_parallel> <running_count> <is_projection> <projection_running>
#
# Decide si un issue pendiente puede lanzarse ya, dado el estado actual del
# lote. Pura (sin gh, sin procesos, sin arrays) para poder testear las
# combinaciones sin lanzar background jobs reales -- el llamador (scheduler de
# parallel-pipeline.sh) es quien calcula running_count/projection_running
# inspeccionando sus propios PIDs.
#
#   <max_parallel>       entero; 0 = sin limite
#   <running_count>      entero; cuantos pipelines siguen vivos ahora mismo
#   <is_projection>      "true"/"false"; el pendiente evaluado es tipo:projection
#   <projection_running> "true"/"false"; ya hay un tipo:projection vivo ahora mismo
#
# Retorna 0 si puede lanzarse, 1 si debe esperar.
can_launch_now() {
    local max_parallel="$1" running="$2" is_projection="$3" projection_running="$4"
    if [ "$max_parallel" -gt 0 ] && [ "$running" -ge "$max_parallel" ]; then
        return 1
    fi
    if [ "$is_projection" = "true" ] && [ "$projection_running" = "true" ]; then
        return 1
    fi
    return 0
}

# find_open_pr_for_branch <branch_name> [repo_slug] [base_branch]
#
# Busca un PR ABIERTO existente para <branch_name> via `gh pr list --head`, para
# que el pipeline lo REUTILICE en vez de abortar cuando `gh pr create` fallaria
# con "a pull request for branch ... already exists" (issue #378 -- incidente
# del batch mefisto-batch-125628: un agente del Stage 1 crea el PR el mismo,
# violando la prohibicion de push/PR de su prompt, y el bloque "Creando PR" del
# pipeline abortaba en vez de recuperar la URL ya existente).
#
# [repo_slug] es opcional (formato owner/repo); se pasa a `gh pr list --repo`
# cuando el caller no invoca gh desde dentro del repo (p. ej. el pipeline se
# queda en REPO_ROOT y no hace cd al worktree).
#
# [base_branch] (default 'main') filtra por rama base. Es deliberado y no
# cosmetico: la unicidad que GitHub impone -- y que produce el error que este
# gate esquiva -- es por par (head, base), como lo dice el propio mensaje
# (`a pull request for branch "X" into branch "main" already exists`). Sin el
# filtro, un PR abierto de la misma rama hacia OTRA base se devolveria como si
# fuera el PR del pipeline, y el `gh pr create --base main` que si habria
# funcionado nunca correria: el pipeline reportaria una URL equivocada.
#
# Imprime la URL a stdout si existe un PR abierto, cadena vacia si no hay PR o
# si el chequeo no se pudo hacer (gh ausente o gh fallo). NUNCA aborta: es un
# chequeo defensivo antes de `gh pr create`, no una fuente de verdad -- si gh
# esta roto de verdad (auth, red), ese fallo lo reporta el `gh pr create`
# normal que sigue a continuacion.
#
# Retorna siempre 0.
find_open_pr_for_branch() {
    local branch="$1"
    local repo="${2:-}"
    local base="${3:-main}"
    [ -z "$branch" ] && { echo ""; return 0; }

    command -v gh >/dev/null 2>&1 || { echo ""; return 0; }

    local gh_args=(pr list --head "$branch" --base "$base" --state open --json url -q '.[0].url')
    [ -n "$repo" ] && gh_args+=(--repo "$repo")

    local url
    url=$(gh "${gh_args[@]}" 2>/dev/null) || url=""
    # gh 2.92 imprime cadena vacia cuando la lista viene vacia, pero `.[0].url`
    # sobre `[]` es `null` en jq: normalizamos para no depender de como cada
    # version de gh serializa ese null (un "null" con fuga aqui haria que el
    # pipeline reutilizara un PR inexistente con URL literal "null").
    [ "$url" = "null" ] && url=""
    echo "$url"
    return 0
}

# --- Clasificacion de archivos para el coverage gate (Stage 4) --------------

# coverage_classify_file <filepath> <worktree_path> [is_projection=false]
#
# Clasifica un archivo .cs del PR para el coverage gate del Stage 4 de
# scripts/tdd-pipeline.sh (MEF-ADR-0014). Extraida del cuerpo del Stage 4 para
# poder testearla con fixtures reales en vez de con una reimplementacion que
# puede divergir del script (issue #416) -- mismo motivo que can_launch_now.
#
# NO es pura: en tres ramas (eventos/Entities/DomainEvents y ValueObjects con
# factory Crear(), y la exclusion de records DTO) lee <worktree_path>/<filepath>
# del disco. Por eso recibe worktree_path/is_projection como parametros explicitos
# en vez de leer $WORKTREE_PATH/$IS_PROJECTION del entorno del caller: el
# motivo es eliminar acoplamiento oculto en un archivo que sourcean todos los
# pipelines publicados, no solo habilitar la testabilidad (un test que sourcea
# tambien podria setear esos globales antes de llamar).
#
#   <filepath>       ruta relativa del archivo dentro del worktree (ej:
#                     src/Foo.Bar/Feature/FunctionEndpoint.cs)
#   <worktree_path>   ruta absoluta del worktree del consumidor
#   [is_projection]   "true"/"false" (default "false"). Gatea el carve-out
#                     read-side de FunctionEndpoint.cs (issue #371)
#
# Imprime a stdout una de: "logic" (exige 95% de cobertura de lineas),
# "excluded" (no se mide) o "not_evaluated" (no matchea ningun patron vigente).
# El gate nunca bloquea por "not_evaluated", pero tampoco lo presenta como una
# exclusion deliberada: la tabla del PR lo reporta como "sin clasificar" con
# marcador de atencion propio, para revision humana (issue #586,
# MEF-ADR-0014). Retorna siempre 0.
coverage_classify_file() {
    local filepath="$1"
    local worktree_path="$2"
    local is_projection="${3:-false}"
    local basename
    basename=$(basename "$filepath")
    local dirname
    dirname=$(dirname "$filepath")

    # Excluidos por nombre. IdentidadEventos*.cs es el hermano exacto de
    # ConfiguracionSerializacion*.cs -- lista declarativa de tipos persistidos,
    # sin logica de negocio (MEF-ADR-0036 seccion 3) --, y su guarda real son
    # los dos guardrails de ComposicionContenedorTests sobre el store que
    # compone el contenedor real (MEF-ADR-0036 seccion 4 + MEF-ADR-0029), no
    # cobertura de lineas.
    case "$basename" in
        HealthCheck.cs|Program.cs|*Mensajes.cs|*AssemblyMarker.cs|ConfiguracionSerializacion*.cs|IdentidadEventos*.cs|*.resx)
            echo "excluded"; return ;;
    esac

    # Excluidos por directorio de infraestructura (wiring puro)
    if echo "$dirname" | grep -q '/Infraestructura/'; then
        case "$basename" in
            RequestValidator.cs|ServiceBusDeserializador.cs)
                echo "excluded"; return ;;
        esac
    fi

    # *Api.cs bajo Infraestructura/ de un servidor MCP (issue #788, MEF-ADR-0047
    # decision 3, agents/mcp-scaffolder.md artefacto 5): cliente HTTP tipado que
    # arma el request y devuelve el HttpResponseMessage crudo -- wiring puro,
    # mismo rol que RequestValidator.cs/ServiceBusDeserializador.cs arriba. El
    # check de esos dos exige un '/' DESPUES de "Infraestructura" en $dirname
    # (solo dispara con subcarpeta, ver comentario del Escenario B del test), pero
    # el layout real de mcp-scaffolder coloca *Api.cs directo en Infraestructura/
    # sin subcarpeta -- por eso este check ancla "Infraestructura" como segmento
    # completo de ruta, hoja o no, en vez de reusar el de arriba.
    if echo "$dirname" | grep -qE '(^|/)Infraestructura(/|$)'; then
        case "$basename" in
            *Api.cs)
                echo "excluded"; return ;;
        esac
    fi

    # Carve-out read-side (issue #371, MEF-ADR-0014 + MEF-ADR-0035 seccion 6):
    # el FunctionEndpoint.cs de una query GET delgada (Obtener{X}/Listar{X}s,
    # naming.md del Skill projections) no exige cobertura unitaria -- se cubre
    # por el test de composicion (MEF-ADR-0029) y los smoke tests (MEF-ADR-0013).
    # Acotado a issues tipo:projection y al naming exacto de esas carpetas (sin
    # sufijo "Function", a diferencia de un FunctionEndpoint.cs de comando) para
    # no aflojar el gate del resto: la ausencia del sufijo es parte del criterio,
    # no solo del comentario -- una carpeta `Obtener...Function` seria un comando
    # y sigue exigiendo el 95%.
    local query_dir
    query_dir=$(basename "$dirname")
    if [ "$is_projection" = true ] && [ "$basename" = "FunctionEndpoint.cs" ] \
       && [ "${query_dir%Function}" = "$query_dir" ] \
       && echo "$query_dir" | grep -qE '^(Obtener|Listar)[A-Za-z0-9]*$'; then
        echo "excluded"; return
    fi

    # Logica: patrones que requieren 95%
    # *Projection.cs (MEF-ADR-0034 seccion 9): la clase de proyeccion
    # companion lleva logica real (que evento aplica, como transforma el
    # documento) y no va gateada por is_projection -- a diferencia del
    # carve-out de arriba (que afloja), esta regla endurece el gate, y una
    # regla que endurece gateada por label dejaria sin medir una proyeccion
    # tocada por un issue tipo:feature. Patron en singular: no coincide con
    # ConfiguracionMartenProjections{Dominio}.cs (plural + sufijo dominio)
    # ni ConfiguracionMartenProjections.cs (plural) -- MEF-ADR-0006 no
    # registra otro artefacto del marco con el sufijo "Projection".
    # *EventHandler.cs (issue #590): el EventHandler directo del patron
    # 2.1.0 (`IPrivateEventHandlerAsync<TEvent>`, sin comando espejo --
    # implementer.md seccion "EventHandler — reaccionar a un evento
    # privado") es el punto de entrada de un evento del bus, con el mismo
    # peso que un CommandHandler: decide que se escribe y como se maneja el
    # fallo, y eso es logica de negocio del marco (MEF-ADR-0004). Tampoco va
    # gateado por is_projection ni por label, mismo razonamiento que
    # *Projection.cs arriba. Patron anclado al final del basename: el
    # companion {Clase}.Mensajes.cs del handler (MEF-ADR-0009) cae antes en la
    # exclusion de boilerplate de arriba y sigue sin medirse.
    # *Tool.cs (issue #788, MEF-ADR-0047 decision 4): el McpToolTrigger es el
    # punto de entrada de un servidor MCP con logica de negocio real (routing
    # de parametros, filtros de relevancia, truncado con senal), y MEF-ADR-0048
    # nivel 1 exige unit tests de esa logica -- mismo peso que un
    # CommandHandler. Tampoco va gateado por is_projection ni por label, mismo
    # razonamiento que *Projection.cs/*EventHandler.cs arriba.
    case "$basename" in
        *CommandHandler.cs|*AggregateRoot.cs|*Validator.cs|FunctionEndpoint.cs|*Projection.cs|*EventHandler.cs|*Tool.cs)
            echo "logic"; return ;;
    esac

    # Logica: Eventos con factory Crear()
    # Dos layouts conviven (MEF-ADR-0039): el historico bajo una subcarpeta
    # /Eventos/ o /Entities/ del Function App, y el vigente en la raiz -- o
    # cualquier subcarpeta -- de un proyecto *.DomainEvents, sin subcarpeta
    # Eventos/ (decision 1). El patron sobre el segmento de ruta
    # (\.DomainEvents al final de dirname, o \.DomainEvents/ seguido de mas
    # ruta) cubre ambos casos sin exigir subcarpeta.
    if echo "$dirname" | grep -qE '/Eventos/|/Entities/|\.DomainEvents$|\.DomainEvents/'; then
        if [ -f "$worktree_path/$filepath" ] && grep -q 'static.*Crear(' "$worktree_path/$filepath" 2>/dev/null; then
            echo "logic"; return
        fi
    fi

    # Logica: ValueObjects con factory Crear()
    if echo "$dirname" | grep -q '/ValueObjects/'; then
        if [ -f "$worktree_path/$filepath" ] && grep -q 'static.*Crear(' "$worktree_path/$filepath" 2>/dev/null; then
            echo "logic"; return
        fi
    fi

    # Excluir: records DTO puros del estilo canonico (MEF-ADR-0035 seccion
    # 2: 'public sealed record X(...)', companion de proyeccion aparte).
    # Sin depender del conteo de lineas -- el estilo canonico es
    # multilinea -- ni de 'public record' adyacente -- el estilo canonico
    # es 'public sealed record'. Se aplana el contenido (una sola linea) y
    # se ubica cada declaracion de record con sus modificadores opcionales
    # (sealed/partial, en cualquier combinacion); si tras cerrar la lista
    # de parametros el record termina en ';' es un DTO sin cuerpo. Si en
    # cambio abre un cuerpo '{' (metodos u otros miembros) no cuenta como
    # record puro.
    # Segunda condicion (issue #788, relaja la original "el archivo declara
    # UN solo tipo" del issue #416): TODOS los tipos declarados en el
    # archivo son records puros -- conteo de record-decls puros == total de
    # type_decls. El layout natural de un contrato upstream redeclarado
    # (MEF-ADR-0047 decision 3) es un archivo con N records puros (ej.
    # FichaColaborador + EtiquetaFicha), y todos deberian excluirse igual.
    # La proteccion que motivo la cota original se preserva: un record puro
    # junto a -- o dentro de -- una clase (o cualquier tipo) con metodos deja
    # pure_record_count < type_decls y sigue sin excluirse, evitando que se
    # etiquete "excluido" un archivo que en realidad nadie midio.
    if [ -f "$worktree_path/$filepath" ]; then
        local content
        content=$(grep -v '^\s*//' "$worktree_path/$filepath" | grep -v '^\s*$' | grep -v '^using ' | grep -v '^namespace ' || true)
        local content_flat
        content_flat=$(echo "$content" | tr '\n' ' ')
        local record_decls
        record_decls=$(echo "$content_flat" | grep -oE 'public\s+(sealed\s+|partial\s+)*record\s+\w+\([^()]*\)[^;{]*[;{]' 2>/dev/null || true)
        local type_decls
        type_decls=$(echo "$content_flat" | grep -oE '(class|record|struct|interface|enum)\s+\w+' 2>/dev/null | wc -l | tr -d ' ')
        if [ -n "$record_decls" ]; then
            # '|| true' en los dos grep de arriba y de aqui: los pipelines
            # publicados corren bajo `set -euo pipefail` y un grep sin match
            # sale con status 1 (grep -c imprime "0" pero tambien sale 1),
            # asi que sin la guarda un archivo sin records -- o con records
            # todos con cuerpo -- podria abortar a un caller que invoque la
            # funcion directamente, no dentro de una sustitucion de comando.
            local pure_record_count
            pure_record_count=$(echo "$record_decls" | grep -cE ';$' || true)
            if [ "$pure_record_count" -eq "$type_decls" ]; then
                echo "excluded"; return
            fi
        fi
    fi

    echo "not_evaluated"
}

# caffeinate_prefix
#
# Imprime por stdout "caffeinate -i" si el binario 'caffeinate' esta
# disponible en PATH (macOS), o cadena vacia en cualquier otro sistema
# (Linux/CI) -- issue #800. Antepuesto al lanzamiento de un pipeline largo
# evita que el Mac entre en suspension idle mientras corre en un pane de
# tmux/Herdr (`-i`: solo suspension idle; sin `-d` la pantalla si puede
# apagarse; `-s` se descarta porque solo aplica con AC conectado). El
# prefijo muere junto con el comando envuelto -- caffeinate es el proceso
# padre, sin huerfano que limpiar manualmente.
#
# Alcance: se calcula UNA vez por corrida y se aplica en los RUNNERS
# (tmux-pipeline.sh, herdr-pipeline.sh) sobre el lanzamiento del sub-pipeline,
# no en cada `claude -p` individual dentro de tdd/tooling/iac-pipeline.sh. Un
# pipeline invocado directo, sin pasar por un runner, queda sin envolver.
caffeinate_prefix() {
    if command -v caffeinate >/dev/null 2>&1; then
        printf '%s' "caffeinate -i"
    fi
}
