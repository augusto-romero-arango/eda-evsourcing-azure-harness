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
raw='{"action":"normalize","home":"/home/uno","policy":{"tools":{"write":true,"patch":false},"permission":{"edit":{"*":"allow","a":"deny"},"apply_patch":"deny"}}}'
assert 'tools legacy convergen en edit y permission explicito queda despues' '[.rules[] | select(.permission == "edit")] | length == 5 and .[-1].value == "deny"' "$raw"
assert 'permission escalar se representa con wildcard universal' '.rules | any(.permission == "edit" and .pattern == "*" and .value == "deny")' "$raw"
assert 'valor invalido rechaza toda normalizacion parcial' '.rules == [] and (.conflicts | any(.code == "policy-not-representable"))' '{"action":"normalize","policy":{"permission":{"edit":{"safe":"allow","bad":"invalid"}}}}'
for case in \
  '{"pattern":"git *","candidate":"git"}' \
  '{"pattern":"git *","candidate":"git status"}' \
  '{"pattern":"a/*","candidate":"a/b/c"}' \
  '{"pattern":"a?c","candidate":"añc"}' \
  '{"pattern":"\\home\\uno\\x","candidate":"/home/uno/x"}' \
  '{"pattern":"$HOME/x","candidate":"/home/uno/x"}' \
  '{"pattern":"$HOME","candidate":"/home/uno"}' \
  '{"pattern":"~","candidate":"/home/uno"}' \
  '{"pattern":"[x].+","candidate":"[x].+"}' \
  '{"pattern":"\"literal\"","candidate":"\"literal\""}'; do
  input="{\"action\":\"evaluate\",\"home\":\"/home/uno\",\"policy\":{\"rules\":[{\"permission\":\"bash\",\"pattern\":$(jq -c .pattern <<<"$case"),\"value\":\"allow\"}]},\"candidates\":[{\"permission\":\"bash\",\"candidate\":$(jq -c .candidate <<<"$case")}] }"
  assert 'matcher documentado acepta el candidato' '.decisions[0].decision == "allow"' "$input"
done
assert 'ultima coincidencia permite despues de deny general' '[.decisions[].decision] == ["allow","deny"]' '{"action":"evaluate","policy":{"rules":[{"permission":"bash","pattern":"*","value":"deny"},{"permission":"bash","pattern":"git *","value":"allow"}]},"candidates":[{"permission":"bash","candidate":"git"},{"permission":"bash","candidate":"other"}]}'
assert 'ultima coincidencia deniega despues de allow general' '.decisions[0].decision == "deny"' '{"action":"evaluate","policy":{"rules":[{"permission":"bash","pattern":"*","value":"allow"},{"permission":"bash","pattern":"git *","value":"deny"}]},"candidates":[{"permission":"bash","candidate":"git status"}]}'
assert 'write se evalua mediante el control edit' '.decisions[0].permission == "edit" and .decisions[0].decision == "deny"' '{"action":"evaluate","policy":{"rules":[{"permission":"edit","pattern":"*","value":"deny"}]},"candidates":[{"permission":"write","candidate":"x"}]}'

assert 'literal que no casa con un glob es disjunto y no ambiguo' '.conflicts == [] and ([.policy.rules[] | select(.permission == "bash")] | length) == 1' '{"action":"compose","managed":{"permission":{"bash":{"run exact":"allow"}}},"global":{"permission":{"bash":{"*":"allow","rm *":"deny"}}}}'
printf '%s\n' '[composicion sin ampliacion]'
compose='{"action":"compose","home":"/h","managed":{"permission":{"edit":{"safe/*":"allow","blocked/*":"deny"}}},"global":{"permission":{"edit":{"*":"deny","safe/ok":"allow"},"read":{"*":"allow"}}}}'
assert 'deny global y excepcion posterior se materializan en orden' '.conflicts == [] and [.policy.rules[] | select(.permission == "edit") | .value] == ["allow","deny","allow","deny"]' "$compose"
assert 'politica global desconocida no concede fuera de M' '([.policy.rules[] | select(.permission == "read")] | length) == 0' "$compose"
composed_policy="$(printf '%s' "$compose" | run | jq -c '.policy')"
corpus="$(jq -cn --argjson policy "$composed_policy" '{action:"evaluate",policy:$policy,candidates:[{permission:"edit",candidate:"safe/ok"},{permission:"edit",candidate:"safe/no"},{permission:"edit",candidate:"blocked/x"},{permission:"read",candidate:"safe/ok"}]}')"
assert 'corpus conserva deny ganador y nunca concede fuera de M' '[.decisions[].decision] == ["allow","deny","deny","ask"]' "$corpus"
inverse='{"action":"compose","managed":{"permission":{"edit":"allow"}},"global":{"permission":{"edit":{"safe/*":"allow","safe/no":"deny"}}}}'
inverse_policy="$(printf '%s' "$inverse" | run | jq -c '.policy')"
assert 'deny global posterior prevalece sobre allow anterior' '[.decisions[].decision] == ["allow","deny"]' "$(jq -cn --argjson policy "$inverse_policy" '{action:"evaluate",policy:$policy,candidates:[{permission:"edit",candidate:"safe/ok"},{permission:"edit",candidate:"safe/no"}]}')"
assert 'dos prefijos solapados producen el mas estrecho' '.conflicts == [] and (.policy.rules | any(.pattern == "safe/sub*" and .value == "deny"))' '{"action":"compose","managed":{"permission":{"edit":{"safe/*":"allow"}}},"global":{"permission":{"edit":{"safe/sub*":"deny"}}}}'
assert 'literal contenido se materializa exactamente' '.conflicts == [] and (.policy.rules | any(.pattern == "safe/x" and .value == "deny"))' '{"action":"compose","managed":{"permission":{"edit":{"safe/*":"allow"}}},"global":{"permission":{"edit":{"safe/x":"deny"}}}}'
assert 'prefijos disjuntos no agregan filas' '.conflicts == [] and (.policy.rules | length == 1)' '{"action":"compose","managed":{"permission":{"edit":{"safe/*":"allow"}}},"global":{"permission":{"edit":{"other/*":"deny"}}}}'
assert 'interseccion glob no representable rechaza toda politica parcial' '.policy == null and (.conflicts | any(.code == "policy-not-representable" and .permission == "edit" and .rule_index == 0))' '{"action":"compose","managed":{"permission":{"edit":{"a?c":"allow"}}},"global":{"permission":{"edit":{"ab*":"deny"}}}}'
assert 'ask solo se convierte con consentimiento vigente y dentro de M' '.policy.rules == [{"permission":"edit","pattern":"safe/*","value":"allow","index":0},{"permission":"edit","pattern":"safe/*","value":"allow","index":0}]' '{"action":"compose","consent":true,"managed":{"permission":{"edit":{"safe/*":"allow"}}},"global":{"permission":{"edit":"ask"}}}'
assert 'auto no sustituye el consentimiento para ask' '.policy.rules[-1].value == "ask"' '{"action":"compose","auto":true,"managed":{"permission":{"edit":{"safe/*":"allow"}}},"global":{"permission":{"edit":"ask"}}}'
serial='{"action":"serialize","rules":[{"pattern":"a","value":"deny"},{"pattern":"b","value":"allow"},{"pattern":"a","value":"allow"}]}'
assert 'serializacion desplaza la ultima clave repetida al final' '.permission | keys_unsorted == ["b","a"] and .a == "allow"' "$serial"

