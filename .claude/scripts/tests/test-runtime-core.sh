#!/usr/bin/env bash
# Shim de suite: la prueba canonica de la frontera comun vive en src/runtime/.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/src/runtime/tests/test-runtime-core.sh"
