#!/usr/bin/env bash
# validate-internal-artifacts.sh -- Valida agentes/comandos de
# src/internal/{agents,commands}/*.md contra el contrato neutral (MEF-ADR-0049
# CA-6, issue #853).
#
# Extrae el bloque JSON de frontmatter de cada archivo, lo parsea con jq y lo
# valida contra internal-artifact.schema.json mediante el subconjunto de JSON
# Schema que implementa lib/jsonschema-lite.jq. El schema es la unica
# declaracion de campos: este script no duplica la lista de campos validos,
# solo orquesta la extraccion y dos chequeos que el schema no puede expresar
# (frontmatter ausente/no-JSON e id vs. nombre de archivo, que dependen del
# archivo mismo, no solo de su contenido).
#
# Uso: validate-internal-artifacts.sh [archivo...]
#   Sin argumentos: valida todo src/internal/{agents,commands}/*.md (orden
#   determinista, LC_ALL=C).
# Exit code: 0 si todos los archivos son validos, 1 si alguno se rechaza.
# Cada rechazo imprime una linea "<archivo>: <campo>: <motivo>".

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONTRACT_DIR="$REPO_ROOT/src/internal/contract"
SCHEMA_FILE="$CONTRACT_DIR/internal-artifact.schema.json"
JSONSCHEMA_LITE="$SCRIPT_DIR/lib/jsonschema-lite.jq"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq no esta instalado (MEF-ADR-0049 CA-6: bash + jq, sin validador externo)" >&2
    exit 1
fi

if [ ! -f "$SCHEMA_FILE" ]; then
    echo "ERROR: no existe el schema '$SCHEMA_FILE'" >&2
    exit 1
fi

# extract_frontmatter <archivo> -- imprime por stdout el bloque entre la
# primera linea ("---") y la siguiente linea que sea exactamente "---". Un
# objeto JSON nunca contiene una linea que sea solo "---", asi que el corte es
# robusto sin necesitar un parser JSON para encontrar el limite (ver README.md,
# "Regla de extraccion del frontmatter"). Vacio si la primera linea no es
# "---" (frontmatter ausente).
extract_frontmatter() {
    awk 'NR==1 && $0!="---"{exit 1} NR>1 && $0=="---"{exit} NR>1' "$1"
}

# validate_file <archivo> -- imprime rechazos a stdout, retorna 1 si hubo
# alguno, 0 si el archivo es valido.
validate_file() {
    local file="$1"
    local rel="${file#"$REPO_ROOT"/}"
    local basename_no_ext
    basename_no_ext="$(basename "$file" .md)"

    local frontmatter
    frontmatter="$(extract_frontmatter "$file")"
    if [ -z "$frontmatter" ]; then
        echo "$rel: frontmatter: ausente (se esperaba un bloque '---' JSON al inicio del archivo)"
        return 1
    fi

    local instance_json
    if ! instance_json="$(printf '%s\n' "$frontmatter" | jq -c '.' 2>/dev/null)"; then
        echo "$rel: frontmatter: no es JSON valido"
        return 1
    fi

    local id
    id="$(printf '%s' "$instance_json" | jq -r 'if (.id? | type) == "string" then .id else empty end')"
    if [ -z "$id" ]; then
        echo "$rel: id: campo requerido ausente"
        return 1
    fi
    if [ "$id" != "$basename_no_ext" ]; then
        echo "$rel: id: '$id' distinto del nombre de archivo '$basename_no_ext'"
        return 1
    fi

    local schema_json
    schema_json="$(cat "$SCHEMA_FILE")"

    local errors
    if ! errors="$(jq -n -S --argjson schema "$schema_json" --argjson instance "$instance_json" -f "$JSONSCHEMA_LITE" 2>&1)"; then
        echo "$rel: schema: el validador jq fallo: $errors"
        return 1
    fi

    local error_count
    error_count="$(printf '%s' "$errors" | jq 'length')"
    if [ "$error_count" -gt 0 ]; then
        printf '%s' "$errors" | jq -r --arg rel "$rel" '.[] | "\($rel): \(.)"'
        return 1
    fi

    return 0
}

FILES=("$@")
if [ ${#FILES[@]} -eq 0 ]; then
    FILES=()
    while IFS= read -r f; do
        [ -n "$f" ] && FILES+=("$f")
    done < <(find "$REPO_ROOT/src/internal/agents" "$REPO_ROOT/src/internal/commands" -name '*.md' 2>/dev/null | sort)
fi

STATUS=0
if [ ${#FILES[@]} -gt 0 ]; then
    for f in "${FILES[@]}"; do
        if ! validate_file "$f"; then
            STATUS=1
        fi
    done
fi

exit $STATUS