limit_input="$(jq -cn '{action:"compose",managed:{permission:{edit:(reduce range(0;1025) as $i ({}; .[("p"+($i|tostring))]="allow"))}},global:{permission:{}}}')"
assert 'limite excedido rechaza sin politica parcial' '.policy == null and (.conflicts | any(.code == "policy-expansion-limit" and .permission == "edit"))' "$limit_input"

printf '%s\n' '[sesion y diagnosticos no sensibles]'
session='{"action":"certify-session","home":"/h","consent":true,"managed":{"permission":{"edit":{"safe":"allow"}}},"session":[{"permission":"edit","pattern":"safe","value":"allow"}],"required":[{"permission":"edit","candidate":"safe"}]}'
assert 'sesion observada no amplia una operacion gestionada' '.accepted == true' "$session"
assert 'sesion vacia conocida conserva la decision del agente' '.accepted == true and .decisions[0].decision == "allow"' '{"action":"certify-session","consent":true,"managed":{"permission":{"edit":{"safe":"allow"}}},"session":[],"required":[{"permission":"edit","candidate":"safe"}]}'
assert 'grant de sesion no demostrable se rechaza' '.accepted == false and (.conflicts | any(.code == "session-grant-not-provable"))' '{"action":"certify-session","consent":true,"managed":{"permission":{"edit":{"safe":"allow"}}},"session":[{"permission":"edit","pattern":"other","value":"allow"}],"required":[]}'
assert 'grant contenido tolera allow gestionado posterior' '.accepted == true' '{"action":"certify-session","consent":true,"managed":{"permission":{"edit":{"safe/*":"allow","safe/sub/*":"allow"}}},"session":[{"permission":"edit","pattern":"safe/sub/*","value":"allow"}],"required":[]}'
assert 'allow de sesion tapado por deny posterior no es grant efectivo' '.accepted == true' '{"action":"certify-session","consent":true,"managed":{"permission":{}},"session":[{"permission":"edit","pattern":"*","value":"allow"},{"permission":"edit","pattern":"*","value":"deny"}],"required":[]}'
assert 'deny efectivo de sesion rechaza operacion requerida' '.accepted == false and (.conflicts | any(.code == "session-operation-not-allowed"))' '{"action":"certify-session","consent":true,"managed":{"permission":{"edit":"allow"}},"session":[{"permission":"edit","pattern":"safe","value":"deny"}],"required":[{"permission":"edit","candidate":"safe"}]}'
assert 'ask efectivo de sesion rechaza operacion requerida' '.accepted == false and (.conflicts | any(.code == "session-operation-not-allowed"))' '{"action":"certify-session","consent":true,"managed":{"permission":{"edit":"allow"}},"session":[{"permission":"edit","pattern":"safe","value":"ask"}],"required":[{"permission":"edit","candidate":"safe"}]}'
assert 'sin consentimiento se rechaza y auto no sirve de prueba' '.accepted == false and .conflicts[0].code == "consent-required"' '{"action":"certify-session","consent":false,"auto":true,"managed":{},"session":[],"required":[]}'
assert 'aprobaciones recordadas no sirven de prueba' '.accepted == false and .conflicts[0].code == "consent-required"' '{"action":"certify-session","remembered":"always","managed":{},"session":[],"required":[]}'
assert 'diagnostico no incluye candidato centinela' '(.accepted == false) and ((.conflicts | tostring | contains("SECRETO-1838")) | not)' '{"action":"certify-session","consent":true,"managed":{},"session":[],"required":[{"permission":"edit","candidate":"SECRETO-1838"}]}'
assert 'sesion no consultable se distingue de vacia' '.accepted == false and .conflicts[0].code == "session-not-observed"' '{"action":"certify-session","consent":true,"managed":{},"session":null,"required":[]}'

printf '\n%s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
