#!/usr/bin/env bash
# Pruebas aisladas de la biblioteca pura de politica efectiva (issue #1838).
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
LIB="$REPO_ROOT/src/published/scripts/adapters/lib"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
run() { jq -L "$LIB" 'include "opencode-entry-permissions"; entry_permissions'; }
assert() { local name="$1" filter="$2" input="$3"; if printf '%s' "$input" | run | jq -e "$filter" >/dev/null; then pass "$name"; else fail "$name"; fi; }

printf '%s\n' '[normalizacion y matcher]'
raw='{"action":"normalize","home":"/home/uno","policy":{"tools":{"write":true,"patch":false},"permission":{"edit":{"*":"allow","a":"deny"}}}}'
assert 'tools legacy converge en edit y permission explicito prevalece' '[.rules[] | select(.permission == "edit")] | length == 4 and .[-1].value == "deny"' "$raw"
for case in \
  '{"pattern":"git *","candidate":"git"}' \
  '{"pattern":"git *","candidate":"git status"}' \
  '{"pattern":"a/*","candidate":"a/b/c"}' \
  '{"pattern":"a?c","candidate":"añc"}' \
  '{"pattern":"\\home\\uno\\x","candidate":"/home/uno/x"}' \
  '{"pattern":"$HOME/x","candidate":"/home/uno/x"}' \
  '{"pattern":"\"literal\"","candidate":"\"literal\""}'; do
  input="{\"action\":\"evaluate\",\"home\":\"/home/uno\",\"policy\":{\"rules\":[{\"permission\":\"bash\",\"pattern\":$(jq -c .pattern <<<"$case"),\"value\":\"allow\"}]},\"candidates\":[{\"permission\":\"bash\",\"candidate\":$(jq -c .candidate <<<"$case")}] }"
  assert 'matcher documentado acepta el candidato' '.decisions[0].decision == "allow"' "$input"
done

printf '%s\n' '[composicion sin ampliacion]'
compose='{"action":"compose","home":"/h","managed":{"permission":{"edit":{"safe/*":"allow","blocked/*":"deny"}}},"global":{"permission":{"edit":{"*":"deny","safe/ok":"allow"},"read":{"*":"allow"}}}}'
assert 'deny global y excepcion posterior conservan ultima coincidencia' '(.conflicts == []) and (.policy.rules | length > 0)' "$compose"
decisions='{"action":"evaluate","home":"/h","policy":{"rules":[{"permission":"edit","pattern":"safe/*","value":"allow"},{"permission":"edit","pattern":"safe/ok","value":"allow"},{"permission":"edit","pattern":"blocked/*","value":"deny"}]},"candidates":[{"permission":"edit","candidate":"safe/ok"},{"permission":"edit","candidate":"blocked/x"}]}'
assert 'ultima coincidencia permite la excepcion y conserva deny inverso' '[.decisions[].decision] == ["allow","deny"]' "$decisions"
unsupported='{"action":"compose","home":"/h","managed":{"permission":{"edit":{"a?c":"allow"}}},"global":{"permission":{"edit":{"ab*":"deny"}}}}'
assert 'interseccion glob no representable falla cerrado' '.conflicts | any(.code == "policy-not-representable")' "$unsupported"
serial='{"action":"serialize","rules":[{"pattern":"a","value":"deny"},{"pattern":"b","value":"allow"},{"pattern":"a","value":"allow"}]}'
assert 'serializacion desplaza la ultima clave repetida al final' '.permission | keys_unsorted == ["b","a"] and .a == "allow"' "$serial"

printf '%s\n' '[sesion y diagnosticos no sensibles]'
session='{"action":"certify-session","home":"/h","consent":true,"managed":{"permission":{"edit":{"safe":"allow"}}},"session":[{"permission":"edit","pattern":"safe","value":"allow"}],"required":[{"permission":"edit","candidate":"safe"}]}'
assert 'sesion observada no amplia una operacion gestionada' '.accepted == true' "$session"
assert 'grant de sesion no demostrable se rechaza' '.accepted == false and (.conflicts | any(.code == "session-grant-not-provable"))' '{"action":"certify-session","home":"/h","consent":true,"managed":{"permission":{"edit":{"safe":"allow"}}},"session":[{"permission":"edit","pattern":"other","value":"allow"}],"required":[]}'
assert 'sin consentimiento se rechaza sin incluir el centinela' '(.accepted == false) and ((.conflicts | tostring | contains("SECRETO-1838")) | not)' '{"action":"certify-session","consent":false,"managed":{},"session":[],"required":[{"permission":"edit","candidate":"SECRETO-1838"}]}'
assert 'sesion ausente se diagnostica' '.conflicts[0].code == "session-not-observed"' '{"action":"certify-session","consent":true,"managed":{},"session":null,"required":[]}'

printf '\n%s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
