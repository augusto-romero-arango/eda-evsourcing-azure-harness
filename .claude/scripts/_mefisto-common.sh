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
