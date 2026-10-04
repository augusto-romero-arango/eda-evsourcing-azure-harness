#!/usr/bin/env bash
# test-onboard-tenancy-write.sh -- El paso 6 delega el setter publicado.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
COMMAND="$REPO_ROOT/src/published/commands/onboard.md"

if grep -Fq '{{mefisto:run set-harness-tenancy.sh --strategy <mono-tenant-transitorio|multi-tenant-header>}}' "$COMMAND" \
    && ! grep -Fq 'source "$COMMON"' "$COMMAND"; then
    echo 'PASS: onboard delega tenancy.strategy al setter publicado'
else
    echo 'FAIL: onboard no delega exclusivamente al setter publicado' >&2
    exit 1
fi

exec bash "$HERE/test-set-harness-tenancy.sh"
