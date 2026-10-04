#!/usr/bin/env bash
# Contrato del catálogo de roles controlados y del manifest OpenCode.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
CATALOG="$REPO_ROOT/src/published/contract/agent-execution.json"
MANIFEST="$REPO_ROOT/dist/opencode/agent-execution-manifest.json"
NUGET_FIXTURE="$HERE/fixtures/agent-execution/nuget-roles.json"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

printf '[catalogo] ids, ownership y recursos\n'
jq -e '
  .schemaVersion == 1 and
  (.roles | length == 22 and (map(.id) | length == (unique | length))) and
  ([.roles[].id] | sort) == ["apim-gateway-scaffolder","bug-investigator","domain-scaffolder","historiador","implementer","infra-base-scaffolder","infra-bootstrap","infra-reviewer","infra-writer","mcp-scaffolder","planner","pr-sync","projection-implementer","projection-test-writer","projections-scaffolder","reviewer","smoke-test-writer","test-writer","tooling-investigator","tooling-reviewer","tooling-writer","workos-identity-scaffolder"] and
  all(.roles[]; .resources[0:4] == ["project","release","state","runtime-tool-output"] and (.writeScope == "project" or .writeScope == "none")) and
  .pipelines == {tdd:["test-writer","implementer","projection-test-writer","projection-implementer","smoke-test-writer","reviewer","domain-scaffolder"],tooling:["tooling-writer","tooling-reviewer"],iac:["infra-writer","infra-reviewer"],scaffold:["domain-scaffolder"]} and
  .roots == {implement:["tdd"],tooling:["tooling"],infra:["iac"],scaffold:["scaffold"],sequential:["tdd","tooling","iac"],parallel:["tdd","tooling","iac"]}
' "$CATALOG" >/dev/null && pass 'catalogo declara exactamente los 22 roles y las tablas cerradas' || fail 'catalogo de roles incompleto o divergente'
jq -e --slurpfile expected "$NUGET_FIXTURE" '(.roles | map(select(.resources | index("nuget-packages")) | .id) | sort) == ($expected[0] | sort) and all(.roles[]; ((.id != "infra-bootstrap" and .id != "pr-sync") or .writeScope == "none"))' "$CATALOG" >/dev/null && pass 'fixture separa NuGet requerido de roles shell-only' || fail 'recursos NuGet o roles shell-only divergentes'

printf '[manifest] renderer actual y politica propia\n'
bash "$GENERATOR" --check >/dev/null 2>&1 && pass 'salidas generadas estan sincronizadas' || fail 'salidas generadas no estan sincronizadas'
jq -e --slurpfile catalog "$CATALOG" '
  .schemaVersion == 1 and .catalogFingerprint != "" and
  (.roles | length == 22 and (map(.id) | length == (unique | length))) and
  ([.roles[].id] | sort) == ($catalog[0].roles | map(.id) | sort) and
  all(.roles[]; .alias == ("autonomy-" + .id) and .hidden == true and .mode == "all" and .question == "deny" and (.sourceDigest | test("^[0-9a-f]{64}$")) and (.metadata | keys == ["mode","permission","skills","tools"]))
' "$MANIFEST" >/dev/null && pass 'manifest deriva alias, digest y metadata de cada rol' || fail 'manifest de ejecucion invalido'
printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
