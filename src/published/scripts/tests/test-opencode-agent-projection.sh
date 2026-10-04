#!/usr/bin/env bash
# Pruebas del compilador de politica por rol (#1856) contra una release copiada
# de dist/opencode, sin checkout fuente, SDK, LLM ni red.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
WORK="$(cd -P "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert() { local label="$1" filter; shift; filter="${*: -1}"; set -- "${@:1:$#-1}"; jq -e "$@" "$filter" >/dev/null <<< "$OUT" && pass "$label" || { fail "$label"; printf '%s\n' "$OUT" | cut -c1-400 >&2; }; }

RELEASE="$WORK/release"
cp -R "$REPO_ROOT/dist/opencode" "$RELEASE" || { echo 'FAIL: no se pudo copiar la release'; exit 1; }
CLI="$RELEASE/scripts/resolve-agent-execution.sh"
MAN="$RELEASE/agent-execution-manifest.json"
EXEC="$WORK/proj"; STATE="$EXEC/.mefisto/pipeline"; TOOL="$WORK/data/opencode/tool-output"; NUGET="$WORK/nuget"
R="$RELEASE"

snapshot() {
    jq -cn --arg exec "$EXEC" --arg state "$STATE" --arg tool "$TOOL" --arg nuget "$NUGET" --arg rel "$R" '
      {schemaVersion:1,resolutionScope:"resources",status:"ready",projectId:"project-aaaaaaaaaaaaaaaaaaaaaaaa",profileDigest:("a" * 64),resourcesDigest:("b" * 64),
       release:{root:$rel,version:"0.40.2"},project:{approvedRoot:$exec,executionRoot:$exec,gitCommonDir:($exec + "/.git")},
       permissionBase:{worktree:{logical:$exec,physical:$exec},directory:$exec},
       resources:[
         {id:"release",root:$rel,exists:true,maxAccess:"read",relativeRoot:"../release",aliases:[],excludedPaths:[]},
         {id:"project",root:$exec,exists:true,maxAccess:"project",relativeRoot:"",aliases:[],excludedPaths:[($exec + "/.mefisto/pipeline/autonomy"),($exec + "/.mefisto/harness.config.json")],provenance:{source:"project-identity",role:"execution"}},
         {id:"state",root:$state,exists:true,maxAccess:"state",relativeRoot:".mefisto/pipeline",aliases:[],excludedPaths:[($state + "/autonomy")]},
         {id:"runtime-tool-output",root:$tool,exists:false,maxAccess:"read",relativeRoot:"../data/opencode/tool-output",aliases:[],excludedPaths:[]},
         {id:"nuget-packages",root:$nuget,exists:true,maxAccess:"read",relativeRoot:"../nuget",aliases:[],excludedPaths:[]}],
       protectedRoots:[{id:"runtime-data",root:($tool | sub("/tool-output$"; "")),exceptions:[$tool]},{id:"ssh",root:($exec | sub("/proj$"; "/home/.ssh")),exceptions:[]}]}'
}
GLOBAL='{"permission":{"read":"allow","edit":"allow","external_directory":"allow","bash":"allow","task":"allow","skill":"allow","list":"allow","glob":"allow","grep":"allow","webfetch":"deny","websearch":"deny"}}'
attach() { jq -cn --arg exe "$R/scripts/execution-context.sh" --arg c "$STATE/autonomy" '{executable:$exe,pid:4242,controlRoot:$c,request:($c + "/req-1.json")}'; }
# envelope <phase> <roles-json> [extra-jq-filter]
envelope() {
    local phase="$1" roles="$2" extra="${3:-.}"
    jq -cn --arg phase "$phase" --argjson snap "$(snapshot)" --argjson roles "$roles" --argjson global "$GLOBAL" --slurpfile man "$MAN" '
      {schemaVersion:1,phase:$phase,profile:{projectId:$snap.projectId,profileDigest:$snap.profileDigest},snapshot:$snap,home:"/home/x",roles:$roles,
       originals:[$man[0].roles[] | {id,mode:.metadata.mode,permission:.metadata.permission,tools:.metadata.tools,promptHash:.sourceDigest}],
       globalPolicy:$global,sessionPolicy:null,collisions:[]}' | jq -c "$extra"
}
run() { OUT="$("$CLI" 2>/dev/null)"; RC=$?; }
SHELL_ROLE="$(jq -c '.roles[] | select((.metadata.permission.bash | type) == "object") | .id' "$MAN" | head -1 | tr -d '"')"
printf '%s\n' '[config]'
ROLES="$(jq -cn --arg s "$SHELL_ROLE" --argjson a "$(attach)" '[{role:"tooling-writer",taskTargets:[],attach:$a},{role:"tooling-reviewer",taskTargets:[],attach:$a},{role:"implementer",taskTargets:[],attach:$a}]')"
run < <(envelope config "$ROLES")
[ "$RC" -eq 0 ] && pass 'writer, reviewer e implementer con NuGet son ready (exit 0)' || fail "exit $RC"
assert 'salida cerrada con scope, digests y tres actores' '.status=="ready" and .admissionScope=="agent-projection" and (.catalogDigest|length)==64 and .resourcesDigest==("b"*64) and (.projectionDigest|length)==64 and (.actors|length)==3 and ([.actors[].alias]|sort)==["autonomy-implementer","autonomy-tooling-reviewer","autonomy-tooling-writer"]'
assert 'solo el execution-root es editable y el estado se excluye' --arg e "$EXEC" --arg tx "$TOOL/*" '.actors[0].permission.edit as $p | ($p[$e + "/*"]=="allow") and ($p[$e + "/.mefisto/pipeline/autonomy/*"]=="deny") and ($p["../*"]=="deny") and ($p[$tx]=="deny")' 
assert 'tool-output y release son read, nunca edit' --arg t "$TOOL" --arg r "$R" '.actors[0].permission as $p | ($p.read[$t + "/*"]=="allow") and ($p.read[$r + "/*"]=="allow") and ($p.edit[$t + "/*"]=="deny") and ($p.edit[$r + "/*"]=="deny")'
assert 'read usa raiz relativa y external_directory raices absolutas' --arg r "$R" '.actors[0].permission | (.read["*"]=="allow") and (.external_directory[$r + "/*"]=="allow") and (.external_directory["*"]=="deny")'
assert 'NuGet solo para roles que lo declaran' --arg n "$NUGET" '[.actors[] | {k:.originalId, v:(.permission.read | has($n + "/*"))}] | map({(.k):.v}) | add == {"tooling-writer":false,"tooling-reviewer":false,"implementer":true}'
assert 'shell: solo el prefijo de attach y deny generico, sin prepare/approve/finish' '.actors[0].permission.bash | (to_entries | map(select(.value=="allow")) | length)==1 and (.["*"]=="deny") and (keys[1] | test("execution-context.sh\" attach --shell-pid 4242 --request")) and (tostring | test("prepare|approve|finish") | not)'
assert 'Task denegado por defecto y sin shell/task/MCP universales' '.actors[0].permission | (.task=={"*":"deny"}) and (.bash["*"]=="deny") and (.["microsoft-learn_*"]=={"*":"deny"})'
assert 'diagnosticos y salida sin prompts ni patrones crudos' '(tostring | test("sourceDigest|You are|Eres") | not)'
printf '%s\n' '[ownership]'
run < <(envelope config "$ROLES" '.originals |= map(if .id=="tooling-writer" then .promptHash="0" else . end)')
assert 'prompt ajeno es conflicto y no emite actores' '.status=="conflict" and .actors==[] and (.diagnostics | any(.code=="PROMPT_OWNERSHIP")) and .projectionDigest==null'
[ "$RC" -eq 1 ] && pass 'exit 1 en conflicto' || fail "exit $RC"
run < <(envelope config "$ROLES" '.originals |= map(if .id=="tooling-writer" then .permission.bash["curl *"]="allow" else . end)')
assert 'override del usuario en permission es conflicto, no se borra' '.diagnostics | any(.code=="CAPABILITY_METADATA_DIVERGENCE")'
run < <(envelope config "$ROLES" '.collisions=["autonomy-tooling-writer"]')
assert 'alias en colision' '.diagnostics | any(.code=="ALIAS_COLLISION")'
run < <(envelope config "$ROLES" '.originals |= map(select(.id != "implementer"))')
assert 'original no observado' '.diagnostics | any(.code=="ORIGINAL_NOT_OBSERVED")'
run < <(envelope config "$ROLES" '.originals |= map(if .id=="tooling-writer" then .model="x" else . end)')
[ "$RC" -eq 2 ] && pass 'campos extra (modelo/opciones) son error de protocolo' || fail "exit $RC modelo"
run < <(envelope config "$ROLES" '.globalPolicy=null')
assert 'politica global desconocida es conflicto' '.diagnostics | any(.code=="GLOBAL_POLICY_UNKNOWN")'
run < <(envelope config "$ROLES" '.globalPolicy.permission.edit="deny"')
assert 'global que deniega edit impide la proyeccion' '.status=="conflict" and (.diagnostics | any(.code=="OPERATION_NOT_ALLOWED"))'

