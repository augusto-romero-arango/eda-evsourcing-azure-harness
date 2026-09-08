#!/usr/bin/env bash
# Shim temporal de compatibilidad para los pipelines internos (issue #1045).
# La implementación canónica no pertenece al lado interno: vive en src/runtime/.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/src/runtime/mefisto-run-agent.sh" "$@"
