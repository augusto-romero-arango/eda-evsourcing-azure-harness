#!/usr/bin/env bash
# set-harness-tenancy.sh -- Actualiza tenancy.strategy del contrato consumidor.
# Uso: set-harness-tenancy.sh --strategy <mono-tenant-transitorio|multi-tenant-header>

set -euo pipefail

usage() {
    echo "Uso: set-harness-tenancy.sh --strategy <mono-tenant-transitorio|multi-tenant-header>" >&2
    exit 1
}

[ "$#" -eq 2 ] && [ "$1" = "--strategy" ] || usage
STRATEGY="$2"
case "$STRATEGY" in
    mono-tenant-transitorio|multi-tenant-header) ;;
    *) usage ;;
esac

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: set-harness-tenancy.sh es del plugin publicado y solo aplica al consumidor." >&2
    exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"

CONFIG="$(resolve_harness_config_path write "$REPO_ROOT")" || exit 1
if ! load_harness_config >/dev/null; then
    echo "ERROR: el config efectivo no es valido. Corrigelo antes de escribir $CONFIG." >&2
    exit 1
fi
if [ "$HARNESS_CONFIG_PATH" != "$CONFIG" ]; then
    echo "ERROR: el config efectivo todavia es legacy ($HARNESS_CONFIG_PATH)." >&2
    echo "       Migra primero el config a $CONFIG; los escritores nuevos no modifican la ruta legacy." >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq no esta instalado. Requerido para escribir $CONFIG." >&2
    exit 1
fi

CURRENT="$(jq -r '.tenancy.strategy // "mono-tenant-transitorio"' "$CONFIG")"
if [ "$CURRENT" = "$STRATEGY" ]; then
    jq -cn --arg configPath "$CONFIG" --arg strategy "$STRATEGY" \
        '{schemaVersion: 1, configPath: $configPath, strategy: $strategy, changed: false}'
    exit 0
fi

STATE_TEMP="$(mefisto_state_path "set-harness-tenancy.XXXXXX")" || {
    echo "ERROR: no se pudo preparar el estado temporal del consumidor." >&2
    exit 1
}
CONFIG_DEVICE="$(stat -f '%d' "$(dirname "$CONFIG")" 2>/dev/null || stat -c '%d' "$(dirname "$CONFIG")")" || {
    echo "ERROR: no se pudo verificar el filesystem del config." >&2
    exit 1
}
STATE_DEVICE="$(stat -f '%d' "$(dirname "$STATE_TEMP")" 2>/dev/null || stat -c '%d' "$(dirname "$STATE_TEMP")")" || {
    echo "ERROR: no se pudo verificar el filesystem del temporal." >&2
    exit 1
}
if [ "$CONFIG_DEVICE" != "$STATE_DEVICE" ]; then
    echo "ERROR: no se puede asegurar una sustitucion atomica de $CONFIG." >&2
    exit 1
fi

TMP="$(mktemp "$STATE_TEMP")" || {
    echo "ERROR: no se pudo crear un temporal para actualizar $CONFIG." >&2
    exit 1
}
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

if ! jq --arg strategy "$STRATEGY" \
    '.tenancy = ((.tenancy // {}) + {strategy: $strategy})' "$CONFIG" > "$TMP"; then
    echo "ERROR: no se pudo preparar la actualizacion de $CONFIG." >&2
    exit 1
fi
if ! jq empty "$TMP" >/dev/null 2>&1; then
    echo "ERROR: la actualizacion preparada de $CONFIG no es JSON valido." >&2
    exit 1
fi
if ! mv "$TMP" "$CONFIG"; then
    echo "ERROR: no se pudo sustituir atomicamente $CONFIG; no se modifico el destino." >&2
    exit 1
fi
trap - EXIT

jq -cn --arg configPath "$CONFIG" --arg strategy "$STRATEGY" \
    '{schemaVersion: 1, configPath: $configPath, strategy: $strategy, changed: true}'
