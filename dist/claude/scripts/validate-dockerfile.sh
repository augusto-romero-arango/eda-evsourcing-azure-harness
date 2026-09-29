#!/usr/bin/env bash
# validate-dockerfile.sh -- validacion opcional y no bloqueante del Dockerfile del
# worker de proyecciones (issue #1652). Uso: validate-dockerfile.sh <ruta-relativa-al-Dockerfile>
#
# Alcance acotado (MEF-ADR-0031): solo ejecuta `docker info` y
# `docker build -f <ruta> -t projections-worker-check <raiz-del-repo>`; nunca push, run ni otros subcomandos.
# La ruta debe ser relativa, sin `..` y quedar bajo `src/` del toplevel del consumidor
# tambien tras resolver symlinks.
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"

_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$_REPO_TOP/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/validate-dockerfile.sh es del plugin publicado y solo aplica al consumidor." >&2
    exit 1
fi

USO="Uso: validate-dockerfile.sh <ruta-relativa-al-Dockerfile> (bajo src/)"
if [ $# -ne 1 ] || [ -z "$1" ]; then
    echo "$USO" >&2
    exit 1
fi
DOCKERFILE="$1"

case "$DOCKERFILE" in
    /*) echo "ERROR: la ruta debe ser relativa al repo, no absoluta: $DOCKERFILE" >&2; exit 1 ;;
    src/*) ;;
    *) echo "ERROR: la ruta debe estar bajo src/: $DOCKERFILE" >&2; exit 1 ;;
esac
case "/$DOCKERFILE/" in
    */../*|*//*|*/./*) echo "ERROR: la ruta no admite segmentos '..', '.' ni vacios: $DOCKERFILE" >&2; exit 1 ;;
esac

_REPO_TOP=$(cd "$_REPO_TOP" && pwd -P) || exit 1
cd "$_REPO_TOP" || exit 1
if [ ! -f "$DOCKERFILE" ]; then
    echo "ERROR: no existe el Dockerfile: $DOCKERFILE" >&2
    exit 1
fi
_DIR_FISICO=$(cd "$(dirname "$DOCKERFILE")" && pwd -P) || exit 1
_BASE_FISICO=$(basename "$DOCKERFILE")
[ -L "$DOCKERFILE" ] && _DIR_FISICO=""
case "$_DIR_FISICO/$_BASE_FISICO" in
    "$_REPO_TOP"/src/*) ;;
    *) echo "ERROR: el Dockerfile resuelto queda fuera de src/ del repo: $DOCKERFILE" >&2; exit 1 ;;
esac

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "docker no disponible: validacion del Dockerfile pendiente manual"
    exit 0
fi

LOG="$(mefisto_state_path logs/projections-docker-build.log "$_REPO_TOP")" || exit 1
docker build -f "$DOCKERFILE" -t projections-worker-check "$_REPO_TOP" > "$LOG" 2>&1
rc=$?
echo "docker build exit=$rc"
tail -20 "$LOG"
exit 0
