#!/usr/bin/env bash
# test-onboard-tenancy-write.sh -- Regresion del bloque de escritura de
# tenancy.strategy del paso 6 de /onboard (#1513): debe preservar los demas
# campos del objeto tenancy (y del documento) al actualizar la estrategia,
# igual que el escritor equivalente de /install-apim (#1504).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
COMMAND="$REPO_ROOT/commands/onboard.md"
PASS=0
FAIL=0

pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"

extract_bash_after_heading() {
    local heading="$1"
    awk -v heading="$heading" '
        $0 == heading { found=1; next }
        found && /^```bash$/ { inside=1; next }
        found && /^```$/ && inside { exit }
        inside { print }
    ' "$COMMAND"
}

WRITE_BLOCK="$(extract_bash_after_heading '### 6. Bifurcacion de auth: provision opt-in de la estrategia de tenancy (crecer vs POC)')"

if [ -z "$WRITE_BLOCK" ]; then
    fail 'no se pudo extraer el bloque bash del paso 6 de onboard.md'
    echo '----------------------------------------'
    echo "  Resumen: $PASS pass, $FAIL fail"
    echo '----------------------------------------'
    exit 1
fi

if grep -Fq '.tenancy = {strategy: $s}' <<< "$WRITE_BLOCK"; then
    fail 'el bloque extraido todavia reemplaza el objeto tenancy completo (.tenancy = {strategy: $s})'
fi

prepare_repo() {
    local repo="$1"
    mkdir -p "$repo/.mefisto/pipeline"
    git -C "$repo" init -q
    printf '%s\n' "$REPO_ROOT" > "$repo/.mefisto/pipeline/.plugin-root"
}

write_config_with_tenancy() {
    local path="$1" strategy="$2" extra="$3"
    mkdir -p "$(dirname "$path")"
    jq -n --arg strategy "$strategy" --arg extra "$extra" \
        '{projectName:"Ejemplo", namespacePrefix:"Ejemplo", solutionFile:"Ejemplo.slnx", domainLabels:["ventas"], boundedContext:{name:"Principal", domains:["ventas"]}, tenancy:{strategy:$strategy, extra:$extra}}' > "$path"
}

write_config_without_tenancy() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    jq -n \
        '{projectName:"Ejemplo", namespacePrefix:"Ejemplo", solutionFile:"Ejemplo.slnx", domainLabels:["ventas"], boundedContext:{name:"Principal", domains:["ventas"]}}' > "$path"
}

run_write() {
    local repo="$1" estrategia="$2" output="$3"
    local block="${WRITE_BLOCK/<mono-tenant-transitorio|multi-tenant-header>/$estrategia}"
    # Si el placeholder de ESTRATEGIA cambia de texto, la sustitucion no aplica
    # y el bloque escribiria el literal del placeholder: sin este guard el
    # fallo aparece como "no preservo los demas campos", que apunta al filtro
    # jq equivocado en vez de a la extraccion.
    if [ "$block" = "$WRITE_BLOCK" ]; then
        echo 'el bloque del paso 6 ya no expone el placeholder de ESTRATEGIA esperado' >"$output"
        return 1
    fi
    (cd "$repo" && bash -c "$block") >"$output" 2>&1
}

echo '[1] Tenancy existente con estrategia previa y campo adicional (CA-2)'
WITH_TENANCY="$WORK/con-tenancy"
prepare_repo "$WITH_TENANCY"
write_config_with_tenancy "$WITH_TENANCY/.mefisto/harness.config.json" 'mono-tenant-transitorio' 'preservar'
if run_write "$WITH_TENANCY" 'multi-tenant-header' "$WORK/con-tenancy.out"; then
    CONFIG_FILE="$WITH_TENANCY/.mefisto/harness.config.json"
    if jq -e '.tenancy.strategy == "multi-tenant-header" and .tenancy.extra == "preservar" and .projectName == "Ejemplo"' "$CONFIG_FILE" >/dev/null \
        && jq empty "$CONFIG_FILE" >/dev/null \
        && grep -Fq 'escrito en' "$WORK/con-tenancy.out"; then
        pass 'actualiza tenancy.strategy y preserva el campo adicional y el campo de nivel superior'
    else
        fail "no preservo los demas campos o no actualizo la estrategia: $(cat "$CONFIG_FILE")"
    fi
else
    fail "el bloque aborto con tenancy existente: $(cat "$WORK/con-tenancy.out")"
fi

echo '[2] Config canonico sin objeto tenancy (CA-3)'
WITHOUT_TENANCY="$WORK/sin-tenancy"
prepare_repo "$WITHOUT_TENANCY"
write_config_without_tenancy "$WITHOUT_TENANCY/.mefisto/harness.config.json"
if run_write "$WITHOUT_TENANCY" 'multi-tenant-header' "$WORK/sin-tenancy.out"; then
    CONFIG_FILE="$WITHOUT_TENANCY/.mefisto/harness.config.json"
    if jq -e '.tenancy.strategy == "multi-tenant-header" and .projectName == "Ejemplo" and .boundedContext.name == "Principal"' "$CONFIG_FILE" >/dev/null \
        && jq empty "$CONFIG_FILE" >/dev/null \
        && grep -Fq 'escrito en' "$WORK/sin-tenancy.out"; then
        pass 'crea tenancy.strategy sin alterar los demas campos del documento'
    else
        fail "no creo tenancy.strategy correctamente sin alterar el resto: $(cat "$CONFIG_FILE")"
    fi
else
    fail "el bloque aborto sin tenancy previo: $(cat "$WORK/sin-tenancy.out")"
fi

echo '----------------------------------------'
echo "  Resumen: $PASS pass, $FAIL fail"
echo '----------------------------------------'
[ "$FAIL" -eq 0 ]
