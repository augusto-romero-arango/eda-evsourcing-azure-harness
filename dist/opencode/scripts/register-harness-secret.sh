#!/usr/bin/env bash
# register-harness-secret.sh -- registra metadatos de un secreto en
# .mefisto/harness.config.json > secrets[] (MEF-ADR-0025: nunca valores).
# Punto de entrada ejecutable sobre upsert_harness_secret (_pipeline-common.sh).
#
# Uso: register-harness-secret.sh <nombre> <output|github-secret|composite> <referencia>
set -euo pipefail

USO="Uso: register-harness-secret.sh <nombre> <output|github-secret|composite> <referencia>"

if [ $# -ne 3 ] || [ -z "$1" ] || [ -z "$3" ]; then
    echo "$USO" >&2
    exit 1
fi
case "$2" in
    output|github-secret|composite) ;;
    *)
        echo "$USO" >&2
        exit 1
        ;;
esac

_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$_REPO_TOP/.claude-plugin/plugin.json" ]; then
    echo "ERROR: register-harness-secret.sh es del plugin publicado y solo aplica al consumidor." >&2
    exit 1
fi
unset _REPO_TOP

source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"

upsert_harness_secret "$1" "$2" "$3"
