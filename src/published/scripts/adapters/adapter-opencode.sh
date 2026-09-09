#!/usr/bin/env bash
# Renderizador OpenCode de artefactos publicados neutrales. Se invoca mediante
# generate-published-adapters.sh; no escribe fuera de stdout.
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MAPPING="$SCRIPT_DIR/../../contract/opencode-permissions.json"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd -P)"
SKILLS_ROOT="$REPO_ROOT/skills"
HOOKS_CONTRACT="$REPO_ROOT/src/published/hooks/interactive-hooks.json"
HOOKS_VALIDATOR="$REPO_ROOT/src/published/scripts/validate-interactive-hooks.sh"

error() { printf '%s\n' "$1" >&2; return 1; }
frontmatter() { awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$1"; }
body() { awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$1"; }
needs_package_root() { case "$1" in *'{{mefisto:run '*|*'{{mefisto:package-root}}'*) return 0 ;; *) return 1 ;; esac; }

package_root_preamble() {
    cat <<'EOF'
```bash
mefisto_opencode_data_root() {
    if [ -n "${XDG_DATA_HOME:-}" ]; then printf '%s/mefisto\n' "$XDG_DATA_HOME"
    elif [ "$(uname -s)" = Darwin ]; then printf '%s/Library/Application Support/mefisto\n' "$HOME"
    else printf '%s/.local/share/mefisto\n' "$HOME"; fi
}
mefisto_opencode_launcher="$(mefisto_opencode_data_root)/active/bin/mefisto-opencode"
if [ ! -f "$mefisto_opencode_launcher" ] || [ -L "$mefisto_opencode_launcher" ] || [ ! -x "$mefisto_opencode_launcher" ]; then
    printf '%s\n' 'ERROR OpenCode: no hay una release activa valida; instale o active la release OpenCode.' >&2; exit 1
fi
MEFISTO_PACKAGE_ROOT="$("$mefisto_opencode_launcher" package-root)" || {
    printf '%s\n' 'ERROR OpenCode: no se pudo resolver la release activa; instale o active la release OpenCode.' >&2; exit 1;
}
case "$MEFISTO_PACKAGE_ROOT" in
    /*) ;;
    *) printf '%s\n' 'ERROR OpenCode: la release activa no devolvio una raiz absoluta; reinstale o active la release OpenCode.' >&2; exit 1 ;;
esac
MEFISTO_PACKAGE_ROOT="$(cd "$MEFISTO_PACKAGE_ROOT" 2>/dev/null && pwd -P)" || {
    printf '%s\n' 'ERROR OpenCode: la release activa no existe; reinstale o active la release OpenCode.' >&2; exit 1;
}
export MEFISTO_PACKAGE_ROOT
```
EOF
}

