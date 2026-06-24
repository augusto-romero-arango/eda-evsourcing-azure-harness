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
#   commands/                Skills publicados (los modifica /mefisto-tooling)
#   agents/                  Agentes publicados
#   scripts/                 Pipelines publicados
#   hooks/                   Hooks publicados
#   docs/                    ADRs, testing, field-notes, cheatsheets
#   .claude-plugin/          Metadata del plugin (plugin.json, marketplace.json)
#   .claude/commands/        Skills internos del propio Mefisto
#   .claude/agents/          Agentes internos
#   .claude/scripts/         Pipelines internos
#   README.md, CHANGELOG.md, CLAUDE.md, .gitignore   Gobierno del repo
is_path_in_mefisto_scope() {
    local path="$1"
    [ -z "$path" ] && return 1

    case "$path" in
        commands/*|agents/*|scripts/*|hooks/*|docs/*) return 0 ;;
        .claude-plugin/*) return 0 ;;
        .claude/commands/*|.claude/agents/*|.claude/scripts/*) return 0 ;;
        README.md|CHANGELOG.md|CLAUDE.md|.gitignore) return 0 ;;
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
        echo "Mefisto solo permite cambios en: commands/, agents/, scripts/," >&2
        echo "hooks/, docs/, .claude-plugin/, .claude/{commands,agents,scripts}/," >&2
        echo "README.md, CHANGELOG.md, CLAUDE.md, .gitignore" >&2
        return 1
    fi
}

# is_path_changelog_exempt <path>
#
# Retorna 0 si el path es EXENTO de exigir entrada en el CHANGELOG (un cambio que
# toca solo rutas exentas no es "notable" y no obliga a actualizar [Unreleased]),
# 1 si el path es NOTABLE (exige entrada). Usado por changes_require_changelog.
#
# Rutas exentas (cambios de bitacora / gobierno no notable):
#   docs/bitacora/**   Bitacora y field notes (no son cambios de comportamiento)
#   README.md          Documentacion de gobierno
#   CLAUDE.md          Instrucciones de gobierno
#   .gitignore         Configuracion de gobierno
#
# Todo lo demas dentro del scope de Mefisto (commands/, agents/, scripts/, hooks/,
# docs/adr/, docs/ no-bitacora, .claude-plugin/, .claude/{commands,agents,scripts}/,
# CHANGELOG.md) es NOTABLE y exige entrada en [Unreleased].
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
# y por tanto exigen una entrada bajo "## [Unreleased]" en CHANGELOG.md.
#
# Retorna:
#   0  -> al menos una ruta tocada es NOTABLE: se exige entrada en [Unreleased]
#   1  -> TODAS las rutas tocadas son exentas (o no hay cambios): no se exige entrada
#
# Solo clasifica rutas; NO parsea el CHANGELOG (de eso se encarga
# check_unreleased_touched). Reutiliza el patron de recoleccion de rutas de
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

# check_unreleased_touched <worktree_path> <base_commit>
#
# Verifica si los cambios del worktree (base..HEAD + working tree) anadieron
# contenido nuevo bajo el header "## [Unreleased]" de CHANGELOG.md.
#
# No basta con que CHANGELOG.md aparezca en el diff: se compara el cuerpo de la
# seccion [Unreleased] en el commit base contra el del working tree actual y se
# considera "tocada" solo si quedo contenido no vacio que difiere del base
# (es decir, este diff aporto algo a la seccion).
#
# Reutiliza el mismo patron regex que extract_unreleased_section en
# mefisto-release.sh para localizar el bloque [Unreleased].
#
# Retorna:
#   0  -> la seccion [Unreleased] recibio contenido (o no se pudo verificar)
#   1  -> el diff NO anadio nada a [Unreleased]
#
# Desde el issue #70 este check es el componente "tirantes" de un GATE: el
# pipeline interno aborta cuando el cambio es notable (changes_require_changelog
# retorna 0) Y esta funcion retorna 1 (entrada ausente). A falta de python3
# degrada a 0 ("no se pudo verificar") para NO abortar por un falso positivo en
# entornos sin python (degradacion benigna que se mantiene con el gate).
check_unreleased_touched() {
    local wt="$1"
    local base="$2"

    # CHANGELOG.md vive en la raiz del repo de Mefisto.
    local changelog="$wt/CHANGELOG.md"
    [ -f "$changelog" ] || return 1

    # Sin python3 no podemos parsear la seccion con fiabilidad; al ser un check
    # informativo, retornamos 0 para no emitir un recordatorio que seria un
    # falso positivo.
    command -v python3 >/dev/null 2>&1 || return 0

    local base_changelog
    base_changelog=$(git -C "$wt" show "${base}:CHANGELOG.md" 2>/dev/null || true)

    MEFISTO_BASE_CHANGELOG="$base_changelog" python3 - "$changelog" <<'PYEOF'
import os, re, sys

def unreleased_body(text):
    m = re.search(r'(?ms)^##\s*\[Unreleased\][^\n]*\n(.*?)(?=^##\s*\[|\Z)', text)
    return m.group(1).strip() if m else ""

with open(sys.argv[1], encoding='utf-8') as f:
    current = unreleased_body(f.read())
base = unreleased_body(os.environ.get('MEFISTO_BASE_CHANGELOG', ''))

# "Tocada" si hay contenido no vacio que difiere del base (este diff lo aporto).
sys.exit(0 if (current and current != base) else 1)
PYEOF
}
