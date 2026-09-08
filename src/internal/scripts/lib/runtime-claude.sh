#!/usr/bin/env bash
# Shim temporal de compatibilidad; el adaptador canónico vive en src/runtime/.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)/src/runtime/lib/runtime-claude.sh"