printf '%s\n' '[roles sin bash ni attach]'
NOSHELL="$(jq -r '[.roles[] | select((.metadata.permission.bash | type) != "object")] | first | .id // empty' "$MAN")"
if [ -n "$NOSHELL" ]; then
    run < <(envelope config "$(jq -cn --arg r "$NOSHELL" '[{role:$r,taskTargets:[]}]')")
    assert 'rol sin shell no recibe permisos bash' '.status=="ready" and (.actors[0].permission.bash=={"*":"deny"})'
else pass 'todos los roles tienen shell (sin caso sin-shell)'; fi
run < <(envelope config '[{"role":"tooling-writer","taskTargets":[]}]')
assert 'rol shell sin attach es conflicto' '.diagnostics | any(.code=="ATTACH_INVALID")'
run < <(envelope config "$(jq -cn --argjson a "$(attach | jq -c '.request="/tmp/otro.json"')" '[{role:"tooling-writer",taskTargets:[],attach:$a}]')")
assert 'request fuera del controlRoot es invalido' '.diagnostics | any(.code=="ATTACH_INVALID")'

printf '%s\n' '[task]'
ATASK="$(jq -cn --argjson a "$(attach)" '[{role:"tooling-writer",taskTargets:["tooling-reviewer"],attach:$a}]')"
run < <(envelope config "$ATASK")
assert 'task denegado por el original no genera allow del alias' '.status=="conflict" and (.diagnostics | any(.code=="TASK_DENIED"))'
run < <(envelope config "$ATASK" '.originals |= map(if .id=="tooling-writer" then .permission.task={"tooling-reviewer":"allow"} else . end) | .originals |= map(if .id=="tooling-writer" then . else . end)')
assert 'metadata propia modificada del original sigue siendo conflicto' '.status=="conflict" and (.diagnostics | any(.code=="CAPABILITY_METADATA_DIVERGENCE"))'
TMAN="$WORK/man-task.json"
jq '(.roles[] | select(.id=="tooling-writer") | .metadata.permission.task) = {"tooling-reviewer":"allow"}' "$MAN" > "$TMAN"; cp "$TMAN" "$RELEASE/agent-execution-manifest.json"
run < <(envelope config "$ATASK" '.originals |= map(if .id=="tooling-writer" then .permission.task={"tooling-reviewer":"allow"} else . end)' | jq -c --slurpfile m "$TMAN" '.originals = [$m[0].roles[] | {id,mode:.metadata.mode,permission:.metadata.permission,tools:.metadata.tools,promptHash:.sourceDigest}]')
assert 'destino permitido: par original/alias y taskBindings' '.status=="ready" and (.actors[0].permission.task | (.["tooling-reviewer"]=="allow") and (.["autonomy-tooling-reviewer"]=="allow") and (.["*"]=="deny")) and (.actors[0].taskBindings==[{target:"tooling-reviewer",alias:"autonomy-tooling-reviewer"}])'
MOD="$(envelope config "$ATASK" | jq -c --slurpfile m "$TMAN" '.originals = [$m[0].roles[] | {id,mode:.metadata.mode,permission:.metadata.permission,tools:.metadata.tools,promptHash:.sourceDigest}]')"
run < <(jq -c '.globalPolicy.permission.task={"*":"allow","tooling-reviewer":"deny"}' <<< "$MOD")
assert 'deny global al nombre original sigue negando al mapear alias' '.status=="conflict" and (.diagnostics | any(.code=="TASK_DENIED"))'
run < <(jq -c '.globalPolicy.permission.task={"*":"allow","autonomy-tooling-reviewer":"deny"}' <<< "$MOD")
assert 'deny global al alias tambien bloquea' '.status=="conflict" and (.diagnostics | any(.code=="TASK_DENIED"))'
run < <(jq -c '.sessionPolicy=[{"permission":"task","pattern":"tooling-reviewer","value":"deny"}]' <<< "$MOD")
assert 'deny de sesion al original bloquea' '.status=="conflict" and (.diagnostics | any(.code=="TASK_DENIED"))'
run < <(jq -c '.sessionPolicy=[{"permission":"task","pattern":"*","value":"allow"}]' <<< "$MOD")
assert 'grant de sesion con comodin no demostrable no se admite' '.status=="conflict" and (.diagnostics | any(.code=="SESSION_GRANT_NOT_PROVABLE"))'
run < <(jq -c '.sessionPolicy=[{"permission":"task","pattern":"tooling-reviewer","value":"allow"}]' <<< "$MOD")
assert 'grant literal al nombre original no es una capacidad nueva' '.status=="ready"'
cp "$MAN" "$WORK/man-orig.json" 2>/dev/null; cp "$REPO_ROOT/dist/opencode/agent-execution-manifest.json" "$RELEASE/agent-execution-manifest.json"