permission_json() {
    local rel="$1" capabilities="$2" mode="$3" cap
    [ -f "$MAPPING" ] || { error "$rel: capabilities: no existe el mapping de permisos OpenCode"; return 1; }
    if ! jq -e '
      . as $mapping |
      ([.always_deny[], "question", .capability_scalar[][],
        .capability_map[].keys[]] | unique) as $mapped |
      (.supported_permissions | length) == 17 and
      (.supported_permissions | unique | length) == 17 and
      (.supported_permissions | all(. as $key | $mapped | index($key) != null)) and
      ($mapped | all(. as $key | $mapping.supported_permissions | index($key) != null))
    ' "$MAPPING" >/dev/null 2>&1; then
        error "$rel: capabilities: mapping OpenCode incompleto o invalido"
        return 1
    fi
    while IFS= read -r cap; do
        [ -z "$cap" ] && continue
        if ! jq -e --arg cap "$cap" '((.capability_scalar | keys) + (.capability_map | keys)) | index($cap) != null' "$MAPPING" >/dev/null 2>&1; then
            error "$rel: capabilities: capacidad '$cap' sin mapping OpenCode"
            return 1
        fi
    done < <(printf '%s' "$capabilities" | jq -r '.[]')
    jq -cn --slurpfile mapping "$MAPPING" --argjson capabilities "$capabilities" --arg mode "$mode" '
      ($mapping[0]) as $m |
      (reduce ($m.always_deny[]) as $key ({}; . + {($key): "deny"})) +
      {question: ($m.question[$mode] // "deny")} +
      (reduce ($m.capability_scalar | to_entries[]) as $entry ({};
        . + (reduce ($entry.value[]) as $key ({};
          . + {($key): (if $capabilities | index($entry.key) then "allow" else "deny" end)})))) +
      (reduce ($m.capability_map | to_entries[]) as $entry ({};
        ($entry.value) as $spec |
        . + (reduce ($spec.keys[]) as $key ({};
          . + {($key): (if $capabilities | index($entry.key)
                         then ({"*": $spec.catch_all} + reduce ($spec.rules[]) as $rule ({}; . + {($rule.pattern): $rule.value}))
                         else {"*": "deny"} end)}))))'
}

translate_body() {
    local rel="$1" input="$2" line original prefix suffix script args translated
    while IFS= read -r line || [ -n "$line" ]; do
        original="$line"
        if [[ "$line" =~ ^[[:space:]]*\{\{mefisto:assert-consumer-repo\}\}[[:space:]]*$ ]]; then
            printf '%s\n' 'Antes de continuar, aborta si existe `src/internal/scripts/generate-internal-adapters.sh`: ese directorio es el repositorio de Mefisto, no un consumidor.'
        elif [[ "$line" =~ ^[[:space:]]*\{\{mefisto:launch-agent[[:space:]]+([a-z0-9-]+)\}\}[[:space:]]*$ ]]; then
            printf 'Actua como el agente `%s` con este mensaje inicial: $ARGUMENTS\n' "${BASH_REMATCH[1]}"
        else
            # Se reemplaza de derecha a izquierda para admitir varias
            # directivas inline sin perder el texto que las rodea.
            while [[ "$line" == *'{{mefisto:'* ]]; do
                translated=""
                if [[ "$line" =~ ^(.*)\{\{mefisto:run[[:space:]]+([^[:space:]]+)[[:space:]]+([^}]*)\}\}(.*)$ ]]; then
                    prefix="${BASH_REMATCH[1]}"; script="${BASH_REMATCH[2]}"; args="${BASH_REMATCH[3]}"; suffix="${BASH_REMATCH[4]}"
                    args="$(printf '%s' "$args" | sed -E 's/[[:space:]]+$//')"
                    translated="${prefix}"'"${MEFISTO_PACKAGE_ROOT}'"/scripts/${script}\" ${args}${suffix}"
                elif [[ "$line" =~ ^(.*)\{\{mefisto:package-root\}\}(.*)$ ]]; then
                    translated="${BASH_REMATCH[1]}"'${MEFISTO_PACKAGE_ROOT}'"${BASH_REMATCH[2]}"
                elif [[ "$line" =~ ^(.*)\{\{mefisto:config-path\}\}(.*)$ ]]; then
                    translated="${BASH_REMATCH[1]}.mefisto/harness.config.json${BASH_REMATCH[2]}"
                elif [[ "$line" =~ ^(.*)\{\{mefisto:state-path[[:space:]]+([A-Za-z0-9][A-Za-z0-9._/-]*)\}\}(.*)$ ]]; then
                    translated="${BASH_REMATCH[1]}.mefisto/pipeline/${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
                elif [[ "$line" =~ ^(.*)\{\{mefisto:command[[:space:]]+([a-z0-9-]+)\}\}(.*)$ ]]; then
                    translated="${BASH_REMATCH[1]}/mefisto:${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
                else
                    error "$rel: body: directiva sin mapping OpenCode: '$original'"
                    return 1
                fi
                line="$translated"
            done
            printf '%s\n' "$line"
        fi
    done <<< "$input"
}

launch_agent_id() {
    local input="$1" line
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^[[:space:]]*\{\{mefisto:launch-agent[[:space:]]+([a-z0-9-]+)\}\}[[:space:]]*$ ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <<< "$input"
}

# OpenCode descubre Skills por directorio. La fuente permanece nativa para
# Claude; este borde adapta a la vez el directorio y el campo name (ADR-0050).
skill_frontmatter_value() {
    local key="$1" source="$2"
    awk -v key="$key" '
        NR == 1 { if ($0 != "---") exit 1; next }
        $0 == "---" { closed=1; exit }
        $0 ~ "^" key ":[[:space:]]*" {
            found++
            value=$0
            sub("^" key ":[[:space:]]*", "", value)
            sub(/[[:space:]]+$/, "", value)
        }
        END {
            if (!closed || found != 1) exit 1
            print value
        }
    ' "$source"
}

skill_frontmatter_string() {
    local key="$1" source="$2" raw
    raw="$(skill_frontmatter_value "$key" "$source")" || return 1
    case "$raw" in
        \"*\") printf '%s' "$raw" | jq -Rer 'fromjson | strings' ;;
        \'*\') printf '%s' "$raw" | sed "s/^'//; s/'$//; s/''/'/g" ;;
        \"*|*\"|\'*|*\') return 1 ;;
        *) printf '%s' "$raw" ;;
    esac
}

