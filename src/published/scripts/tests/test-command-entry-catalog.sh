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
  local commands='[]' agents='[]' file id body
  for file in "$ROOT"/src/published/commands/*.md; do
    id="$(basename "$file" .md)"
    body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$file")"
    commands="$(jq -cn --argjson prior "$commands" --arg id "$id" --arg body "$body" '$prior + [{id:$id,body:$body}]')"
  done
  for file in "$ROOT"/src/published/agents/*.md; do
    agents="$(jq -cn --argjson prior "$agents" --arg id "$(basename "$file" .md)" '$prior + [$id]')"
  done
  jq -cn --slurpfile matrix "$MATRIX" --argjson commands "$commands" --argjson agents "$agents" '{matrix:$matrix[0],commands:$commands,agents:$agents}'
}
printf '%s\n' '[catalogo]'
out="$(catalog_input | jq -c -f "$FILTER")"; rc=$?
[ "$rc" -eq 0 ] && [ "$(jq '.commands | length' <<< "$out")" -eq 27 ] && pass 'las 27 filas forman un catalogo cerrado' || fail 'catalogo de 27 filas'
jq -e '.commands[] | select(.id == "bitacora") | .closure.commands == ["bitacora","merge"] and .closure.delegates == ["historiador"] and .closure.capabilities == ["read","shell","task"]' <<< "$out" >/dev/null && pass 'bitacora compone merge sin heredar capacidades del delegado' || fail 'clausura de bitacora'
jq -e '.commands[] | select(.id == "install-auth") | .closure.commands == ["install-apim","install-auth","install-workos","seed-secret"] and .closure.delegates == ["apim-gateway-scaffolder","workos-identity-scaffolder"]' <<< "$out" >/dev/null && pass 'install-auth alcanza seed-secret y ambos scaffolders' || fail 'clausura de install-auth'
jq -e '.commands[] | select(.id == "onboard") | .closure.commands == ["onboard","scaffold-projections"] and .closure.delegates == ["projections-scaffolder"]' <<< "$out" >/dev/null && pass 'onboard alcanza projections-scaffolder' || fail 'clausura de onboard'
jq -e 'all(.commands[]; .resources[0:4] == ["project","release","state","runtime-tool-output"]) and ([.commands[] | select(.writeScope == "none") | .resources | index("state")] | all)' <<< "$out" >/dev/null && pass 'state es recurso legible base sin conceder escritura' || fail 'recursos base y escritura'
jq -e '.commands[] | select(.id == "runtimes") | .executionClass == {kind:"by-operation",parser:"runtimes-v1"}' <<< "$out" >/dev/null && pass 'runtimes declara parser cerrado' || fail 'parser runtimes'
classify() { jq -cn --arg command "$1" --arg arguments "$2" '{classification:{commandId:$command,arguments:$arguments}}' | jq -c -f "$FILTER"; }
for case in 'runtimes|' 'runtimes|status' 'upgrade|--status'; do command="${case%%|*}"; arguments="${case#*|}"; [ "$(classify "$command" "$arguments")" = '{"kind":"execute","operation":"query"}' ] && pass "consulta canonica $command ${arguments:-sin argumentos}" || fail "consulta canonica $command"; done
for case in 'runtimes|enable opencode' 'runtimes|disable opencode' 'upgrade|' 'upgrade|--align-peer'; do command="${case%%|*}"; arguments="${case#*|}"; [ "$(classify "$command" "$arguments")" = '{"kind":"maintenance","operation":"mutate"}' ] && pass "mutacion canonica $command ${arguments:-sin argumentos}" || fail "mutacion canonica $command"; done
[ "$(classify upgrade '--prune --keep 2 --loaded 1.2.3')" = '{"kind":"execute","operation":"prune"}' ] && pass 'poda canonica clasificada sin ejecutar shell' || fail 'poda canonica'
for case in 'runtimes|enable opencode enable opencode' 'runtimes|status enable opencode' 'runtimes|enable claude' 'upgrade|--status --prune' 'upgrade|--prune --prune' 'upgrade|--unknown' 'upgrade|--prune --loaded 1.2.3 --keep 2' 'upgrade|--prune; touch $WORK/no-ejecutar'; do command="${case%%|*}"; arguments="${case#*|}"; classify "$command" "$arguments" >/dev/null 2>&1; [ "$?" -ne 0 ] && pass "forma rechazada $command" || fail "forma aceptada indebidamente $command"; done
classify desconocido '' >/dev/null 2>&1; [ "$?" -ne 0 ] && pass 'id ajeno al inventario falla cerrado' || fail 'id desconocido aceptado'
jq -cn '{classification:{commandId:"runtimes",arguments:"status",extra:true}}' | jq -e -f "$FILTER" >/dev/null 2>&1; [ "$?" -ne 0 ] && pass 'request de clasificacion con campos extra falla cerrado' || fail 'request abierto'
jq -cn '{classification:{commandId:"runtimes",arguments:["status"]}}' | jq -e -f "$FILTER" >/dev/null 2>&1; [ "$?" -ne 0 ] && pass 'argv no textual falla cerrado' || fail 'argv no textual aceptado'
[ ! -e "$WORK/no-ejecutar" ] && pass 'el payload hostil se clasifica como datos sin ejecutar shell' || fail 'el clasificador ejecuto el payload'
bad="$(catalog_input | jq '.matrix.commands[0].composes=["ausente"]')"
printf '%s' "$bad" | jq -e -f "$FILTER" >/dev/null 2>&1; [ "$?" -ne 0 ] && pass 'target faltante falla cerrado' || fail 'target faltante'
bad="$(catalog_input | jq '.matrix.commands[0].composes=["batch-stop"]')"
printf '%s' "$bad" | jq -e -f "$FILTER" >/dev/null 2>&1; [ "$?" -ne 0 ] && pass 'ciclo falla cerrado' || fail 'ciclo'
bad="$(catalog_input | jq '.matrix.commands[0].extra=true')"
printf '%s' "$bad" | jq -e -f "$FILTER" >/dev/null 2>&1; [ "$?" -ne 0 ] && pass 'campo desconocido falla cerrado' || fail 'campo desconocido'
bad="$(catalog_input | jq '.matrix.commands += [.matrix.commands[0]]')"
printf '%s' "$bad" | jq -e -f "$FILTER" >/dev/null 2>&1; [ "$?" -ne 0 ] && pass 'id duplicado falla cerrado' || fail 'id duplicado'
bad="$(catalog_input | jq 'del(.matrix.commands[0])')"
printf '%s' "$bad" | jq -e -f "$FILTER" >/dev/null 2>&1; [ "$?" -ne 0 ] && pass 'comando sin fila falla cerrado' || fail 'comando sin fila'
informative="$(catalog_input | jq '(.commands[] | select(.id == "draft") | .body) += "\n{{mefisto:command merge}}"' | jq -c -f "$FILTER")"
jq -e '.commands[] | select(.id == "draft") | .closure.commands == ["draft"]' <<< "$informative" >/dev/null && pass 'mencion informativa no compone comandos' || fail 'mencion informativa'
manifest="$($ADAPTER render-asset command-entry-manifest "$MATRIX")"; rc=$?
[ "$rc" -eq 0 ] && jq -e '(.templates | length == 27) and (.delegatedPrompts | length > 0) and (.catalogFingerprint | test("^[0-9a-f]{64}$")) and all(.templates[]; .nativeBinding == {commandEntryId:.id,subtask:false} and .legacyBinding == {commandEntryId:.id,subtask:false})' <<< "$manifest" >/dev/null && pass 'manifest identifica templates, prompts y binding observado' || fail 'manifest de ownership'
source "$ADAPTER"
fixture_root="$ROOT/src/published/scripts/tests/fixtures/command-entry"
before_binding="$(native_command_binding < "$fixture_root/before-header.md")"
native_binding="$(native_command_binding < "$fixture_root/native-header.md")"
[ "$before_binding" = 'null' ] && [ "$native_binding" = '{"commandEntryId":"batch-stop","subtask":false}' ] && pass 'binding nativo distingue ausencia y header sintetico completo' || fail 'binding nativo sintetico'
fixture_marker='<!-- fixture -->'
before_rendered="$(render "$fixture_root/before-header.md" "$fixture_marker")"
override_rendered="$(render "$fixture_root/native-header-override.md" "$fixture_marker")"
before_hash="$(printf '%s' "$before_rendered" | body /dev/stdin | trimmed_sha256)"
override_hash="$(printf '%s' "$override_rendered" | body /dev/stdin | trimmed_sha256)"
[ "$(printf '%s\n' "$before_rendered" | native_command_binding)" = '{"commandEntryId":"before-header","subtask":false}' ] && [ "$(printf '%s\n' "$override_rendered" | native_command_binding)" = '{"commandEntryId":"native-header-override","subtask":false}' ] && [ "$before_hash" = "$override_hash" ] && pass 'renderer restaura ownership e ignora override neutral sin alterar el body' || fail 'ownership del renderer'
printf '%s\n' '---' 'agent: "command-entry-batch-stop"' '---' | native_command_binding >/dev/null 2>&1; [ "$?" -ne 0 ] && pass 'metadata nativa parcial falla cerrado' || fail 'metadata parcial aceptada'
expected="$(printf 'uno\r\ndos' | shasum -a 256 | awk '{print $1}')"
actual="$(printf ' \r\nuno\r\ndos\r\n ' | trimmed_sha256)"
[ "$actual" = "$expected" ] && pass 'hash reproduce trim y preserva CRLF interior' || fail 'semantica trim/CRLF'
changed="$(printf 'uno\r\nDOS' | trimmed_sha256)"
[ "$changed" != "$actual" ] && pass 'modificar el cuerpo cambia su identidad' || fail 'identidad ante cambio real'
source_file="$ROOT/src/published/commands/batch-stop.md"
marker='<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/batch-stop.md. No editar a mano. -->'
rendered="$($ADAPTER render "$source_file" "$marker")"
rendered_hash="$(printf '%s' "$rendered" | body /dev/stdin | trimmed_sha256)"
manifest_hash="$(jq -r '.templates[] | select(.id == "batch-stop") | .sha256' <<< "$manifest")"
[ "$rendered_hash" = "$manifest_hash" ] && pass 'manifest identifica el contenido realmente distribuido' || fail 'hash del template distribuido'
agent_source="$ROOT/src/published/agents/historiador.md"
agent_marker='<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/agents/historiador.md. No editar a mano. -->'
agent_rendered="$($ADAPTER render "$agent_source" "$agent_marker")"
agent_hash="$(printf '%s' "$agent_rendered" | body /dev/stdin | trimmed_sha256)"
delegated_hash="$(jq -r '.delegatedPrompts[] | select(.command == "bitacora" and .agent == "historiador") | .sha256' <<< "$manifest")"
[ "$agent_hash" = "$delegated_hash" ] && pass 'manifest identifica el prompt delegado distribuido' || fail 'hash del prompt delegado'
[ "$FAIL" -eq 0 ] && exit 0
exit 1
