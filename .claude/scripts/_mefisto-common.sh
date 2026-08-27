#!/usr/bin/env bash
# _mefisto-common.sh -- Funciones compartidas entre pipelines INTERNOS de Mefisto
#
# Uso: source "$(dirname "${BASH_SOURCE[0]}")/_mefisto-common.sh"
#
# No invocar directamente (prefijo _ = sourceable).
#
# ALCANCE: estos pipelines solo se ejecutan dentro del repo del propio Mefisto
# (eda-evsourcing-azure-harness). No usan .claude/harness.config.json (que es
# del consumidor) ni dotnet/Terraform. Operan sobre commands/, agents/, scripts/,
# hooks/, docs/adr/ y archivos de gobierno del repo.

# assert_in_mefisto
#
# Verifica que estamos en el repo del propio Mefisto (presencia de
# .claude-plugin/plugin.json en la raiz). Aborta con mensaje claro si no.
# Llamar al inicio de cualquier pipeline interno.
#
# Exporta:
#   MEFISTO_REPO_ROOT       - Raiz del repo (toplevel git)
#   MEFISTO_PROJECT_NAME    - Nombre legible ("mefisto", leido de plugin.json)
#   MEFISTO_REPO_SLUG       - owner/repo (ej: augusto-romero-arango/eda-evsourcing-azure-harness)
assert_in_mefisto() {
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo "ERROR: no estas en un repositorio git" >&2
        return 1
    }

    if [ ! -f "$repo_root/.claude-plugin/plugin.json" ]; then
        echo "ERROR: este pipeline solo se ejecuta dentro del repo de Mefisto" >&2
        echo "  No se encontro $repo_root/.claude-plugin/plugin.json" >&2
        echo "  Si querias trabajar sobre tu proyecto consumidor, usa los skills" >&2
        echo "  publicados (/tooling, /implement, etc.) desde la raiz de ese repo." >&2
        return 1
    fi

    export MEFISTO_REPO_ROOT="$repo_root"

    if command -v jq >/dev/null 2>&1; then
        export MEFISTO_PROJECT_NAME=$(jq -r '.name // "mefisto"' "$repo_root/.claude-plugin/plugin.json")
    else
        export MEFISTO_PROJECT_NAME="mefisto"
    fi

    if command -v gh >/dev/null 2>&1; then
        export MEFISTO_REPO_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
    fi
}

# get_harness_version
#
# Imprime por stdout el '.version' de .claude-plugin/plugin.json del repo de
# Mefisto (issue #662), mismo criterio que su homologo publicado
# (get_harness_version en scripts/_pipeline-common.sh): en el repo de Mefisto
# ese campo solo cambia en /mefisto-release, y sirve como campo de paridad
# para poder portar/reusar el mismo criterio de segmentacion del reporte
# interno (issue #664) que ya usa el lado publicado.
#
# Ubica plugin.json relativo a este mismo archivo (dos niveles arriba de
# .claude/scripts/), no al cwd del pipeline -- mismo motivo que el lado
# publicado: la ruta tiene que resolver sea cual sea el cwd desde el que se
# invoque el pipeline.
#
# Con jq disponible, lee '.version' via jq -r. Sin jq en PATH, degrada a una
# extraccion con sed sobre la linea '"version": "X.Y.Z"'. Si plugin.json no
# existe, o ninguna extraccion produce un valor, imprime cadena vacia -- nunca
# aborta y siempre retorna 0.
get_harness_version() {
    local script_dir plugin_json
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || script_dir=""
    plugin_json="$script_dir/../../.claude-plugin/plugin.json"

    if [ ! -f "$plugin_json" ]; then
        echo ""
        return 0
    fi

    local version=""
    if command -v jq >/dev/null 2>&1; then
        version=$(jq -r '.version // ""' "$plugin_json" 2>/dev/null) || true
        [ "$version" = "null" ] && version=""
    else
        # '|| true' y no '|| version=""': con pipefail heredado del caller,
        # head -n1 cierra el pipe apenas lee la linea y sed puede morir de
        # SIGPIPE DESPUES de haber emitido la version -- reasignar ahi
        # borraria un valor ya capturado (mismo motivo que el homologo
        # publicado).
        version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$plugin_json" 2>/dev/null | head -n1) || true
    fi

    echo "$version"
    return 0
}

# get_harness_sha
#
# Imprime por stdout el SHA corto (`git rev-parse --short HEAD`) del repo
# PRINCIPAL de Mefisto (issue #662) -- exclusivo del lado interno, sin
# homologo publicado. Complementa a get_harness_version: en el repo de
# Mefisto '.version' solo cambia en /mefisto-release, y entre release y
# release entran decenas de PRs -- justo lo que el plan de velocidad interno
# (#645-#648) necesita comparar entre si. El SHA es lo que distingue esas
# corridas entre si cuando la version no cambio.
#
# Opera sobre el cwd del proceso que la invoca: el caller (el prologo de
# mefisto-tooling-pipeline.sh) debe llamarla ANTES de crear el worktree del
# issue, cuando el cwd todavia es el checkout principal -- los
# .claude/scripts/ que ejecutan la corrida son los del checkout principal, no
# los del worktree (que arranca desde origin/main y puede estar en otro SHA).
#
# Degrada a cadena vacia -- sin abortar, exit 0 siempre -- si 'git' no esta
# en PATH o si el cwd no es un repositorio git.
get_harness_sha() {
    command -v git >/dev/null 2>&1 || { echo ""; return 0; }

    local sha=""
    sha=$(git rev-parse --short HEAD 2>/dev/null) || sha=""
    echo "$sha"
    return 0
}