validate_skill_links() {
    local skill_root="$1" source="$2" match target target_dir target_file physical_root physical_target
    physical_root="$(cd "$skill_root" && pwd -P)" || return 1
    while IFS= read -r match; do
        target="${match#](}"
        case "$target" in ''|*'://'*|mailto:*|/*|\#*) continue ;; esac
        target_dir="$(dirname "$source")"
        target_file="$target_dir/$target"
        [ -e "$target_file" ] && [ ! -L "$target_file" ] || { error "$source: links: enlace local no resoluble: $target"; return 1; }
        physical_target="$(cd "$(dirname "$target_file")" && pwd -P)/$(basename "$target_file")" || return 1
        case "$physical_target" in "$physical_root"/*) ;; *) error "$source: links: enlace local fuera del Skill: $target"; return 1 ;; esac
    done < <(grep -hoE '\]\([^ )#]+' "$source" 2>/dev/null || true)
}

validate_skills() {
    local skill skill_id source_name description adapted link_source entry invalid_entry
    [ -d "$SKILLS_ROOT" ] && [ ! -L "$SKILLS_ROOT" ] || { error 'skills: la raiz publicada no existe o es un symlink'; return 1; }
    while IFS= read -r skill; do
        [ ! -L "$skill" ] || { error "${skill#"$REPO_ROOT/"}: skill no puede ser symlink"; return 1; }
        skill_id="$(basename "$skill")"
        printf '%s\n' "$skill_id" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$' || { error "$skill_id: id de Skill invalido"; return 1; }
        [ -f "$skill/SKILL.md" ] && [ ! -L "$skill/SKILL.md" ] || { error "skills/$skill_id: falta SKILL.md regular"; return 1; }
        source_name="$(skill_frontmatter_string name "$skill/SKILL.md")" || { error "skills/$skill_id/SKILL.md: frontmatter o name invalido"; return 1; }
        [ "$source_name" = "$skill_id" ] || { error "skills/$skill_id/SKILL.md: name debe coincidir con el directorio"; return 1; }
        adapted="mefisto-$skill_id"
        [ "${#adapted}" -le 64 ] || { error "skills/$skill_id: nombre OpenCode supera 64 caracteres"; return 1; }
        description="$(skill_frontmatter_string description "$skill/SKILL.md")" || { error "skills/$skill_id/SKILL.md: falta description valida"; return 1; }
        [ "${#description}" -ge 1 ] && [ "${#description}" -le 1024 ] || { error "skills/$skill_id/SKILL.md: description debe tener entre 1 y 1024 caracteres"; return 1; }
        while IFS= read -r link_source; do validate_skill_links "$skill" "$link_source" || return 1; done < <(find "$skill" -type f | LC_ALL=C sort)
    done < <(find "$SKILLS_ROOT" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
    for entry in "$SKILLS_ROOT"/*; do
        [ -e "$entry" ] || continue
        [ -d "$entry" ] || { error "${entry#"$REPO_ROOT/"}: un Skill debe ser un directorio"; return 1; }
    done
    if find "$SKILLS_ROOT" -type l -print -quit | grep -q .; then error 'skills: no se admiten symlinks en la fuente'; return 1; fi
    invalid_entry="$(find "$SKILLS_ROOT" ! -type f ! -type d -print -quit)"
    [ -z "$invalid_entry" ] || { error "${invalid_entry#"$REPO_ROOT/"}: recurso de Skill no regular"; return 1; }
}

skill_assets() {
    local source skill_id relative adapted asset_id
    validate_skills || return 1
    while IFS= read -r source; do
        relative="${source#"$SKILLS_ROOT"/}"
        skill_id="${relative%%/*}"
        relative="${relative#*/}"
        adapted="mefisto-$skill_id"
        asset_id="skills/$skill_id/$relative"
        jq -cn --arg id "$asset_id" --arg source "skills/$skill_id/$relative" --arg destination "skills/$adapted/$relative" --arg mode 0644 '{id: $id, source: $source, destination: $destination, mode: $mode}'
    done < <(find "$SKILLS_ROOT" -type f | LC_ALL=C sort) | jq -s .
}

