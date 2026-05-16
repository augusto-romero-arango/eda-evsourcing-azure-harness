#!/usr/bin/env bash
# mefisto-release.sh -- Versionado y publicacion del plugin Mefisto.
#
# Uso:
#   ./.claude/scripts/mefisto-release.sh patch     # fase prepare (PR de release)
#   ./.claude/scripts/mefisto-release.sh minor     # fase prepare
#   ./.claude/scripts/mefisto-release.sh major     # fase prepare
#   ./.claude/scripts/mefisto-release.sh           # fase publish (tag + GH release)
#
# Dos fases en una invocacion logica:
#   prepare (plugin.json.version == ultimo tag)
#     - crea rama release/vX.Y.Z
#     - mueve [Unreleased] del CHANGELOG.md a [X.Y.Z] - YYYY-MM-DD
#     - actualiza links de comparacion al pie
#     - bumpea .claude-plugin/plugin.json con jq
#     - commitea, pushea, abre PR contra main
#   publish (plugin.json.version > ultimo tag)
#     - exige main + working tree limpio + al dia con origin/main + gh auth
#     - extrae notas de la seccion [X.Y.Z] del CHANGELOG
#     - crea tag anotado, lo pushea
#     - crea GitHub Release con esas notas
#
# Sigue SemVer y Keep a Changelog (formato declarado en el header del CHANGELOG).

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_mefisto-common.sh"
assert_in_mefisto || exit 1

cd "$MEFISTO_REPO_ROOT"

# --- Colores y logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1"; }
log_success() { echo -e "${GREEN}${BOLD}v${NC} $1"; }
log_warn()    { echo -e "${YELLOW}!${NC} $1" >&2; }
log_error()   { echo -e "${RED}${BOLD}x ERROR:${NC} $1" >&2; }
abort()       { log_error "$1"; exit 1; }

# --- Dependencias ---
for cmd in jq git gh python3; do
    command -v "$cmd" >/dev/null 2>&1 || abort "Falta comando requerido: $cmd"
done

PLUGIN_JSON="$MEFISTO_REPO_ROOT/.claude-plugin/plugin.json"
CHANGELOG="$MEFISTO_REPO_ROOT/CHANGELOG.md"
[ -f "$PLUGIN_JSON" ] || abort "No existe $PLUGIN_JSON"
[ -f "$CHANGELOG" ]   || abort "No existe $CHANGELOG"

REPO_SLUG="${MEFISTO_REPO_SLUG:-}"
if [ -z "$REPO_SLUG" ]; then
    REPO_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
fi
[ -n "$REPO_SLUG" ] || abort "No se pudo determinar el repo slug (gh repo view fallo)"

REPO_URL="https://github.com/${REPO_SLUG}"

# --- Helpers ---

# current_plugin_version: imprime la version actual de plugin.json
current_plugin_version() {
    jq -r '.version' "$PLUGIN_JSON"
}

# latest_tag_version: imprime la version (sin prefijo v) del ultimo tag SemVer,
# o cadena vacia si no hay ninguno.
latest_tag_version() {
    git tag -l 'v[0-9]*.[0-9]*.[0-9]*' \
        | sed 's/^v//' \
        | sort -V \
        | tail -n1
}

# bump_version <current> <part>  -> nueva version segun SemVer
bump_version() {
    local current="$1" part="$2"
    [[ "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] \
        || abort "La version actual no es SemVer X.Y.Z: $current"
    local major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
    case "$part" in
        major) echo "$((major+1)).0.0" ;;
        minor) echo "${major}.$((minor+1)).0" ;;
        patch) echo "${major}.${minor}.$((patch+1))" ;;
        *)     abort "Parte SemVer invalida: $part (esperado patch|minor|major)" ;;
    esac
}

# extract_unreleased_section: extrae el contenido del bloque [Unreleased]
# (sin el header). Imprime en stdout.
extract_unreleased_section() {
    python3 - "$CHANGELOG" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    text = f.read()
m = re.search(r'(?ms)^##\s*\[Unreleased\][^\n]*\n(.*?)(?=^##\s*\[|\Z)', text)
if not m:
    sys.exit(0)
sys.stdout.write(m.group(1).rstrip() + "\n" if m.group(1).strip() else "")
PYEOF
}

