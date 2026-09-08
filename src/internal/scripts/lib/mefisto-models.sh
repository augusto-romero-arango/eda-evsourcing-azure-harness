#!/usr/bin/env bash
# Shim temporal hasta #1046. La implementacion y el contrato viven en
# src/runtime/; este lado conserva solo la carga para callers internos legados.

_mefisto_internal_models_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_mefisto_internal_models_dir/../../../runtime/lib/mefisto-models.sh"
unset _mefisto_internal_models_dir

# Compatibilidad de firma hasta #1046: los callers legados entregaban la ruta
# mediante MEFISTO_MODELS_FILE. El nucleo siempre recibe una ruta explicita.
mefisto_resolve_model() {
    _mefisto_models_resolve "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-${MEFISTO_MODELS_FILE:-}}"
}
