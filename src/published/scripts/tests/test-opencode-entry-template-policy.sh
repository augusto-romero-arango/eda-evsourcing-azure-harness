#!/usr/bin/env bash
# Guardia cruzada (#2017): lo que cada plantilla OpenCode manda ejecutar y leer
# se evalua contra la politica real de su command-entry-<id> con el mismo
# evaluador de reglas del adaptador. Cualquier deny falla el test.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
WORK="$(cd -P "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

OS_HOME="$WORK/os home"; DATA="$OS_HOME/Library/Application Support"; CONFIG_HOME="$WORK/config"; RUNTIME_DATA="$OS_HOME/.local/share/opencode"
STORE="$DATA/mefisto"; RELEASE="$STORE/releases/0.40.2"; CONFIG="$CONFIG_HOME/opencode"; PROJ="$WORK/proj"
mkdir -p "$OS_HOME" "$STORE/releases" "$CONFIG" "$RUNTIME_DATA/storage" "$RUNTIME_DATA/tool-output/ses_a" "$PROJ/.mefisto"
cp -R "$REPO_ROOT/dist/opencode" "$RELEASE" || { echo 'FAIL: no se pudo copiar la release'; exit 1; }
jq -n '{schemaVersion:1,runtime:"opencode",version:"0.40.2",commit:"0123456789abcdef0123456789abcdef01234567",minimumRuntimeVersion:"1.18.29"}' > "$RELEASE/mefisto-manifest.json"
ln -s "$RELEASE" "$STORE/active"
mv "$RELEASE/scripts/autonomy-profile.sh" "$RELEASE/scripts/autonomy-profile.real.sh"
cat > "$RELEASE/scripts/autonomy-profile.sh" <<'EOS'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd -P)"
cat "$d/inspect.json"; exit 0
EOS
chmod +x "$RELEASE/scripts/autonomy-profile.sh"
printf '{"schemaVersion":1,"release":"0.40.2","paths":[],"directories":["."]}\n' > "$CONFIG/.mefisto-projection.json"
git -C "$PROJ" init -q 2>/dev/null && git -C "$PROJ" config user.email t@t && git -C "$PROJ" config user.name t
printf '{}\n' > "$PROJ/.mefisto/harness.config.json"
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm init

