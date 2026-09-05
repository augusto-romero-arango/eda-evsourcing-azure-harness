#!/usr/bin/env bash
# test-guards.sh -- Tests de los guards defensivos de skills publicados e internos.
#
# Valida que:
#   A) Los skills publicados (commands/*.md) llevan el guard "cwd != Mefisto"
#      al inicio (presencia del bloque que verifica .claude-plugin/plugin.json).
#   B) Los skills internos (.claude/commands/mefisto-*.md) llevan el guard inverso.
#   C) Los pipelines publicados (scripts/tooling-pipeline.sh, scripts/parallel-pipeline.sh,
#      scripts/batch-pipeline.sh, scripts/pr-sync.sh, scripts/tdd-pipeline.sh,
#      scripts/iac-pipeline.sh, scripts/scaffold-pipeline.sh, scripts/tmux-pipeline.sh)
#      y los scripts auxiliares publicados (appinsights-query.sh,
#      setup-github-ci.sh, setup-github-labels.sh, bootstrap-backend.sh,
#      seed-secret.sh, onboard-diagnose.sh, update-plugin.sh) abortan si se
#      sourcean en un contexto donde .claude-plugin/plugin.json existe.
#   D) Las funciones validate_*_scope_changes son sourceables sin errores.
#   F) Integridad de los Agent Skills (MEF-ADR-0033 seccion 4): el `name` del
#      frontmatter de cada SKILL.md coincide con su directorio, tiene
#      `description` no vacio, sus recursos de Nivel 3 referenciados existen, y
#      todo valor de `skills:` declarado por un agente resuelve a un Skill real.
#      Esta es la mitigacion que MEF-ADR-0033 delego al issue que creara el
#      primer Skill: un `skills:` mal escrito NO aborta el agente ni emite error
#      visible ("Claude Code skips it and logs a warning to the debug log"), asi
#      que en los pipelines headless (`claude -p`) el subagente correria sin su
#      doctrina y produciria codigo plausible pero ciego a ella.
#   G) Ningun bloque triple-backtick `bash` de commands/*.md contiene sintaxis
#      posicional de shell ($1..$9, ${N}, $*, $@, $#): Claude Code la expande como
#      placeholder de argumentos del slash command ANTES de entregar el texto al
#      modelo, incluso dentro de comillas simples de un heredoc o de un awk, y sin
#      argumentos la sustituye por cadena vacia -- un `awk '{print $1}'` llega al
#      modelo como `awk '{print }'`. Replica en el lado publicado (issue #443) el
#      guard que el bloque G de .claude/scripts/tests/test-batch-deps-validation.sh
#      aplica a .claude/commands/*.md (issue #436).
#
# Uso: scripts/tests/test-guards.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# -------- Bloque A: guards en skills publicados --------

echo "[A] Skills publicados (commands/*.md): guard 'cwd != Mefisto' presente"

PUBLISHED_SKILLS=(
    bitacora.md bug.md draft.md eraser-diagram.md fix-review.md health-check.md
    implement.md infra.md infra-base.md install-apim.md install-auth.md install-workos.md
    merge.md onboard.md parallel.md purge-store.md scaffold.md scaffold-mcp.md
    scaffold-projections.md seed-secret.md sequential.md tooling.md upgrade.md work-status.md
)

for skill in "${PUBLISHED_SKILLS[@]}"; do
    path="$REPO_ROOT/commands/$skill"
    if [ ! -f "$path" ]; then
        fail "$skill: archivo no existe"
        continue
    fi
    if grep -q '\.claude-plugin/plugin\.json' "$path"; then
        pass "$skill: menciona .claude-plugin/plugin.json"
    else
        fail "$skill: no menciona .claude-plugin/plugin.json (falta guard)"
    fi
done