# extract_version_section <version>: extrae el contenido de [X.Y.Z]
# (sin el header), apto para usar como notas de release.
extract_version_section() {
    local version="$1"
    python3 - "$CHANGELOG" "$version" <<'PYEOF'
import re, sys
path, version = sys.argv[1], sys.argv[2]
with open(path, encoding='utf-8') as f:
    text = f.read()
pattern = r'(?ms)^##\s*\[' + re.escape(version) + r'\][^\n]*\n(.*?)(?=^##\s*\[|^\[Unreleased\]:|\Z)'
m = re.search(pattern, text)
if not m:
    sys.exit(1)
body = m.group(1).strip()
sys.stdout.write(body + "\n")
PYEOF
}

# rewrite_changelog_prepare <new_version> <prev_version> <date>
# Reescribe el CHANGELOG: mueve [Unreleased] a [new] y actualiza/agrega
# links de comparacion al pie.
rewrite_changelog_prepare() {
    local new_version="$1" prev_version="$2" date="$3" tmp
    tmp=$(mktemp)
    REPO_URL="$REPO_URL" \
    NEW_VERSION="$new_version" \
    PREV_VERSION="$prev_version" \
    RELEASE_DATE="$date" \
    python3 - "$CHANGELOG" "$tmp" <<'PYEOF'
import os, re, sys

src, dst = sys.argv[1], sys.argv[2]
new_version = os.environ['NEW_VERSION']
prev_version = os.environ['PREV_VERSION']
date = os.environ['RELEASE_DATE']
repo_url = os.environ['REPO_URL']

with open(src, encoding='utf-8') as f:
    text = f.read()

# 1. Mover bloque [Unreleased] a una seccion versionada y dejar [Unreleased] vacio.
m = re.search(
    r'(?ms)^(##\s*\[Unreleased\][^\n]*\n)(.*?)(?=^##\s*\[|\Z)',
    text,
)
if not m:
    print("ERROR: no se encontro la seccion [Unreleased]", file=sys.stderr)
    sys.exit(1)

unreleased_header = m.group(1)
unreleased_body = m.group(2)
if not unreleased_body.strip():
    print("ERROR: la seccion [Unreleased] esta vacia, nada que liberar", file=sys.stderr)
    sys.exit(1)

new_block = (
    unreleased_header
    + "\n"
    + f"## [{new_version}] - {date}\n"
    + (unreleased_body if unreleased_body.endswith("\n") else unreleased_body + "\n")
)
text = text[:m.start()] + new_block + text[m.end():]

# 2. Actualizar link [Unreleased] al pie. Si no existe, anadirlo al final.
unreleased_link = f"[Unreleased]: {repo_url}/compare/v{new_version}...HEAD"
new_version_link = f"[{new_version}]: {repo_url}/compare/v{prev_version}...v{new_version}"

if re.search(r'(?m)^\[Unreleased\]:[^\n]*$', text):
    text = re.sub(
        r'(?m)^\[Unreleased\]:[^\n]*$',
        unreleased_link,
        text,
        count=1,
    )
else:
    if not text.endswith("\n"):
        text += "\n"
    text += unreleased_link + "\n"

# 3. Insertar el link de la nueva version justo debajo del de [Unreleased].
text = re.sub(
    r'(?m)^(\[Unreleased\]:[^\n]*\n)',
    r'\1' + new_version_link + "\n",
    text,
    count=1,
)

with open(dst, "w", encoding='utf-8') as f:
    f.write(text)
PYEOF
    mv "$tmp" "$CHANGELOG"
}

# bump_plugin_json <new_version>
bump_plugin_json() {
    local new_version="$1" tmp
    tmp=$(mktemp)
    jq --arg v "$new_version" '.version = $v' "$PLUGIN_JSON" > "$tmp"
    mv "$tmp" "$PLUGIN_JSON"
}

# tag_exists_local <tag>
tag_exists_local() {
    git rev-parse -q --verify "refs/tags/$1" >/dev/null 2>&1
}

