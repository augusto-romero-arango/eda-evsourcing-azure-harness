#!/usr/bin/env bash
# Verifica (#2009) que el plugin de entrada OpenCode serializa como escalar las
# claves de permiso sin patrones (webfetch, websearch, list, glob, grep) y como
# mapa solo las que lo admiten, para todo el catalogo. Sin runtime ni red.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
ADAPTER="$REPO_ROOT/src/published/scripts/adapters/adapter-opencode.sh"
SOURCE="$REPO_ROOT/src/published/contract/command-entry.json"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

VERSION="$(jq -r .version "$REPO_ROOT/src/published/release-identity.json")"; COMMIT="$(jq -r .commit "$REPO_ROOT/src/published/release-identity.json")"
make_release() { # root rules-json
  local root="$1"
  mkdir -p "$root/plugins" "$root/scripts" "$root/fake"
  "$ADAPTER" render-asset command-entry-plugin "$SOURCE" > "$root/plugins/mefisto-command-entry.js" || exit 1
  cp "$REPO_ROOT/dist/opencode/command-entry-manifest.json" "$root/command-entry-manifest.json"
  jq -n --arg v "$VERSION" --arg c "$COMMIT" '{schemaVersion:1,runtime:"opencode",version:$v,commit:$c}' > "$root/mefisto-manifest.json"
  jq -n --argjson rules "$2" --slurpfile m "$SOURCE" '
    {schemaVersion:1,admissionScope:"entry",status:"ready",reasonCode:"OK",projectionDigest:"d1",
      agents:[$m[0].commands[].id | {id:("command-entry-"+.),rules:$rules}],
      bindings:[$m[0].commands[].id | {command:("mefisto:"+.),agent:("command-entry-"+.),admitted:false}]}' > "$root/fake/config.json"
  printf '#!/usr/bin/env bash\ncat >/dev/null\ncat "$(cd "$(dirname "$0")/.." && pwd -P)/fake/config.json"\n' > "$root/scripts/resolve-command-entry.sh"
  chmod 0755 "$root/scripts/resolve-command-entry.sh"
}
cat > "$WORK/run.mjs" <<'EOS'
import { pathToFileURL } from "node:url";
const [root, project] = process.argv.slice(2);
const factory = (await import(pathToFileURL(root + "/plugins/mefisto-command-entry.js").href)).default;
const hooks = await factory({ client: { app: { log: async () => {} }, session: { get: async () => ({ data: { id: "s1", directory: project, permission: [] } }) } }, directory: project, worktree: project });
const ids = JSON.parse(process.env.CATALOG);
const cfg = { default_agent: "build", command: Object.fromEntries(ids.map((id) => ["mefisto:" + id, { template: "T-" + id, agent: "command-entry-" + id, subtask: false }])), agent: {} };
await hooks.config(cfg);
console.log(JSON.stringify(cfg.agent));
EOS
mkdir -p "$WORK/project/.claude"; printf '{}\n' > "$WORK/project/.claude/harness.config.json"; git -C "$WORK/project" init -q
count="$(jq '[.commands[].id] | length' "$SOURCE")"
GOOD='[{"permission":"webfetch","pattern":"*","value":"deny"},{"permission":"websearch","pattern":"*","value":"deny"},
 {"permission":"list","pattern":"*","value":"allow"},{"permission":"glob","pattern":"*","value":"deny"},{"permission":"grep","pattern":"*","value":"allow"},
 {"permission":"read","pattern":"*","value":"deny"},{"permission":"read","pattern":"/r/*","value":"allow"},{"permission":"edit","pattern":"*","value":"deny"},
 {"permission":"bash","pattern":"*","value":"deny"},{"permission":"task","pattern":"*","value":"deny"},{"permission":"skill","pattern":"*","value":"deny"},
 {"permission":"external_directory","pattern":"*","value":"deny"},{"permission":"srv_*","pattern":"*","value":"allow"}]'
R="$WORK/good"; make_release "$R" "$GOOD"
out="$(CATALOG="$(jq -c '[.commands[].id]' "$SOURCE")" node "$WORK/run.mjs" "$R" "$WORK/project" 2>/dev/null)"
jq -e --argjson n "$count" '
  length == $n and
  all(.[]; .permission | (.webfetch == "deny" and .websearch == "deny" and .list == "allow" and .glob == "deny" and .grep == "allow" and .["srv_*"] == "allow")) and
  all(.[]; .permission | (.read | type) == "object" and (.edit | type) == "object" and (.bash | type) == "object" and (.task | type) == "object" and (.skill | type) == "object" and (.external_directory | type) == "object")' <<< "$out" >/dev/null \
  && pass "catalogo completo ($count): claves escalares como escalar, mapas solo donde el esquema los admite" || fail "serializacion de permisos: $out"

BAD='[{"permission":"webfetch","pattern":"https://x/*","value":"allow"}]'
R="$WORK/bad"; make_release "$R" "$BAD"
out="$(CATALOG="$(jq -c '[.commands[].id]' "$SOURCE")" node "$WORK/run.mjs" "$R" "$WORK/project" 2>/dev/null)"
jq -e 'all(.[]; has("permission") | not)' <<< "$out" >/dev/null && pass 'escalar con patron distinto de * se rechaza: ningun agente recibe politica propia' || fail "patron en clave escalar aceptado: $out"

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
