#!/usr/bin/env bash
# Observa las carpetas de paquetes usadas por la CLI y por assets v3. No restaura
# ni evalua proyectos; sus resultados no son una autorizacion de lectura.
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../src/published/scripts/lib/resource-paths.sh"

usage() { printf '%s\n' 'Uso: resolve-nuget-resources.sh --worktree-root <absolute-root> [--assets-file <absolute-file> ...]' >&2; }
WORKTREE_INPUT=''
EXPLICIT_ASSETS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --worktree-root) [ "$#" -ge 2 ] || { usage; exit 2; }; WORKTREE_INPUT="$2"; shift 2 ;;
        --assets-file) [ "$#" -ge 2 ] || { usage; exit 2; }; EXPLICIT_ASSETS+=("$2"); shift 2 ;;
        *) usage; exit 2 ;;
    esac
done
[ -n "$WORKTREE_INPUT" ] || { usage; exit 2; }

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
DIAGNOSTICS=() ROOT_LOGICAL=() ROOT_PHYSICAL=() ROOT_EXISTS=() ROOT_SOURCES=() ASSET_ROWS=()
STATUS=resolved CLI_AVAILABLE=true CONFLICT=false
diagnostic() { DIAGNOSTICS+=("$1"); }
conflict() { CONFLICT=true; diagnostic "$1"; }
unavailable() { [ "$CONFLICT" = true ] || STATUS=unavailable; diagnostic "$1"; }
sha256_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1; else shasum -a 256 "$1" | cut -d ' ' -f 1; fi; }

WORKTREE_JSON="$(resource_path_resolve "$WORKTREE_INPUT" existing 2>/dev/null)" || { printf '%s\n' '{"schemaVersion":1,"status":"conflict","coverage":"global-only","worktreeRoot":null,"roots":[],"assets":[],"diagnostics":["WORKTREE_UNRESOLVABLE"]}'; exit 1; }
WORKTREE_LOGICAL="$(jq -r .logicalRoot <<< "$WORKTREE_JSON")"
WORKTREE_PHYSICAL="$(jq -r .physicalRoot <<< "$WORKTREE_JSON")"
HOME_PHYSICAL=''
if [ -n "${HOME:-}" ]; then HOME_JSON="$(resource_path_resolve "$HOME" existing 2>/dev/null || true)"; [ -n "$HOME_JSON" ] && HOME_PHYSICAL="$(jq -r .physicalRoot <<< "$HOME_JSON")"; fi

root_is_broad() {
    [ "$2" = / ] && return 0
    [ -n "$HOME_PHYSICAL" ] && [ "$2" = "$HOME_PHYSICAL" ] && return 0
    resource_path_contains "$2" "$WORKTREE_PHYSICAL" >/dev/null 2>&1
}
add_root() {
    local candidate="$1" source="$2" resolved logical physical exists index
    resolved="$(resource_path_resolve "$candidate" planned 2>/dev/null)" || { conflict INVALID_PACKAGE_FOLDER; return; }
    logical="$(jq -r .logicalRoot <<< "$resolved")"; physical="$(jq -r .physicalRoot <<< "$resolved")"; exists="$(jq -r .exists <<< "$resolved")"
    root_is_broad "$logical" "$physical" && { conflict BROAD_PACKAGE_FOLDER; return; }
    for index in "${!ROOT_PHYSICAL[@]}"; do
        if [ "${ROOT_PHYSICAL[$index]}" = "$physical" ]; then ROOT_SOURCES[$index]="$(jq -c --argjson source "$source" '. + [$source]' <<< "${ROOT_SOURCES[$index]}")"; return; fi
    done
    ROOT_LOGICAL+=("$logical"); ROOT_PHYSICAL+=("$physical"); ROOT_EXISTS+=("$exists"); ROOT_SOURCES+=("[$source]")
}

# La invocacion esta deliberadamente limitada a este argv y al cwd fisico.
CLI_OUTPUT="$(cd "$WORKTREE_PHYSICAL" && dotnet nuget locals global-packages --list --force-english-output 2>"$TMP/cli.stderr")"; CLI_RC=$?
if [ "$CLI_RC" -ne 0 ]; then
    CLI_AVAILABLE=false; unavailable CLI_UNAVAILABLE
else
    CLI_LINES=()
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in 'global-packages: '*|'info : global-packages: '*) CLI_LINES+=("$line") ;; *) [ -n "$line" ] && CLI_LINES+=("__unexpected__") ;; esac
    done <<< "$CLI_OUTPUT"
    if [ "${#CLI_LINES[@]}" -ne 1 ] || [ "${CLI_LINES[0]}" = __unexpected__ ]; then
        CLI_AVAILABLE=false; unavailable CLI_OUTPUT_INVALID
    else
        CLI_PATH="${CLI_LINES[0]#info : }"; CLI_PATH="${CLI_PATH#global-packages: }"
        [ -n "$CLI_PATH" ] || { CLI_AVAILABLE=false; unavailable CLI_OUTPUT_INVALID; }
        [ "$CLI_AVAILABLE" = true ] && add_root "$CLI_PATH" '{"kind":"cli"}'
    fi
