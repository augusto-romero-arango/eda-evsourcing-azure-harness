#!/usr/bin/env bash
# Pruebas deterministas del ensamblador de la proyeccion OpenCode de entrada
# (#1836) contra una release copiada de dist/opencode, sin checkout fuente, SDK,
# LLM ni red. Los dobles de inspect solo describen el perfil.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
WORK="$(cd -P "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert() { local label="$1" filter="$2"; shift 2; jq -e "$@" "$filter" >/dev/null <<< "$OUT" && pass "$label" || { fail "$label"; printf '%s\n' "$OUT" | cut -c1-500 >&2; }; }
rc_is() { [ "$RC" -eq "$3" ] && pass "$1" || fail "$1 (exit $RC)"; }

# Caso macOS (CA-3): store en ~/Library/Application Support (con espacio) y
# runtime data en ~/.local/share/opencode, sin overrides XDG de datos.
OS_HOME="$WORK/os home"; DATA="$OS_HOME/Library/Application Support"; CONFIG_HOME="$WORK/config"; RUNTIME_DATA="$OS_HOME/.local/share/opencode"
STORE="$DATA/mefisto"; RELEASE="$STORE/releases/0.40.2"; CONFIG="$CONFIG_HOME/opencode"; PROJ="$WORK/proj"
mkdir -p "$OS_HOME" "$STORE/releases" "$CONFIG" "$RUNTIME_DATA/storage" "$RUNTIME_DATA/tool-output/ses_a" "$RUNTIME_DATA/tool-output/ses_b" "$PROJ/.mefisto"
cp -R "$REPO_ROOT/dist/opencode" "$RELEASE" || { echo 'FAIL: no se pudo copiar la release'; exit 1; }
jq -n '{schemaVersion:1,runtime:"opencode",version:"0.40.2",commit:"0123456789abcdef0123456789abcdef01234567",minimumRuntimeVersion:"1.18.29"}' > "$RELEASE/mefisto-manifest.json"
ln -s "$RELEASE" "$STORE/active"
mv "$RELEASE/scripts/autonomy-profile.sh" "$RELEASE/scripts/autonomy-profile.real.sh"
cat > "$RELEASE/scripts/autonomy-profile.sh" <<'EOS'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd -P)"
cat "$d/inspect.json"; exit "$(cat "$d/inspect.rc")"
EOS
chmod +x "$RELEASE/scripts/autonomy-profile.sh"
printf '{"schemaVersion":1,"release":"0.40.2","paths":[],"directories":["."]}\n' > "$CONFIG/.mefisto-projection.json"
git -C "$PROJ" init -q 2>/dev/null && git -C "$PROJ" config user.email t@t && git -C "$PROJ" config user.name t
printf '{}\n' > "$PROJ/.mefisto/harness.config.json"
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm init

CLI="$RELEASE/scripts/resolve-command-entry.sh"
MAN="$RELEASE/command-entry-manifest.json"
MAT="$RELEASE/src/published/contract/command-entry.json"
SHELLS="$RELEASE/src/published/contract/command-shell-templates.json"
set_inspect() { # status reason rc commands-json
    jq -cn --arg s "$1" --arg r "$2" --argjson c "${4:-null}" '{schemaVersion:1,status:$s,reasonCode:$r,projectId:"project-aaaaaaaaaaaaaaaaaaaaaaaa",profileDigest:("a" * 64),profile:(if $c == null then null else {commands:$c} end)}' > "$RELEASE/scripts/inspect.json"
    printf '%s\n' "$3" > "$RELEASE/scripts/inspect.rc"
}
APPROVED='["sequential","bitacora","install-auth","onboard","draft","eraser-diagram","seed-secret","install-apim","upgrade","runtimes","batch-stop"]'
set_inspect ready CONSENT_APPROVED 0 "$APPROVED"
[ -f "$SHELLS" ] || { echo 'FAIL: la release no trae command-shell-templates.json'; exit 1; }

