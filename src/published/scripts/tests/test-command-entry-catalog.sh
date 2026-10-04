#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/../../../.." && pwd -P)"
FILTER="$ROOT/src/published/scripts/lib/command-entry.jq"
MATRIX="$ROOT/src/published/contract/command-entry.json"
ADAPTER="$ROOT/src/published/scripts/adapters/adapter-opencode.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }
catalog_input() {
  jq -n --slurpfile matrix "$MATRIX" --arg root "$ROOT" '
    {matrix:$matrix[0], commands:[ $matrix[0].commands[] | {id,body:("{{mefisto:assert-consumer-repo}}\n" + ([.composes[] | "{{mefisto:command-doc " + . + "}}"] | join("\n")) + "\n" + ([.delegates[] | "{{mefisto:launch-agent " + . + " mensaje}}"] | join("\n")))}], agents:["historiador","bug-investigator","tooling-investigator","infra-base-scaffolder","apim-gateway-scaffolder","workos-identity-scaffolder","mcp-scaffolder","projections-scaffolder"]}'
}
printf '%s\n' '[catalogo]'
out="$(catalog_input | jq -c -f "$FILTER")"; rc=$?
[ "$rc" -eq 0 ] && [ "$(jq '.commands | length' <<< "$out")" -eq 27 ] && pass 'las 27 filas forman un catalogo cerrado' || fail 'catalogo de 27 filas'
jq -e '.commands[] | select(.id == "bitacora") | .closure.commands == ["bitacora","merge"]' <<< "$out" >/dev/null && pass 'bitacora compone merge sin heredar delegados' || fail 'clausura de bitacora'
jq -e '.commands[] | select(.id == "install-auth") | (.closure.commands | index("seed-secret")) and (.closure.commands | index("install-workos")) and (.closure.commands | index("install-apim"))' <<< "$out" >/dev/null && pass 'install-auth alcanza seed-secret por composicion transitiva' || fail 'clausura de install-auth'
jq -e '.commands[] | select(.id == "onboard") | .closure.commands | index("scaffold-projections")' <<< "$out" >/dev/null && pass 'onboard alcanza scaffold-projections' || fail 'clausura de onboard'
bad="$(catalog_input | jq '.matrix.commands[0].composes=["ausente"]')"
printf '%s' "$bad" | jq -e -f "$FILTER" >/dev/null 2>&1; [ "$?" -ne 0 ] && pass 'target faltante falla cerrado' || fail 'target faltante'
manifest="$($ADAPTER render-asset command-entry-manifest "$MATRIX")"; rc=$?
[ "$rc" -eq 0 ] && jq -e '(.templates | length == 27) and (.delegatedPrompts | length > 0) and (.catalogFingerprint | test("^[0-9a-f]{64}$"))' <<< "$manifest" >/dev/null && pass 'manifest identifica templates y prompts por hash' || fail 'manifest de ownership'
[ "$FAIL" -eq 0 ] && exit 0
exit 1
