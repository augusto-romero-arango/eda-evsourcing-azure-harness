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
    'CONFIG="<SETTER_CONFIG_PATH exacto devuelto por el setter en 9.2>"'
    'TENANCY_TOKEN_FLIPPED="<SETTER_CHANGED exacto devuelto por el setter en 9.2>"'
    'git add "$CONFIG"'
)
for marker in "${required[@]}"; do
    grep -Fq "$marker" "$COMMAND" || { echo "FAIL: falta $marker" >&2; exit 1; }
done
if grep -Fq 'source "$COMMON"' "$COMMAND" || grep -Fq 'TMP=$(mktemp)' "$COMMAND"; then
    echo 'FAIL: install-apim conserva el escritor duplicado' >&2
    exit 1
fi
STEP10="$(awk '
    $0 == "### 10. Commitear la migracion de tenancy" { found=1; next }
    found && /^```bash$/ { inside=1; next }
    found && inside && /^```$/ { exit }
    inside { print }
' "$COMMAND")"
if grep -Fq 'CONFIG="<SETTER_CONFIG_PATH exacto devuelto por el setter en 9.2>"' <<< "$STEP10" \
    && grep -Fq 'TENANCY_TOKEN_FLIPPED="<SETTER_CHANGED exacto devuelto por el setter en 9.2>"' <<< "$STEP10"; then
    echo 'PASS: install-apim rehidrata configPath/changed en el bloque que los consume'
else
    echo 'FAIL: install-apim depende de variables de un shell anterior' >&2
    exit 1
fi