printf '%s\n' '[entryTaskPolicies]'
EDIG="$(jq -cS -n '{entryId:"coord",targets:["tooling-reviewer","tooling-writer"]}' | tr -d '\n' | shasum -a 256 | cut -d ' ' -f 1)"
run < <(envelope config "$ROLES" ". + {entryTaskPolicies:[{entryId:\"coord\",targets:[\"tooling-writer\",\"tooling-reviewer\"],digest:\"$EDIG\"}]}")
assert 'entryTaskBindings por entryId' '.status=="ready" and (.entryTaskBindings.coord | map(.alias) | sort)==["autonomy-tooling-reviewer","autonomy-tooling-writer"]'
run < <(envelope config "$ROLES" ". + {entryTaskPolicies:[{entryId:\"coord\",targets:[\"tooling-reviewer\"],digest:\"$EDIG\"}]}")
assert 'digest que no corresponde a la proyeccion es conflicto' '.diagnostics | any(.code=="ENTRY_POLICY_DIGEST")'
run < <(envelope config "$ROLES" '. + {entryTaskPolicies:[{entryId:"coord",targets:["inventado"],digest:"x"}]}')
assert 'destino desconocido en la entrada es conflicto' '.diagnostics | any(.code=="ENTRY_TARGET_UNKNOWN")'

