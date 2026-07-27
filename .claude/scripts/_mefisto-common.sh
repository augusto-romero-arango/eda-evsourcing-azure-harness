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
#   changelog.d/             Fragmentos de CHANGELOG/indice de ADRs (issue #380)
#   README.md, CHANGELOG.md, CLAUDE.md, .gitignore   Gobierno del repo
is_path_in_mefisto_scope() {
    local path="$1"
    [ -z "$path" ] && return 1

    case "$path" in
        commands/*|skills/*|agents/*|scripts/*|hooks/*|docs/*) return 0 ;;
        .claude-plugin/*) return 0 ;;
        .claude/commands/*|.claude/skills/*|.claude/agents/*|.claude/scripts/*) return 0 ;;
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
        echo "changelog.d/, README.md, CHANGELOG.md, CLAUDE.md, .gitignore" >&2
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
# de que existieran fragmentos.
existing = {}
order = []
current = None
current_lines = []
for line in body.splitlines():
    hm = re.match(r'^###\s*(\w+)', line)
    if hm:
        if current is not None:
            existing[current] = current_lines
        current = hm.group(1)
        order.append(current)
        current_lines = []
    elif current is not None:
        current_lines.append(line)
if current is not None:
    existing[current] = current_lines

def strip_blank_edges(lines):
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    return lines

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
