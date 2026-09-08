#!/usr/bin/env bash
# Shim temporal de compatibilidad para consumidores internos (issue #1045).
# La implementación y el discovery canónicos viven en src/runtime/lib/.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)/src/runtime/lib/mefisto-runtime.sh"