CLI="$RELEASE/scripts/resolve-command-entry.sh"
MAN="$RELEASE/command-entry-manifest.json"
MAT="$RELEASE/src/published/contract/command-entry.json"
LIBDIR="$RELEASE/src/published/scripts/adapters/lib"
ALL="$(jq -c '[.commands[].id]' "$MAT")"
jq -cn --argjson c "$ALL" '{schemaVersion:1,status:"ready",reasonCode:"CONSENT_APPROVED",projectId:"project-aaaaaaaaaaaaaaaaaaaaaaaa",profileDigest:("a" * 64),profile:{commands:$c}}' > "$RELEASE/scripts/inspect.json"
GLOBAL='{"permission":{"read":"allow","edit":"allow","external_directory":"allow","bash":"allow","task":"allow","skill":"allow","list":"allow","glob":"allow","grep":"allow"}}'
envelope() { # <phase> <requested>
  jq -cn --arg phase "$1" --arg req "${2:-}" --arg os "$OS_HOME" --arg cfg "$CONFIG_HOME" --arg dir "$PROJ" --argjson global "$GLOBAL" --slurpfile man "$MAN" --slurpfile roles "$RELEASE/agent-execution-manifest.json" '
    {schemaVersion:1,phase:$phase,home:$os,configPolicyKnown:true,
     runtimeContext:{platform:"darwin",osHome:$os,home:$os,xdgDataHome:null,xdgConfigHome:$cfg,opencodeConfigDir:null,directory:$dir,worktree:$dir},
     nugetAssetsFiles:[],
     commands:[$man[0].templates[] | select(.kind=="command") | {name:("mefisto:" + .id),sourceDigest:.sha256,agent:("command-entry-" + .id),subtask:false}],
     delegateAgents:([$man[0].delegatedPrompts[] | .agent as $a | {id:$a,available:true,sourceDigest:.sha256,mode:(([$roles[0].roles[] | select(.id==$a) | .mode] | first) // "subagent")}] | unique_by(.id)),
     foreignEntryAgents:[],permission:$global}
    + (if $phase == "command" then {requestedCommand:$req,sessionPolicyKnown:true,sessionProjectMatches:true,sessionPermission:[]} else {} end)'
}
evaluate() { # <rules-json> <permission> <candidate>
  jq -L "$LIBDIR" -cnr --argjson rules "$1" --arg p "$2" --arg c "$3" \
    'include "opencode-entry-permissions"; {action:"evaluate",policy:{rules:$rules},candidates:[{permission:$p,candidate:$c}]} | entry_permissions | .decisions[0].decision'
}
extract() { # <doc> -> un comando por linea ejecutable de los bloques bash
  awk '
    /^```(bash|sh|shell)/ { b=1; next }
    /^```/ { b=0; next }
    !b { next }
    {
      line=$0; sub(/^[ \t]+/, "", line)
      if (heredoc != "") { if (line == heredoc) heredoc=""; next }
      cont=prevcont; prevcont=(line ~ /\\$/)
      if (match(line, /<<-?[\047"]?[A-Za-z_]+[\047"]?/)) {
        tag=substr(line, RSTART, RLENGTH); gsub(/<<-?|[\047"]/, "", tag); heredoc=tag
      }
      if (cont) next
      if (line == "" || line ~ /^#/ || line ~ /^[)}|]/ || line ~ /^;;/ || line ~ /^[^ ]*\)/) next
      for (i = 0; i < 6; i++) {
        if (sub(/^(if|elif|while|!) +/, "", line)) continue
        if (sub(/^\(cd [^&]*&& */, "", line)) continue
        if (match(line, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
          line=substr(line, RLENGTH + 1)
          if (sub(/^\$\( */, "", line)) continue
          line=""; break
        }
        break
      }
      split(line, w, /[ \t;]/)
      if (line == "" || w[1] ~ /^(for|do|done|then|else|fi|case|esac|in|return|exit|break|sleep|echo|printf|test|true|false|\[|\[\[|:|\{|\()$/) next
      print line
    }' "$1"
}

CORPUS="$REPO_ROOT/src/published/scripts/tests/fixtures/bash-candidates/opencode-1.18.29.json"
human="$(jq -r '.inventory.humanInstruction[] | .artifact + "\t" + .snippet' "$CORPUS")"

printf '%s\n' '[politica ready por comando]'
OUT="$(cd "$WORK" && envelope config | "$CLI" --project-root "$PROJ" 2>"$WORK/stderr")"
jq -e '.status == "ready"' <<< "$OUT" >/dev/null && pass 'el catalogo completo proyecta politica ready' || { fail "proyeccion no ready: $(printf '%s' "$OUT" | cut -c1-300)"; printf 'Resultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"; exit 1; }

printf '%s\n' '[plantillas]'
checked=0; reads=0; bad=0
while IFS= read -r id; do
  doc="$REPO_ROOT/dist/opencode/commands/mefisto:$id.md"
  rules="$(jq -c --arg a "command-entry-$id" '.agents[] | select(.id == $a) | .rules' <<< "$OUT")"
  if [ -z "$rules" ]; then fail "$id: sin politica de entrada"; bad=1; continue; fi
  if grep -Eq 'mefisto_opencode_launcher|Cada llamada bash que use \$\{MEFISTO_PACKAGE_ROOT\}|MEFISTO_CONFIG_PATH=|MEFISTO_INSTRUCTIONS_PATH=' "$doc"; then
    fail "$id: la plantilla reintroduce un preambulo shell"; bad=1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if grep -Fxq "commands/$id.md	$line" <<< "$human"; then continue; fi
    checked=$((checked+1))
    [ "$(evaluate "$rules" bash "$line")" = allow ] || { fail "$id: bash denegado por su politica: $line"; bad=1; }
  done < <(extract "$doc")
  if grep -Eq '\$\{?MEFISTO_CONFIG_PATH' "$doc"; then
    reads=$((reads+1))
    for cfg in .mefisto/harness.config.json .claude/harness.config.json; do
      [ "$(evaluate "$rules" read "$cfg")" = allow ] || { fail "$id: read denegado: $cfg"; bad=1; }
    done
  fi
  [ "$(evaluate "$rules" read ".mefisto/pipeline/autonomy/runs/x.json")" = deny ] || { fail "$id: la ruta protegida del estado de autonomia ya no se deniega"; bad=1; }
  [ "$(evaluate "$rules" edit ".mefisto/harness.config.json")" = deny ] || { fail "$id: edit del config canonico debe seguir denegado"; bad=1; }
done < <(jq -r '.[]' <<< "$ALL")
[ "$bad" -eq 0 ] && [ "$checked" -gt 20 ] && pass "ningun bash ($checked) ni lectura de config ($reads comandos) queda denegado en el catalogo" || fail 'hay llamadas denegadas o un preambulo reintroducido'

printf '%s\n' '[la guardia detecta regresiones]'
rules="$(jq -c '.agents[] | select(.id == "command-entry-next-order") | .rules' <<< "$OUT")"
[ "$(evaluate "$rules" bash "printf '%s\\n' \"\$PWD\"")" = deny ] && pass 'el subcomando del antiguo preambulo cae en deny' || fail 'el subcomando del preambulo no se deniega'

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
