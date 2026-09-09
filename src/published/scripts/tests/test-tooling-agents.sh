#!/usr/bin/env bash
# Verifica el corte vertical de los agentes neutrales del pipeline de tooling.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
FIXTURES="$HERE/fixtures/tooling-agents"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }
frontmatter() { awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$1"; }
body() { awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$1"; }

echo '[fuentes] contrato neutral y responsabilidades'
for agent in tooling-writer tooling-reviewer; do
    source="$REPO_ROOT/src/published/agents/$agent.md"
    if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$source" >/dev/null; then pass "$agent valida"; else fail "$agent no valida"; fi
    metadata="$(frontmatter "$source")"
    expected_profile=balanced; [ "$agent" = tooling-reviewer ] && expected_profile=deep
    if printf '%s' "$metadata" | jq -e --arg id "$agent" --arg profile "$expected_profile" \
        '.kind == "agent" and .id == $id and .mode == "all" and .profile == $profile and .capabilities == ["read", "edit", "shell"] and (keys | sort) == ["capabilities", "description", "id", "kind", "mode", "profile"]' >/dev/null; then
        pass "$agent declara solo el contrato neutral esperado"
    else
        fail "$agent no declara el contrato neutral esperado"
    fi
    agent_body="$(body "$source")"
    contains "$agent_body" '{{mefisto:assert-consumer-repo}}' "$agent conserva el guard"
    contains "$agent_body" 'archivo de summary' "$agent declara el summary entregado"
    for token in '.claude/' '.opencode/' '.mefisto/' 'Claude' 'OpenCode' 'model:' 'tools:' 'permission:'; do
        absent "$agent_body" "$token" "$agent no fija token de runtime o ruta de estado: $token"
    done
done
writer="$(< "$REPO_ROOT/src/published/agents/tooling-writer.md")"
reviewer="$(< "$REPO_ROOT/src/published/agents/tooling-reviewer.md")"
contains "$writer" 'scope exacto recibido' 'writer respeta el scope recibido'
contains "$writer" 'patrones existentes' 'writer lee patrones antes de editar'
contains "$writer" 'comandos de verificacion permitidos' 'writer limita sus verificaciones'
contains "$writer" 'no hagas preguntas' 'writer opera sin interaccion'
contains "$writer" 'logica de dominio, artefactos de Mefisto o rutas fuera del scope' 'writer bloquea trabajo ajeno al tooling permitido'
contains "$writer" '## Implementado' 'writer declara Implementado'
contains "$writer" '## Verificacion' 'writer declara Verificacion'
contains "$writer" '## Pendiente/bloqueos' 'writer declara Pendiente/bloqueos'
contains "$reviewer" 'Audita el diff contra el issue y las directivas efectivas' 'reviewer audita issue y directivas'
contains "$reviewer" 'Corrige directamente' 'reviewer corrige directamente'
contains "$reviewer" 'fuera de scope sin ampliar la tarea' 'reviewer contiene cambios fuera de scope'
contains "$reviewer" 'Verifica las correcciones' 'reviewer verifica sus correcciones'
contains "$reviewer" '## Resultado' 'reviewer declara Resultado'
contains "$reviewer" '## Correcciones' 'reviewer declara Correcciones'
contains "$reviewer" '## Verificacion' 'reviewer declara Verificacion'
for role in "$writer" "$reviewer"; do
    contains "$role" 'Nunca hagas push ni abras un pull request' 'el agente no publica rama ni PR'
done

echo '[salidas] snapshots y capacidades derivadas'
for runtime in claude opencode; do
    for agent in tooling-writer tooling-reviewer; do
        actual="$REPO_ROOT/dist/$runtime/agents/$agent.md"
        expected="$FIXTURES/expected-$runtime-$agent.md"
        if cmp -s "$expected" "$actual"; then pass "$runtime/$agent coincide con el snapshot"; else fail "$runtime/$agent difiere del snapshot"; fi
        rendered="$(< "$actual")"
        contains "$rendered" 'Antes de continuar, aborta si existe' "$runtime/$agent traduce el guard"
        absent "$rendered" '{{mefisto:' "$runtime/$agent no conserva directivas"
        case "$rendered" in *[Mm][Cc][Pp]*) fail "$runtime/$agent omite MCP" ;; *) pass "$runtime/$agent omite MCP" ;; esac
        if [ "$runtime" = claude ]; then
            case "$rendered" in *[Ss]kill*) fail "$runtime/$agent omite Skills" ;; *) pass "$runtime/$agent omite Skills" ;; esac
        else
            contains "$rendered" '"skill":"deny"' "$runtime/$agent omite Skills habilitados"
        fi
    done
