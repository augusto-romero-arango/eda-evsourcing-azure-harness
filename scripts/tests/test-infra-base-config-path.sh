#!/usr/bin/env bash
# test-infra-base-config-path.sh -- Contratos de config, instrucciones, naming y PostgreSQL de /infra-base (#1212, #1219, #1222, #1251, #1517).
#
# Cubre MEF-ADR-0053 para el prompt de infra-base-scaffolder: canonico, ambos
# divergentes (prevalece canonico), legacy y ausencia. Tambien evita que una
# lectura directa legacy reaparezca fuera de los bloques de fallback explicitos
# del agente y del workflow generado.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT="$REPO_ROOT/agents/infra-base-scaffolder.md"
COMMAND="$REPO_ROOT/commands/infra-base.md"
README="$REPO_ROOT/README.md"
ADR="$REPO_ROOT/docs/adr/mef-adr-0021-infraestructura-base.md"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

resolve_config() {
    local root="$1"
    local config="$root/.mefisto/harness.config.json"
    [ -f "$config" ] || config="$root/.claude/harness.config.json"
    [ -f "$config" ] || return 1
    printf '%s\n' "$config"
}

write_config() {
    local path="$1" project="$2" projections="$3" secret="$4"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<JSON
{"projectName":"$project","infraResourceGroupPrefix":"rg-$project","terraformStateStorage":"st${project}tfstate","azureLocation":"$project-location","azureRegionShort":"$project-region","resourceSequence":"$project-seq","serviceBus":{"internal":{"secretName":"$secret"},"external":[{"alias":"$project-bus","alcance":"compartido","secretName":"$secret-external"}]},"projections":{"enabled":$projections},"secrets":[{"name":"$secret","source":{"type":"output","value":"$project-output"}}]}
JSON
}

read_tokens() {
    jq -r '[.projectName, .infraResourceGroupPrefix, .terraformStateStorage, .azureLocation, .azureRegionShort, .resourceSequence, .serviceBus.internal.secretName, .serviceBus.external[0].alias, .projections.enabled, .secrets[0].name] | join("|")' "$1"
}

assert_effective() {
    local label="$1" root="$2" expected="$3" actual rc
    actual=$(resolve_config "$root"); rc=$?
    if [ "$rc" -eq 0 ] && [ "$actual" = "$expected" ]; then
        pass "$label resuelve la ruta efectiva esperada"
    else
        fail "$label esperaba '$expected' y obtuvo '${actual:-<sin ruta>}'"
    fi
}

extract_instructions_resolver() {
    awk '
        /^if \[ -f "AGENTS\.md" \]; then$/ { inside=1 }
        inside { print }
        inside && /^export MEFISTO_INSTRUCTIONS_PATH$/ { exit }
    ' "$AGENT"
}

echo "[1] Consumidor canonico"
CANONICAL_ROOT="$TMP_DIR/canonical"
write_config "$CANONICAL_ROOT/.mefisto/harness.config.json" canonical true canonical-secret
assert_effective "canonico" "$CANONICAL_ROOT" "$CANONICAL_ROOT/.mefisto/harness.config.json"
CANONICAL_TOKENS=$(read_tokens "$(resolve_config "$CANONICAL_ROOT")")
if [ "$CANONICAL_TOKENS" = "canonical|rg-canonical|stcanonicaltfstate|canonical-location|canonical-region|canonical-seq|canonical-secret|canonical-bus|true|canonical-secret" ]; then
    pass "canonico provee todos los tokens y secrets"
else
    fail "canonico no provee todos los tokens esperados: $CANONICAL_TOKENS"
fi