printf '%s\n' '[verify]'
CFG="$(envelope config "$ROLES" | { "$CLI" 2>/dev/null; })"
OBS_RULES="$(jq -c '.actors[0] | [.permission | to_entries[] | .key as $p | .value | if type=="object" then to_entries[] | {permission:$p,pattern:.key,value:.value} else {permission:$p,pattern:"*",value:.} end]' <<< "$CFG")"
verify_env() {
    local rules="$1" extra="${2:-.}"
    envelope verify '[{"role":"tooling-writer","taskTargets":[],"attach":'"$(attach)"'}]' | jq -c --argjson rules "$rules" --slurpfile m "$MAN" '.observed=[{name:"autonomy-tooling-writer",mode:($m[0].roles[]|select(.id=="tooling-writer")|.mode),promptHash:($m[0].roles[]|select(.id=="tooling-writer")|.sourceDigest),rules:$rules,available:true}]' | jq -c "$extra"
}
run < <(verify_env "$OBS_RULES")
assert 'observacion identica a la proyeccion es ready con digest de observacion' '.status=="ready" and .phase=="verify" and (.observations[0].observationDigest|length)==64 and (.projectionDigest|length)==64'
run < <(verify_env "$OBS_RULES" '.observed[0].available=false')
assert 'actor no disponible es conflicto' '.diagnostics | any(.code=="ACTOR_UNAVAILABLE")'
run < <(verify_env "$OBS_RULES" '.observed[0].promptHash="0"')
assert 'prompt observado distinto es conflicto' '.diagnostics | any(.code=="PROMPT_OWNERSHIP")'
run < <(verify_env "$(jq -c '. + [{permission:"bash",pattern:"curl *",value:"allow"}]' <<< "$OBS_RULES")")
assert 'ampliacion observada no demostrable es conflicto' '.diagnostics | any(.code=="OBSERVED_GRANT_NOT_PROVABLE" or .code=="OBSERVED_WIDENING")'
run < <(verify_env "$(jq -c '[.[] | select(.permission != "edit")]' <<< "$OBS_RULES")")
assert 'operacion requerida ausente en la observacion es conflicto' '.diagnostics | any(.code=="OBSERVED_OPERATION_DENIED")'
run < <(verify_env "$OBS_RULES" '.observed += [.observed[0] | .rules = []]')
assert 'observaciones duplicadas del mismo alias son conflicto' '.status=="conflict" and (.diagnostics | any(.code=="OBSERVATION_DUPLICATED"))'
run < <(verify_env "$OBS_RULES" '.observed=[]')
assert 'sin actor observado no se acepta la mera presencia del alias' '.diagnostics | any(.code=="ACTOR_NOT_OBSERVED")'
run < <(verify_env "$OBS_RULES" 'del(.observed)')
[ "$RC" -eq 2 ] && pass 'verify sin observed es error de protocolo' || fail 'verify sin observed'
printf '{' | "$CLI" >/dev/null 2>&1; [ "$?" -eq 2 ] && pass 'JSON invalido es protocolo (exit 2)' || fail 'exit del JSON invalido'

printf '%s\n' '[clausura]'
BEFORE="$(find "$RELEASE" -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256)"
run < <(envelope config "$ROLES")
AFTER="$(find "$RELEASE" -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256)"
[ "$BEFORE" = "$AFTER" ] && pass 'no escribe en la release ni aplica config' || fail 'la corrida modifico la release'
[ "$(env -i PATH="$PATH" "$CLI" < <(envelope config "$ROLES") 2>/dev/null | jq -r .status)" = ready ] && pass 'corre sin entorno ni source checkout (release copiada)' || fail 'no corre desde la release copiada'
grep -Eq 'provider|model' <<< "$(jq -c '.actors' <<< "$OUT")" && fail 'la salida contiene modelo/provider' || pass 'la salida no contiene modelo ni provider'

printf '\nResultado: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