render_skill_asset() {
    local asset_id="$1" source="$2" skill_id adapted
    case "$asset_id" in skills/*/SKILL.md) ;; *) cat "$source"; return ;; esac
    skill_id="${asset_id#skills/}"; skill_id="${skill_id%%/*}"; adapted="mefisto-$skill_id"
    awk -v name="$adapted" 'NR == 1 { print; next } $0 == "---" && !closed { closed=1; print; next } !closed && $0 ~ /^name:[[:space:]]*/ { print "name: " name; next } { print }' "$source"
}

opencode_release_identity() {
    local identity="$1" plugin="$REPO_ROOT/.claude-plugin/plugin.json" version commit
    [ -f "$identity" ] && [ ! -L "$identity" ] || { error 'release-identity.json: fuente ausente o no regular'; return 1; }
    [ -f "$plugin" ] && [ ! -L "$plugin" ] || { error 'plugin.json: fuente ausente o no regular'; return 1; }
    jq -e '(keys | sort) == ["commit", "schemaVersion", "version"] and .schemaVersion == 1 and (.version | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)")) and (.commit | type == "string" and test("^[0-9a-f]{40}$"))' "$identity" >/dev/null 2>&1 || { error 'release-identity.json: schema, version o commit invalidos'; return 1; }
    version="$(jq -er '.version' "$identity")" && commit="$(jq -er '.commit' "$identity")" || return 1
    [ "$(jq -er '.version | strings' "$plugin" 2>/dev/null)" = "$version" ] || { error 'release-identity.json: version distinta de .claude-plugin/plugin.json'; return 1; }
    jq -cn --arg version "$version" --arg commit "$commit" '{schemaVersion:1,runtime:"opencode",version:$version,commit:$commit}'
}

validate_interactive_hooks() {
    [ -x "$HOOKS_VALIDATOR" ] || { error 'interactive-hooks: falta validador ejecutable'; return 1; }
    "$HOOKS_VALIDATOR" "$HOOKS_CONTRACT" || return 1
    jq -e '[.bindings[] | {id,signal,action,destinations,persistedFields,delivery}] | length == 7 and ([.[].id] | sort) == ["append-dotnet-test-result","append-file-change","append-session","append-session-model","append-terraform-result","record-active-release","remind-field-notes"] and all(.[]; .delivery == {mode:"sync",failure:"continue",timeoutSeconds:null})' "$HOOKS_CONTRACT" >/dev/null || { error 'interactive-hooks: bindings o delivery no representables'; return 1; }
}