# tag_exists_remote <tag>
tag_exists_remote() {
    git ls-remote --tags --exit-code origin "$1" >/dev/null 2>&1
}

# release_exists <tag>
release_exists() {
    gh release view "$1" >/dev/null 2>&1
}

# require_clean_tree
require_clean_tree() {
    if [ -n "$(git status --porcelain)" ]; then
        abort "Hay cambios sin commitear. Limpia el working tree antes de continuar."
    fi
}

# require_gh_auth
require_gh_auth() {
    gh auth status >/dev/null 2>&1 || abort "gh no esta autenticado. Ejecuta 'gh auth login' y reintenta."
}

# ============================================================================
# Deteccion de fase
# ============================================================================
CURRENT_VERSION=$(current_plugin_version)
LAST_TAG_VERSION=$(latest_tag_version)

[ -n "$CURRENT_VERSION" ] || abort "No se pudo leer .claude-plugin/plugin.json (.version)"
[ -n "$LAST_TAG_VERSION" ] || abort "El repo no tiene tags vX.Y.Z previos. Crea al menos uno manualmente antes de usar este skill."

log_info "Version en plugin.json: ${CURRENT_VERSION}"
log_info "Ultimo tag SemVer:      v${LAST_TAG_VERSION}"

if [ "$CURRENT_VERSION" = "$LAST_TAG_VERSION" ]; then
    PHASE="prepare"
elif [ "$(printf '%s\n%s\n' "$CURRENT_VERSION" "$LAST_TAG_VERSION" | sort -V | tail -n1)" = "$CURRENT_VERSION" ]; then
    PHASE="publish"
else
    abort "Inconsistencia: plugin.json.version (${CURRENT_VERSION}) es menor que el ultimo tag (v${LAST_TAG_VERSION})."
fi

# ============================================================================
# FASE PREPARE
# ============================================================================
if [ "$PHASE" = "prepare" ]; then
    echo -e "\n${CYAN}${BOLD}=== Fase prepare ===${NC}"

    BUMP_PART="${1:-}"
    if [ -z "$BUMP_PART" ]; then
        cat >&2 <<EOF
Uso: $(basename "$0") {patch|minor|major}

