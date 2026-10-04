#!/usr/bin/env bash
# test-install-apim-config-path.sh -- El flip rehidrata el resultado del setter.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
COMMAND="$REPO_ROOT/src/published/commands/install-apim.md"

required=(
    '{{mefisto:run set-harness-tenancy.sh --strategy multi-tenant-header}}'
    "CONFIG=\$(printf '%s' \"\$SETTER_RESULT\" | jq -er '.configPath')"
    "TENANCY_TOKEN_FLIPPED=\$(printf '%s' \"\$SETTER_RESULT\" | jq -r 'if (.changed | type) == \"boolean\" then .changed else error(\"changed debe ser booleano\") end')"
    'git add "$CONFIG"'
)
for marker in "${required[@]}"; do
    grep -Fq "$marker" "$COMMAND" || { echo "FAIL: falta $marker" >&2; exit 1; }
done
if grep -Fq 'source "$COMMON"' "$COMMAND" || grep -Fq 'TMP=$(mktemp)' "$COMMAND"; then
    echo 'FAIL: install-apim conserva el escritor duplicado' >&2
    exit 1
fi
echo 'PASS: install-apim rehidrata configPath/changed y conserva el staging condicional'
exec bash "$HERE/test-set-harness-tenancy.sh"
