#!/usr/bin/env bash
# validate-internal-artifacts.sh -- Valida agentes/comandos de
# src/internal/{agents,commands}/*.md contra el contrato neutral (MEF-ADR-0049
# CA-6, issue #853).
#
# Extrae el bloque JSON de frontmatter de cada archivo, lo parsea con jq y lo
# valida contra internal-artifact.schema.json mediante el subconjunto de JSON
# Schema que implementa lib/jsonschema-lite.jq. El schema es la unica
# declaracion de campos: este script no duplica la lista de campos validos,
# solo orquesta la extraccion y los tres chequeos que el schema no puede
# expresar porque no dependen solo del frontmatter:
#   - frontmatter ausente, sin cierre o no-JSON (estructura del archivo);
#   - `id` comparado contra el nombre del archivo;
#   - neutralidad del body (CA-1: no nombra `claude` ni `opencode`).
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

for required in "$SCHEMA_FILE" "$JSONSCHEMA_LITE"; do
    if [ ! -f "$required" ]; then
        echo "ERROR: no existe '$required'" >&2
        exit 1
    fi
done

# extract_frontmatter <archivo> -- imprime por stdout el bloque entre la
# primera linea ("---") y la siguiente linea que sea exactamente "---". Un
# objeto JSON nunca contiene una linea que sea solo "---", asi que el corte es
# robusto sin necesitar un parser JSON para encontrar el limite (ver README.md,
# "Regla de extraccion del frontmatter").
# Exit: 0 bloque delimitado, 1 la primera linea no es "---", 2 falta el cierre.
extract_frontmatter() {
    awk '
        NR==1 { if ($0 != "---") { bad=1; exit 1 } ; next }
        $0 == "---" { closed=1; exit 0 }
        { print }
        END { if (bad) exit 1; if (!closed) exit 2 }
    ' "$1"
}

# body_runtime_references <archivo> -- imprime el numero de linea (relativo al
# archivo) de cada linea del body que nombra un runtime concreto. CA-1: la
# fuente neutral describe intenciones, nunca `claude`/`opencode` ni sus
# directorios; esas referencias las introduce el generador (#854) o el
# adaptador. Sin este chequeo, la mitad de CA-1 quedaria documentada pero no
# verificada, justo cuando #865-#867 migren los artefactos reales.
body_runtime_references() {
    awk '
        NR==1 && $0 != "---" { exit }
        NR>1 && $0 == "---" && !seen { seen=1; next }
        seen && tolower($0) ~ /claude|opencode/ { print NR }
    ' "$1"
}

# validate_file <archivo> -- imprime rechazos a stdout, retorna 1 si hubo
# alguno, 0 si el archivo es valido.
validate_file() {
    local file="$1"
    local rel="${file#"$REPO_ROOT"/}"

    if [ ! -f "$file" ]; then
        echo "$rel: archivo: no existe o no es un archivo regular"
        return 1
    fi

    local basename_no_ext
    basename_no_ext="$(basename "$file" .md)"

    local frontmatter extract_rc
    frontmatter="$(extract_frontmatter "$file")"
    extract_rc=$?
    case "$extract_rc" in
        1)
            echo "$rel: frontmatter: ausente (se esperaba un bloque '---' JSON al inicio del archivo)"
            return 1
            ;;
        2)
            echo "$rel: frontmatter: sin delimitador de cierre (falta una linea '---' tras el objeto JSON)"
            return 1
            ;;
    esac
    if [ -z "$frontmatter" ]; then
        echo "$rel: frontmatter: bloque vacio (se esperaba un objeto JSON)"
        return 1
    fi

    local instance_json
    if ! instance_json="$(printf '%s\n' "$frontmatter" | jq -c '.' 2>/dev/null)"; then
        echo "$rel: frontmatter: no es JSON valido"
        return 1
    fi

    local status=0

    # El schema corre primero y es quien juzga los campos: si `id` falta, no es
    # un string o la instancia ni siquiera es un objeto, el motivo que se
    # imprime es el del schema, no un "id ausente" generico que ocultaria la
    # causa real.
    local schema_json errors
    schema_json="$(cat "$SCHEMA_FILE")"
    if ! errors="$(jq -n --argjson schema "$schema_json" --argjson instance "$instance_json" -f "$JSONSCHEMA_LITE" 2>&1)"; then
        echo "$rel: schema: el validador jq fallo: $errors"
        return 1
    fi
    if [ -n "$errors" ] && [ "$(printf '%s' "$errors" | jq 'length')" -gt 0 ]; then
        printf '%s' "$errors" | jq -r --arg rel "$rel" '.[] | "\($rel): \(.)"'
        status=1
    fi

    # Chequeo que el schema no puede expresar: el `id` depende del nombre del
    # archivo, que no viaja en la instancia.
    local id
    id="$(printf '%s' "$instance_json" | jq -r 'if (.id? | type) == "string" then .id else empty end')"
    if [ -n "$id" ] && [ "$id" != "$basename_no_ext" ]; then
        echo "$rel: id: '$id' distinto del nombre de archivo '$basename_no_ext'"
        status=1
    fi

    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        echo "$rel: body: linea $line nombra un runtime concreto (claude/opencode); la fuente neutral es agnostica (CA-1)"
        status=1
    done < <(body_runtime_references "$file")

    return $status
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
