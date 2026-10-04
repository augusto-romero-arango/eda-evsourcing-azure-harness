#!/usr/bin/env bash
# render-eraser-diagram.sh -- Renderiza un payload Eraser validado del consumidor.
# Uso: render-eraser-diagram.sh --payload-file <ruta bajo .mefisto/pipeline/tmp/>
set -uo pipefail
set +x
export LC_ALL=C

ENDPOINT='https://app.eraser.io/api/render/elements'

error() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

[ "$#" -eq 2 ] && [ "$1" = '--payload-file' ] && [ -n "$2" ] || error 'uso: render-eraser-diagram.sh --payload-file <ruta>'

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || error 'solo se puede renderizar desde un repositorio consumidor'
[ ! -f "$repo_root/.claude-plugin/plugin.json" ] || error 'el renderizador publicado solo opera sobre un consumidor'
payload_input="$2"
case "$payload_input" in
    /*) payload_candidate="$payload_input" ;;
    *) payload_candidate="$PWD/$payload_input" ;;
esac
[ -f "$payload_candidate" ] && [ ! -L "$payload_candidate" ] || error 'el payload debe ser un archivo regular'
tmp_root="$repo_root/.mefisto/pipeline/tmp"
[ -d "$tmp_root" ] && [ ! -L "$tmp_root" ] || error 'no existe el directorio temporal del pipeline'
tmp_root="$(cd -P "$tmp_root" && pwd)" || error 'no se pudo resolver el directorio temporal del pipeline'
payload_dir="$(cd -P "$(dirname "$payload_candidate")" 2>/dev/null && pwd)" || error 'no se pudo resolver el directorio del payload'
payload="$payload_dir/$(basename "$payload_candidate")"
case "$payload" in "$tmp_root"/*) ;; *) error 'el payload debe estar bajo .mefisto/pipeline/tmp/' ;; esac

command -v jq >/dev/null 2>&1 || error 'jq es requerido para validar la respuesta de Eraser'
jq -e '
  (keys | sort) == ["background", "elements", "scale", "theme"] and
  .scale == 2 and .theme == "dark" and .background == true and
  (.elements | type == "array" and length == 1) and
  (.elements[0] | (keys | sort) == ["code", "diagramType", "id", "type"] and
    .type == "diagram" and .id == "diagram-1" and
    (.code | type == "string" and length > 0) and
    (.diagramType | IN("sequence-diagram", "cloud-architecture-diagram", "flowchart-diagram", "entity-relationship-diagram", "bpmn-diagram")))
' "$payload" >/dev/null 2>&1 || error 'el payload de Eraser no tiene el contrato esperado'

token="${ERASER_API_TOKEN:-}"
[ -n "$token" ] || error 'falta ERASER_API_TOKEN; muestra el DSL y pegalo en https://app.eraser.io'
case "$token" in *$'\n'*|*$'\r'*) error 'ERASER_API_TOKEN no es valido' ;; esac
escaped_token="$(printf '%s' "$token" | sed 's/[\\"]/\\&/g')"

response="$(printf 'header = "Authorization: Bearer %s"\n' "$escaped_token" | curl --disable --silent --show-error --fail --connect-timeout 5 --max-time 60 --request POST --url "$ENDPOINT" --header 'Content-Type: application/json' --header 'X-Skill-Source: mefisto' --data-binary "@$payload" --config - 2>/dev/null)" || error 'no se pudo renderizar el diagrama por transporte o HTTP'
printf '%s' "$response" | jq -ce '{imageUrl, createEraserFileUrl} | (.imageUrl | type == "string" and length > 0) and (.createEraserFileUrl | type == "string" and length > 0)' >/dev/null 2>&1 || error 'Eraser devolvio una respuesta incompleta'
printf '%s' "$response" | jq -c '{imageUrl, createEraserFileUrl}'