# Cobertura del listado: un skill nuevo que nadie agregue a PUBLISHED_SKILLS quedaria sin
# verificar su guard, en silencio (fue el caso de install-apim/install-auth hasta el issue #367).
for path in "$REPO_ROOT"/commands/*.md; do
    skill="$(basename "$path")"
    listed=0
    for known in "${PUBLISHED_SKILLS[@]}"; do
        [ "$known" = "$skill" ] && listed=1 && break
    done
    if [ "$listed" -eq 1 ]; then
        pass "$skill: enumerado en PUBLISHED_SKILLS"
    else
        fail "$skill: existe en commands/ pero no esta en PUBLISHED_SKILLS (agregalo a este test)"
    fi
done

# -------- Bloque B: guards inversos en skills internos --------

echo ""
echo "[B] Skills internos (.claude/commands/mefisto-*.md): guard inverso presente"

INTERNAL_SKILLS=(
    mefisto-tooling.md mefisto-tooling-verbose.md mefisto-plan.md mefisto-bug.md
    mefisto-fix-review.md mefisto-merge.md mefisto-work-status.md
    mefisto-sequential.md mefisto-release.md mefisto-bitacora.md
)

for skill in "${INTERNAL_SKILLS[@]}"; do
    path="$REPO_ROOT/.claude/commands/$skill"
    if [ ! -f "$path" ]; then
        fail "$skill: archivo no existe"
        continue
    fi
    # El guard inverso verifica que el archivo NO existe -> aborta
    if grep -q '\.claude-plugin/plugin\.json' "$path"; then
        pass "$skill: menciona .claude-plugin/plugin.json (guard inverso)"
    else
        fail "$skill: no menciona .claude-plugin/plugin.json"
    fi
done

# Cobertura del listado, simetrica a la del Bloque A: un skill interno nuevo que nadie
# agregue a INTERNAL_SKILLS quedaria sin verificar su guard inverso, en silencio (fue el
# caso de mefisto-sequential/mefisto-release/mefisto-bitacora hasta el issue #530).
for path in "$REPO_ROOT"/.claude/commands/mefisto-*.md; do
    skill="$(basename "$path")"
    listed=0
    for known in "${INTERNAL_SKILLS[@]}"; do
        [ "$known" = "$skill" ] && listed=1 && break
    done
    if [ "$listed" -eq 1 ]; then
        pass "$skill: enumerado en INTERNAL_SKILLS"
    else
        fail "$skill: existe en .claude/commands/ pero no esta en INTERNAL_SKILLS (agregalo a este test)"
    fi
done

# -------- Bloque C: pipelines publicados abortan en repo de Mefisto --------

echo ""
echo "[C] Pipelines publicados: contienen guard contra repo de Mefisto"

PUBLISHED_PIPELINES=(
    tooling-pipeline.sh parallel-pipeline.sh batch-pipeline.sh pr-sync.sh
    tdd-pipeline.sh iac-pipeline.sh scaffold-pipeline.sh tmux-pipeline.sh
    appinsights-query.sh setup-github-ci.sh setup-github-labels.sh
    bootstrap-backend.sh seed-secret.sh onboard-diagnose.sh purge-store.sh
)

for pipe in "${PUBLISHED_PIPELINES[@]}"; do
    path="$REPO_ROOT/scripts/$pipe"
    if [ ! -f "$path" ]; then
        fail "$pipe: archivo no existe"
        continue
    fi
    if grep -q '\.claude-plugin/plugin\.json' "$path"; then
        pass "$pipe: menciona .claude-plugin/plugin.json (guard)"
    else
        fail "$pipe: no menciona .claude-plugin/plugin.json"
    fi

    # Validar sintaxis bash
    if bash -n "$path" 2>/dev/null; then
        pass "$pipe: sintaxis bash valida"
    else
        fail "$pipe: sintaxis bash invalida"
    fi
done

# -------- Bloque C2: scripts auxiliares publicados abortan en repo de Mefisto --------

echo ""
echo "[C2] Scripts auxiliares publicados: el guard aborta cuando se ejecutan en Mefisto"

AUX_SCRIPTS=(
    appinsights-query.sh setup-github-ci.sh setup-github-labels.sh
    bootstrap-backend.sh seed-secret.sh onboard-diagnose.sh update-plugin.sh
    purge-store.sh
)

for aux in "${AUX_SCRIPTS[@]}"; do
    path="$REPO_ROOT/scripts/$aux"
    output=$("$path" 2>&1)
    rc=$?
    if [ "$rc" -eq 1 ] && echo "$output" | grep -q "plugin publicado y solo aplica al consumidor"; then
        pass "$aux: aborta con exit 1 y mensaje correcto en repo de Mefisto"
    else
        fail "$aux: no aborta como se espera (exit=$rc)"
    fi
done

# -------- Bloque D: _pipeline-common.sh y _mefisto-common.sh sourceables --------

echo ""
echo "[D] Funciones de scope son sourceables y exportan los simbolos esperados"

# Subshell para no contaminar este shell con las funciones
(
    set +u
    source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null
    if declare -F is_path_in_consumer_blocklist >/dev/null; then
        echo "  PASS: is_path_in_consumer_blocklist definida en _pipeline-common.sh"
        exit 0
    else
        echo "  FAIL: is_path_in_consumer_blocklist NO definida"
        exit 1
    fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

(
    set +u
    source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null
    if declare -F validate_consumer_scope_changes >/dev/null; then
        echo "  PASS: validate_consumer_scope_changes definida"
        exit 0
    else
        echo "  FAIL: validate_consumer_scope_changes NO definida"
        exit 1
    fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

(
    set +u
    source "$REPO_ROOT/.claude/scripts/_mefisto-common.sh" 2>/dev/null
    if declare -F is_path_in_mefisto_scope >/dev/null && declare -F validate_mefisto_scope_changes >/dev/null && declare -F assert_in_mefisto >/dev/null; then
        echo "  PASS: _mefisto-common.sh exporta assert_in_mefisto, is_path_in_mefisto_scope, validate_mefisto_scope_changes"
        exit 0
    else
        echo "  FAIL: _mefisto-common.sh no exporta todas las funciones esperadas"
        exit 1
    fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# -------- Bloque E: comportamiento funcional del scope --------

echo ""
echo "[E] is_path_in_consumer_blocklist clasifica correctamente"

(
    set +u
    source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null

    # Rutas que deben estar en el blocklist (reservadas al plugin)
    # skills/: Agent Skills publicados del plugin (MEF-ADR-0033)
    for blocked in "commands/foo.md" "skills/projections/SKILL.md" "skills/projections/reference.md" "agents/bar.md" "hooks/baz.json" ".claude-plugin/plugin.json" "docs/adr/mef-adr-0001-service-bus-topics-por-evento.md"; do
        if is_path_in_consumer_blocklist "$blocked"; then
            echo "  PASS: '$blocked' detectado como blocklist"
        else
            echo "  FAIL: '$blocked' NO detectado como blocklist"
            exit 1
        fi
    done

    # Rutas que NO deben estar en el blocklist (validas para el consumidor)
    # docs/adr/0028-*.md y docs/adr/ca-adr-0009-*.md: ADR local del consumidor
    # (MEF-ADR-0030 decision #4) -- solo docs/adr/mef-adr-* es del marco
    for allowed in "src/Foo.cs" "tests/Bar.cs" ".github/workflows/deploy.yml" ".claude/settings.json" "docs/bitacora/notes.md" "docs/adr/0028-x.md" "docs/adr/ca-adr-0009-x.md" ".opencode/agents/foo.md" "AGENTS.md" "opencode.json"; do
        if is_path_in_consumer_blocklist "$allowed"; then
            echo "  FAIL: '$allowed' detectado como blocklist (deberia estar permitido)"
            exit 1
        else
            echo "  PASS: '$allowed' NO detectado como blocklist"
        fi
    done
    exit 0
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo ""
echo "[E2] is_path_in_mefisto_scope clasifica correctamente"

(
    set +u
    source "$REPO_ROOT/.claude/scripts/_mefisto-common.sh" 2>/dev/null

    # Rutas validas en Mefisto
    # skills/ y .claude/skills/: Agent Skills publicados e internos (MEF-ADR-0033)
    # changelog.d/: fragmentos de CHANGELOG/indice de ADRs (issue #380)
    # .mcp.json: declaracion del server MCP bundleado (issue #763), entrada EXACTA
    # src/internal/, .opencode/{agents,commands,plugins,skills}/, AGENTS.md, opencode.json:
    # arquitectura neutral de runtime/proveedor (issue #852, MEF-ADR-0049)
    for valid in "commands/foo.md" "skills/projections/SKILL.md" "skills/projections/scripts/check.sh" "agents/bar.md" "scripts/baz.sh" "hooks/hooks.json" "docs/adr/mef-adr-0001-service-bus-topics-por-evento.md" ".claude-plugin/plugin.json" ".claude/commands/mefisto-foo.md" ".claude/skills/mefisto-doctrina/SKILL.md" ".claude/settings.json" ".mcp.json" "changelog.d/380.added.md" "changelog.d/README.md" "README.md" "src/internal/foo.ts" ".opencode/agents/foo.md" ".opencode/commands/foo.md" ".opencode/plugins/foo.js" ".opencode/skills/foo/SKILL.md" "AGENTS.md" "opencode.json"; do
        if is_path_in_mefisto_scope "$valid"; then
            echo "  PASS: '$valid' en scope de Mefisto"
        else
            echo "  FAIL: '$valid' NO esta en scope (deberia)"
            exit 1
        fi
    done

    # Rutas invalidas en Mefisto
    # ".mcp.json" es entrada EXACTA de la raiz: ni un glob *.mcp.json ni subdirectorios (issue #763).
    # ".opencode/agent/" (singular), "dist/", ".mefisto/" y "opencode.json" fuera de la raiz
    # exacta siguen fuera de scope (issue #852): dist/ diferido a un ADR posterior, .mefisto/
    # es estado local que va a .gitignore (#856), nunca visible para el gate.
    for invalid in "src/Foo.cs" "src/otro/x.sh" "tests/Bar.cs" ".github/workflows/deploy.yml" "infra/main.tf" ".claude/harness.config.json" ".claude/pipeline/events.log" "sub/.mcp.json" "foo.mcp.json" ".opencode/x.json" ".opencode/agent/x.md" "dist/x" ".mefisto/pipeline/events.log" ".mefisto/models.json" "sub/opencode.json" "foo.opencode.json"; do
        if is_path_in_mefisto_scope "$invalid"; then
            echo "  FAIL: '$invalid' esta en scope (NO deberia)"
            exit 1
        else
            echo "  PASS: '$invalid' fuera del scope"
        fi
    done
    exit 0
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# -------- Bloque F: integridad de los Agent Skills (MEF-ADR-0033) --------

echo ""
echo "[F] Agent Skills: frontmatter, recursos Nivel-3 y referencias 'skills:' de agentes"

# frontmatter_field <archivo> <campo> -- imprime el valor del campo dentro del
# bloque de frontmatter YAML delimitado por '---' al inicio del archivo.
frontmatter_field() {
    awk -v field="$2" '
        NR == 1 { if ($0 != "---") exit; next }
        $0 == "---" { exit }
        index($0, field ":") == 1 {
            sub("^" field ":[ \t]*", "")
            gsub(/^["'"'"']|["'"'"']$/, "")
            print
            exit
        }
    ' "$1"
}

SKILL_FILES="$(find "$REPO_ROOT/skills" "$REPO_ROOT/.claude/skills" -name 'SKILL.md' 2>/dev/null | sort)"
SKILL_NAMES=""

if [ -z "$SKILL_FILES" ]; then
    pass "no hay Agent Skills en el repo todavia: nada que validar en [F]"
else
    while IFS= read -r skill_file; do
        [ -n "$skill_file" ] || continue
        skill_dir="$(dirname "$skill_file")"
        dir_name="$(basename "$skill_dir")"
        rel="${skill_file#"$REPO_ROOT"/}"

        # F1: el `name` del frontmatter es el valor que un agente lista en `skills:`
        # (MEF-ADR-0033 seccion 4: "el campo `name` de su frontmatter, no el nombre
        # del directorio"). Exigirlos iguales elimina la ambiguedad de origen.
        skill_name="$(frontmatter_field "$skill_file" name)"
        if [ -z "$skill_name" ]; then
            fail "$rel: frontmatter sin campo 'name'"
        elif [ "$skill_name" != "$dir_name" ]; then
            fail "$rel: name '$skill_name' != directorio '$dir_name'"
        else
            pass "$rel: name '$skill_name' coincide con su directorio"
            SKILL_NAMES="$SKILL_NAMES $skill_name"
        fi

        # F2: sin `description` el Skill nunca se dispara automaticamente (Nivel 1).
        if [ -z "$(frontmatter_field "$skill_file" description)" ]; then
            fail "$rel: frontmatter sin campo 'description' (Nivel 1 vacio: nunca se dispara)"
        else
            pass "$rel: tiene 'description' en el frontmatter"
        fi

        # F3: todo recurso de Nivel 3 referenciado por el body debe existir --
        # un link roto deja la doctrina inalcanzable sin ningun error visible.
        missing_resources=""
        while IFS= read -r resource; do
            [ -n "$resource" ] || continue
            case "$resource" in
                http*|"#"*|/*) continue ;;
            esac
            [ -f "$skill_dir/$resource" ] || missing_resources="$missing_resources $resource"
        done <<EOF
$(grep -o '](\([^)]*\.md\))' "$skill_file" 2>/dev/null | sed 's/^](//; s/)$//' | sort -u)
EOF
        if [ -n "$missing_resources" ]; then
            fail "$rel: recursos Nivel-3 referenciados que no existen:$missing_resources"
        else
            pass "$rel: todos los recursos Nivel-3 referenciados existen"
        fi
    done <<EOF
$SKILL_FILES
EOF
fi

# F4: todo valor de `skills:` de un agente resuelve a un Skill real del repo.
# Cubre la forma de lista YAML del ejemplo de MEF-ADR-0033 seccion 3
# (`skills:` + items `- nombre`) y la forma inline (`skills: [a, b]`).
AGENT_FILES="$(find "$REPO_ROOT/agents" "$REPO_ROOT/.claude/agents" -name '*.md' 2>/dev/null | sort)"
SKILLS_REFS_FOUND=0

while IFS= read -r agent_file; do
    [ -n "$agent_file" ] || continue
    rel="${agent_file#"$REPO_ROOT"/}"
    refs="$(awk '
        NR == 1 { if ($0 != "---") exit; next }
        $0 == "---" { exit }
        /^skills:[ \t]*$/ { inlist = 1; next }
        inlist && /^[ \t]*-[ \t]*/ { sub(/^[ \t]*-[ \t]*/, ""); print; next }
        inlist { inlist = 0 }
        index($0, "skills:") == 1 {
            sub(/^skills:[ \t]*/, "")
            gsub(/[][,]/, " ")
            print
        }
    ' "$agent_file" | tr -s ' \t' '\n' | tr -d '"'"'" | sort -u)"

    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        SKILLS_REFS_FOUND=$((SKILLS_REFS_FOUND+1))
        if echo " $SKILL_NAMES " | grep -q " $ref "; then
            pass "$rel: skills: '$ref' resuelve a un SKILL.md real"
        else
            fail "$rel: skills: '$ref' NO resuelve a ningun SKILL.md del repo (degradaria en silencio)"
        fi
    done <<EOF
