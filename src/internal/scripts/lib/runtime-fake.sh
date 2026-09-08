#!/usr/bin/env bash
# Shim temporal de compatibilidad; el adaptador canónico vive en src/runtime/.
_mefisto_runtime_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    exec "$_mefisto_runtime_root/src/runtime/lib/runtime-fake.sh" "$@"
fi
source "$_mefisto_runtime_root/src/runtime/lib/runtime-fake.sh"
unset _mefisto_runtime_root