done
claude_writer="$(< "$REPO_ROOT/dist/claude/agents/tooling-writer.md")"
claude_reviewer="$(< "$REPO_ROOT/dist/claude/agents/tooling-reviewer.md")"
contains "$claude_writer" 'name: "tooling-writer"' 'Claude expone el id del writer'
contains "$claude_reviewer" 'name: "tooling-reviewer"' 'Claude expone el id del reviewer'
contains "$claude_writer" 'tools: "Read, Glob, Grep, Edit, Write, Bash"' 'Claude writer deriva solo read/edit/shell'
contains "$claude_reviewer" 'tools: "Read, Glob, Grep, Edit, Write, Bash"' 'Claude reviewer deriva solo read/edit/shell'
contains "$claude_writer" 'model: "sonnet"' 'Claude materializa perfil balanced'
absent "$claude_reviewer" 'model:' 'Claude preserva herencia del perfil deep'
opencode_writer="$(< "$REPO_ROOT/dist/opencode/agents/tooling-writer.md")"
opencode_reviewer="$(< "$REPO_ROOT/dist/opencode/agents/tooling-reviewer.md")"
for rendered in "$opencode_writer" "$opencode_reviewer"; do
    contains "$rendered" 'mode: "all"' 'OpenCode conserva mode all'
    contains "$rendered" '"read":{"*":"allow"' 'OpenCode permite lectura'
    contains "$rendered" '"edit":{"*":"allow"' 'OpenCode permite edicion'
    contains "$rendered" '"bash":{"*":"deny"' 'OpenCode mantiene shell deny por defecto'
    contains "$rendered" '"webfetch":"deny"' 'OpenCode deniega web'
    contains "$rendered" '"skill":"deny"' 'OpenCode deniega Skills'
    contains "$rendered" '"task":"deny"' 'OpenCode deniega delegacion'
    absent "$rendered" 'model:' 'OpenCode hereda modelo'
done

echo '[integracion] generacion de las cuatro salidas y check limpio'
if "$GENERATOR" --out "$WORK" \
    "$REPO_ROOT/src/published/agents/tooling-writer.md" \
    "$REPO_ROOT/src/published/agents/tooling-reviewer.md" >/dev/null; then
    pass 'el generador procesa ambos agentes en conjunto'
else
    fail 'el generador no proceso ambos agentes en conjunto'
fi
generated_count="$(find "$WORK/dist" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
[ "$generated_count" = 41 ] && pass 'la integracion genera agentes, clausura, Skills e inventarios' || fail "la integracion genero $generated_count salidas, no 41"
if jq -e '.schemaVersion == 1 and (.assets | length == 14)' "$WORK/dist/claude/.mefisto-generated-assets.json" >/dev/null && jq -e '.schemaVersion == 1 and (.assets | length == 21) and any(.assets[]; .destination == "skills/mefisto-projections/read-apis.md") and any(.assets[]; .destination == "skills/mefisto-comment-cleanup/ejemplos.md")' "$WORK/dist/opencode/.mefisto-generated-assets.json" >/dev/null; then
    pass 'los inventarios atribuyen clausura y Skills OpenCode'
else
    fail 'los inventarios de integracion no atribuyen los Skills'
fi
for runtime in claude opencode; do
    for agent in tooling-writer tooling-reviewer; do
        if cmp -s "$FIXTURES/expected-$runtime-$agent.md" "$WORK/dist/$runtime/agents/$agent.md"; then
            pass "integracion $runtime/$agent coincide con el snapshot"
        else
            fail "integracion $runtime/$agent difiere del snapshot"
        fi
    done
done
if "$GENERATOR" --check --out "$WORK" \
    "$REPO_ROOT/src/published/agents/tooling-writer.md" \
    "$REPO_ROOT/src/published/agents/tooling-reviewer.md" >/dev/null; then
    pass 'check aislado no detecta divergencias, huerfanos ni copias manuales'
else
    fail 'check aislado detecto divergencias, huerfanos o copias manuales'
fi
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"