render_observability_plugin() {
    validate_interactive_hooks || return 1
    cat <<'EOF'
// GENERADO por src/published/scripts/adapters/adapter-opencode.sh desde src/published/hooks/interactive-hooks.json. No editar a mano.
import { appendFile, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const rootOf = (context) => typeof context.worktree === "string" ? context.worktree : context.directory;
const now = () => new Date().toISOString();
const clock = () => new Date().toISOString().slice(11, 19);
const safe = async (work) => { try { await work(); } catch { /* failure: continue */ } };
const pipeline = (root) => root && path.join(root, ".mefisto", "pipeline");
const identity = async (client) => {
  try {
    const manifest = JSON.parse(await readFile(path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "mefisto-manifest.json"), "utf8"));
    return manifest && manifest.schemaVersion === 1 && manifest.runtime === "opencode" && typeof manifest.version === "string" && typeof manifest.commit === "string" ? manifest : { version: null, commit: null };
  } catch { await diagnostic(client, "Mefisto: manifiesto de release no disponible."); return { version: null, commit: null }; }
};
const append = async (root, file, line) => { const state = pipeline(root); if (!state) return; await mkdir(state, { recursive: true }); await appendFile(path.join(state, file), `${JSON.stringify(line)}\n`, "utf8"); };
const observed = async (root, sessionID, model) => {
  try { const text = await readFile(path.join(pipeline(root), "sessions.jsonl"), "utf8"); return text.split("\n").some((line) => { try { const value = JSON.parse(line); return value.record_type === "session.model-observed" && value.session_id === sessionID && value.model === model; } catch { return false; } }); } catch { return false; }
};
const diagnostic = async (client, message) => safe(async () => { await client?.app?.log?.({ body: { service: "mefisto", level: "warn", message } }); });
const sessionID = (input) => input?.sessionID ?? input?.sessionId ?? input?.properties?.info?.id ?? input?.properties?.session?.id;
const toolName = (input) => String(input?.tool ?? input?.toolName ?? "").toLowerCase();
const args = (input) => input?.args && typeof input.args === "object" ? input.args : {};
const exitCode = (output) => output?.exitCode ?? output?.metadata?.exitCode ?? output?.metadata?.status;

export default async function mefistoObservability(context) {
  const root = rootOf(context);
  const release = await identity(context.client);
  let planReported = false;
  const planUnsupported = async () => { if (!planReported) { planReported = true; await diagnostic(context.client, "Mefisto: plan.completed no soportado por OpenCode."); } };
  await planUnsupported();
  return {
    event: async ({ event } = {}) => safe(async () => {
      if (event?.type !== "session.created") return;
      const id = sessionID(event); if (typeof id !== "string" || !root) return;
      const state = pipeline(root); await mkdir(state, { recursive: true });
       await writeFile(path.join(state, ".plugin-root"), path.dirname(path.dirname(fileURLToPath(import.meta.url))), "utf8");
      await append(root, "sessions.jsonl", { record_type: "session.started", session_id: id, transcript_path: null, cwd: root, source: null, timestamp: now(), runtime: "opencode", model: null, harness_version: release.version, harness_commit: release.commit });
    }),
    "chat.params": async (input) => safe(async () => {
      const id = sessionID(input); const model = input?.model;
      if (!root || typeof id !== "string" || !model || typeof model.id !== "string" || !model.id || typeof model.providerID !== "string" || !model.providerID) return;
      const value = `${model.providerID}/${model.id}`; if (await observed(root, id, value)) return;
      await append(root, "sessions.jsonl", { record_type: "session.model-observed", session_id: id, timestamp: now(), runtime: "opencode", model: value, harness_version: release.version, harness_commit: release.commit });
    }),
    "tool.execute.after": async (input, output) => safe(async () => {
      if (!root) return; const tool = toolName(input); const inputArgs = args(input);
      if (["write", "edit", "patch"].includes(tool)) { const file = inputArgs.filePath ?? inputArgs.file_path ?? inputArgs.path ?? "(desconocido)"; if (typeof file === "string") await append(root, "events.log", { time: clock(), family: "archivo", file_path: file }); return; }
      if (!["bash", "shell"].includes(tool)) return;
      const command = typeof inputArgs.command === "string" ? inputArgs.command : "";
      if (/(^|\s)dotnet\s+test(\s|$)/.test(command)) { await append(root, "events.log", { time: clock(), family: "test", result: exitCode(output) === 0 ? "PASS" : "FAIL" }); return; }
      const match = /(^|\s)terraform\s+(plan|apply|init|validate)(\s|$)/.exec(command);
      if (match) await append(root, "events.log", { time: clock(), family: "terraform", terraform_subcommand: match[2], result: exitCode(output) === 0 ? "OK" : "ERROR" });
    }),
  };
}
EOF
}