echo "[2] Ambos configs divergentes: prevalece el canonico para todos los tokens"
BOTH_ROOT="$TMP_DIR/both"
write_config "$BOTH_ROOT/.mefisto/harness.config.json" canonical true canonical-secret
write_config "$BOTH_ROOT/.claude/harness.config.json" legacy false legacy-secret
assert_effective "ambos" "$BOTH_ROOT" "$BOTH_ROOT/.mefisto/harness.config.json"
EFFECTIVE=$(resolve_config "$BOTH_ROOT")
TOKENS=$(read_tokens "$EFFECTIVE")
if [ "$TOKENS" = "canonical|rg-canonical|stcanonicaltfstate|canonical-location|canonical-region|canonical-seq|canonical-secret|canonical-bus|true|canonical-secret" ]; then
    pass "ambos usa exclusivamente tokens y secrets canonicos"
else
    fail "ambos mezclo tokens legacy: $TOKENS"
fi

echo "[3] Consumidor legacy"
LEGACY_ROOT="$TMP_DIR/legacy"
write_config "$LEGACY_ROOT/.claude/harness.config.json" legacy false legacy-secret
assert_effective "legacy" "$LEGACY_ROOT" "$LEGACY_ROOT/.claude/harness.config.json"
LEGACY_TOKENS=$(read_tokens "$(resolve_config "$LEGACY_ROOT")")
if [ "$LEGACY_TOKENS" = "legacy|rg-legacy|stlegacytfstate|legacy-location|legacy-region|legacy-seq|legacy-secret|legacy-bus|false|legacy-secret" ]; then
    pass "legacy provee todos los tokens y secrets mediante el fallback"
else
    fail "legacy no provee todos los tokens esperados: $LEGACY_TOKENS"
fi

echo "[4] Ausencia de ambos configs"
MISSING_ROOT="$TMP_DIR/missing"
mkdir -p "$MISSING_ROOT"
if resolve_config "$MISSING_ROOT" >/dev/null 2>&1; then
    fail "ausencia debe abortar"
else
    pass "ausencia aborta"
fi

echo "[5] Prompt y workflow generado conservan el fallback explicito"
REPO_CANONICAL_COUNT=$(grep -Fc 'CONFIG="$REPO_ROOT/.mefisto/harness.config.json"' "$AGENT" || true)
REPO_LEGACY_COUNT=$(grep -Fc 'CONFIG="$REPO_ROOT/.claude/harness.config.json"' "$AGENT" || true)
WORKFLOW_CANONICAL_COUNT=$(grep -Fc 'CONFIG="$GITHUB_WORKSPACE/.mefisto/harness.config.json"' "$AGENT" || true)
WORKFLOW_LEGACY_COUNT=$(grep -Fc 'CONFIG="$GITHUB_WORKSPACE/.claude/harness.config.json"' "$AGENT" || true)
if [ "$REPO_CANONICAL_COUNT" -eq 3 ] && [ "$REPO_LEGACY_COUNT" -eq 3 ] \
    && [ "$WORKFLOW_CANONICAL_COUNT" -eq 1 ] && [ "$WORKFLOW_LEGACY_COUNT" -eq 1 ]; then
    pass "cada bloque del agente y el workflow parte del canonico y delimita un fallback legacy"
else
    fail "resolvers inesperados (repo canonico/legacy=$REPO_CANONICAL_COUNT/$REPO_LEGACY_COUNT, workflow=$WORKFLOW_CANONICAL_COUNT/$WORKFLOW_LEGACY_COUNT)"
fi
if grep -Eq '(^|[;&|[:space:]])jq[[:space:]].*\.claude/harness\.config\.json' "$AGENT"; then
    fail "reaparecio una lectura jq directa del config legacy"
else
    pass "no hay lecturas jq directas del config legacy"
fi
if grep -Eq '(^|[;&|[:space:]])(cat|sed|awk|grep|python|python3)[[:space:]].*\.claude/harness\.config\.json|<[[:space:]]*[^[:space:]]*\.claude/harness\.config\.json' "$AGENT"; then
    fail "reaparecio una lectura directa legacy fuera del fallback"
else
    pass "no hay otras lecturas directas del config legacy"
