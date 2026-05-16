#!/usr/bin/env bash
# Provisiona el esquema de labels del proyecto en GitHub.
# Elimina los 9 labels default y crea el esquema dimensional.
#
# Los labels de dominio (dom:*) se leen de .claude/harness.config.json
# campo "domainLabels".
#
# Uso: ./scripts/setup-github-labels.sh
# Prerequisito: gh auth login

set -e

source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"

# Guard defensivo: este script es del lado publicado y solo aplica al consumidor.
# Si detectamos .claude-plugin/plugin.json en la raiz, estamos en el repo de Mefisto.
_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$_REPO_TOP/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/setup-github-labels.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Los labels de Mefisto se configuran manualmente o con un script interno." >&2
    exit 1
fi
unset _REPO_TOP

load_harness_config || exit 1

echo "Eliminando labels default de GitHub..."
for label in "documentation" "duplicate" "enhancement" "good first issue" "help wanted" "invalid" "question" "wontfix"; do
  gh label delete "$label" --yes 2>/dev/null && echo "  - eliminado: $label" || echo "  - no encontrado (ok): $label"
done

echo ""
echo "Creando labels de tipo (azul)..."
gh label create "tipo:feature"   --color "0052CC" --description "Funcionalidad nueva de dominio"
gh label create "tipo:infra"     --color "0052CC" --description "Infraestructura Azure / Terraform"
gh label create "tipo:refactor"  --color "0052CC" --description "Reestructuracion sin comportamiento nuevo"
gh label create "tipo:tooling"   --color "0052CC" --description "Mejoras a pipeline, agentes o scripts"

echo ""
echo "Creando labels de origen (naranja)..."
gh label create "bug"            --color "D93F0B" --description "Correccion de defecto — siempre acompanado de un tipo: que indica el pipeline" --force

echo ""
echo "Creando labels de dominio (verde) desde harness.config.json..."
for dom in $HARNESS_DOMAIN_LABELS; do
  gh label create "dom:${dom}" --color "0E8A16" --description "Dominio ${dom}" --force
done

echo ""
echo "Creando labels de estado (amarillo/rojo)..."
gh label create "estado:borrador" --color "FBCA04" --description "Idea capturada - requiere refinamiento antes del pipeline"
gh label create "estado:listo"    --color "B60205" --description "Refinado y listo para pipeline TDD o IaC"

echo ""
echo "Creando labels especiales..."
gh label create "bloqueado" --color "D93F0B" --description "Depende de otro issue aun no cerrado"

echo ""
echo "Listo. Labels actuales:"
gh label list