render() {
    local source="$1" marker="$2" rel fm instance kind artifact_id raw_body translated preamble='' mode permissions agent
    rel="${source#*/src/published/}"
    rel="src/published/$rel"
    fm="$(frontmatter "$source")" || { error "$rel: frontmatter: no se pudo extraer"; return 1; }
    instance="$(printf '%s\n' "$fm" | jq -c '.')" || { error "$rel: frontmatter: no es JSON valido"; return 1; }
    kind="$(printf '%s' "$instance" | jq -r '.kind')"
    artifact_id="$(printf '%s' "$instance" | jq -r '.id')"
    raw_body="$(body "$source")" || { error "$rel: body: no se pudo extraer"; return 1; }
    if [ "$(printf '%s' "$instance" | jq '[.skills[]?] | length')" -gt 0 ]; then error "$rel: skills: OpenCode no implementa Skills publicados todavia"; return 1; fi
    if [ "$(printf '%s' "$instance" | jq '[.mcp[]?] | length')" -gt 0 ]; then error "$rel: mcp: OpenCode no implementa MCP publicado todavia"; return 1; fi
    translated="$(translate_body "$rel" "$raw_body")" || return 1
    if needs_package_root "$raw_body"; then preamble="$(package_root_preamble)"; fi
    printf '%s\n' '---'
    printf 'description: %s\n' "$(printf '%s' "$instance" | jq -r '.description | @json')"
    if [ "$kind" = agent ]; then
        mode="$(printf '%s' "$instance" | jq -r '.mode')"
        permissions="$(permission_json "$rel" "$(printf '%s' "$instance" | jq -c '.capabilities // []')" "$mode")" || return 1
        printf 'mode: %s\npermission: %s\n' "$(printf '%s' "$mode" | jq -Rr '@json')" "$permissions"
    else
        agent="$(printf '%s' "$instance" | jq -r '.agent // empty')"
        [ -n "$agent" ] || agent="$(launch_agent_id "$raw_body")"
        [ -z "$agent" ] || printf 'agent: %s\nsubtask: true\n' "$(printf '%s' "$agent" | jq -Rr '@json')"
    fi
    printf '%s\n%s\n' '---' "$marker"
    [ -z "$preamble" ] || printf '%s\n' "$preamble"
    printf '%s\n' "$translated"
}

case "${1:-}" in
    root) printf '%s\n' 'dist/opencode' ;;
    path)
        case "${2:-}" in src/published/agents/*.md) printf 'agents/%s\n' "$(basename "$2")" ;; src/published/commands/*.md) printf 'commands/mefisto:%s\n' "$(basename "$2")" ;; *) error "$2: path: fuente publicada desconocida" ;; esac ;;
    render) [ "$#" -eq 3 ] || error 'render: se esperaban fuente y marcador'; render "$2" "$3" ;;
    assets) validate_interactive_hooks && { skill_assets | jq '. + [{id:"mefisto-manifest",source:"src/published/release-identity.json",destination:"mefisto-manifest.json",mode:"0644"},{id:"interactive-observability",source:"src/published/hooks/interactive-hooks.json",destination:"plugins/mefisto-observability.js",mode:"0644"}]'; } ;;
    render-asset)
        [ "$#" -eq 3 ] || error 'render-asset: se esperaban id y fuente'
        case "$2" in mefisto-manifest) opencode_release_identity "$3" ;; interactive-observability) render_observability_plugin ;; *) render_skill_asset "$2" "$3" ;; esac ;;
    *) error 'uso: adapter-opencode.sh root|path|render|assets|render-asset' ;;
esac