fi

ASSET_FILES=()
while IFS= read -r asset; do ASSET_FILES+=("$asset"); done < <(find -P "$WORKTREE_PHYSICAL" \( -name .git -o -name .mefisto -o -name node_modules \) -type d -prune -o -type f -path '*/obj/project.assets.json' -print | sort)
for explicit in "${EXPLICIT_ASSETS[@]}"; do
    normalized="$(resource_path_normalize_input "$explicit" 2>/dev/null || true)"
    [ -n "$normalized" ] || { conflict EXPLICIT_ASSET_INVALID; continue; }
    parent="${normalized%/*}"; basename="${normalized##*/}"; [ -n "$parent" ] || parent=/
    parent_json="$(resource_path_resolve "$parent" existing 2>/dev/null || true)"
    [ -n "$parent_json" ] || { conflict EXPLICIT_ASSET_MISSING; continue; }
    physical_parent="$(jq -r .physicalRoot <<< "$parent_json")"; physical_asset="$physical_parent/$basename"
    resource_path_contains "$WORKTREE_PHYSICAL" "$physical_asset" >/dev/null 2>&1 && [ -f "$physical_asset" ] && [ ! -L "$physical_asset" ] || { conflict EXPLICIT_ASSET_OUTSIDE_OR_MISSING; continue; }
    ASSET_FILES+=("$physical_asset")
done

UNIQUE_ASSETS=()
for asset in "${ASSET_FILES[@]}"; do
    seen=false; for known in "${UNIQUE_ASSETS[@]}"; do [ "$known" = "$asset" ] && seen=true; done; [ "$seen" = false ] && UNIQUE_ASSETS+=("$asset"); done
for asset in "${UNIQUE_ASSETS[@]}"; do
    relative="$(resource_path_relative "$WORKTREE_PHYSICAL" "$asset" | jq -r .)"
    hash="$(sha256_file "$asset")"
    if ! jq -e 'type == "object" and .version == 3 and (.packageFolders | type == "object") and all(.packageFolders | keys[]; type == "string" and length > 0)' "$asset" >/dev/null 2>&1; then conflict ASSET_INVALID; continue; fi
    observed=()
    while IFS= read -r folder; do
        observed+=("$folder")
        add_root "$folder" "$(jq -cn --arg asset "$relative" --arg sha256 "$hash" '{kind:"assets",assetsFile:$asset,sha256:$sha256}')"
    done < <(jq -r '.packageFolders | keys[]' "$asset")
    ASSET_ROWS+=("$(jq -cn --arg path "$relative" --arg sha256 "$hash" --argjson roots "$(printf '%s\n' "${observed[@]}" | jq -R . | jq -sc .)" '{path:$path,sha256:$sha256,roots:$roots}')")
done

[ "$CONFLICT" = true ] && STATUS=conflict
COVERAGE=global-only; [ "${#ASSET_ROWS[@]}" -gt 0 ] && COVERAGE=observed-assets
roots_json='[]'; for index in "${!ROOT_PHYSICAL[@]}"; do roots_json="$(jq -c --arg logical "${ROOT_LOGICAL[$index]}" --arg physical "${ROOT_PHYSICAL[$index]}" --argjson exists "${ROOT_EXISTS[$index]}" --argjson sources "${ROOT_SOURCES[$index]}" '. + [{logicalRoot:$logical,physicalRoot:$physical,exists:$exists,sources:$sources}]' <<< "$roots_json")"; done
assets_json='[]'; for row in "${ASSET_ROWS[@]}"; do assets_json="$(jq -c --argjson row "$row" '. + [$row]' <<< "$assets_json")"; done
diagnostics_json="$(printf '%s\n' "${DIAGNOSTICS[@]}" | jq -R . | jq -sc .)"
jq -cn --arg status "$STATUS" --arg coverage "$COVERAGE" --arg worktreeRoot "$WORKTREE_PHYSICAL" --argjson roots "$roots_json" --argjson assets "$assets_json" --argjson diagnostics "$diagnostics_json" '{schemaVersion:1,status:$status,coverage:$coverage,worktreeRoot:$worktreeRoot,roots:$roots,assets:$assets,diagnostics:$diagnostics}'
[ "$STATUS" = resolved ] && exit 0 || exit 1