# is_path_in_mefisto_scope <path>
#
# Retorna 0 si el path cae en el scope permitido para cambios en Mefisto,
# 1 en caso contrario. Usado por los gates de scope del pipeline interno.
#
# Allowlist:
#   commands/                Skills publicados como slash command (los modifica /mefisto-tooling)
#   skills/                  Agent Skills publicados del plugin (MEF-ADR-0033)
#   agents/                  Agentes publicados
#   scripts/                 Pipelines publicados
#   hooks/                   Hooks publicados
#   docs/                    ADRs, testing, field-notes, cheatsheets
#   .claude-plugin/          Metadata del plugin (plugin.json, marketplace.json)
#   .claude/commands/        Skills internos del propio Mefisto
#   .claude/skills/          Agent Skills internos (MEF-ADR-0033)
#   .claude/agents/          Agentes internos
#   .claude/scripts/         Pipelines internos
#   .claude/settings.json    Hooks del pipeline interno. Entrada EXACTA, no .claude/*:
#                            .claude/harness.config.json y .claude/pipeline/* siguen fuera.
#                            Deliberadamente NO se replica en is_path_in_consumer_blocklist
#                            (scripts/_pipeline-common.sh registra el porque).
#   changelog.d/             Fragmentos de CHANGELOG/indice de ADRs (issue #380)
#   README.md, CHANGELOG.md, CLAUDE.md, .gitignore   Gobierno del repo
is_path_in_mefisto_scope() {
    local path="$1"
    [ -z "$path" ] && return 1

    case "$path" in
        commands/*|skills/*|agents/*|scripts/*|hooks/*|docs/*) return 0 ;;
        .claude-plugin/*) return 0 ;;
        .claude/commands/*|.claude/skills/*|.claude/agents/*|.claude/scripts/*) return 0 ;;
        .claude/settings.json) return 0 ;;
        README.md|CHANGELOG.md|CLAUDE.md|.gitignore) return 0 ;;
        changelog.d/*) return 0 ;;
        *) return 1 ;;
    esac
}

# validate_mefisto_scope_changes <worktree_path> <base_commit>
#
# Verifica que los archivos modificados/creados en el worktree caen dentro del
# scope permitido para Mefisto (ver is_path_in_mefisto_scope).
#
# Retorna 0 si OK, 1 si hay violaciones (las lista en stderr).
validate_mefisto_scope_changes() {
    local wt="$1"
    local base="$2"

    local changed
    changed=$(
        git -C "$wt" diff --name-only "$base..HEAD" 2>/dev/null
        git -C "$wt" status --porcelain 2>/dev/null | sed 's/^...//'
    )

    local violations=()
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        if ! is_path_in_mefisto_scope "$path"; then
            violations+=("$path")
        fi
    done <<< "$changed"

    if [ ${#violations[@]} -gt 0 ]; then
        echo "ERROR: cambios fuera del scope de Mefisto:" >&2
        printf '  - %s\n' "${violations[@]}" >&2
        echo "" >&2
        echo "Mefisto solo permite cambios en: commands/, skills/, agents/, scripts/," >&2
        echo "hooks/, docs/, .claude-plugin/, .claude/{commands,skills,agents,scripts}/," >&2
        echo ".claude/settings.json, changelog.d/, README.md, CHANGELOG.md, CLAUDE.md," >&2
        echo ".gitignore" >&2
        return 1
    fi
}

# is_path_changelog_exempt <path>
#
# Retorna 0 si el path es EXENTO de exigir fragmento de changelog (un cambio que
# toca solo rutas exentas no es "notable" y no obliga a dejar fragmento en
# changelog.d/), 1 si el path es NOTABLE (exige fragmento). Usado por
# changes_require_changelog.
#
# Rutas exentas (cambios de bitacora / gobierno no notable):
#   docs/bitacora/**   Bitacora y field notes (no son cambios de comportamiento)
#   README.md          Documentacion de gobierno
#   CLAUDE.md          Instrucciones de gobierno
#   .gitignore         Configuracion de gobierno
#
# Todo lo demas dentro del scope de Mefisto (commands/, agents/, scripts/, hooks/,
# docs/adr/, docs/ no-bitacora, .claude-plugin/, .claude/{commands,agents,scripts}/,
# CHANGELOG.md) es NOTABLE y exige un fragmento en changelog.d/ (issue #380).
is_path_changelog_exempt() {
    local path="$1"
    [ -z "$path" ] && return 1

    case "$path" in
        docs/bitacora/*) return 0 ;;
        README.md|CLAUDE.md|.gitignore) return 0 ;;
        *) return 1 ;;
    esac
}

# changes_require_changelog <worktree_path> <base_commit>
#
# Clasifica si los cambios del worktree (base..HEAD + working tree) son "notables"
# y por tanto exigen un fragmento propio en changelog.d/ (issue #380).
#
# Retorna:
#   0  -> al menos una ruta tocada es NOTABLE: se exige fragmento en changelog.d/
#   1  -> TODAS las rutas tocadas son exentas (o no hay cambios): no se exige fragmento
#
# Solo clasifica rutas; NO revisa la presencia del fragmento (de eso se encarga
# changelog_fragment_added). Reutiliza el patron de recoleccion de rutas de
# validate_mefisto_scope_changes.
changes_require_changelog() {
    local wt="$1"
    local base="$2"

    # --untracked-files=all evita que git colapse un directorio sin trackear a su
    # raiz (p. ej. "docs/" en vez de "docs/bitacora/x.md"), que enmascararia la
    # clasificacion de exencion. En el pipeline los cambios ya estan commiteados
    # al llegar aqui, asi que el diff base..HEAD lista archivos individuales; esto
    # cubre ademas el caso de invocacion con working tree sucio.
    local changed
    changed=$(
        git -C "$wt" diff --name-only "$base..HEAD" 2>/dev/null
        git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null | sed 's/^...//'
    )

    while IFS= read -r path; do
        [ -z "$path" ] && continue
        if ! is_path_changelog_exempt "$path"; then
            return 0
        fi
    done <<< "$changed"

    return 1
}

# changelog_fragment_added <worktree_path> <base_commit>
#
# Retorna 0 si los cambios del worktree anaden al menos un FRAGMENTO de changelog
# bajo changelog.d/ (un .md que no sea el README del propio mecanismo), 1 si no.
#
# Mecanismo de fragmentos (issue #380): cada PR notable anota su cambio en un
# archivo propio bajo changelog.d/ en vez de editar CHANGELOG.md o la tabla de
# indice de ADRs de CLAUDE.md directamente -- esa edicion por-PR de archivos
# indice compartidos era el punto de contencion que colisionaba entre PRs
# paralelos (o en la ventana entre sync y merge). /mefisto-release consolida
# los fragmentos -- vuelca su contenido en CHANGELOG.md/CLAUDE.md y los borra --
# en su propia rama de release, nunca en la rama de un issue.
#
# Solo detecta la PRESENCIA del fragmento; no valida su formato ni su categoria
# (de eso se encargan consolidate_changelog_fragments/consolidate_adr_index_fragments,
# mas abajo, que abortan ante un nombre de fragmento invalido).
changelog_fragment_added() {
    local wt="$1"
    local base="$2"

    # Mismo patron de recoleccion que changes_require_changelog: diff commiteado
    # mas working tree, con --untracked-files=all para que un changelog.d/ recien
    # creado no se colapse a su directorio raiz y quede invisible al match.
    local changed
    changed=$(
        git -C "$wt" diff --name-only "$base..HEAD" 2>/dev/null
        git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null | sed 's/^...//'
    )

    while IFS= read -r path; do
        [ -z "$path" ] && continue
        case "$path" in
            changelog.d/README.md) continue ;;
            changelog.d/*.md) return 0 ;;
        esac
    done <<< "$changed"

    return 1
}

# consolidate_changelog_fragments <repo_root>
#
# Consolida los fragmentos de CHANGELOG bajo <repo_root>/changelog.d/ (issue
# #380): cada fragmento tiene forma <issue>.<categoria>.md, con categoria en
# added/changed/fixed/removed (Keep a Changelog). Agrupa su contenido por
# categoria y lo anexa a la subseccion "### <Categoria>" del bloque
# [Unreleased] de CHANGELOG.md (creandola si falta, preservando el orden de
# las subsecciones ya presentes), y borra del disco los fragmentos consumidos
# (el caller los stagea con git add junto al resto). Ignora
# changelog.d/README.md y los fragmentos *.adr-index.md (los consume
# consolidate_adr_index_fragments). Usada por la fase prepare de
# mefisto-release.sh, en la propia rama de release.
#
# Sin changelog.d/ o sin fragmentos de changelog dentro, es un no-op (exit 0).
# Aborta (exit 1) si algun fragmento no sigue el patron <issue>.<categoria>.md
# con categoria valida -- mejor fallar el release que consolidar en silencio
# un fragmento mal nombrado.
consolidate_changelog_fragments() {
    local repo_root="$1"
    local dir="$repo_root/changelog.d"
    [ -d "$dir" ] || return 0

    CHANGELOG_FRAGMENTS_DIR="$dir" python3 - "$repo_root/CHANGELOG.md" <<'PYEOF'
import glob, os, re, sys

changelog_path = sys.argv[1]
frag_dir = os.environ['CHANGELOG_FRAGMENTS_DIR']

CATEGORIES = ['added', 'changed', 'fixed', 'removed']
CATEGORY_HEADER = {'added': 'Added', 'changed': 'Changed', 'fixed': 'Fixed', 'removed': 'Removed'}

buckets = {c: [] for c in CATEGORIES}
consumed = []

for path in sorted(glob.glob(os.path.join(frag_dir, '*.md'))):
    name = os.path.basename(path)
    if name == 'README.md' or name.endswith('.adr-index.md'):
        continue
    m = re.match(r'^\d+\.([a-z]+)\.md$', name)
    if not m or m.group(1) not in CATEGORIES:
        print(f"ERROR: fragmento de changelog con nombre invalido: {name}", file=sys.stderr)
        sys.exit(1)
    with open(path, encoding='utf-8') as f:
        body = f.read().strip()
    if body:
        buckets[m.group(1)].append(body)
    consumed.append(path)

if not consumed:
    sys.exit(0)

with open(changelog_path, encoding='utf-8') as f:
    text = f.read()

m = re.search(r'(?ms)^(##\s*\[Unreleased\][^\n]*\n)(.*?)(?=^##\s*\[|\Z)', text)
if not m:
    print("ERROR: no se encontro la seccion [Unreleased]", file=sys.stderr)
    sys.exit(1)
header, body = m.group(1), m.group(2)

# Parsear subsecciones "### Categoria" ya existentes en [Unreleased],
# preservando orden y contenido -- puede haber quedado una nota manual antes
# de que existieran fragmentos. Lo que aparezca ANTES de la primera "###"
# (preambulo suelto, sin subseccion) tambien se conserva, tal cual y en su
# sitio: la consolidacion reescribe el bloque entero, asi que descartarlo
# equivaldria a borrar en silencio una nota escrita a mano.
preamble = []
existing = {}
order = []
current = None
current_lines = []
for line in body.splitlines():
    hm = re.match(r'^###\s*(\w+)', line)
    if hm:
        if current is not None:
            existing[current] = current_lines
        else:
            preamble = current_lines
        current = hm.group(1)
        order.append(current)
        current_lines = []
    else:
        current_lines.append(line)
if current is not None:
    existing[current] = current_lines
else:
    preamble = current_lines

def strip_blank_edges(lines):
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    return lines

preamble = strip_blank_edges(preamble)
for key in existing:
    existing[key] = strip_blank_edges(existing[key])

for category in CATEGORIES:
    if not buckets[category]:
        continue
    header_name = CATEGORY_HEADER[category]
    if header_name not in order:
        order.append(header_name)
        existing[header_name] = []
    for entry in buckets[category]:
        existing[header_name].extend(entry.splitlines())

lines = ['']
if preamble:
    lines.extend(preamble)
    lines.append('')
for header_name in order:
    lines.append(f'### {header_name}')
    lines.append('')
    lines.extend(existing[header_name])
    lines.append('')

new_body = '\n'.join(lines).rstrip('\n') + '\n\n'
text = text[:m.start()] + header + new_body + text[m.end():]

with open(changelog_path, 'w', encoding='utf-8') as f:
    f.write(text)

for path in consumed:
    os.remove(path)
PYEOF
}

# consolidate_adr_index_fragments <repo_root>
#
# Consolida los fragmentos del indice de ADRs bajo <repo_root>/changelog.d/
# (issue #380): cada uno tiene forma <issue>.adr-index.md y contiene una o mas
# filas "| Tema | MEF-ADR-XXXX |". Las anexa, en orden de nombre de archivo, al
# final de la tabla del "Indice tematico" de CLAUDE.md, y borra del disco los
# fragmentos consumidos (el caller los stagea con git add junto al resto).
# Usada por la fase prepare de mefisto-release.sh, en la propia rama de release.
#
# Sin changelog.d/ o sin fragmentos *.adr-index.md dentro, es un no-op.
consolidate_adr_index_fragments() {
    local repo_root="$1"
    local dir="$repo_root/changelog.d"
    [ -d "$dir" ] || return 0

    CLAUDE_MD_PATH="$repo_root/CLAUDE.md" CHANGELOG_FRAGMENTS_DIR="$dir" python3 <<'PYEOF'
import glob, os, re, sys

claude_md_path = os.environ['CLAUDE_MD_PATH']
frag_dir = os.environ['CHANGELOG_FRAGMENTS_DIR']

fragments = sorted(glob.glob(os.path.join(frag_dir, '*.adr-index.md')))
if not fragments:
    sys.exit(0)

rows = []
consumed = []
for path in fragments:
    with open(path, encoding='utf-8') as f:
        body = f.read().strip()
    rows.extend(line for line in body.splitlines() if line.strip())
    consumed.append(path)

if not rows:
    sys.exit(0)

with open(claude_md_path, encoding='utf-8') as f:
    text = f.read()

marker = '| Tema | ADR |\n|---|---|\n'
idx = text.find(marker)
if idx == -1:
    print("ERROR: no se encontro la tabla de indice de ADRs en CLAUDE.md", file=sys.stderr)
    sys.exit(1)
insert_at = idx + len(marker)

rest = text[insert_at:]
end_match = re.search(r'(?m)^(?!\|)', rest)
table_body_end = insert_at + (end_match.start() if end_match else len(rest))

new_rows_text = ''.join(row + '\n' for row in rows)
text = text[:table_body_end] + new_rows_text + text[table_body_end:]

with open(claude_md_path, 'w', encoding='utf-8') as f:
    f.write(text)

for path in consumed:
    os.remove(path)
PYEOF
}

# find_open_pr_for_branch <branch_name> [repo_slug] [base_branch]
#
# Busca un PR ABIERTO existente para <branch_name> via `gh pr list --head`, para
# que el pipeline lo REUTILICE en vez de abortar cuando `gh pr create` fallaria
# con "a pull request for branch ... already exists" (issue #378 -- incidente
# del batch mefisto-batch-125628: el writer del Stage 1 crea el PR el mismo,
# violando la prohibicion de push/PR de su prompt, y el bloque "Creando PR" del
# pipeline abortaba en vez de recuperar la URL ya existente).
#
# [repo_slug] es opcional (formato owner/repo); se pasa a `gh pr list --repo`
# cuando el caller no invoca gh desde dentro del repo (p. ej. el pipeline se
# queda en REPO_ROOT y no hace cd al worktree).
#
# [base_branch] (default 'main') filtra por rama base. Es deliberado y no
# cosmetico: la unicidad que GitHub impone -- y que produce el error que este
# gate esquiva -- es por par (head, base), como lo dice el propio mensaje
# (`a pull request for branch "X" into branch "main" already exists`). Sin el
# filtro, un PR abierto de la misma rama hacia OTRA base se devolveria como si
# fuera el PR del pipeline, y el `gh pr create --base main` que si habria
# funcionado nunca correria: el pipeline reportaria una URL equivocada.
#
# Imprime la URL a stdout si existe un PR abierto, cadena vacia si no hay PR o
# si el chequeo no se pudo hacer (gh ausente o gh fallo). NUNCA aborta: es un
# chequeo defensivo antes de `gh pr create`, no una fuente de verdad -- si gh
# esta roto de verdad (auth, red), ese fallo lo reporta el `gh pr create`
# normal que sigue a continuacion.
#
# Retorna siempre 0.
find_open_pr_for_branch() {
    local branch="$1"
    local repo="${2:-}"
    local base="${3:-main}"
    [ -z "$branch" ] && { echo ""; return 0; }

    command -v gh >/dev/null 2>&1 || { echo ""; return 0; }

    local gh_args=(pr list --head "$branch" --base "$base" --state open --json url -q '.[0].url')
    [ -n "$repo" ] && gh_args+=(--repo "$repo")

    local url
    url=$(gh "${gh_args[@]}" 2>/dev/null) || url=""
    # gh 2.92 imprime cadena vacia cuando la lista viene vacia, pero `.[0].url`
    # sobre `[]` es `null` en jq: normalizamos para no depender de como cada
    # version de gh serializa ese null (un "null" con fuga aqui haria que el
    # pipeline reutilizara un PR inexistente con URL literal "null").
    [ "$url" = "null" ] && url=""
    echo "$url"
    return 0
}

# --- Asignacion de modelo por stage (--models, issue #709) -------------------
#
# Contraparte interna de scripts/_pipeline-common.sh (issue #708, lado
# publicado): mismo contrato de UX para el flag --models, pero sin compartir
# codigo (MEF-ADR-0019 separa fisicamente publicado/interno). Permite
# sobreescribir, por invocacion de mefisto-tooling-pipeline.sh, el modelo que
# corre cada stage sin tocar el default hardcodeado en el `case` de run_agent().
# Requisito invariante del issue: sin el flag --models, el comportamiento es
# byte a byte el actual -- resolve_stage_model() cae siempre al default del
# caller cuando no hay override, y parse_stage_models() con spec vacio deja
# MEFISTO_STAGE_MODELS vacio (ninguna resolucion encuentra match).
#
# Formato interno de MEFISTO_STAGE_MODELS: pares "agente=modelo" separados por
# salto de linea -- no un array asociativo, porque bash 3.2 (macOS) no lo
# soporta.

# parse_stage_models <spec>
#
# Parsea el valor crudo del flag --models ('agente=modelo[,agente=modelo...]')
# y lo deja en la variable global MEFISTO_STAGE_MODELS para que
# resolve_stage_model() lo consulte. El caller debe invocarla ANTES de crear el
# worktree del issue: una entrada malformada debe abortar temprano, no a mitad
# de Stage 1 con un worktree ya creado.
#
# No valida el NOMBRE del modelo (alias como 'sonnet'/'opus' o un id completo
# como 'claude-opus-5[1m]' son ambos pass-through, sin allowlist propia -- los
# alias evolucionan con el CLI): solo la forma 'clave=valor' de cada entrada y
# que ninguna clave de agente se repita. Un modelo invalido lo delata el
# patron de error existente del stream (result.is_error, ya clasificado por
# classify_agent_failure/run_agent).
#
# En caso de entrada malformada, retorna 1 y deja el motivo en
# MEFISTO_STAGE_MODELS_ERROR (un mensaje de una linea, listo para pasarle a
# abort()) -- no imprime nada por si misma, para que el pipeline que la invoca
# controle el formato exacto del error.
#
# Con spec vacio (flag no pasado), deja MEFISTO_STAGE_MODELS vacio y retorna 0
# sin error: es el camino "sin --models", el que preserva el comportamiento
# byte a byte actual.
parse_stage_models() {
    local spec="$1"
    MEFISTO_STAGE_MODELS=""
    MEFISTO_STAGE_MODELS_ERROR=""
    [ -z "$spec" ] && return 0

    local entries=() entry agent model seen=$'\n'
    IFS=',' read -ra entries <<< "$spec"
    for entry in "${entries[@]}"; do
        [ -z "$entry" ] && continue
        case "$entry" in
            *=*) ;;
            *)
                MEFISTO_STAGE_MODELS_ERROR="entrada '$entry' no tiene la forma agente=modelo"
                return 1
                ;;
        esac
        agent="${entry%%=*}"
        model="${entry#*=}"
        if [ -z "$agent" ] || [ -z "$model" ]; then
            MEFISTO_STAGE_MODELS_ERROR="entrada '$entry': agente y modelo no pueden estar vacios"
            return 1
        fi
        case "$seen" in
            *$'\n'"$agent"$'\n'*)
                MEFISTO_STAGE_MODELS_ERROR="el agente '$agent' esta repetido"
                return 1
                ;;
        esac
        seen="${seen}${agent}"$'\n'
        MEFISTO_STAGE_MODELS="${MEFISTO_STAGE_MODELS}${MEFISTO_STAGE_MODELS:+$'\n'}${agent}=${model}"
    done
    return 0
}

# resolve_stage_model <agente> <default>
#
# Imprime por stdout el modelo a usar para <agente>: el override de
# MEFISTO_STAGE_MODELS (poblado por parse_stage_models) si <agente> tiene una
# entrada de clave EXACTA en el mapa, o <default> si no hay mapa cargado o
# <agente> no aparece en el. Pura -- no valida ni aborta, ese trabajo ya lo hizo
# parse_stage_models(). Siempre retorna 0.
resolve_stage_model() {
    local agent="$1" default="$2"
    local line
    if [ -n "${MEFISTO_STAGE_MODELS:-}" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            if [ "${line%%=*}" = "$agent" ]; then
                echo "${line#*=}"
                return 0
            fi
        done <<< "$MEFISTO_STAGE_MODELS"
    fi
    echo "$default"
    return 0
}

# format_stage_models_for_log
#
# Imprime por stdout una representacion de una linea de MEFISTO_STAGE_MODELS
# ("agente=modelo, agente=modelo") lista para log()/eventos (auditabilidad del
# mapa de overrides aplicado). Cadena vacia si no hay mapa cargado (sin
# --models). Siempre retorna 0.
format_stage_models_for_log() {
    [ -z "${MEFISTO_STAGE_MODELS:-}" ] && return 0
    echo "$MEFISTO_STAGE_MODELS" | tr '\n' ',' | sed 's/,/, /g; s/, $//'
    return 0
}

# run_agent_with_watchdog <workdir> <timeout_seconds> <stdout_file> <stderr_file> <events_log> <label> <signal_file> <cmd...>
#
# Ejecuta <cmd...> (sin `eval` -- se preserva "$@" tal cual, asi que las
# comillas/backticks/`$` del prompt del agente nunca se re-interpretan) en
# <workdir>, redirigiendo su stdout a <stdout_file> y su stderr a
# <stderr_file> POR SEPARADO, bajo un watchdog de <timeout_seconds>. Imprime
# por stdout el exit code de <cmd...> (capturable con
# `EXIT=$(run_agent_with_watchdog ...)`).
#
# La separacion stdout/stderr es deliberada (issue #425): desde que el caller
# invoca `claude -p` con `--output-format stream-json`, <stdout_file> recibe
# el stream JSON crudo (una linea por evento) mientras que los mensajes de
# error del propio CLI (`API Error: ...`, cortes de conexion) siguen llegando
# como texto plano por stderr. Un `2>&1` clasico mezclaria ese texto DENTRO
# del JSONL y lo corromperia -- exactamente lo que este cambio evita.
#
# Arregla dos grietas de correctitud del watchdog original de
# mefisto-tooling-pipeline.sh (issue #424), con evidencia en el historico: los
# stages de #416 (writer, 1883s) y #414 (reviewer, 1919s) excedieron el limite
# nominal de 1800s y events.log no tuvo una sola linea TIMEOUT en toda la
# corrida -- el limite de 30 min era decorativo.
#
# CA-1 (mata todo el arbol, no solo el subshell): `kill -9 -$pid` apunta al
# GRUPO de procesos, pero un subshell lanzado con `&` hereda por defecto el
# PGID del shell que lo lanza -- no es lider de su propio grupo, asi que ese
# kill no alcanzaba ni al `claude` ni a sus hijos node. `setsid` no existe en
# macOS (verificado: `command -v setsid` -> vacio). El arreglo verificado en
# bash 3.2/darwin es activar job control (`set -m`) justo antes de lanzar
# <cmd...> en background: con monitor mode activo ese job SI se vuelve lider
# de su propio grupo (PGID == PID del job), y `kill -9 -$pid` alcanza a todo
# el arbol. `set +m` restaura el modo normal enseguida despues del lanzamiento
# -- con job control activo bash reporta cambios de estado de jobs por
# stderr, y acotar la ventana evita ese ruido en el resto de la funcion.
#
# El watchdog se lanza DENTRO de esa misma ventana de `set -m`, por el mismo
# motivo del otro lado: cuando <cmd...> termina solo y hay que cancelarlo, un
# `kill` al PID del subshell del watchdog mata al subshell pero deja su
# `sleep <timeout_s>` huerfano hasta media hora (verificado: un `sleep`
# colgado por stage). Siendo lider de su propio grupo, `kill -9 -$watchdog_pid`
# se lleva subshell y `sleep` de una. Tiene que ser SIGKILL al GRUPO y no
# SIGTERM al `sleep` por separado: matar solo al `sleep` haria que el subshell
# despertara y siguiera con el `touch`/`kill`/`echo`, escribiendo un evento
# TIMEOUT espurio de un stage que en realidad termino bien.
#
# CA-2 (evento TIMEOUT incondicional): el `touch`/`kill`/`echo` del watchdog
# ya NO cuelgan de un `&&` en cadena -- antes, si el `kill` fallaba (como
# pasaba siempre por CA-1, al no ser el subshell lider de grupo), el `echo`
# que le seguia nunca corria y el evento TIMEOUT jamas se escribia en
# events.log. Ahora son tres sentencias independientes: el evento se escribe
# pase lo que pase con el kill.
#
# CA-3 (senal de timeout para clasificacion post-mortem): si el watchdog
# dispara, ademas de matar el grupo y loguear el evento, deja creado
# <signal_file> (se borra primero, por si quedo de una corrida anterior). El
# caller (run_agent) la usa para clasificar failure_type=TIMEOUT sin depender
# de que el exit code que observe `wait` sea justo 137/143 -- una senal de
# grupo no siempre se refleja asi.
run_agent_with_watchdog() {
    local workdir="$1" timeout_s="$2" stdout_file="$3" stderr_file="$4" events_log="$5" label="$6" signal_file="$7"
    shift 7

    rm -f "$signal_file"

    set -m
    ( cd "$workdir" && "$@" ) >"$stdout_file" 2>"$stderr_file" &
    local pid=$!

    (
        sleep "$timeout_s"
        touch "$signal_file" 2>/dev/null
        kill -9 -"$pid" 2>/dev/null
        echo "[$(date +%H:%M:%S)] TIMEOUT: $label supero ${timeout_s}s" >> "$events_log"
    ) </dev/null >/dev/null 2>&1 &
    local watchdog_pid=$!
    set +m

    local exit_code=0
    wait "$pid" || exit_code=$?

    # Si <signal_file> ya existe aqui, el watchdog fue quien mato a <pid> --
    # esta a mitad de escribir su evento TIMEOUT (touch precede a kill en su
    # propio cuerpo, en el mismo proceso, sin concurrencia posible entre
    # ambos). Una senal nuestra en ese instante podria cortarlo antes de
    # llegar al `echo` incondicional (CA-2) -- se lo deja terminar solo, NUNCA
    # se lo mata; solo se cancela el watchdog cuando <pid> termino por su
    # cuenta y el watchdog sigue dormido en el `sleep`.
    if [ -f "$signal_file" ]; then
        wait "$watchdog_pid" 2>/dev/null || true
    else
        kill -9 -"$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
    fi

    echo "$exit_code"
}

# derive_stage_log_from_stream <stream_file> <stderr_file> <out_file>
#
# Deriva el log legible de un stage (issue #425) a partir del stream JSON
# crudo que run_agent_with_watchdog capturo en <stream_file> bajo
# `--output-format stream-json --verbose`: una linea por cada bloque de texto
# del asistente y una linea "[tool] <nombre>" por cada tool_use, en el orden
# en que aparecen en el stream. Al final anexa el contenido de <stderr_file>
# tal cual (ya es texto plano). Sobreescribe <out_file> si ya existia.
#
# CA-5 -- por que tambien se deriva el evento `result` cuando `is_error` es
# true: verificado contra el CLI instalado (v2.1.220) que en una corrida
# fallida el texto del error NO viaja por stderr. Una invocacion con un modelo
# inexistente termino con exit 1, stderr sin una sola linea de error, y todo
# el diagnostico dentro del evento `result` de stdout:
# `{"is_error":true,"terminal_reason":"api_error","api_error_status":404,
# "result":"There's an issue with the selected model ..."}`. Derivar solo los
# eventos `assistant` dejaria ese texto fuera del log, y entonces los
# `grep "API Error: 5"`/`"API Error: 4"` y agent_log_has_stream_cut de
# run_agent no matchearian nunca: un 5xx se clasificaria CLI_ERROR, seria
# "recuperable" y el pipeline volveria a abrir PRs con trabajo truncado --
# exactamente el bug de #416 que arreglo #424. Por eso el filtro emite,
# ademas, una linea por cada `result` con `is_error == true`, prefijada con
# el token canonico `API Error: <status>` cuando el CLI reporta
# `api_error_status` (el status es dato del propio CLI; solo se lo re-expresa
# en el vocabulario que la clasificacion ya leia). Un `result` sin error no
# emite nada: no se introducen falsos positivos en corridas sanas.
#
# El nombre y la ruta de <out_file> NO cambian (sigue siendo
# mefisto-tooling-stage-<N>-<agente>-<TS>-issue-<N>.log): _mefisto-work-status
# y mefisto-investigator lo referencian, y run_agent sigue clasificando
# fallos (grep "API Error"/agent_log_has_stream_cut) y mostrando el `tail`
# de diagnostico del abort contra este mismo archivo derivado -- por eso el
# stderr anexado tiene que llegar aqui, no solo quedarse en <stderr_file>.
#
# CA-4: tolera una traza truncada (la ultima linea puede haber quedado a
# medias si el proceso murio a mitad de escritura) y una traza vacia. La
# tolerancia la da `fromjson?`: jq lee cada linea como texto (`-R`) y el `?`
# descarta en silencio la que no parsea, sin abortar y sin perder lo ya
# derivado de las lineas anteriores. El `select(type == "object")` cubre el
# otro caso degenerado -- una linea que SI es JSON valido pero no un objeto
# (`.type` sobre un string es un error duro de jq, no algo que `?` atrape).
#
# Es una sola invocacion de jq para todo el archivo, no una por linea:
# medido sobre un stream sintetico de 1000 eventos, un jq por linea tarda 5s
# y una sola pasada 0.01s. Un stage real de 30 min produce bastante mas que
# eso, asi que la version por-linea le sumaba decenas de segundos por stage
# al mismo wall-clock que este issue existe para medir (el bash orquestador
# entero cuesta hoy ~10s por issue).
#
# Si jq no esta disponible, degrada con gracia (issue #425, notas tecnicas):
# deja una nota explicita en vez de intentar parsear JSON a mano, y de todos
# modos anexa <stderr_file> -- que ya es texto plano y es donde vive la causa
# de la mayoria de los fallos que le importan a run_agent. Un fallo de
# instrumentacion (falta jq, stream vacio o inexistente) nunca debe tumbar el
# pipeline: la funcion siempre retorna 0.
derive_stage_log_from_stream() {
    local stream_file="$1" stderr_file="$2" out_file="$3"

    : > "$out_file" 2>/dev/null || return 0

    if [ -s "$stream_file" ]; then
        if command -v jq >/dev/null 2>&1; then
            jq -R -r '
                fromjson?
                | select(type == "object")
                | if .type == "assistant" then
                      (.message.content // [])[]?
                      | if .type == "text" then (.text // "")
                        elif .type == "tool_use" then "[tool] " + (.name // "?")
                        else empty end
                  elif .type == "result" and .is_error == true then
                      (if (.api_error_status // null) != null
                         then "API Error: " + (.api_error_status | tostring) + " "
                         else "" end)
                      + ((.result // .error // .terminal_reason // .subtype // "error") | tostring)
                  else empty end
            ' "$stream_file" >> "$out_file" 2>/dev/null || true
        else
            echo "(jq no disponible: no se pudo derivar texto legible del stream crudo -- ver $stream_file)" >> "$out_file"
        fi
    fi

    if [ -s "$stderr_file" ]; then
        [ -s "$out_file" ] && echo "" >> "$out_file"
        cat "$stderr_file" >> "$out_file" 2>/dev/null || true
    fi

    return 0
}

# agent_log_has_stream_cut <log_file>
#
# Retorna 0 si el log de un stage muestra que el CLI murio a mitad de
# respuesta. Unico lugar donde vive el patron: lo consumen tanto
# agent_failure_is_unrecoverable (que decide si se aborta) como la
# clasificacion de failure_type de run_agent (que solo pone la etiqueta
# STREAM_CUT). Con el patron duplicado en los dos, una edicion de uno solo
# desincroniza etiqueta y decision en silencio -- el log diria STREAM_CUT
# mientras el pipeline sigue de largo, que es exactamente el bug de #416.
#
# El match es a proposito amplio (`API Error` sin anclar al codigo de estado,
# asi cubre tanto `API Error: 5xx` como el corte de conexion): la unica
# consecuencia de un falso positivo es abortar un stage que quiza era
# recuperable -- se relanza y listo -- mientras que un falso negativo es
# exactamente el bug que este issue arregla, trabajo truncado llegando a main.
# Ante la duda, se aborta.
agent_log_has_stream_cut() {
    local log_file="$1"
    grep -qE "Connection closed mid-response|API Error" "$log_file" 2>/dev/null
}

# agent_stream_completed_successfully <stream_file>
#
# Retorna 0 si la traza cruda de un stage contiene un evento `result` final que
# declara exito (`is_error == false` y `subtype == "success"`), 1 en cualquier
# otro caso -- incluido que falte el archivo, que no haya evento `result`, que
# jq no este instalado o que la traza este corrupta. El default en 1 (no se
# puede afirmar el exito) es deliberado: esta funcion solo sirve para RELAJAR
# una clasificacion de fallo, asi que ante la duda tiene que dejarla como
# estaba.
#
# El evento `result` es la ultima linea que emite el CLI bajo `--output-format
# stream-json` y es su propia declaracion de haber cumplido el contrato del
# stage: `subtype: success`, `is_error: false`, `stop_reason: end_turn`. La
# traza ya se captura desde el issue #431 y compute_stage_metrics ya la parsea
# (issue #432) -- esta funcion no la vuelve a derivar, solo lee el mismo hecho
# para una decision distinta.
#
# Usa el mismo parseo tolerante que compute_stage_metrics (`try fromjson catch
# empty` sobre las lineas) porque la traza puede traer lineas truncadas si el
# proceso murio a media escritura -- y ese es justamente el caso que NO debe
# reportar exito.
agent_stream_completed_successfully() {
    local stream_file="${1:-}"

    [ -n "$stream_file" ] || return 1
    [ -s "$stream_file" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1

    local verdict
    verdict=$(jq -Rsr '
        (split("\n") | map(select(length > 0)) | map(try fromjson catch empty)
            | map(select(type == "object"))) as $events
        | ($events | map(select(.type == "result")) | last) as $result
        | if ($result != null and $result.is_error == false
              and $result.subtype == "success")
          then "yes" else "no" end
    ' "$stream_file" 2>/dev/null) || return 1

    [ "$verdict" = "yes" ]
}

# agent_failure_is_unrecoverable <timed_out> <exit_code> <log_file> [<stream_file>]
#
# Deriva el flag <unrecoverable> que consume agent_work_is_trustworthy (CA-4
# del issue #424): retorna 0 si el fallo del CLI es de los que NUNCA admiten
# el atajo de recuperacion por has_work, 1 si es un fallo ordinario que si lo
# admite. Vive aqui, y no inline en run_agent, porque es la decision que de
# hecho corta el paso a un PR con trabajo a medias -- extraerla la hace
# testeable directamente (mismo criterio que classify_file del coverage gate,
# issue #421).
#
# Dos familias son irrecuperables:
#   - TIMEOUT: <timed_out>="true" (la senal que dejo el watchdog) o un exit
#     code de senal (137 SIGKILL / 143 SIGTERM).
#   - Corte de stream a mitad de respuesta (agent_log_has_stream_cut). Fue el
#     incidente de #416 -- el reviewer murio con `API Error: Connection closed
#     mid-response` a los 882s y el pipeline abrio igual el PR #421 con una
#     revision truncada a mitad de frase.
#
# EXCEPCION (PR #446): si la traza del stage trae un evento `result` de
# exito, el CLI ya habia cumplido su contrato y lo que vino despues -- una
# senal al proceso, un exit code distinto de cero -- es una muerte POSTERIOR
# al trabajo, no a mitad de vuelo. Ese caso si es recuperable, y sigue pasando
# por los gates de agent_work_is_trustworthy (resumen de stage presente + diff
# real), asi que la relajacion no abre la puerta a un PR con trabajo a medias.
#
# Motivacion, con dos incidentes medidos el 2026-07-28: el writer de #436
# (219s, 34 turnos) y el de #437 (96s, 16 turnos) terminaron ambos con
# `subtype: success` / `is_error: false` / `stop_reason: end_turn`, stderr
# vacio y su commit ya hecho en el worktree; el watchdog NUNCA disparo (limite
# nominal 1800s, sin linea TIMEOUT en events.log), pero el proceso volvio con
# un exit code de senal y la clasificacion los llamo TIMEOUT y tiro el trabajo.
# El de #437 ademas corto un batch a mitad de cadena. La causa de la senal no
# esta identificada -- las tres corridas observadas que murieron asi corrian
# bajo tmux y la que corrio fuera no, pero con n=3 eso es una hipotesis, no un
# diagnostico. Esta funcion no intenta resolver esa causa: hace que el
# pipeline deje de descartar trabajo que el propio CLI declaro completo.
#
# El caso de #416 sigue cubierto: un CLI que muere a mitad de respuesta nunca
# llega a emitir su evento `result`, asi que agent_stream_completed_successfully
# retorna 1 y la clasificacion no se relaja. Un TIMEOUT real del watchdog
# tampoco: el kill llega a mitad de vuelo, sin `result` en la traza.
agent_failure_is_unrecoverable() {
    local timed_out="$1" exit_code="$2" log_file="$3" stream_file="${4:-}"

    # Antes que nada: si el CLI declaro exito, la muerte fue posterior.
    agent_stream_completed_successfully "$stream_file" && return 1

    [ "$timed_out" = "true" ] && return 0
    [ "$exit_code" = "137" ] && return 0
    [ "$exit_code" = "143" ] && return 0

    agent_log_has_stream_cut "$log_file" && return 0

    return 1
}

# classify_agent_failure <timed_out> <exit_code> <elapsed_s> <log_file> [<stream_file>]
#
# Traduce el desenlace de una invocacion fallida del CLI a la etiqueta
# <failure_type> que run_agent registra en events.log. Era logica inline de
# run_agent; se extrae aqui (issue #534) por el mismo motivo que
# agent_failure_is_unrecoverable: pasa a gobernar si un stage se REINTENTA,
# y inline no habia forma de ejercerla sin invocar el CLI real.
#
# El orden de los casos es significativo y se conserva verbatim del original:
# el TIMEOUT del watchdog gana sobre cualquier otro sintoma (es el unico
# TIMEOUT de verdad), y el match de `API Error: 5` precede al de `API Error:
# 4` y al corte de stream generico -- que es mas amplio y se los tragaria.
classify_agent_failure() {
    local timed_out="$1" exit_code="$2" elapsed="$3" log_file="$4" stream_file="${5:-}"

    if [ "$timed_out" = "true" ]; then
        echo "TIMEOUT (${elapsed}s, exit $exit_code)"
        return 0
    fi

    if [ "$exit_code" = "137" ] || [ "$exit_code" = "143" ]; then
        if agent_stream_completed_successfully "$stream_file"; then
            echo "SIGNAL_POST_SUCCESS (exit $exit_code, ${elapsed}s)"
        else
            echo "SIGNAL_MID_FLIGHT (exit $exit_code, ${elapsed}s)"
        fi
        return 0
    fi

    if grep -q "API Error: 5" "$log_file" 2>/dev/null; then
        echo "API_ERROR_SERVER (exit $exit_code)"
    elif grep -q "API Error: 4" "$log_file" 2>/dev/null; then
        echo "API_ERROR_CLIENT (exit $exit_code)"
    elif agent_log_has_stream_cut "$log_file"; then
        echo "STREAM_CUT (exit $exit_code)"
    else
        echo "CLI_ERROR (exit $exit_code)"
    fi
}

# agent_failure_is_retryable <failure_type>
#
# Retorna 0 si <failure_type> describe un fallo TRANSITORIO del lado del
# servidor -- el unico que vale la pena reintentar tal cual (issue #534);
# 1 en cualquier otro caso.
#
# Solo califica API_ERROR_SERVER. La evidencia que motiva el reintento: el
# 2026-08-05, 6 de 10 intentos de stage murieron con 522/529 de
# api.anthropic.com, y el payload del 522 declara literalmente
# `"retryable": true, "retry_after": 120`.
#
# Los demas tipos quedan fuera a proposito, y el default es NO reintentar:
#   - TIMEOUT: el agente estuvo media hora colgado. Reintentar paga otra media
#     hora por el mismo desenlace.
#   - API_ERROR_CLIENT (4xx): un 400/401/413 no se arregla repitiendo la misma
#     peticion; hace falta cambiar la peticion.
#   - SIGNAL_*, STREAM_CUT, CLI_ERROR: causa local o no identificada. Un
#     reintento a ciegas duplica el gasto sin evidencia de que ayude.
#
# La comparacion es por prefijo porque classify_agent_failure adjunta el exit
# code a la etiqueta ("API_ERROR_SERVER (exit 1)").
agent_failure_is_retryable() {
    local failure_type="${1:-}"

    case "$failure_type" in
        API_ERROR_SERVER*) return 0 ;;
        *)                 return 1 ;;
    esac
}

# agent_work_is_trustworthy <worktree_path> <base_commit> <unrecoverable> <summary_file>
#
# Decide si el trabajo que dejo un agente fallido en <worktree_path> es
# confiable para recuperar el stage (el atajo "has_work" que evita abortar
# cuando el CLI vuelve con exit code distinto de cero). Retorna 0 si es
# confiable, 1 si no. Usada por run_agent tras un fallo del CLI (issue #424).
#
# CA-4: <unrecoverable>="true" descalifica la recuperacion sin mirar nada mas
# -- el caller la marca en TIMEOUT o cuando el log del stage contiene un corte
# de stream a mitad de respuesta (`Connection closed mid-response`, `API
# Error`). El incidente de #416 fue justo esto: el reviewer murio con `API
# Error: Connection closed mid-response` a los 882s, y como el worktree tenia
# archivos sucios el pipeline abrio igual el PR #421 con una revision
# truncada a mitad de frase -- un CLI que muere a mitad de su contrato nunca
# es recuperable, sin importar cuantos archivos sucios deje.
#
# CA-5: para el resto de fallos (los que SI admiten recuperacion), exige
# ademas que <summary_file> exista y no este vacio -- el mismo archivo que ya
# lee collect_summary
# ($worktree/.claude/pipeline/summaries/stage-<N>-<agente>.md). Es la
# evidencia de que el agente llego al final de su contrato: la ultima
# instruccion de cada prompt de stage es escribir ese resumen, asi que un
# agente que muere antes de esa linea nunca lo deja escrito, aunque haya
# tocado archivos antes de morir.
#
# Solo si ninguno de los dos gates anteriores descalifica, mira el has_work
# original: diff sucio contra <base_commit> o working tree con cambios sin
# commitear.
agent_work_is_trustworthy() {
    local wt="$1" base="$2" unrecoverable="$3" summary_file="$4"

    [ "$unrecoverable" = "true" ] && return 1

    [ -s "$summary_file" ] || return 1

    if ! git -C "$wt" diff --quiet "${base:-HEAD}..HEAD" 2>/dev/null; then
        return 0
    fi
    if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
        return 0
    fi
    return 1
}

# compute_stage_metrics <stream_file>
#
# Deriva las metricas de un stage (issue #426) a partir del stream JSON crudo
# que run_agent_with_watchdog captura (issue #425): turnos, duraciones, costo,
# tokens desglosados, modelo, motivo de fin y un histograma de tool calls por
# nombre (count + tiempo atribuido, suma y mediana, via emparejamiento
# tool_use.id <-> tool_use_id, ambos fechados por el `timestamp` ISO-8601 de
# nivel superior de cada evento -- ver notas tecnicas del issue).
#
# Imprime por stdout un JSON compacto de una sola linea, o el literal "null"
# si no hay nada que derivar. Nunca aborta y siempre retorna 0 (CA-5): sin
# jq, con el stream vacio, o si el evento `result` no aparece (stage matado
# a mitad de corrida, sin chance de escribirlo), degrada a "null".
#
# `num_turns`, `duration_ms`, `duration_api_ms`, `total_cost_usd`, `usage`,
# `is_error`, `stop_reason` y `terminal_reason` del evento `result` estan
# verificados contra el CLI instalado (v2.1.220, ver issue #425). El "model"
# NO esta en esa lista verificada: se busca primero en el evento
# `system`/`init` (`.model`) y, si falta, en `.message.model` del primer
# evento `assistant` -- si ninguno lo trae, queda "model": null sin abortar.
#
# Ademas de lo que CA-1 exige se persisten tres cifras que el issue marca
# opcionales "si son baratos de derivar": `ttft_ms`, el conteo de
# `permission_denials` (solo la cardinalidad -- el arreglo trae los inputs
# denegados, que pueden cargar rutas y comandos y no aportan al analisis de
# tiempos) y el conteo de eventos `rate_limit_event` del stream. Las tres
# apuntan directo a dos causas candidatas de la lentitud que este issue
# existe para medir: denegaciones de permiso que obligan a reintentar, y
# throttling. `permission_denials` y `ttft_ms` estan verificados en el evento
# `result` del CLI instalado (v2.1.220); si un CLI futuro dejara de emitirlos
# quedan en null sin abortar.
compute_stage_metrics() {
    local stream_file="$1"

    if ! command -v jq >/dev/null 2>&1; then
        echo "null"
        return 0
    fi
    if [ ! -s "$stream_file" ]; then
        echo "null"
        return 0
    fi

    local out
    out=$(jq -R -s -c '
        def parse_ts:
            if . == null or (type != "string") then null
            else
                ((capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.(?<frac>[0-9]+))?Z$")) // null) as $c
                | if $c == null then null
                  else
                      (($c.base + "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $sec
                      | $sec * 1000 + (if $c.frac then (($c.frac + "000") | .[0:3] | tonumber) else 0 end)
                  end
            end;

        def median:
            sort as $s
            | ($s | length) as $n
            | if $n == 0 then null
              elif ($n % 2) == 1 then $s[($n - 1) / 2]
              else ($s[$n / 2 - 1] + $s[$n / 2]) / 2
              end;

        (split("\n") | map(select(length > 0)) | map(try fromjson catch empty) | map(select(type == "object"))) as $events
        | ($events | map(select(.type == "result")) | last) as $result
        | if $result == null then null
          else
              ($events | map(select(.type == "system" and .subtype == "init")) | first | .model) as $model_from_init
            | ($events | map(select(.type == "assistant")) | first | .message.model) as $model_from_assistant
            | (
                [ $events[] | select(.type == "assistant") | . as $ev
                  | ($ev.message.content // [])[]?
                  | select(.type == "tool_use")
                  | {id: .id, name: .name, ts: (try ($ev.timestamp | parse_ts) catch null)}
                ]
              ) as $tool_uses
            | (
                [ $events[] | select(.type == "user") | . as $ev
                  | ($ev.message.content // [])[]?
                  | select(.type == "tool_result")
                  | {id: .tool_use_id, ts: (try ($ev.timestamp | parse_ts) catch null)}
                ]
              ) as $tool_results
            | ($tool_results | INDEX(.id)) as $results_by_id
            | (
                $tool_uses
                | group_by(.name)
                | map(
                    . as $group
                    | ($group | map(
                        . as $u
                        # `// ""` y no `[$u.id]` a secas: en jq indexar un
                        # objeto con null es un error DURO (no algo que `try`
                        # local atrape aqui), y ese error tumba la expresion
                        # entera -- un unico tool_use sin `id` dejaria el
                        # stage sin NINGUNA metrica, aunque el evento
                        # `result` viniera completo. Con la clave vacia el
                        # lookup solo devuelve null: la tool call sigue
                        # contando en `count` y las demas no se pierden.
                        | ($results_by_id[$u.id // ""]) as $r
                        | select($r != null and $u.ts != null and $r.ts != null)
                        | ($r.ts - $u.ts)
                      )) as $durations
                    | {
                        name: $group[0].name,
                        count: ($group | length),
                        duration_ms_sum: (if ($durations | length) > 0 then ($durations | add) else null end),
                        duration_ms_median: (if ($durations | length) > 0 then ($durations | median) else null end)
                      }
                  )
                | sort_by(.name)
              ) as $tool_calls
            | {
                turns: $result.num_turns,
                duration_ms: $result.duration_ms,
                duration_api_ms: $result.duration_api_ms,
                non_api_ms: (if ($result.duration_ms != null and $result.duration_api_ms != null) then ($result.duration_ms - $result.duration_api_ms) else null end),
                cost_usd: $result.total_cost_usd,
                tokens: {
                    input: $result.usage.input_tokens,
                    output: $result.usage.output_tokens,
                    cache_read: $result.usage.cache_read_input_tokens,
                    cache_creation: $result.usage.cache_creation_input_tokens
                },
                model: ($model_from_init // $model_from_assistant),
                is_error: $result.is_error,
                stop_reason: $result.stop_reason,
                terminal_reason: $result.terminal_reason,
                ttft_ms: $result.ttft_ms,
                permission_denials: (if ($result.permission_denials | type) == "array" then ($result.permission_denials | length) else null end),
                rate_limit_events: ($events | map(select(.type == "rate_limit_event")) | length),
                tool_calls: $tool_calls
              }
          end
    ' "$stream_file" 2>/dev/null) || out=""

    if [ -n "$out" ]; then
        echo "$out"
    else
        echo "null"
    fi
    return 0
}

# build_agents_history_json <wr_dur> <wr_metrics_json> <rv_dur> <rv_metrics_json>
#
# Construye el objeto JSON "agents" para una entrada de pipeline-history.jsonl
# (issue #426), agregando agents.<agente>.metrics con las cifras derivadas de
# la traza (compute_stage_metrics) SIN tocar el campo "duration" existente --
# CA-2 solo agrega, nunca renombra ni mueve. <wr_metrics_json>/<rv_metrics_json>
# son el JSON compacto que devuelve compute_stage_metrics (o cadena vacia si
# ese stage todavia no corrio).
#
# Con jq disponible construye via `jq -n --argjson` (interpolar objetos
# anidados por concatenacion de string es fragil); sin jq -- o si el jq
# falla por cualquier motivo -- degrada al formato plano de siempre (sin
# "metrics"), igual que antes de este issue (CA-5). Imprime por stdout el
# JSON compacto de "agents" en una sola linea. Retorna siempre 0: un fallo de
# instrumentacion nunca debe tumbar la escritura del historial.
build_agents_history_json() {
    local wr_dur="$1" wr_metrics="$2" rv_dur="$3" rv_metrics="$4"

    local wr_dur_json="null" rv_dur_json="null"
    [ -n "$wr_dur" ] && wr_dur_json="$wr_dur"
    [ -n "$rv_dur" ] && rv_dur_json="$rv_dur"

    [ -z "$wr_metrics" ] && wr_metrics="null"
    [ -z "$rv_metrics" ] && rv_metrics="null"

    if command -v jq >/dev/null 2>&1; then
        local built
        built=$(jq -n -c \
            --argjson wr_dur "$wr_dur_json" --argjson wr_metrics "$wr_metrics" \
            --argjson rv_dur "$rv_dur_json" --argjson rv_metrics "$rv_metrics" \
            '{writer: {duration: $wr_dur, metrics: $wr_metrics},
              reviewer: {duration: $rv_dur, metrics: $rv_metrics}}' 2>/dev/null) || built=""
        if [ -n "$built" ]; then
            echo "$built"
            return 0
        fi
    fi

    printf '{"writer":{"duration":%s},"reviewer":{"duration":%s}}' "$wr_dur_json" "$rv_dur_json"
    return 0
}