plugin.json.version (${CURRENT_VERSION}) ya coincide con el ultimo tag (v${LAST_TAG_VERSION}).
Necesitas indicar la magnitud del bump para preparar el PR de release.
EOF
        exit 1
    fi

    case "$BUMP_PART" in patch|minor|major) ;; *)
        abort "Argumento invalido: '$BUMP_PART'. Esperado patch|minor|major."
        ;;
    esac

    NEW_VERSION=$(bump_version "$CURRENT_VERSION" "$BUMP_PART")
    NEW_TAG="v${NEW_VERSION}"
    PREV_VERSION="$CURRENT_VERSION"
    RELEASE_BRANCH="release/${NEW_TAG}"
    RELEASE_DATE=$(date -u +%Y-%m-%d)

    log_info "Bump: ${PREV_VERSION} -> ${NEW_VERSION} (${BUMP_PART})"
    log_info "Rama de release: ${RELEASE_BRANCH}"
    log_info "Fecha (UTC): ${RELEASE_DATE}"

    # Precondiciones
    require_clean_tree
    require_gh_auth

    if tag_exists_local "$NEW_TAG" || tag_exists_remote "$NEW_TAG"; then
        abort "Ya existe el tag ${NEW_TAG}. Aborta para no pisar historia."
    fi
    if release_exists "$NEW_TAG"; then
        abort "Ya existe un GitHub Release ${NEW_TAG}. Aborta."
    fi

    UNRELEASED_BODY=$(extract_unreleased_section || true)
    if [ -z "$UNRELEASED_BODY" ] || [ -z "$(echo "$UNRELEASED_BODY" | tr -d '[:space:]')" ]; then
        abort "La seccion [Unreleased] del CHANGELOG esta vacia. Agrega notas antes de hacer release."
    fi

    if git show-ref --verify --quiet "refs/heads/$RELEASE_BRANCH"; then
        abort "Ya existe localmente la rama ${RELEASE_BRANCH}. Borrala o renombra antes de continuar."
    fi

    # Asegurar que main esta al dia antes de ramificar
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    log_info "Rama actual: ${CURRENT_BRANCH}"

    log_info "Actualizando refs desde origin..."
    git fetch origin --tags --quiet || abort "No se pudo hacer fetch desde origin"

    log_info "Creando rama ${RELEASE_BRANCH} desde origin/main..."
    git switch -c "$RELEASE_BRANCH" origin/main >/dev/null 2>&1 \
        || abort "No se pudo crear la rama ${RELEASE_BRANCH} (verifica que origin/main existe)"

    # Reescribir CHANGELOG y bumpear plugin.json
    log_info "Reescribiendo CHANGELOG.md..."
    rewrite_changelog_prepare "$NEW_VERSION" "$PREV_VERSION" "$RELEASE_DATE" \
        || abort "Fallo al reescribir CHANGELOG.md"

    log_info "Bumpeando .claude-plugin/plugin.json a ${NEW_VERSION}..."
    bump_plugin_json "$NEW_VERSION"

    # Verificar que tenemos cambios stage-ables
    git add CHANGELOG.md .claude-plugin/plugin.json
    if git diff --cached --quiet; then
        abort "No se produjeron cambios en CHANGELOG ni plugin.json (algo va mal)"
    fi

    COMMIT_MSG="chore(release): ${NEW_TAG}"
    log_info "Commiteando: ${COMMIT_MSG}"
    git commit -m "$COMMIT_MSG" >/dev/null

    log_info "Pusheando rama ${RELEASE_BRANCH}..."
    git push -u origin "$RELEASE_BRANCH" >/dev/null 2>&1 \
        || abort "No se pudo pushear la rama ${RELEASE_BRANCH}"

    # Extraer notas de la nueva seccion versionada para el body del PR
    RELEASE_NOTES=$(extract_version_section "$NEW_VERSION") \
        || abort "No se pudieron extraer las notas de [${NEW_VERSION}] del CHANGELOG"

    PR_BODY_FILE=$(mktemp)
    cat > "$PR_BODY_FILE" <<EOF
## Resumen

PR de release ${NEW_TAG} (${BUMP_PART}: ${PREV_VERSION} -> ${NEW_VERSION}).

