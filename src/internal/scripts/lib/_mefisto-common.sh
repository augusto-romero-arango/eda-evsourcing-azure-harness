#!/usr/bin/env bash
# _mefisto-common.sh -- Funciones compartidas entre pipelines INTERNOS de Mefisto
#
# Implementacion CANONICA (MEF-ADR-0049 decision 2, issue #869). Vive en
# src/internal/scripts/lib/, junto al resto de la libreria (mefisto-state.sh,
# mefisto-runtime.sh...). El shim de compatibilidad .claude/scripts/_mefisto-common.sh
# la `source`a con una linea (plantilla documentada en
# src/internal/scripts/README.md); invocar por cualquiera de las dos rutas es
# equivalente. Uso: source "$(dirname "${BASH_SOURCE[0]}")/_mefisto-common.sh"
# (o, desde el canonico, "$(dirname "${BASH_SOURCE[0]}")/lib/_mefisto-common.sh").
#
# No invocar directamente (prefijo _ = sourceable).
#
# ALCANCE: estos pipelines solo se ejecutan dentro del repo del propio Mefisto
# (eda-evsourcing-azure-harness). No usan .claude/harness.config.json (que es
# del consumidor) ni dotnet/Terraform. Operan sobre commands/, agents/, scripts/,
# hooks/, docs/adr/ y archivos de gobierno del repo.

# --- Estado interno resuelto por mefisto-state.sh (issue #856) --------------
#
# Fuente unica de MEFISTO_STATE_DIR/MEFISTO_LEGACY_STATE_DIR y de las funciones
# mefisto_state_path/mefisto_state_read_paths/mefisto_state_read_first
# (MEF-ADR-0049 CA-3). Vive junto a este archivo, en src/internal/scripts/lib/
# (issue #851/#869); este archivo solo lo `source`a. Misma tecnica de
# resolucion de ruta que get_harness_version (mas abajo): relativa a este
# propio archivo via BASH_SOURCE, nunca a una variable de entorno especifica
# de un runtime concreto (issue #873, R3 del gate de neutralidad lo prohibe).
# El `[ -f ]` previo al `source` no es defensa decorativa: sin el, un helper
# ausente o movido aborta con un "No such file or directory" crudo que no dice
# ni que archivo faltaba ni por que; y si el `cd` fallara, la ruta compuesta
# seria un "/../../src/..." que despista mas de lo que informa. El `return 1`
# corta el resto de este archivo a proposito -- deja is_path_in_mefisto_scope
# sin definir, que es justo lo que el hook de scope detecta con `declare -F`
# para degradar en silencio (mefisto-scope-hook.sh), mientras los pipelines
# con `set -e` abortan de una con el motivo en stderr.
_mefisto_common_state_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/mefisto-state.sh"
if [ ! -f "$_mefisto_common_state_lib" ]; then
    echo "ERROR: no se encontro el helper de estado interno de Mefisto en '$_mefisto_common_state_lib' (issue #856)" >&2
    unset _mefisto_common_state_lib
    return 1
