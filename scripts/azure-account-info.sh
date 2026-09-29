#!/usr/bin/env bash
# Expone la cuenta de Azure de la sesion 'az' activa como JSON de solo lectura.
# Ejecuta unicamente 'az account show'; nunca emite tokens ni secretos.
#
# Salida (stdout): {"subscriptionId","subscriptionName","tenantId","user"}
#
# Uso: ./scripts/azure-account-info.sh
# Prerequisito: az login

set -euo pipefail

# Guard defensivo: este script es del lado publicado y solo aplica al consumidor.
_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$_REPO_TOP/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/azure-account-info.sh es del plugin publicado y solo aplica al consumidor." >&2
    exit 1
fi
unset _REPO_TOP

_NO_SESSION_MSG="ERROR: no hay sesion de Azure activa. Ejecuta 'az login' y reintenta."

if ! command -v az >/dev/null 2>&1; then
    echo "$_NO_SESSION_MSG" >&2
    exit 1
fi

_RAW=$(az account show -o json 2>/dev/null) || {
    echo "$_NO_SESSION_MSG" >&2
    exit 1
}

_OUT=$(printf '%s' "$_RAW" | jq -e -c '{
    subscriptionId: .id,
    subscriptionName: .name,
    tenantId: .tenantId,
    user: (.user.name // "")
}' 2>/dev/null) || {
    echo "$_NO_SESSION_MSG" >&2
    exit 1
}

printf '%s\n' "$_OUT"