fi
if grep -Eq '(^|[;&|[:space:]])jq[[:space:]].*\.(mefisto|claude)/harness\.config\.json' "$AGENT"; then
    fail "alguna lectura jq evita la ruta efectiva CONFIG"
else
    pass "todas las lecturas jq pasan por la ruta efectiva CONFIG"
fi
if grep -Fq 'jq -r '\''{projectName, infraResourceGroupPrefix, terraformStateStorage, azureLocation, azureRegionShort, resourceSequence, serviceBus, projections}'\'' "$CONFIG"' "$AGENT" \
    && grep -Fq 'COUNT=$(jq -r '\''.secrets // [] | length'\'' "$CONFIG")' "$AGENT" \
    && grep -Fq 'No se encontro .mefisto/harness.config.json ni el fallback legacy .claude/harness.config.json; no se pueden sembrar secretos.' "$AGENT"; then
    pass "tokens del agente y secrets del workflow usan CONFIG y la ausencia aborta"
else
    fail "alguna lectura efectiva o diagnostico de ausencia no usa el contrato resuelto"
fi
if grep -Fq '.mefisto/harness.config.json' "$COMMAND" \
    && grep -Fq 'fallback de **lectura**' "$COMMAND" \
    && grep -Fq 'sin copiarlo ni migrarlo' "$COMMAND"; then
    pass "comando documenta contrato canonico sin instruir migracion"
else
    fail "comando no documenta correctamente el contrato"
fi

echo "[6] Naming regional independiente y persistente de PostgreSQL"
POSTGRESQL_REGION_BLOCK=$(awk '/^variable "postgresql_region_short"/,/^}/' "$AGENT")
POSTGRESQL_ZONE_BLOCK=$(awk '/^variable "postgresql_zone"/,/^}/' "$AGENT")
POSTGRESQL_MODULE_BLOCK=$(awk '/^module "postgresql"/,/^}/' "$AGENT")
POSTGRESQL_RECIPE_BLOCK=$(awk '/^### 1\.3 `infra\/modules\/postgresql\/main\.tf`/,/^### 1\.4 `infra\/modules\/service-bus\/main\.tf`/' "$AGENT")
POSTGRESQL_RECIPE_ZONE_BLOCK=$(awk '/^variable "zone"/,/^}/' <<< "$POSTGRESQL_RECIPE_BLOCK")
POSTGRESQL_RECIPE_SERVER_BLOCK=$(awk '/^resource "azurerm_postgresql_flexible_server" "this"/,/^}/' <<< "$POSTGRESQL_RECIPE_BLOCK")
POSTGRESQL_RECIPE_LIFECYCLE_BLOCK=$(awk '/^  lifecycle \{$/,/^  }$/' <<< "$POSTGRESQL_RECIPE_SERVER_BLOCK")
if grep -Fq 'variable "postgresql_region_short"' <<< "$POSTGRESQL_REGION_BLOCK" \
    && grep -Fq 'default     = "<azure_region_short>"' <<< "$POSTGRESQL_REGION_BLOCK" \
    && grep -Fq 'postgresql_region_seq_suffix = var.postgresql_region_short != "" ? "-${var.postgresql_region_short}-${var.resource_sequence}" : ""' "$AGENT" \
    && grep -Fq 'name                   = "pgsql-${var.project_short}-${var.environment}${local.postgresql_region_seq_suffix}"' <<< "$POSTGRESQL_MODULE_BLOCK"; then
    pass "el agente declara el sufijo regional exclusivo y el nombre CAF de PostgreSQL"
else
    fail "falta la variable, el local o el nombre regional de PostgreSQL"
fi
if grep -Fq 'location               = var.postgresql_location' <<< "$POSTGRESQL_MODULE_BLOCK" \
    && grep -Fq 'zone                   = var.postgresql_zone' <<< "$POSTGRESQL_MODULE_BLOCK" \
    && grep -Fq 'default     = null' <<< "$POSTGRESQL_ZONE_BLOCK" \
    && grep -Fq 'prefix      = "${var.project}-${var.environment}${local.region_seq_suffix}"' "$AGENT" \
    && grep -Fq 'prefix_func = "${var.project_short}-${var.environment}${local.region_seq_suffix}"' "$AGENT" \
    && grep -Fq 'name     = "rg-${local.prefix}"' "$AGENT" \
    && grep -Fq 'name                     = local.prefix' "$AGENT" \
    && grep -Fq 'name                = "sbns-interno-${local.prefix}"' "$AGENT" \
    && grep -Fq 'name                = "kv-${var.project_short}-${var.environment}${local.region_seq_suffix}"' "$AGENT"; then
    pass "PostgreSQL conserva location/zone y los demas recursos conservan los locals primarios"
else
    fail "se altero el aislamiento regional de PostgreSQL o el naming primario"
fi
if grep -Fq 'defaults versionados' "$AGENT" \
    && grep -Fq 'infra/environments/<env>/variables.tf' "$AGENT" \
    && grep -Fq 'runner limpio de CI no lo recibe' "$AGENT" \
    && grep -Fq 'variable "postgresql_location" { default = "centralus" }' "$COMMAND" \
    && grep -Fq 'variable "postgresql_region_short" { default = "cus" }' "$COMMAND" \
    && grep -Fq 'variables.tf' "$COMMAND" \
    && grep -Fq 'solo sirve para overrides locales no versionados' "$COMMAND" \
    && grep -Fq 'nunca guardes alli postgresql_admin_password ni otro secreto' "$COMMAND" \
    && grep -Fq 'variable "postgresql_location" {' "$README" \
    && grep -Fq 'default = "centralus"' "$README" \
    && grep -Fq 'variable "postgresql_region_short" {' "$README" \
    && grep -Fq 'default = "cus"' "$README" \
    && grep -Fq 'no altera `location` ni `azure_region_short`' "$README" \
    && grep -Fq 'nunca guardes allí `postgresql_admin_password` ni otro secreto' "$README" \
    && grep -Fq 'default no sensible y versionado de `infra/environments/<env>/variables.tf`' "$ADR" \
    && grep -Fq '`terraform.tfvars` ignorado queda reservado para overrides locales no versionados' "$ADR"; then
    pass "agente, comando, README y ADR versionan el par regional de CI como defaults HCL"
else
    fail "falta la receta versionada del par postgresql_location/postgresql_region_short"
fi
if grep -Fq 'juntos en el terraform.tfvars ignorado' "$AGENT" "$COMMAND" "$README" "$ADR" \
    || grep -Fq 'ambos overrides no sensibles viven en el `terraform.tfvars` ignorado' "$AGENT" "$COMMAND" "$README" "$ADR" \
    || grep -Fq 'revisable en `infra/environments/<env>/terraform.tfvars`' "$AGENT" "$COMMAND" "$README" "$ADR"; then
    fail "la receta regional vuelve a presentar terraform.tfvars ignorado como fuente de CI"
else
    pass "terraform.tfvars ignorado no se presenta como fuente regional de CI"
fi

echo "[7] PostgreSQL ignora el drift de zona asignada por Azure"
if grep -Fq 'variable "zone"' <<< "$POSTGRESQL_RECIPE_ZONE_BLOCK" \
    && grep -Fq 'default     = null' <<< "$POSTGRESQL_RECIPE_ZONE_BLOCK" \
    && grep -Fq 'zone = var.zone' <<< "$POSTGRESQL_RECIPE_SERVER_BLOCK" \
    && grep -Fq 'prevent_destroy = true' <<< "$POSTGRESQL_RECIPE_LIFECYCLE_BLOCK" \
    && grep -Fq 'ignore_changes  = [zone]' <<< "$POSTGRESQL_RECIPE_LIFECYCLE_BLOCK"; then
    pass "la receta conserva create con zone null y protege lifecycle contra el drift de Azure"
else
    fail "la receta PostgreSQL debe conservar default/wiring de zone, prevent_destroy e ignore_changes"
fi
if grep -Fq 'high_availability[0].standby_availability_zone' <<< "$POSTGRESQL_RECIPE_BLOCK" \
    && grep -Fq 'Migracion de modulos ya provisionados' <<< "$POSTGRESQL_RECIPE_BLOCK" \
    && grep -Fq 'nunca sobrescribe un `.tf` existente' <<< "$POSTGRESQL_RECIPE_BLOCK" \
    && grep -Fq 'https://github.com/hashicorp/terraform-provider-azurerm/blob/main/website/docs/r/postgresql_flexible_server.html.markdown' <<< "$POSTGRESQL_RECIPE_BLOCK"; then
    pass "la receta documenta recomendacion del provider, HA futura y migracion de consumidores"
else
    fail "la receta debe documentar provider, standby de HA y migracion de modulos existentes"
fi

echo "[8] Instrucciones efectivas para RootNamespace"
INSTRUCTIONS_RESOLVER=$(extract_instructions_resolver)
if [ -z "$INSTRUCTIONS_RESOLVER" ]; then
    fail "no se pudo extraer el resolver de instrucciones del agente"
else
    resolve_instructions() {
        local root="$1"
        (cd "$root" && bash -c "$INSTRUCTIONS_RESOLVER"$'\n''root_namespace=$(awk -F '\''[:][[:space:]]*'\'' '\''$1 == "RootNamespace" { print $2; exit }'\'' "$MEFISTO_INSTRUCTIONS_PATH"); printf "%s|%s.Projections\\n" "$MEFISTO_INSTRUCTIONS_PATH" "$root_namespace"')
    }

    INSTRUCTIONS_CANONICAL="$TMP_DIR/instructions-canonical"
    mkdir -p "$INSTRUCTIONS_CANONICAL"
    printf '## Tokens del harness\nRootNamespace: Canonical\n' > "$INSTRUCTIONS_CANONICAL/AGENTS.md"
    printf '@AGENTS.md\n' > "$INSTRUCTIONS_CANONICAL/CLAUDE.md"
    out=$(resolve_instructions "$INSTRUCTIONS_CANONICAL" 2>"$TMP_DIR/instructions-canonical.err"); rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = 'AGENTS.md|Canonical.Projections' ] && grep -Fq 'se ignora el legacy CLAUDE.md' "$TMP_DIR/instructions-canonical.err"; then
        pass "canonico resuelve desde AGENTS.md el service.name de la alerta y conserva visible el aviso"
    else
        fail "canonico no resolvio AGENTS.md con aviso (rc=$rc, out='$out', err='$(cat "$TMP_DIR/instructions-canonical.err")')"
    fi

    INSTRUCTIONS_LEGACY="$TMP_DIR/instructions-legacy"
    mkdir -p "$INSTRUCTIONS_LEGACY"
    printf '## Tokens del harness\nRootNamespace: Legacy\n' > "$INSTRUCTIONS_LEGACY/CLAUDE.md"
    out=$(resolve_instructions "$INSTRUCTIONS_LEGACY" 2>"$TMP_DIR/instructions-legacy.err"); rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = 'CLAUDE.md|Legacy.Projections' ] && [ ! -s "$TMP_DIR/instructions-legacy.err" ]; then
        pass "solo legacy resuelve el service.name desde CLAUDE.md como fallback de lectura"
    else
        fail "legacy no resolvio como fallback (rc=$rc, out='$out', err='$(cat "$TMP_DIR/instructions-legacy.err")')"
    fi

    INSTRUCTIONS_BOTH="$TMP_DIR/instructions-both"
    mkdir -p "$INSTRUCTIONS_BOTH"
    printf '## Tokens del harness\nRootNamespace: Canonical\n' > "$INSTRUCTIONS_BOTH/AGENTS.md"
    printf '## Tokens del harness\nRootNamespace: Legacy\n' > "$INSTRUCTIONS_BOTH/CLAUDE.md"
    out=$(resolve_instructions "$INSTRUCTIONS_BOTH" 2>"$TMP_DIR/instructions-both.err"); rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = 'AGENTS.md|Canonical.Projections' ] && grep -Fq 'AVISO: se usara AGENTS.md; se ignora el legacy CLAUDE.md.' "$TMP_DIR/instructions-both.err"; then
        pass "coexistencia usa el RootNamespace canonico para la alerta y avisa que ignora el legacy"
    else
        fail "coexistencia no preservo la precedencia canonica (rc=$rc, out='$out', err='$(cat "$TMP_DIR/instructions-both.err")')"
    fi

    INSTRUCTIONS_MISSING="$TMP_DIR/instructions-missing"
    mkdir -p "$INSTRUCTIONS_MISSING"
    out=$(resolve_instructions "$INSTRUCTIONS_MISSING" 2>"$TMP_DIR/instructions-missing.err"); rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$out" ] && grep -Fq '/mefisto:onboard' "$TMP_DIR/instructions-missing.err"; then
        pass "ausencia de instrucciones aborta y remite a onboard"
    else
        fail "ausencia de instrucciones no aborto como corresponde (rc=$rc, out='$out', err='$(cat "$TMP_DIR/instructions-missing.err")')"
    fi