fi
source "$_mefisto_common_state_lib"
unset _mefisto_common_state_lib

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
# Ubica plugin.json relativo a este mismo archivo (cuatro niveles arriba de
# src/internal/scripts/lib/, issue #869), no al cwd del pipeline -- mismo
# motivo que el lado publicado: la ruta tiene que resolver sea cual sea el cwd
# desde el que se invoque el pipeline.
#
# Con jq disponible, lee '.version' via jq -r. Sin jq en PATH, degrada a una
# extraccion con sed sobre la linea '"version": "X.Y.Z"'. Si plugin.json no
# existe, o ninguna extraccion produce un valor, imprime cadena vacia -- nunca
# aborta y siempre retorna 0.
get_harness_version() {
    local script_dir plugin_json
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || script_dir=""
    plugin_json="$script_dir/../../../../.claude-plugin/plugin.json"

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
# issue, cuando el cwd todavia es el checkout principal -- los scripts que
# ejecutan la corrida son los del checkout principal, no los del worktree (que
# arranca desde origin/main y puede estar en otro SHA).
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
#                            .claude/harness.config.json y el legado de estado
#                            previo a MEF-ADR-0049 siguen fuera.
#                            Deliberadamente NO se replica en is_path_in_consumer_blocklist
#                            (scripts/_pipeline-common.sh registra el porque).
#   .mcp.json                Declaracion del servidor MCP bundleado del plugin (server
#                            microsoft-learn, que puebla el issue #762), unica ubicacion
#                            que Claude Code registra de verdad. Registrada aqui de
#                            antemano por el issue #763 -- MEF-ADR-0019 seccion E: registro
#                            y primer uso son dos PRs distintos, el de registro va primero.
#                            Entrada EXACTA (raiz del repo), no un glob
#                            *.mcp.json ni subdirectorios. Deliberadamente NO se replica en
#                            is_path_in_consumer_blocklist (scripts/_pipeline-common.sh
#                            registra el porque) -- mismo precedente que .claude/settings.json
#                            (issue #522): en el repo consumidor, .mcp.json en la raiz es su
#                            propia configuracion MCP de proyecto, ruta legitima suya, no
#                            reservada del plugin.
#   src/internal/            Layout interno del BC bajo la arquitectura neutral de runtime
#                            y proveedor (MEF-ADR-0049, issue #851): recetas/plantillas de
#                            USO EXCLUSIVO de Mefisto, analogas a src/ del consumidor pero
#                            fuera de su alcance. Registrada de antemano por el issue #852
#                            (MEF-ADR-0019 seccion E). src/ fuera de internal/ sigue fuera de
#                            scope (Mefisto no tiene src/ propio, solo este layout interno).
#                            Deliberadamente NO se replica en is_path_in_consumer_blocklist:
#                            src/ es una ruta legitima del consumidor (mismo precedente que
#                            .mcp.json, issue #763, y .claude/settings.json, issue #522).
#   .opencode/{agents,commands,plugins,skills}/   Adaptadores OpenCode del propio Mefisto
#                            (MEF-ADR-0049), espejo neutral de .claude/{agents,commands,skills}/.
#                            Solo PLURAL: OpenCode 1.18.29 acepta singular y plural por igual,
#                            pero el generador (#854) solo emite plural y aqui solo se registra
#                            lo que se usa. Registrada de antemano por el issue #852.
#                            Deliberadamente NO se replica en is_path_in_consumer_blocklist:
#                            .opencode/ es la config legitima de OpenCode del consumidor.
#   AGENTS.md, opencode.json   Doctrina canonica neutral (AGENTS.md) y config raiz de OpenCode
#                            (opencode.json, issue #868) -- MEF-ADR-0049. Entradas EXACTAS de
#                            la raiz del repo, no globs, mismo precedente que .mcp.json (issue
#                            #763) y .claude/settings.json (issue #522). Registradas de
#                            antemano por el issue #852. Deliberadamente NO se replican en
#                            is_path_in_consumer_blocklist: ambas son rutas legitimas del
#                            consumidor (AGENTS.md es su propia doctrina neutral; opencode.json
#                            su propia config de proyecto OpenCode).
#   changelog.d/             Fragmentos de CHANGELOG/indice de ADRs (issue #380)
#   README.md, CHANGELOG.md, CLAUDE.md, .gitignore   Gobierno del repo
is_path_in_mefisto_scope() {
    local path="$1"
    [ -z "$path" ] && return 1

    case "$path" in
        commands/*|skills/*|agents/*|scripts/*|hooks/*|docs/*) return 0 ;;
        src/internal/*) return 0 ;;
        .claude-plugin/*) return 0 ;;
        .claude/commands/*|.claude/skills/*|.claude/agents/*|.claude/scripts/*) return 0 ;;
        .claude/settings.json) return 0 ;;
        .opencode/agents/*|.opencode/commands/*|.opencode/plugins/*|.opencode/skills/*) return 0 ;;
        .mcp.json) return 0 ;;
        README.md|CHANGELOG.md|CLAUDE.md|.gitignore|AGENTS.md|opencode.json) return 0 ;;
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

    # --untracked-files=all: sin el, git colapsa un directorio nuevo sin trackear
    # a su raiz ("src/") y esa entrada no casa con patrones como src/internal/*
    # en is_path_in_mefisto_scope, rechazando cambios que si estan en scope
    # (issue #882). Mismo patron que changes_require_changelog y
    # changelog_fragment_added.
    local changed
    changed=$(
        git -C "$wt" diff --name-only "$base..HEAD" 2>/dev/null
        git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null | sed 's/^...//'
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
        echo ".claude/settings.json, .mcp.json, src/internal/," >&2
        echo ".opencode/{agents,commands,plugins,skills}/, AGENTS.md, opencode.json," >&2
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
#   AGENTS.md          Doctrina canonica neutral (MEF-ADR-0049, issue #852) -- mismo
#                      tratamiento de gobierno que CLAUDE.md
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
        README.md|CLAUDE.md|AGENTS.md|.gitignore) return 0 ;;
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
# final de la tabla del "Indice tematico" de docs/adr/INDICE-TEMATICO.md, y
# borra del disco los fragmentos consumidos (el caller los stagea con git add
# junto al resto). Usada por la fase prepare de mefisto-release.sh, en la
# propia rama de release.
#
# Sin changelog.d/ o sin fragmentos *.adr-index.md dentro, es un no-op.
consolidate_adr_index_fragments() {
    local repo_root="$1"
    local dir="$repo_root/changelog.d"
    [ -d "$dir" ] || return 0

    ADR_INDEX_PATH="$repo_root/docs/adr/INDICE-TEMATICO.md" CHANGELOG_FRAGMENTS_DIR="$dir" python3 <<'PYEOF'
import glob, os, re, sys

adr_index_path = os.environ['ADR_INDEX_PATH']
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

with open(adr_index_path, encoding='utf-8') as f:
    text = f.read()

marker = '| Tema | ADR |\n|---|---|\n'
idx = text.find(marker)
if idx == -1:
    print("ERROR: no se encontro la tabla de indice de ADRs en docs/adr/INDICE-TEMATICO.md", file=sys.stderr)
    sys.exit(1)
insert_at = idx + len(marker)

rest = text[insert_at:]
end_match = re.search(r'(?m)^(?!\|)', rest)
table_body_end = insert_at + (end_match.start() if end_match else len(rest))

new_rows_text = ''.join(row + '\n' for row in rows)
text = text[:table_body_end] + new_rows_text + text[table_body_end:]

with open(adr_index_path, 'w', encoding='utf-8') as f:
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
# No valida el NOMBRE del modelo (un alias corto o un id de modelo completo son
# ambos pass-through, sin allowlist propia -- el vocabulario de modelos de cada
# proveedor evoluciona con el CLI): solo la forma 'clave=valor' de cada entrada y
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

# --- Modo --variant: corridas paralelas del mismo issue (issue #711) --------
#
# Contraparte interna de validate_variant_label en scripts/_pipeline-common.sh
# (issue #710, lado publicado): mismo contrato de UX para el flag --variant,
# sin compartir codigo (MEF-ADR-0019 separa fisicamente publicado/interno).
# Permite correr el MISMO issue de Mefisto N veces en paralelo -- cada corrida
# en su propio worktree/rama/log, sin PR ni mutacion del issue -- para
# comparar modelos sobre el propio harness (contraparte de --models, issue
# #709). El resto del mecanismo (sufijar worktree/rama/logs con el label,
# suprimir push/PR/comentario al issue) es codigo lineal propio de
# mefisto-tooling-pipeline.sh, sin logica compartida que valga la pena
# extraer.

# validate_variant_label <label>
#
# Valida el label de --variant (CA-1): slug de minusculas, digitos y guiones
# ([a-z0-9-]), longitud 1-40 -- mismo tope que el slug del titulo del issue en
# mefisto-tooling-pipeline.sh (`cut -c1-40`), para que
# "worktree-mefisto-issue-<N>-<slug>-<label>" no dispare el nombre de
# rama/carpeta mas alla de lo practico. El caller debe invocarla ANTES de
# crear el worktree: un label malformado debe abortar temprano, igual que
# parse_stage_models con --models.
#
# Retorna 0 si valido. Retorna 1 y deja el motivo en
# MEFISTO_VARIANT_LABEL_ERROR (una linea, lista para abort()) si no -- mismo
# contrato que MEFISTO_STAGE_MODELS_ERROR.
validate_variant_label() {
    local label="$1"
    MEFISTO_VARIANT_LABEL_ERROR=""

    if [ -z "$label" ]; then
        MEFISTO_VARIANT_LABEL_ERROR="el label de --variant no puede estar vacio"
        return 1
    fi
    if [ "${#label}" -gt 40 ]; then
        MEFISTO_VARIANT_LABEL_ERROR="el label de --variant '$label' supera 40 caracteres"
        return 1
    fi
    if ! printf '%s' "$label" | grep -Eq '^[a-z0-9-]+$'; then
        MEFISTO_VARIANT_LABEL_ERROR="el label de --variant '$label' es invalido: solo minusculas, digitos y guiones ([a-z0-9-])"
        return 1
    fi
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
# invoca el CLI del runtime en modo no interactivo con la salida de eventos en
# streaming JSON, <stdout_file> recibe el stream JSON crudo (una linea por
# evento) mientras que los mensajes de error del propio CLI (`API Error: ...`,
# cortes de conexion) siguen llegando como texto plano por stderr. Un `2>&1`
# clasico mezclaria ese texto DENTRO del JSONL y lo corromperia -- exactamente
# lo que este cambio evita.
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
# kill no alcanzaba ni al `claude` ni a sus hijos node. El mecanismo YA NO es
# job control (`set -m`) sobre el lanzamiento del AGENTE (issue #943): activar
# monitor mode ahi volvia al job lider de su propio grupo, si, pero ese grupo
# seguia colgado de la MISMA sesion que la pty del pane -- y cualquier tool
# del arbol que tocara la terminal (`read </dev/tty`, `stty`/tcsetattr, o
# simplemente leer stdin heredado) disparaba SIGTTIN/SIGTTOU y el kernel
# detenia al grupo ENTERO (STAT=T), a veces durante minutos hasta un
# `SIGCONT` manual -- confirmado por experimento en una pty de tmux. Ahora
# <cmd...> arranca en una SESION nueva y sin terminal de control: `setsid` si
# esta en PATH (Linux), o si no el fallback
# `perl -e 'use POSIX; POSIX::setsid() or die; exec @ARGV' -- <cmd...>`
# (macOS, donde `setsid(1)` no existe -- verificado: `command -v setsid` ->
# vacio en macOS 26.4 -- pero `/usr/bin/perl` si). Una sesion nueva resuelve
# las DOS cosas a la vez: hace al proceso lider de su propio GRUPO por si
# misma (PGID == PID, el mismo invariante que necesita CA-1) y ademas lo deja
# SIN terminal de control -- sin ella, `SIGTTIN`/`SIGTTOU` son imposibles
# (`isbackground()` del kernel exige la MISMA sesion que la terminal): un
# `open /dev/tty` falla con ENXIO y un `stty` sobre stdin (redirigido a
# `/dev/null`) falla con "not a terminal", ninguno de los dos detiene nada. Si
# ni `setsid` ni `perl` estan en PATH, la funcion degrada al mecanismo viejo
# (`set -m` mas `</dev/null` en stdin) y deja constancia EXPLICITA con un WARN
# en <events_log> -- nunca en silencio, porque ese camino vuelve a exponer la
# clase de bug que este issue elimina.
#
# El `set -m` NO puede volver a envolver el lanzamiento del agente, y no solo
# porque sea innecesario: `setsid(1)` de util-linux, cuando su invocante YA es
# lider de grupo (que es justo lo que `set -m` provoca), no puede llamar a
# setsid(2) -- forkea, y el padre sale con exit 0 de inmediato. `$!` dejaria de
# apuntar al proceso real, `wait "$pid"` devolveria 0 al instante para un
# agente todavia corriendo y `kill -9 -"$pid"` apuntaria a un grupo ajeno. El
# `exec` del subshell es la otra mitad del mismo invariante: conserva el PID
# que `$!` capturo.
#
# El watchdog se lanza en su PROPIA ventana de `set -m` (la unica que le
# queda a esta funcion en el camino feliz -- el agente ya no la necesita, ver
# arriba): cuando <cmd...> termina solo y hay que cancelarlo, un `kill` al PID
# del subshell del watchdog mata al subshell pero deja su `sleep <timeout_s>`
# huerfano hasta media hora (verificado: un `sleep` colgado por stage).
# Siendo lider de su propio grupo, `kill -9 -$watchdog_pid` se lleva subshell
# y `sleep` de una. Tiene que ser SIGKILL al GRUPO y no SIGTERM al `sleep`
# por separado: matar solo al `sleep` haria que el subshell despertara y
# siguiera con el `touch`/`kill`/`echo`, escribiendo un evento TIMEOUT espurio
# de un stage que en realidad termino bien.
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
#
# Clase de evento STOPPED (issue #945; las CA-1..CA-3 que se citan mas abajo
# EN EL CUERPO son las de ese issue, no las de #424 que numeran los parrafos
# anteriores): el subshell del watchdog ya no duerme <timeout_s> de una sola
# pieza -- itera en rebanadas de MEFISTO_WATCHDOG_POLL_S segundos (default 5)
# hasta agotar el presupuesto (la ultima rebanada se recorta para que la suma
# nunca exceda <timeout_s>, asi que el disparo de TIMEOUT ocurre en el mismo
# instante que antes). En cada rebanada revisa con `ps -eo pid=,pgid=,stat=`
# -- nunca `ps -g`, cuyo significado difiere entre BSD/macOS y GNU/Linux --
# filtrado por PGID con awk (portable en ambos) si algun proceso del grupo de
# <cmd...> quedo en STAT=T (detenido: SIGSTOP/SIGTSTP/SIGTTIN/SIGTTOU -- no
# necesariamente el mismo mecanismo que #943 ya elimino, sino defensa en
# profundidad ante cualquier causa futura). Si encuentra alguno, envia SIGCONT
# al GRUPO (`kill -CONT -"$pid"`, NUNCA otra senal por este camino) y deja
# constancia en <events_log>: "[HH:MM:SS] STOPPED: <label> tenia N proceso(s)
# detenido(s) -- SIGCONT enviado". Es observabilidad y auto-sanado DENTRO del
# lazo de control existente (issue #945 retoma esto de la evaluacion de la
# propuesta "supervisor autonomo"), nunca un supervisor externo, y no cambia
# la semantica de TIMEOUT (MEF-ADR-0031): sigue siendo el unico exit code que
# esta funcion provoca, la clase STOPPED solo anota un evento de texto plano.
#
# Efecto colateral del troceo sobre el `sleep` huerfano de CA-1/#424: la
# ventana de fuga ya no es <timeout_s> sino una rebanada. Si el kill de grupo
# con que se cancela el watchdog no alcanza a su `sleep`, ese huerfano muere
# solo en <= MEFISTO_WATCHDOG_POLL_S segundos en vez de sobrevivir media hora.
run_agent_with_watchdog() {
    local workdir="$1" timeout_s="$2" stdout_file="$3" stderr_file="$4" events_log="$5" label="$6" signal_file="$7"
    shift 7

    rm -f "$signal_file"

    local pid
    if command -v setsid >/dev/null 2>&1; then
        ( cd "$workdir" && exec setsid "$@" ) </dev/null >"$stdout_file" 2>"$stderr_file" &
        pid=$!
    elif command -v perl >/dev/null 2>&1; then
        ( cd "$workdir" && exec perl -e 'use POSIX; POSIX::setsid() or die; exec @ARGV' -- "$@" ) </dev/null >"$stdout_file" 2>"$stderr_file" &
        pid=$!
    else
        echo "[$(date +%H:%M:%S)] WARN: $label corre con terminal de control (sin setsid ni perl): riesgo de SIGTTIN" >> "$events_log"
        set -m
        ( cd "$workdir" && "$@" ) </dev/null >"$stdout_file" 2>"$stderr_file" &
        pid=$!
        set +m
    fi

    # <poll_s> tiene que ser un entero >= 1. Con 0 (o con un valor no numerico,
    # donde el `sleep` falla al instante y la aritmetica no avanza) <elapsed>
    # nunca crece: el watchdog giraria para siempre forkeando `ps` y jamas
    # dispararia el TIMEOUT. Una variable de entorno mal puesta no puede
    # desarmar en silencio el unico limite de presupuesto del pipeline, asi que
    # cualquier valor invalido cae al default y el 0 se eleva al minimo.
    local poll_s="${MEFISTO_WATCHDOG_POLL_S:-5}"
    case "$poll_s" in
        ''|*[!0-9]*) poll_s=5 ;;
        0) poll_s=1 ;;
    esac

    set -m
    (
        # CA-1 (#945): rebanadas de <poll_s> en vez de un solo
        # `sleep <timeout_s>` -- cada rebanada es una oportunidad de revisar
        # si el grupo quedo detenido (ver CA-6 en la cabecera de esta
        # funcion) sin retrasar el disparo de TIMEOUT: la ultima rebanada se
        # recorta para que la suma de todas nunca exceda <timeout_s>.
        elapsed=0
        while [ "$elapsed" -lt "$timeout_s" ]; do
            slice="$poll_s"
            remaining=$((timeout_s - elapsed))
            [ "$slice" -gt "$remaining" ] && slice="$remaining"
            sleep "$slice"
            elapsed=$((elapsed + slice))

            # CA-2 (#945): STAT empieza por T/t cuando el proceso esta detenido
            # (SIGSTOP/SIGTSTP/SIGTTIN/SIGTTOU). `ps -eo pid=,pgid=,stat=`
            # filtrado por PGID con awk, no `ps -g` (su significado difiere
            # entre BSD/macOS y GNU/Linux).
            # El conteo lo cierra el propio awk (`END { print n + 0 }`) y no un
            # `| wc -l | tr -d ' '`: son dos forks menos por rebanada -- lo
            # unico que este lazo agrega al presupuesto de TIMEOUT, y se paga
            # una vez cada <poll_s> durante toda la corrida del agente.
            stopped_count=$(ps -eo pid=,pgid=,stat= 2>/dev/null | awk -v pgid="$pid" '$2 == pgid && $3 ~ /^[Tt]/ { n++ } END { print n + 0 }')
            if [ "${stopped_count:-0}" -gt 0 ]; then
                # El evento se escribe ANTES del CONT, no despues: apenas se
                # reanuda, el grupo puede terminar de inmediato y el caller
                # (wait "$pid") cancela este watchdog con un SIGKILL de grupo
                # -- si el `echo` fuera posterior al `kill -CONT`, esa
                # cancelacion podria alcanzar al watchdog antes de que
                # llegara a escribir su propia linea, perdiendo el evento.
                # Nunca otra senal que CONT por este camino: reanudar, no
                # terminar -- el grupo puede seguir trabajando.
                echo "[$(date +%H:%M:%S)] STOPPED: $label tenia $stopped_count proceso(s) detenido(s) -- SIGCONT enviado" >> "$events_log"
                kill -CONT -"$pid" 2>/dev/null
            fi
        done

        # `: >` (builtin, sin fork) y no `touch`: un `touch` es un proceso
        # externo, y si el SIGKILL con que esta funcion cancela al watchdog
        # aterriza justo entre el fork y el exit de ese `touch`, el binario
        # queda HUERFANO y termina de crear <signal_file> DESPUES del
        # `rm -f "$signal_file"` de la rama de cancelacion -- una senal de
        # timeout para un stage que termino bien, que el caller clasifica
        # como TIMEOUT y descarta trabajo bueno. Medido en la rama de #943:
        # 2-4 senales espurias por cada 300 corridas cortas con `touch`
        # (bloque C-6 de test-watchdog-trabajo-util.sh, fallo intermitente
        # que precede a este issue), cero con la redireccion builtin, que se
        # completa dentro del propio proceso del watchdog y por tanto nunca
        # sobrevive al kill.
        : > "$signal_file" 2>/dev/null
        kill -9 -"$pid" 2>/dev/null
        echo "[$(date +%H:%M:%S)] TIMEOUT: $label supero ${timeout_s}s" >> "$events_log"
    ) </dev/null >/dev/null 2>&1 &
    local watchdog_pid=$!
    set +m

    local exit_code=0
    wait "$pid" || exit_code=$?

    # Si <signal_file> ya existe aqui, el watchdog fue quien mato a <pid> --
    # esta a mitad de escribir su evento TIMEOUT (la senal precede al kill en
    # su propio cuerpo, en el mismo proceso, sin concurrencia posible entre
    # ambos). Una senal nuestra en ese instante podria cortarlo antes de
    # llegar al `echo` incondicional (CA-2) -- se lo deja terminar solo, NUNCA
    # se lo mata; solo se cancela el watchdog cuando <pid> termino por su
    # cuenta y el watchdog sigue dormido en el `sleep`.
    if [ -f "$signal_file" ]; then
        wait "$watchdog_pid" 2>/dev/null || true
    else
        kill -9 -"$watchdog_pid" 2>/dev/null || true
        # Respaldo al PID pelado por si el kill al GRUPO no alcanzo al
        # watchdog (medido: el `sleep` sobrevive al kill de grupo en ~2% de
        # las corridas cortas, ver mas abajo). Deja huerfano el `sleep` -- mal
        # menor frente a un watchdog vivo que dentro de 30 min haria
        # `kill -9` sobre un PGID ya reciclado por un proceso ajeno.
        kill -9 "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
        # Carrera del watchdog perdido: entre que `wait` retorno y este `kill`
        # aterrizo, un watchdog que sobrevivio a su `sleep` alcanza a hacer su
        # senal -- y deja <signal_file> creado para un stage que en realidad
        # termino solo. El caller lo leeria como TIMEOUT y descartaria trabajo
        # bueno (se observo como "TIMEOUT (0s, exit 0)" en el bloque G de
        # test-tooling-state-paths.sh, ~40% de las corridas cuando el CLI
        # responde en menos de un segundo). Aqui ya se decidio que el watchdog
        # NO habia disparado cuando el proceso termino -- esa es la rama else
        # --, asi que cualquier senal posterior es ruido y se borra. El caso
        # legitimo (el watchdog SI disparo) va por la rama de arriba y su
        # senal nunca se toca.
        rm -f "$signal_file"
    fi

    echo "$exit_code"
}

# derive_stage_log_from_stream <events_file> <stderr_file> <out_file>
#
# Deriva el log legible de un stage (issue #425, reescrita sobre el JSONL
# neutral en el issue #906) a partir de <events_file> -- el
# `<log_base>.events.jsonl` que run_agent escribe traduciendo la traza cruda
# del CLI con runtime_claude_translate (MEF-ADR-0049 decision 1: esta capa ya
# no interpreta el vocabulario de un runtime concreto). Emite una linea por
# cada `message{kind:"text"}` (la ausencia de `kind` tambien cuenta como
# texto, ver run-events.schema.json), una linea "[tool] <nombre>" por cada
# `tool.started`, y una linea "<error.kind>: <error.detail>" cuando el
# evento terminal (`run.completed`/`run.failed`) trae `error` no nulo -- el
# `detail` ya llega con el prefijo "API Error: <status>" cuando el traductor
# lo conoce (runtime-claude.jq), asi que el log derivado sigue siendo
# grep-able para un humano aunque la clasificacion de mas abajo ya no lea de
# aqui (ver agent_events_error_kind). Al final anexa el contenido de
# <stderr_file> tal cual (ya es texto plano). Sobreescribe <out_file> si ya
# existia.
#
# El nombre y la ruta de <out_file> NO cambian (sigue siendo
# mefisto-tooling-stage-<N>-<agente>-<TS>-issue-<N>.log): _mefisto-work-status
# y mefisto-investigator lo referencian, y run_agent muestra el `tail` de
# diagnostico del abort contra este mismo archivo derivado.
#
# CA-4 (#425): tolera una traza truncada (la ultima linea puede haber quedado
# a medias si el proceso murio a mitad de escritura) y una traza vacia. La
# tolerancia la da `fromjson?`: jq lee cada linea como texto (`-R`) y el `?`
# descarta en silencio la que no parsea, sin abortar y sin perder lo ya
# derivado de las lineas anteriores. El `select(type == "object")` cubre el
# otro caso degenerado -- una linea que SI es JSON valido pero no un objeto.
#
# Es una sola invocacion de jq para todo el archivo, no una por linea:
# medido sobre un stream sintetico de 1000 eventos, un jq por linea tarda 5s
# y una sola pasada 0.01s.
#
# Si jq no esta disponible, degrada con gracia (issue #425): deja una nota
# explicita en vez de intentar parsear JSON a mano, y de todos modos anexa
# <stderr_file> -- que ya es texto plano y es donde vive la causa de la
# mayoria de los fallos que le importan a run_agent. Un fallo de
# instrumentacion (falta jq, stream vacio o inexistente) nunca debe tumbar el
# pipeline: la funcion siempre retorna 0.
derive_stage_log_from_stream() {
    local events_file="$1" stderr_file="$2" out_file="$3"

    : > "$out_file" 2>/dev/null || return 0

    if [ -s "$events_file" ]; then
        if command -v jq >/dev/null 2>&1; then
            jq -R -r '
                fromjson?
                | select(type == "object")
                | if .type == "message" then
                      (if (.kind // "text") == "text" then (.text // "") else empty end)
                  elif .type == "tool.started" then
                      "[tool] " + (.tool // "?")
                  elif (.type == "run.completed" or .type == "run.failed") then
                      (if (.error // null) != null
                       then ((.error.kind // "error") + ": " + (.error.detail // ""))
                       else empty end)
                  else empty end
            ' "$events_file" >> "$out_file" 2>/dev/null || true
        else
            echo "(jq no disponible: no se pudo derivar texto legible del JSONL neutral -- ver $events_file)" >> "$out_file"
        fi
    fi

    if [ -s "$stderr_file" ]; then
        [ -s "$out_file" ] && echo "" >> "$out_file"
        cat "$stderr_file" >> "$out_file" 2>/dev/null || true
    fi

    return 0
}

# agent_stream_completed_successfully <events_file>
#
# Retorna 0 si el JSONL neutral de un stage (<events_file>, el
# `<log_base>.events.jsonl` que escribe run_agent -- issue #906) contiene un
# evento terminal `run.completed{status:"success"}`, 1 en cualquier otro caso
# -- incluido que falte el archivo, que no haya terminal, que jq no este
# instalado o que la traza este corrupta. El default en 1 (no se puede
# afirmar el exito) es deliberado: esta funcion solo sirve para RELAJAR una
# clasificacion de fallo, asi que ante la duda tiene que dejarla como estaba.
#
# `run.completed{status:"success"}` es la unica forma en que el contrato
# neutral (run-events.schema.json) representa que el runtime cumplio su
# contrato -- MEF-ADR-0049 CA-4 parte el vocabulario de `status` entre los
# dos terminales a proposito, asi que basta leer `.type`/`.status`, sin
# nombrar ningun campo propio de un runtime concreto (los que antes de este
# issue vivian aqui: ver el historial de git de esta funcion).
#
# Parseo tolerante (`try fromjson catch empty`) porque la traza puede traer
# lineas truncadas si el proceso murio a media escritura -- y ese es
# justamente el caso que NO debe reportar exito.
agent_stream_completed_successfully() {
    local events_file="${1:-}"

    [ -n "$events_file" ] || return 1
    [ -s "$events_file" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1

    local verdict
    verdict=$(jq -Rsr '
        (split("\n") | map(select(length > 0)) | map(try fromjson catch empty)
            | map(select(type == "object"))) as $events
        | ($events | map(select(.type == "run.completed" or .type == "run.failed")) | last) as $terminal
        | if ($terminal != null and $terminal.type == "run.completed" and $terminal.status == "success")
          then "yes" else "no" end
    ' "$events_file" 2>/dev/null) || return 1

    [ "$verdict" = "yes" ]
}

# agent_events_error_field <events_file> <campo>
#
# Imprime por stdout `error.<campo>` del evento terminal (`run.completed` o
# `run.failed`) del JSONL neutral <events_file> (issue #906), o cadena vacia
# si no hay terminal, el terminal no trae `error` (null), el archivo esta
# vacio/inexistente o jq no esta disponible. Nunca aborta, siempre retorna 0.
#
# Es el UNICO lugar donde vive la seleccion del evento terminal para decidir
# recuperacion/clasificacion; sus dos wrappers (agent_events_error_kind /
# agent_events_error_detail) son la interfaz que usan los callers. Con la
# expresion duplicada en cada consumidor, un cambio en como se elige el
# terminal (hoy: el ULTIMO, por si una traza trae dos) tendria que replicarse
# a mano en cada copia -- el mismo modo de desincronizacion silenciosa que
# motivo centralizar el patron del corte de stream en #424.
#
# Antes de este issue la decision vivia en un grep amplio sobre el log
# DERIVADO -- MEF-ADR-0049 (decision 1) prohibe que esta capa interprete el
# vocabulario de un runtime concreto, asi que la fuente pasa a ser el campo
# estructurado que el adaptador ya declaro.
#
# Parseo tolerante (`try fromjson catch empty`), igual que
# agent_stream_completed_successfully: una linea truncada a mitad de escritura
# se descarta sin perder las anteriores.
agent_events_error_field() {
    local events_file="${1:-}" field="${2:-kind}"

    if [ -z "$events_file" ] || [ ! -s "$events_file" ] || ! command -v jq >/dev/null 2>&1; then
        echo ""
        return 0
    fi

    local value
    value=$(jq -Rsr --arg field "$field" '
        (split("\n") | map(select(length > 0)) | map(try fromjson catch empty)
            | map(select(type == "object"))) as $events
        | ($events | map(select(.type == "run.completed" or .type == "run.failed")) | last) as $terminal
        | ((($terminal.error // {})[$field]) // "")
    ' "$events_file" 2>/dev/null) || value=""

    echo "$value"
    return 0
}

# agent_events_error_kind <events_file>
#
# `error.kind` del terminal, o cadena vacia. Lo consumen
# agent_failure_is_unrecoverable (que solo mira si vale "stream_cut") y
# classify_agent_failure (que ademas necesita el detalle para distinguir 5xx
# de 4xx dentro de "api_error", ver agent_events_error_detail).
agent_events_error_kind() {
    agent_events_error_field "${1:-}" kind
}

# agent_events_error_detail <events_file>
#
# `error.detail` del terminal, o cadena vacia. Solo lo consulta
# classify_agent_failure cuando el kind ya es "api_error": el status HTTP no
# es un campo propio del contrato neutral, viaja dentro del detalle con el
# prefijo canonico "API Error: <status>" que el adaptador ya normaliza
# (runtime-claude.jq).
agent_events_error_detail() {
    agent_events_error_field "${1:-}" detail
}

# agent_failure_is_unrecoverable <timed_out> <exit_code> <events_file>
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
#   - `error.kind == "stream_cut"` del terminal (issue #906: antes de este
#     issue este criterio era un grep amplio -- "Connection closed
#     mid-response"/"API Error", cualquier status -- que de paso marcaba
#     irrecuperable un fallo de API ordinario; ahora solo el corte de stream
#     genuino lo hace, y un `api_error` que agota reintentos cae al mismo
#     atajo has_work que un CLI_ERROR). El corte de stream a mitad de
#     respuesta fue el incidente de #416 -- el reviewer murio con `API Error:
#     Connection closed mid-response` a los 882s y el pipeline abrio igual el
#     PR #421 con una revision truncada a mitad de frase.
#
# EXCEPCION (PR #446): si el terminal del stage declara exito
# (agent_stream_completed_successfully), el CLI ya habia cumplido su
# contrato y lo que vino despues -- una senal al proceso, un exit code
# distinto de cero -- es una muerte POSTERIOR al trabajo, no a mitad de
# vuelo. Ese caso si es recuperable, y sigue pasando por los gates de
# agent_work_is_trustworthy (resumen de stage presente + diff real), asi que
# la relajacion no abre la puerta a un PR con trabajo a medias.
agent_failure_is_unrecoverable() {
    local timed_out="$1" exit_code="$2" events_file="$3"

    # Antes que nada: si el CLI declaro exito, la muerte fue posterior.
    agent_stream_completed_successfully "$events_file" && return 1

    [ "$timed_out" = "true" ] && return 0
    [ "$exit_code" = "137" ] && return 0
    [ "$exit_code" = "143" ] && return 0

    [ "$(agent_events_error_kind "$events_file")" = "stream_cut" ] && return 0

    return 1
}

# classify_agent_failure <timed_out> <exit_code> <elapsed_s> <events_file>
#
# Traduce el desenlace de una invocacion fallida del CLI a la etiqueta
# <failure_type> que run_agent registra en events.log. Era logica inline de
# run_agent; se extrajo aqui en el issue #534 por el mismo motivo que
# agent_failure_is_unrecoverable: pasa a gobernar si un stage se REINTENTA, y
# inline no habia forma de ejercerla sin invocar el CLI real.
#
# El orden de los casos es significativo y se conserva verbatim de versiones
# previas (issue #906 solo cambia la FUENTE -- `error.kind`/`error.detail`
# del terminal del JSONL neutral en vez de un grep sobre el log): el TIMEOUT
# del watchdog gana sobre cualquier otro sintoma (es el unico TIMEOUT de
# verdad), y el match de "API Error: 5" precede al de "API Error: 4" y al
# `stream_cut` generico -- que es mas amplio y se los tragaria.
classify_agent_failure() {
    local timed_out="$1" exit_code="$2" elapsed="$3" events_file="$4"

    if [ "$timed_out" = "true" ]; then
        echo "TIMEOUT (${elapsed}s, exit $exit_code)"
        return 0
    fi

    if [ "$exit_code" = "137" ] || [ "$exit_code" = "143" ]; then
        if agent_stream_completed_successfully "$events_file"; then
            echo "SIGNAL_POST_SUCCESS (exit $exit_code, ${elapsed}s)"
        else
            echo "SIGNAL_MID_FLIGHT (exit $exit_code, ${elapsed}s)"
        fi
        return 0
    fi

    local error_kind
    error_kind="$(agent_events_error_kind "$events_file")"

    if [ "$error_kind" = "api_error" ]; then
        local error_detail
        error_detail="$(agent_events_error_detail "$events_file")"
        if printf '%s' "$error_detail" | grep -q "API Error: 5"; then
            echo "API_ERROR_SERVER (exit $exit_code)"
        elif printf '%s' "$error_detail" | grep -q "API Error: 4"; then
            echo "API_ERROR_CLIENT (exit $exit_code)"
        else
            echo "CLI_ERROR (exit $exit_code)"
        fi
    elif [ "$error_kind" = "stream_cut" ]; then
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
# -- el caller la marca en TIMEOUT, en una senal de proceso (137/143) sin
# exito previo, o cuando el terminal del JSONL neutral del stage trae
# `error.kind == "stream_cut"` (issue #906, agent_failure_is_unrecoverable).
# El incidente de #416 fue justo esto: el reviewer murio con `API Error:
# Connection closed mid-response` a los 882s, y como el worktree tenia
# archivos sucios el pipeline abrio igual el PR #421 con una revision
# truncada a mitad de frase -- un CLI que muere a mitad de su contrato nunca
# es recuperable, sin importar cuantos archivos sucios deje.
#
# CA-5: para el resto de fallos (los que SI admiten recuperacion), exige
# ademas que <summary_file> exista y no este vacio -- el mismo archivo que ya
# lee collect_summary (mefisto_state_path "summaries/stage-<N>-<agente>.md"
# "$worktree", issue #869). Es la evidencia de que el agente llego al final
# de su contrato: la ultima
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

# compute_stage_metrics <events_file>
#
# Deriva las metricas de un stage (issue #426, reescrita sobre el JSONL
# neutral en el issue #907) a partir de <events_file> -- el
# `<log_base>.events.jsonl` que run_agent escribe traduciendo la traza cruda
# del runtime con runtime_<id>_translate (issue #906, MEF-ADR-0049). Ya no
# interpreta el vocabulario de ningun runtime concreto: todo lo que imprime
# sale del vocabulario cerrado de src/internal/contract/run-events.schema.json.
# El evento terminal (`run.completed`/`run.failed`) ya trae runtime, model,
# status, duration_ms, tokens{input,output}, cost_usd, turns, denials,
# ttft_ms, api_duration_ms y error{kind,detail}|null calculados por el
# traductor -- esta funcion solo los copia y arma el histograma de tool
# calls agrupando por nombre los eventos `tool.started` (cuenta) y
# `tool.completed` (duration_ms, cuando no es null).
#
# Imprime por stdout un JSON compacto de una sola linea, o el literal "null"
# si no hay nada que derivar. Nunca aborta y siempre retorna 0 (CA-5): sin
# jq, con el archivo vacio, o si ningun evento terminal aparece (stage matado
# a mitad de corrida sin evento sintetizado todavia), degrada a "null".
#
# `cost_usd` (y el resto de campos numericos del terminal) se copia tal
# cual, sin el operador `//` de jq: un `0` real (el costo de una corrida bajo
# suscripcion de OpenCode, ver runtime-opencode.jq) nunca debe degradar a
# null, y `//` colapsa `0` igual que colapsa `false`/`null` si se usara aqui.
#
# `tool_calls` agrupa por NOMBRE, no por id: el contrato neutral ya no expone
# un id de tool call (`tool.completed.duration_ms` viene precalculado por el
# traductor de cada runtime), asi que agrupar por nombre es la unica
# correlacion posible -- y la que CA-1 pide. Un `tool.started` sin
# `tool.completed` (el proceso murio a mitad de la llamada), o con
# `tool.completed.duration_ms: null`, cuenta en `count` pero no aporta a
# `duration_ms_sum`/`duration_ms_median`. El caso simetrico -- un
# `tool.completed` cuyo nombre no aparece en ningun `tool.started` (traza
# cortada justo antes del inicio, o un traductor que no pudo resolver el
# nombre y emitio "?") -- no aparece en `tool_calls`: `count` es la cuenta
# de llamadas EMPEZADAS, y sumar ahi una duracion sin llamada que la
# explique dejaria un `duration_ms_sum` sin `count` que lo respalde.
compute_stage_metrics() {
    local events_file="$1"

    if ! command -v jq >/dev/null 2>&1; then
        echo "null"
        return 0
    fi
    if [ ! -s "$events_file" ]; then
        echo "null"
        return 0
    fi

    local out
    out=$(jq -R -s -c '
        def median:
            sort as $s
            | ($s | length) as $n
            | if $n == 0 then null
              elif ($n % 2) == 1 then $s[($n - 1) / 2]
              else ($s[$n / 2 - 1] + $s[$n / 2]) / 2
              end;

        (split("\n") | map(select(length > 0)) | map(try fromjson catch empty) | map(select(type == "object"))) as $events
        | ($events | map(select(.type == "run.completed" or .type == "run.failed")) | last) as $terminal
        | if $terminal == null then null
          else
              (
                $events
                | map(select(.type == "tool.started"))
                | group_by(.tool)
                | map({name: .[0].tool, count: length})
              ) as $counts
            | (
                $events
                | map(select(.type == "tool.completed"))
                | group_by(.tool)
                | map({name: .[0].tool, durations: (map(select(.duration_ms != null) | .duration_ms))})
              ) as $durations_by_name
            | (
                $counts
                | map(
                    . as $c
                    | (($durations_by_name | map(select(.name == $c.name)) | first | .durations) // []) as $d
                    | {
                        name: $c.name,
                        count: $c.count,
                        duration_ms_sum: (if ($d | length) > 0 then ($d | add) else null end),
                        duration_ms_median: (if ($d | length) > 0 then ($d | median) else null end)
                      }
                  )
                | sort_by(.name)
              ) as $tool_calls
            | {
                runtime: $terminal.runtime,
                model: $terminal.model,
                status: $terminal.status,
                error_kind: $terminal.error.kind,
                duration_ms: $terminal.duration_ms,
                api_duration_ms: $terminal.api_duration_ms,
                non_api_ms: (if ($terminal.duration_ms != null and $terminal.api_duration_ms != null) then ($terminal.duration_ms - $terminal.api_duration_ms) else null end),
                ttft_ms: $terminal.ttft_ms,
                turns: $terminal.turns,
                cost_usd: $terminal.cost_usd,
                tokens: { input: $terminal.tokens.input, output: $terminal.tokens.output },
                denials: $terminal.denials,
                tool_calls: $tool_calls
              }
          end
    ' "$events_file" 2>/dev/null) || out=""

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
# (issue #426), agregando agents.<agente>.metrics con las cifras derivadas del
# JSONL neutral (compute_stage_metrics) SIN tocar el campo "duration"
# existente -- CA-2 solo agrega, nunca renombra ni mueve. Ademas de "metrics"
# agrega "runtime" (issue #907): el mismo dato que ya trae metrics.runtime,
# promovido a la raiz de cada agente porque es la pregunta mas frecuente
# sobre una corrida ("con que runtime corrio esto") y no deberia obligar a
# bajar un nivel para leerla -- `null` si ese stage no dejo metricas (no
# corrio, o compute_stage_metrics degrado a "null"). <wr_metrics_json>/
# <rv_metrics_json> son el JSON compacto que devuelve compute_stage_metrics
# (o cadena vacia si ese stage todavia no corrio).
#
# Con jq disponible construye via `jq -n --argjson` (interpolar objetos
# anidados por concatenacion de string es fragil); sin jq -- o si el jq
# falla por cualquier motivo -- degrada al formato plano de siempre (sin
# "metrics" ni "runtime"), igual que antes de este issue (CA-5). Imprime por
# stdout el JSON compacto de "agents" en una sola linea. Retorna siempre 0:
# un fallo de instrumentacion nunca debe tumbar la escritura del historial.
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
            '{writer: {duration: $wr_dur, metrics: $wr_metrics, runtime: $wr_metrics.runtime},
              reviewer: {duration: $rv_dur, metrics: $rv_metrics, runtime: $rv_metrics.runtime}}' 2>/dev/null) || built=""
        if [ -n "$built" ]; then
            echo "$built"
            return 0
        fi
    fi

    printf '{"writer":{"duration":%s},"reviewer":{"duration":%s}}' "$wr_dur_json" "$rv_dur_json"
    return 0
}

# caffeinate_prefix
#
# Espejo interno de caffeinate_prefix de scripts/_pipeline-common.sh (issue
# #800). Imprime por stdout "caffeinate -i" si el binario 'caffeinate' esta
# disponible en PATH (macOS), o cadena vacia en cualquier otro sistema
# (Linux/CI). Antepuesto al lanzamiento de un pipeline interno largo evita
# que el Mac entre en suspension idle mientras corre en un pane de
# tmux/Herdr (`-i`: solo suspension idle; sin `-d` la pantalla si puede
# apagarse; `-s` se descarta porque solo aplica con AC conectado). El
# prefijo no envuelve al pipeline como proceso padre: `caffeinate <utility>`
# hace fork de un helper que sostiene la assertion y exec del utility EN SU
# LUGAR (verificado en macOS 25.4 -- `caffeinate -i /bin/sleep 25 &` deja $!
# apuntando a /bin/sleep, con un hijo 'caffeinate'). De ahi las dos
# propiedades que hacen barato el prefijo: el helper muere con el utility (sin
# huerfano ni assertion colgada) y el PID y el exit code del comando envuelto
# se conservan, asi que $!, wait, kill y el rc de los runners no cambian de
# semantica.
#
# Alcance: se calcula UNA vez por corrida y se aplica en los RUNNERS
# (mefisto-tmux-pipeline.sh, mefisto-herdr-pipeline.sh) sobre el lanzamiento
# del sub-pipeline interno, no en cada invocacion individual del CLI del
# runtime. Un pipeline invocado directo, sin pasar por un runner, queda sin
# envolver.
caffeinate_prefix() {
    if command -v caffeinate >/dev/null 2>&1; then
        printf '%s' "caffeinate -i"
    fi
}