- Mueve \`[Unreleased]\` a \`[${NEW_VERSION}] - ${RELEASE_DATE}\` en \`CHANGELOG.md\`.
- Bumpea \`.claude-plugin/plugin.json\` a ${NEW_VERSION}.
- Actualiza links de comparacion al pie del CHANGELOG.

## Notas del release

${RELEASE_NOTES}

## Siguiente paso

1. \`/mefisto-merge <pr>\` para mergear este PR a \`main\`.
2. \`git pull --ff-only\` en \`main\` para sincronizar local.
3. \`/mefisto-release\` (sin argumentos) para crear el tag ${NEW_TAG} y el GitHub Release.
EOF

    log_info "Creando PR contra main..."
    PR_URL=$(gh pr create \
        --base main \
        --head "$RELEASE_BRANCH" \
        --title "${COMMIT_MSG}" \
        --body-file "$PR_BODY_FILE") \
        || abort "No se pudo crear el PR"
    rm -f "$PR_BODY_FILE"

    log_success "PR de release creado: ${PR_URL}"

    echo ""
    echo -e "${CYAN}${BOLD}=== Resumen prepare ===${NC}"
    echo "  Version:  ${PREV_VERSION} -> ${NEW_VERSION} (${BUMP_PART})"
    echo "  Rama:     ${RELEASE_BRANCH}"
    echo "  PR:       ${PR_URL}"
    echo ""
    echo "Siguiente paso:"
    echo "  /mefisto-merge ${PR_URL##*/}"
    echo "  git switch main && git pull --ff-only"
    echo "  /mefisto-release   # (sin argumentos) para publicar el tag y el release"
    exit 0
fi

# ============================================================================
# FASE PUBLISH
# ============================================================================
echo -e "\n${CYAN}${BOLD}=== Fase publish ===${NC}"

if [ "$#" -gt 0 ]; then
    log_warn "Argumento '${1}' ignorado en fase publish (plugin.json ya esta bumpeado)."
fi

NEW_VERSION="$CURRENT_VERSION"
NEW_TAG="v${NEW_VERSION}"
PREV_VERSION="$LAST_TAG_VERSION"

log_info "Tag a crear: ${NEW_TAG} (publicando ${PREV_VERSION} -> ${NEW_VERSION})"

# Precondiciones
require_gh_auth

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "main" ]; then
    abort "Debes estar en 'main' para publicar el release (rama actual: ${CURRENT_BRANCH})."
fi

require_clean_tree

log_info "Actualizando refs de origin..."
git fetch origin main --tags --quiet || abort "No se pudo hacer fetch de origin"

BEHIND_COUNT=$(git rev-list --count HEAD..origin/main)
AHEAD_COUNT=$(git rev-list --count origin/main..HEAD)
if [ "$BEHIND_COUNT" -gt 0 ]; then
    abort "main local esta ${BEHIND_COUNT} commit(s) detras de origin/main. Ejecuta 'git pull --ff-only' y reintenta."
fi
if [ "$AHEAD_COUNT" -gt 0 ]; then
    abort "main local tiene ${AHEAD_COUNT} commit(s) que no estan en origin/main. Pushea o resetea antes de publicar."
fi

# Verificar coherencia: el plugin.json mergeado debe coincidir con el actual
MAIN_PLUGIN_VERSION=$(git show "origin/main:.claude-plugin/plugin.json" | jq -r '.version')
if [ "$MAIN_PLUGIN_VERSION" != "$NEW_VERSION" ]; then
    abort "plugin.json en origin/main reporta ${MAIN_PLUGIN_VERSION}, no ${NEW_VERSION}. El PR de release aun no esta mergeado."
fi

if tag_exists_local "$NEW_TAG"; then
    abort "Ya existe el tag local ${NEW_TAG}. Aborta."
fi
if tag_exists_remote "$NEW_TAG"; then
    abort "Ya existe el tag remoto ${NEW_TAG}. Aborta."
fi
if release_exists "$NEW_TAG"; then
    abort "Ya existe un GitHub Release ${NEW_TAG}. Aborta."
fi

# Extraer notas del bloque versionado
RELEASE_NOTES=$(extract_version_section "$NEW_VERSION") \
    || abort "No se encontro la seccion [${NEW_VERSION}] en el CHANGELOG. Faltan notas en main?"

NOTES_FILE=$(mktemp)
printf '%s\n' "$RELEASE_NOTES" > "$NOTES_FILE"

# Crear y pushear tag anotado
log_info "Creando tag anotado ${NEW_TAG}..."
git tag -a "$NEW_TAG" -m "Release ${NEW_TAG}" \
    || abort "No se pudo crear el tag ${NEW_TAG}"

log_info "Pusheando tag ${NEW_TAG}..."
if ! git push origin "$NEW_TAG" >/dev/null 2>&1; then
    git tag -d "$NEW_TAG" >/dev/null 2>&1 || true
    abort "No se pudo pushear el tag ${NEW_TAG} (tag local revertido)"
fi

# Crear GitHub Release
log_info "Creando GitHub Release ${NEW_TAG}..."
if ! RELEASE_URL=$(gh release create "$NEW_TAG" \
        --title "${NEW_TAG}" \
        --notes-file "$NOTES_FILE"); then
    rm -f "$NOTES_FILE"
    abort "No se pudo crear el GitHub Release ${NEW_TAG}. El tag ya esta pusheado; eliminalo manualmente si quieres reintentar."
fi
rm -f "$NOTES_FILE"

log_success "GitHub Release publicado: ${RELEASE_URL}"

echo ""
echo -e "${CYAN}${BOLD}=== Resumen publish ===${NC}"
echo "  v${PREV_VERSION} -> v${NEW_VERSION}"
echo "  Tag:     ${NEW_TAG}"
echo "  Release: ${RELEASE_URL}"
