#!/usr/bin/env bash
# Compatibilidad temporal: el contrato canonico se prueba en src/runtime/.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT/src/internal/scripts/lib/mefisto-models.sh"
declare -F mefisto_resolve_model >/dev/null
exec bash "$ROOT/src/runtime/tests/test-models.sh"
