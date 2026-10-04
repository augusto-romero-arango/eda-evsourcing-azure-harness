#!/usr/bin/env bash
# Contrato del agente projections-scaffolder neutral y sus proyecciones publicadas (issue #1652).
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/agents/projections-scaffolder.md"
CLAUDE="$REPO_ROOT/dist/claude/agents/projections-scaffolder.md"
OPENCODE="$REPO_ROOT/dist/opencode/agents/projections-scaffolder.md"
MIRROR="$REPO_ROOT/agents/projections-scaffolder.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[a] metadata y perfil'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "agent" and .id == "projections-scaffolder" and .mode == "all" and .profile == "balanced" and .capabilities == ["read","edit","shell","web"] and (has("mcp") | not)' >/dev/null; then
    pass 'metadata agent/projections-scaffolder/all/balanced/read-edit-shell-web sin mcp'
else
    fail 'metadata neutral invalida'
fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:config-path}}' 'lee projections.enabled via config-path'
contains "$body" '{{mefisto:instructions-path}}' 'lee RootNamespace via instructions-path'
contains "$body" '{{mefisto:run validate-dockerfile.sh src/<RootNamespace>.Projections/Dockerfile}}' 'valida el Dockerfile via run'

echo '[fuentes] reverificacion condicional de pines'
SOURCE_FIXTURE="$HERE/fixtures/projections-scaffolder-sources/cases.json"
if jq -e '
    .schemaVersion == 1 and (.cases | length) == 8 and
    any(.cases[]; .id == "local-pines-intactos" and .expected == "sin-red-extra" and .localEvidence == ["adr","csproj","build","config-tests"]) and
    all(.cases[] | select(.id | startswith("nuget-index-")); .tool == "WebFetch" and .proof == "publicacion" and .requiredVersion != .latestAbsolute and (.fetchedUrl | endswith("/index.json"))) and
    all(.cases[] | select(.id | startswith("nuget-nuspec-")); .tool == "WebFetch" and .proof == "dependencias-y-firma" and (.fetchedUrl | endswith(".nuspec")) and .buildProof == "requisitos-y-firma") and
    ([.cases[] | select(.packageId == "Microsoft.Extensions.Hosting") | .requiredVersion] | unique) == ["10.0.10"] and
    ([.cases[] | select(.packageId == "Azure.Monitor.OpenTelemetry.Exporter") | .requiredVersion] | unique) == ["1.8.3"] and
    ([.cases[] | select(.packageId == "OpenTelemetry.Exporter.InMemory") | .requiredVersion] | unique) == ["1.17.0"] and
    any(.cases[]; .id == "fuente-web-ausente-pin-nuevo" and .expected == "NO VERIFICADO" and .localRunContinues == true) and
    all(.cases[]; ((.queryTerms // []) | join(" ") | test("https?://|secret|credential|token|curl"; "i") | not))
' "$SOURCE_FIXTURE" >/dev/null 2>&1; then
    pass 'fixture separa evidencia local, publicacion index, nuspec exacto y NO VERIFICADO'
else
    fail 'fixture de reverificacion de projections-scaffolder incompleta'
fi
for statement in \
    'no consultes red por defecto ni elijas `latest`' \
    'la **version y linea exactas**' \
    'El indice o `latest` solo prueban publicacion' \
    'informa **NO VERIFICADO**' \
    'No uses `curl` ni shell como sustituto' \
    'ni modifiques el DoR o tests para ocultar el faltante'; do
    contains "$body" "$statement" "conserva la regla de fuente: $statement"
done

echo '[b] ausencia de acoplamientos'
absent "$body" '.claude/harness.config.json' 'sin config legacy'
absent "$body" 'export MEFISTO_INSTRUCTIONS_PATH' 'sin export de instrucciones'
absent "$body" 'claude --agent' 'sin invocacion directa del CLI'
absent "$body" '/tmp/' 'sin /tmp'
if printf '%s\n' "$body" | grep -E '^[[:space:]]*rm ' | grep -q '\$REPO_ROOT'; then fail 'un rm usa $REPO_ROOT'; else pass 'ningun rm usa $REPO_ROOT'; fi

echo '[salidas]'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"
contains "$claude_body" 'name: "projections-scaffolder"' 'Claude expone el id'
contains "$claude_body" 'model: "sonnet"' 'Claude materializa balanced como sonnet'
contains "$claude_body" 'tools: "Read, Glob, Grep, Edit, Write, Bash, WebFetch, WebSearch"' 'Claude suma solo el par web'
absent "$opencode_body" 'model:' 'OpenCode no emite model'
contains "$opencode_body" '"webfetch":"allow"' 'OpenCode permite webfetch solo en este agente'
contains "$opencode_body" '"websearch":"allow"' 'OpenCode permite websearch solo en este agente'
absent "$claude_body" '/tmp/' 'Claude sin /tmp'
absent "$opencode_body" '/tmp/' 'OpenCode sin /tmp'

echo '[c] validacion del Dockerfile por script distribuido'
contains "$claude_body" 'MEFISTO_RUNTIME=claude "${MEFISTO_PACKAGE_ROOT}/scripts/validate-dockerfile.sh"' 'Claude invoca el script con su runtime'
contains "$opencode_body" 'MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/validate-dockerfile.sh"' 'OpenCode invoca el script con su runtime'
for text_var in claude_body opencode_body; do
    text="${!text_var}"
    absent "$text" 'docker info' "$text_var no ejecuta docker info directo"
    absent "$text" 'docker build -f "src/' "$text_var no ejecuta el docker build de validacion directo"
done
permission="$(awk 'NR == 1 { next } /^permission: / { sub(/^permission: /, ""); print; exit }' "$OPENCODE")"
if printf '%s' "$permission" | jq -e '.read["*"] == "allow" and .edit["*"] == "allow" and .bash["*"] == "deny" and .skill == "deny" and .task == "deny"' >/dev/null 2>&1 \
   && [[ "$opencode_body" == *'tools: {"microsoft-learn_*":false,"terraform_*":false}'* ]]; then
    pass 'OpenCode conserva lectura, escritura, shell y denegaciones ajenas al delta web'
else
    fail 'OpenCode altero permisos ajenos al delta web'
fi
for command in 'docker info' 'docker build -f x .' 'docker run x'; do
    if printf '%s' "$permission" | jq -e --arg c "$command" '.bash as $b | ($b | to_entries | map(select(.key != "*" and (.key | sub("\\*$"; "") as $pre | $c | startswith($pre))))) | length == 0 and $b["*"] == "deny"' >/dev/null 2>&1; then
        pass "OpenCode deniega '$command'"
    else
        fail "OpenCode no deniega '$command'"
    fi
done

echo '[d] cada rm casa una regla allow'
rms="$(printf '%s\n' "$body" | grep -E '^[[:space:]]*rm ' | sed 's/^[[:space:]]*//')"
[ -n "$rms" ] && pass 'hay rm en la doctrina' || fail 'no se encontraron rm'
while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    if printf '%s' "$permission" | jq -e --arg c "$cmd" '[.bash | to_entries[] | . as $e | select($e.value == "allow" and ($e.key | endswith("*")) and ($c | startswith($e.key | sub("\\*$"; ""))))] | length > 0' >/dev/null 2>&1; then
        pass "allow casa: $cmd"
    else
        fail "ninguna regla allow casa: $cmd"
    fi
done <<< "$rms"
for pattern in 'basename *' 'cd *' 'dotnet *' 'touch *' 'tail *' 'mkdir *' 'grep *' 'test *' 'ls *'; do
    if printf '%s' "$permission" | jq -e --arg p "$pattern" '.bash[$p] == "allow"' >/dev/null 2>&1; then pass "bash permite '$pattern'"; else fail "bash no permite '$pattern'"; fi
done

echo '[e] mirror'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror identico a dist/claude'; else fail 'mirror diverge'; fi
for inventory in "$REPO_ROOT/dist/claude/.mefisto-generated-assets.json" "$REPO_ROOT/dist/opencode/.mefisto-generated-assets.json"; do
    if jq -e '.assets[] | select(.destination == "agents/projections-scaffolder.md")' "$inventory" >/dev/null 2>&1 \
       && jq -e '.assets[] | select(.destination == "scripts/validate-dockerfile.sh")' "$inventory" >/dev/null 2>&1; then
        pass "$(basename "$(dirname "$inventory")") inventaria agente y script"
    else
        fail "$(basename "$(dirname "$inventory")") no inventaria agente y script"
    fi
done
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check al dia'; else fail '--check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
