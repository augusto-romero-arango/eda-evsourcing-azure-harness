#!/usr/bin/env bash
# Digest de proyeccion de la entrada OpenCode (#2013): config y command producen el mismo projectionDigest.
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

# Proyecto consumidor con la autonomia ready y huellas reales de comandos y delegados.
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

printf '%s\n' '[config -> command]'
run < <(envelope config); CFG="$OUT"; rc_is 'config ready exit 0' x 0
run < <(envelope command); CMD="$OUT"; rc_is 'command ready exit 0' x 0
[ "$(jq -r .projectionDigest <<< "$CFG")" = "$(jq -r .projectionDigest <<< "$CMD")" ] && [ "$(jq -r .projectionDigest <<< "$CFG")" != null ] && pass 'projectionDigest igual entre fases' || fail 'projectionDigest difiere entre fases'
[ "$(jq -r .resourcesDigest <<< "$CFG")" = "$(jq -r .resourcesDigest <<< "$CMD")" ] && pass 'resourcesDigest estable entre fases' || fail 'resourcesDigest difiere entre fases'
OUT="$CMD"
jq -e '[.bindings[] | select(.admitted)] | map(.command) == ["mefisto:sequential"]' >/dev/null <<< "$OUT" && pass 'binding admitted true solo para el comando pedido' || fail 'binding de command no admitido'
run < <(envelope command '.requestedCommand = "bitacora"')
[ "$(jq -r .projectionDigest <<< "$OUT")" = "$(jq -r .projectionDigest <<< "$CFG")" ] && pass 'digest independiente del comando solicitado' || fail 'digest depende del comando solicitado'

printf '%s\n' '[cambio real]'
set_inspect ready CONSENT_APPROVED 0 '["sequential","bitacora"]'
run < <(envelope config)
[ "$(jq -r .projectionDigest <<< "$OUT")" != "$(jq -r .projectionDigest <<< "$CFG")" ] && pass 'cambio de perfil cambia el digest' || fail 'cambio de perfil no cambia el digest'
set_inspect ready CONSENT_APPROVED 0 "$APPROVED"
run < <(envelope config '.commands[0].sourceDigest = ("f" * 64)'); [ "$RC" -ne 0 ] && pass 'plantilla modificada no se admite' || fail 'plantilla modificada admitida'

printf '\n%s: %d passed, %d failed\n' "test-opencode-entry-digest-phase.sh" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