GLOBAL='{"permission":{"read":"allow","edit":"allow","external_directory":"allow","bash":"allow","task":"allow","skill":"allow","list":"allow","glob":"allow","grep":"allow"}}'
envelope() { # <phase> [jq-filter]
    jq -cn --arg phase "$1" --arg os "$OS_HOME" --arg data "$DATA" --arg cfg "$CONFIG_HOME" --arg dir "$PROJ" --argjson global "$GLOBAL" --slurpfile man "$MAN" --slurpfile roles "$RELEASE/agent-execution-manifest.json" '
      {schemaVersion:1,phase:$phase,home:$os,configPolicyKnown:true,
       runtimeContext:{platform:"darwin",osHome:$os,home:$os,xdgDataHome:null,xdgConfigHome:$cfg,opencodeConfigDir:null,directory:$dir,worktree:$dir},
       nugetAssetsFiles:[],
       commands:[$man[0].templates[] | select(.kind=="command") | {name:("mefisto:" + .id),sourceDigest:.sha256,agent:("command-entry-" + .id),subtask:false}],
       delegateAgents:([$man[0].delegatedPrompts[] | .agent as $a | {id:$a,available:true,sourceDigest:.sha256,mode:(([$roles[0].roles[] | select(.id==$a) | .mode] | first) // "subagent")}] | unique_by(.id)),
       foreignEntryAgents:[],permission:$global}
      + (if $phase == "command" then {requestedCommand:"sequential",sessionPolicyKnown:true,sessionProjectMatches:true,sessionPermission:[]} else {} end)' | jq -c "${2:-.}"
}
run() { OUT="$(cd "$WORK" && "$CLI" --project-root "$PROJ" 2>"$WORK/stderr")"; RC=$?; }
snapshot_tree() { find "$PROJ" "$CONFIG_HOME" "$RUNTIME_DATA" -type f -exec shasum {} + 2>/dev/null | sort | shasum; }
before="$(snapshot_tree)"

printf '%s\n' '[protocolo]'
OUT="$(printf '' | "$CLI" --project-root "$PROJ" 2>/dev/null)"; RC=$?; rc_is 'stdin vacio es error de protocolo' x 2
OUT="$("$CLI" 2>/dev/null <<< '{}')"; RC=$?; rc_is 'sin --project-root es uso incorrecto' x 2
run < <(envelope config '.home = "/otro"'); rc_is 'home superior distinto del contexto es protocolo' x 2

printf '%s\n' '[perfil]'
set_inspect disabled NO_PROFILE 0
run < <(envelope config); rc_is 'perfil ausente: disabled exit 0' x 0
assert 'NO_PROFILE legacy sin bindings' '.status=="disabled" and .reasonCode=="NO_PROFILE" and (.bindings|length)==0 and .admissionScope=="entry"'
set_inspect disabled CONSENT_REVOKED 0 "$APPROVED"
run < <(envelope config); rc_is 'consentimiento revocado: exit 0' x 0
assert 'revocado conserva motivo y filas no admitidas (no legacy)' '.status=="disabled" and .reasonCode=="CONSENT_REVOKED" and (.bindings|length)==27 and all(.bindings[]; .admitted==false)'
set_inspect needs-approval CONSENT_DIGEST_MISMATCH 1 "$APPROVED"
run < <(envelope config); rc_is 'perfil cambiado: needs-approval exit 1' x 1
assert 'needs-approval con 27 filas denegadas' '.status=="needs-approval" and (.bindings|length)==27 and all(.bindings[]; .admitted==false)'
set_inspect ready CONSENT_APPROVED 0 "$APPROVED"

printf '%s\n' '[config]'
run < <(envelope config); rc_is 'config ready exit 0' x 0
assert 'envelope cerrado con digests e identidad' '.status=="ready" and .phase=="config" and .admissionScope=="entry" and (.projectionDigest|length)==64 and (.catalogDigest|length)==64 and (.resourcesDigest|length)==64 and .release.version=="0.40.2" and .projectId=="project-aaaaaaaaaaaaaaaaaaaaaaaa"'
assert 'inventario completo: 27 bindings y 27 agentes, todos admitted false' '(.bindings|length)==27 and (.agents|length)==27 and all(.bindings[]; .admitted==false and .subtask==false and (.agent|startswith("command-entry-")) and (.command|startswith("mefisto:"))) and all(.agents[]; .mode=="primary" and .hidden==true and (has("model")|not))'
assert 'fila no aprobada queda con permisos denegados' '[.agents[] | select(.id=="command-entry-merge") | .rules[] | select(.value=="allow")] | length==0'
assert 'bitacora no obtiene task universal ni capacidades del hijo' '[.agents[] | select(.id=="command-entry-bitacora") | .rules[] | select(.permission=="task" and .value=="allow")] | map(.pattern) | unique == ["historiador"]'
assert 'sequential sin task nativo (solo runner shell)' '[.agents[] | select(.id=="command-entry-sequential") | .rules[] | select(.permission=="task" and .value=="allow")] | length==0'
assert 'orden de reglas conservado: deny base antes que allow del recurso' '.agents[] | select(.id=="command-entry-draft") | .rules | (map(.value) | index("deny")) < (map(.value) | index("allow"))'
assert 'sin proveedor ni modelo ni secretos' '(tostring | test("apiKey|auth.json|provider|\"model\"") | not)'
assert 'macOS: read/edit con candidatos relativos al worktree' '[.agents[] | select(.id=="command-entry-draft") | .rules[] | select((.permission=="read" or .permission=="edit") and .value=="allow" and (.pattern|startswith("/")|not))] | length > 0'
assert 'macOS: external_directory solo con directorios absolutos' '[.agents[] | select(.id=="command-entry-draft") | .rules[] | select(.permission=="external_directory" and .value=="allow") | .pattern] | length > 0 and all(.[]; startswith("/"))'
assert 'macOS: release bajo Application Support legible por absoluto' '[.agents[] | select(.id=="command-entry-draft") | .rules[] | select(.permission=="external_directory" and .value=="allow" and .pattern==($r + "/*"))] | length > 0' --arg r "$RELEASE"
assert 'tool-output de cualquier sesion es lectura, nunca edicion' '[.agents[] | select(.id=="command-entry-draft") | .rules[] | select(.pattern==($t + "/*"))] as $r | any($r[]; .permission=="read" and .value=="allow") and all($r[]; .permission!="edit" or .value!="allow")' --arg t "$RUNTIME_DATA/tool-output"
FIRST="$OUT"
run < <(envelope config); [ "$OUT" = "$FIRST" ] && pass 'determinista: misma salida' || fail 'salida no determinista'

printf '%s\n' '[command]'
run < <(envelope command); rc_is 'command ready exit 0' x 0
assert 'solo la fila solicitada queda admitida' '.phase=="command" and ([.bindings[] | select(.admitted)] | map(.command) == ["mefisto:sequential"])'
run < <(envelope command '.requestedCommand = "merge"'); rc_is 'comando no aprobado: conflict exit 1' x 1
assert 'COMMAND_NOT_APPROVED y todo no admitido' '.status=="conflict" and any(.diagnostics[]; .code=="COMMAND_NOT_APPROVED") and all(.bindings[]; .admitted==false) and (.bindings|length)==27'
run < <(envelope command '.sessionPolicyKnown = false | .sessionPermission = []'); rc_is 'sesion desconocida: conflict' x 1
assert 'SESSION_UNKNOWN' 'any(.diagnostics[]; .code=="SESSION_UNKNOWN")'
run < <(envelope command '.sessionProjectMatches = false'); rc_is 'sesion de otro proyecto: conflict' x 1
run < <(envelope command '.sessionPermission = [{"permission":"read","pattern":"*","value":"deny"}]'); rc_is 'restriccion de sesion efectiva: conflict' x 1
assert 'la restriccion de sesion se evalua en su posicion' 'any(.diagnostics[]; .code|test("SESSION_OPERATION_NOT_ALLOWED"))'
run < <(envelope command '.sessionPermission = [{"permission":"read","pattern":"*","value":"allow"}]'); rc_is 'allow de sesion mas amplio que el alcance propio no se admite' x 1
run < <(envelope command '.permission = {"permission":{"read":[]}}'); rc_is 'politica no representable: conflict' x 1
run < <(envelope command '.permission = {"permission":{"bash":"deny"}}'); rc_is 'restriccion global ganadora impide la operacion requerida' x 1
assert 'OPERATION_NOT_ALLOWED' 'any(.diagnostics[]; .code=="OPERATION_NOT_ALLOWED")'
run < <(envelope command '.permission = {"permission":{"bash":"ask"}}'); rc_is 'ask global cubierto por consentimiento' x 0
run < <(envelope command '.permission = {"permission":{"bash":{"gh *":"deny","*":"allow"}}}'); rc_is 'deny seguido de allow: gana el ultimo' x 0
run < <(envelope command '.permission = {"permission":{"bash":{"*":"allow","gh *":"deny"}}}'); rc_is 'allow seguido de deny: gana el deny' x 1

printf '%s\n' '[command: contrato real de plantillas shell]'
EVAL_DIR="$REPO_ROOT/src/published/scripts/adapters/lib"
rules_of() { # <comando solicitado> <agente cuyas reglas se extraen>
    run < <(envelope command ".requestedCommand = \"$1\"")
    jq -c --arg a "command-entry-$2" '[.agents[] | select(.id==$a) | .rules[] | select(.permission=="bash")]' <<< "$OUT"
}
decide() { # <reglas-json> <candidato>
    jq -L "$EVAL_DIR" -cnr --argjson rules "$1" --arg c "$2" 'include "opencode-entry-permissions"; {action:"evaluate",policy:{rules:$rules},candidates:[{permission:"bash",candidate:$c}]} | entry_permissions | .decisions[0].decision'
}
expect() { # <reglas-json> <allow|deny> <candidato> <etiqueta>
    local got; got="$(decide "$1" "$3")"
    [ "$got" = "$2" ] && pass "$4: $2" || fail "$4: se esperaba $2 y fue $got"
}
PK='MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts'
R_ERASER="$(rules_of eraser-diagram eraser-diagram)"
expect "$R_ERASER" allow "$PK/render-eraser-diagram.sh\" --payload-file .mefisto/pipeline/tmp/eraser-diagram-payload.json" 'eraser: wrapper canonico'
expect "$R_ERASER" deny 'curl https://app.eraser.io/api/render/elements -d @payload.json' 'eraser: API directa'
expect "$R_ERASER" deny "$PK/tmux-pipeline.sh\" x" 'eraser: otro script'
R_TF="$(rules_of seed-secret seed-secret)"
expect "$R_TF" allow 'terraform validate' 'terraform: validate normalizado a cwd'
expect "$R_TF" allow 'terraform init -backend=false' 'terraform: init sin backend'
expect "$R_TF" deny 'terraform -chdir=/otra/ruta validate' 'terraform: -chdir a otra ruta'
expect "$R_TF" deny 'terraform apply' 'terraform: apply'
expect "$R_TF" deny 'terraform plan' 'terraform: plan'
R_TEN="$(rules_of install-apim install-apim)"
expect "$R_TEN" allow "$PK/set-harness-tenancy.sh\" --strategy multi-tenant-header" 'tenancy: setter canonico'
expect "$R_TEN" deny "$PK/seed-secret.sh\" --strategy multi-tenant-header" 'tenancy: otro script'
expect "$R_TEN" deny 'MEFISTO_RUNTIME=opencode /tmp/set-harness-tenancy.sh --strategy multi-tenant-header' 'tenancy: ruta fuera del paquete'
expect "$R_TEN" deny 'curl https://example.com/set-harness-tenancy.sh' 'tenancy: red'
R_DRAFT="$(rules_of draft draft)"
for pair in upgrade:"$PK/upgrade.sh\" --status" runtimes:'"$MEFISTO_LIFECYCLE_LAUNCHER" projection-status' batch-stop:'pgrep -f "[s]cripts/batch-pipeline\.sh"'; do
    id="${pair%%:*}"; cand="${pair#*:}"
    R_OWN="$(rules_of "$id" "$id")"
    expect "$R_OWN" allow "$cand" "$id: reglas de su agente"
    expect "$R_DRAFT" deny "$cand" "$id: reglas de command-entry-draft (sin herencia)"
done
expect "$(rules_of upgrade upgrade)" deny 'rm -rf "$HOME"' 'upgrade: borrado arbitrario'
expect "$(rules_of runtimes runtimes)" deny '"$MEFISTO_LIFECYCLE_LAUNCHER" purge' 'runtimes: accion fuera de contrato'
expect "$(rules_of batch-stop batch-stop)" deny 'pkill -f batch-pipeline' 'batch-stop: pkill'
expect "$R_ERASER" deny 'pgrep -f "[s]cripts/batch-pipeline\.sh"' 'entre filas: eraser no hereda pgrep de batch-stop'

printf '%s\n' '[ownership y contexto]'
run < <(envelope config '.configPolicyKnown = false'); rc_is 'configuracion desconocida: conflict' x 1
assert 'CONFIG_POLICY_UNKNOWN' 'any(.diagnostics[]; .code=="CONFIG_POLICY_UNKNOWN")'
run < <(envelope config '.permission = null'); rc_is 'configuracion conocida sin reglas: ready' x 0
run < <(envelope config '.commands |= map(if .name=="mefisto:merge" then .sourceDigest="0" else . end)'); rc_is 'template modificado: conflict' x 1
assert 'COMMAND_OWNERSHIP' 'any(.diagnostics[]; .code=="COMMAND_OWNERSHIP")'
run < <(envelope config '.commands |= map(select(.name != "mefisto:merge"))'); rc_is 'comando ausente: conflict' x 1
run < <(envelope config '.commands |= map(if .name=="mefisto:draft" then .agent="build" else . end)'); rc_is 'agente original ajeno al binding: conflict' x 1
run < <(envelope config '.delegateAgents |= map(if .id=="historiador" then .sourceDigest="0" else . end)'); rc_is 'delegado modificado: conflict' x 1
assert 'DELEGATE_MODIFIED' 'any(.diagnostics[]; .code=="DELEGATE_MODIFIED")'
run < <(envelope config '.delegateAgents |= map(select(.id != "historiador"))'); rc_is 'delegado ausente: conflict' x 1
run < <(envelope config '.delegateAgents |= map(if .id=="historiador" then .mode="primary" else . end)'); rc_is 'modo de delegado incompatible: conflict' x 1
run < <(envelope config '.foreignEntryAgents = ["command-entry-merge"]'); rc_is 'colision de agente tecnico: conflict' x 1
assert 'filas denegadas ante colision' 'all(.bindings[]; .admitted==false) and (.bindings|length)==27'
run < <(envelope config '.runtimeContext.directory = "/no/existe"'); rc_is 'directorio no verificable: conflict' x 1
rm "$SHELLS"
run < <(envelope config); rc_is 'sin plantillas shell de la release no se admite' x 1
assert 'SHELL_TEMPLATES_UNAVAILABLE sin catalogo parcial' 'any(.diagnostics[]; .code=="SHELL_TEMPLATES_UNAVAILABLE") and (.bindings|length)==27 and all(.bindings[]; .admitted==false)'
cp "$REPO_ROOT/dist/opencode/src/published/contract/command-shell-templates.json" "$SHELLS"
run < <(envelope config); rc_is 'contrato empaquetado de #1944: config ready' x 0
assert 'contrato empaquetado: ninguna fila emite SHELL_TEMPLATES_UNAVAILABLE' '(.diagnostics|type)=="array" and all(.diagnostics[]; .code != "SHELL_TEMPLATES_UNAVAILABLE") and (.bindings|length)==27'
rm -rf "$RELEASE/src/published/scripts/adapters/lib/opencode-command-entry.jq"
run < <(envelope config); rc_is 'clausura incompleta: protocolo' x 2

after="$(snapshot_tree)"
printf '%s\n' '[sin efectos]'
grep -q 'resolve-command-entry' "$REPO_ROOT/dist/opencode/.mefisto-generated-assets.json" && pass 'el resolver esta en el inventario generado' || fail 'resolver fuera del inventario'
[ ! -e "$PROJ/.mefisto/pipeline" ] && [ "$before" = "$after" ] && pass 'no se escribio consentimiento, estado, config ni tool-output' || fail 'se escribieron archivos en el consumidor, la config o el runtime'
bash "$REPO_ROOT/src/published/scripts/generate-published-adapters.sh" --check >/dev/null 2>&1 && pass 'dist coincide con la fuente (agentes, comandos y mirrors Claude sin cambios)' || fail 'dist diverge'

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