fi
if grep -Fq 'CLAUDE.md raiz' "$AGENT" || grep -Fq 'Lee ademas `CLAUDE.md`' "$AGENT"; then
    fail "el agente vuelve a presentar CLAUDE.md como fuente directa de tokens"
else
    pass "el agente no presenta CLAUDE.md como fuente directa de tokens"
fi
if grep -Eq 'derivacion desde `?CLAUDE\.md`?|CLAUDE\.md.*token `?RootNamespace`?|token `?RootNamespace`?.*CLAUDE\.md' "$AGENT"; then
    fail "RootNamespace vuelve a leerse desde CLAUDE.md fuera del fallback"
else
    pass "RootNamespace se deriva solo del archivo efectivo de instrucciones"
fi
if grep -Eq 'declare `?RootNamespace`?.*CLAUDE\.md|CLAUDE\.md.*declare `?RootNamespace`?' "$AGENT"; then
    fail "el Paso 5 vuelve a pedir declarar RootNamespace en CLAUDE.md"
else
    pass "el Paso 5 no pide declarar RootNamespace en CLAUDE.md"
fi
AGENT_WITHOUT_RESOLVER=$(awk '
    /^if \[ -f "AGENTS\.md" \]; then$/ { resolver=1; next }
    resolver && /^export MEFISTO_INSTRUCTIONS_PATH$/ { resolver=0; next }
    !resolver { print }
' "$AGENT")
if grep -Fq 'CLAUDE.md' <<< "$AGENT_WITHOUT_RESOLVER"; then
    fail "CLAUDE.md aparece fuera del bloque literal de fallback"
else
    pass "CLAUDE.md queda confinado al bloque literal de fallback"
fi
if grep -Fq 'projections_service_name' "$AGENT" \
    && grep -Fq '`${MEFISTO_INSTRUCTIONS_PATH}`' "$AGENT" \
    && grep -Fq 'omite **solo** el recurso de la alerta' "$AGENT" \
    && grep -Fq 'declarar `RootNamespace` en `AGENTS.md`, seccion "Tokens del harness"' "$AGENT"; then
    pass "la alerta usa el token efectivo y conserva la omision acotada y su diagnostico canonico"
else
    fail "falta el contrato que conecta RootNamespace efectivo con la alerta de proyecciones"
fi

echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