$refs
EOF
done <<EOF
$AGENT_FILES
EOF

if [ "$SKILLS_REFS_FOUND" -eq 0 ]; then
    pass "ningun agente declara 'skills:' todavia: nada que resolver (guard activo para cuando lo declaren)"
fi

# -------- Bloque G: guard de regresion, lado publicado (issue #443) --------
#
# Mismo guard que el Bloque G de .claude/scripts/tests/test-batch-deps-validation.sh
# (issue #436), pero sobre commands/*.md (lado publicado): Claude Code expande la
# sintaxis posicional de shell ($1..$9, ${N}, $*, $@, $#) que encuentra en el texto
# de un slash command antes de entregarlo al modelo, sin importar que ese texto este
# dentro de comillas simples de un heredoc o de un awk. commands/onboard.md incrustaba
# un heredoc bash con 5 ocurrencias hasta que el issue #443 lo extrajo a
# scripts/onboard-diagnose.sh.

echo ""
echo "[G] Guard de regresion: sin sintaxis posicional de shell en bloques bash de commands/*.md"

scan_bash_positional_leaks_published() {
    local f="$1"
    awk -v F="$f" '
        /^```bash/ {inb=1; next}
        /^```/ {inb=0; next}
        inb && (/\$[1-9]/ || /\$\{[0-9]+\}/ || /\$\*/ || /\$@/ || /\$#/) { printf "%s:%d: %s\n", F, NR, $0 }
    ' "$f"
}

PUBLISHED_VIOLATIONS=""
for f in "$REPO_ROOT"/commands/*.md; do
    hits=$(scan_bash_positional_leaks_published "$f")
    [ -n "$hits" ] && PUBLISHED_VIOLATIONS="$PUBLISHED_VIOLATIONS
$hits"
done
if [ -z "$PUBLISHED_VIOLATIONS" ]; then
    pass "cero hallazgos de sintaxis posicional en commands/*.md"
else
    fail "hallazgos de sintaxis posicional en commands/*.md:$PUBLISHED_VIOLATIONS"
fi

# El guard debe SI detectar un $1 introducido a mano -- si no, es un guard ciego
# que nunca pondria nada en rojo (verificacion positiva, no solo "hoy no encuentra nada").
SYNTH_DIR_PUB=$(mktemp -d)
cat > "$SYNTH_DIR_PUB/synthetic-leak.md" <<'EOF'
Prosa de un skill sintetico.

```bash
echo "$1"
```
EOF
HITS_PUB=$(scan_bash_positional_leaks_published "$SYNTH_DIR_PUB/synthetic-leak.md")
if [ -n "$HITS_PUB" ]; then
    pass "el guard detecta un \$1 introducido a mano en un archivo sintetico"
else
    fail "el guard NO detecto un \$1 introducido a mano (guard ciego)"
fi

# Y NO debe marcar $ARGUMENTS ni ${#ARRAY[@]}: los dos son idiomas legitimos de un
# skill publicado (commands/onboard.md documenta $ARGUMENTS en su ultima regla) y
# Claude Code no los expande como posicionales. Sin este caso, ensanchar el regex
# del guard hasta volverlo ruidoso pasaria inadvertido.
cat > "$SYNTH_DIR_PUB/synthetic-clean.md" <<'EOF'
Prosa de un skill sintetico.

```bash
echo "$ARGUMENTS"
echo "${#SEC_NAMES[@]}"
```
EOF
HITS_PUB2=$(scan_bash_positional_leaks_published "$SYNTH_DIR_PUB/synthetic-clean.md")
rm -rf "$SYNTH_DIR_PUB"
if [ -z "$HITS_PUB2" ]; then
    pass "el guard no marca \$ARGUMENTS ni \${#ARRAY[@]} (sin falsos positivos)"
else
    fail "falso positivo del guard sobre \$ARGUMENTS/\${#ARRAY[@]}: $HITS_PUB2"
fi

# -------- Bloque H: convenciones acopladas de la guarda "Esperar deploys ajenos" --------

echo "[H] Guarda de deploys ajenos (issue #604, MEF-ADR-0031 seccion 4): convenciones acopladas"

DS="$REPO_ROOT/agents/domain-scaffolder.md"
GUARDA=$(grep -F 'startswith("Deploy ")' "$DS" | grep -F 'workflow_runs' || true)

if [ -n "$GUARDA" ]; then
    pass "la plantilla del reutilizable conserva el filtro de runs de la guarda"
else
    fail "no se encontro el filtro de runs de la guarda ('workflow_runs' + startswith(\"Deploy \")) en agents/domain-scaffolder.md"
fi

# La guarda solo se activa para la clase "no despliego el FA que pruebo" (CA-3): la condicion es el
# input vacio, nunca una lista de dominios o de workflows.
if grep -qF "if: inputs.expected_sha == ''" "$DS"; then
    pass "la guarda se condiciona a inputs.expected_sha == '' (sin enumerar dominios)"
else
    fail "la guarda perdio su condicion 'if: inputs.expected_sha == \\'\\''' en agents/domain-scaffolder.md"
fi

# El literal que la guarda busca en los runs ajenos ('deploy') tiene que seguir siendo el nombre del
# job de la plantilla deploy-{kebab}.yml, y su nombre de workflow tiene que seguir empezando con
# 'Deploy ': si alguno se renombra sin mover el literal, la guarda deja de ver a ese invocador EN
# SILENCIO y la carrera del issue #604 vuelve sin senal.
if grep -qE '^name: Deploy \{PascalCase\}' "$DS"; then
    pass "la plantilla deploy-{kebab}.yml conserva un nombre de workflow con prefijo 'Deploy '"
else
    fail "la plantilla deploy-{kebab}.yml ya no se llama 'Deploy {PascalCase}': mueve el prefijo en el filtro de la guarda (Paso 6.1)"
fi

if grep -qE '^  deploy:$' "$DS" && grep -qF 'select(.name == "deploy")' "$DS"; then
    pass "el job 'deploy' de la plantilla y el literal que la guarda busca coinciden"
else
    fail "desalineacion entre el job 'deploy' de deploy-{kebab}.yml y el literal 'select(.name == \"deploy\")' de la guarda"
fi

# Porque la guarda FALLA (no degrada) cuando un run 'Deploy *' no expone un job 'deploy', todo
# workflow del marco que comparta ese prefijo SIN desplegar una Function App (sin job 'deploy')
# debe estar excluido por path (hoy, deploy-projections.yml: jobs build-and-test/publish). Un
# workflow 'Deploy *' que SI declara su propio job 'deploy' (deploy-mcp-{proposito}.yml,
# mcp-scaffolder) conforma la convencion sin necesitar exclusion -- la guarda lo encuentra por el
# nombre del job, no por su path. El patron tolera placeholders ({...}) en el path generado: un
# servidor MCP es parametrico por {Proposito}, asi que no hay un unico literal que excluir.
for agente in "$REPO_ROOT"/agents/*.md; do
    [ "$agente" = "$DS" ] && continue
    grep -qE '^name: Deploy ' "$agente" || continue
    generados=$(grep -oE '\.github/workflows/deploy-[A-Za-z0-9{}.-]+\.yml' "$agente" | sort -u)
    if [ -z "$generados" ]; then
        fail "$(basename "$agente") emite un workflow 'Deploy *' sin un path .github/workflows/deploy-*.yml identificable: no se puede verificar su exclusion en la guarda"
        continue
    fi
    tiene_job_deploy=$(grep -qE '^  deploy:$' "$agente" && echo 1 || echo 0)
    for wf in $generados; do
        if echo "$GUARDA" | grep -qF "select(.path != \"$wf\")"; then
            pass "la guarda excluye $wf ($(basename "$agente"): 'Deploy *' que no despliega ninguna Function App)"
        elif [ "$tiene_job_deploy" = "1" ]; then
            pass "$wf ($(basename "$agente")) declara su propio job 'deploy' -- conforma la convencion de la guarda sin necesitar exclusion por path"
        else
            fail "$wf ($(basename "$agente")) matchea el prefijo 'Deploy ' de la guarda pero no esta excluido por path ni declara un job 'deploy': la guarda abortaria con exit 1 al no encontrarle uno"
        fi
    done
done

# actions: read en el reutilizable y en los dos jobs invocadores que hacen el 'uses:' (CA-4/CA-5).
# Sin la concesion el run muere en startup_failure SIN annotation: nada mas lo atraparia.
ACTIONS_READ=$(grep -cE '^[[:space:]]+actions: read' "$DS" || true)
if [ "$ACTIONS_READ" -eq 3 ]; then
    pass "las 3 plantillas conceden 'actions: read' (reutilizable + job smoke-tests de deploy-{kebab}.yml + job smoke-tests del global)"
else
    fail "se esperaban 3 concesiones de 'actions: read' en agents/domain-scaffolder.md (reutilizable + 2 invocadores), se encontraron $ACTIONS_READ"
fi

# -------- Resumen --------

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
