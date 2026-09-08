#!/usr/bin/env bash
# Compara exclusivamente los manifiestos generados de las instalaciones Mefisto.
# Uso: diagnose-installation-identity.sh [--claude-root <ruta>] [--opencode-root <ruta>]
set -uo pipefail
export LC_ALL=C

SEMVER_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
COMMIT_PATTERN='^[0-9a-f]{40}$'

usage_error() { printf 'ERROR: uso: diagnose-installation-identity.sh [--claude-root <ruta>] [--opencode-root <ruta>]\n' >&2; exit 64; }

opencode_data_root() {
    if [ -n "${XDG_DATA_HOME:-}" ]; then printf '%s/mefisto\n' "$XDG_DATA_HOME"
    elif [ "$(uname -s)" = Darwin ]; then printf '%s/Library/Application Support/mefisto\n' "$HOME"
    else printf '%s/.local/share/mefisto\n' "$HOME"; fi
}

# Cada root es una interfaz declarada por su adaptador. Solo se consulta su
# mefisto-manifest.json; no se inspecciona configuracion ni almacenamiento del runtime.
read_identity() {
    local runtime="$1" root="$2" manifest
    if [ -z "$root" ] || [ ! -d "$root" ]; then
        jq -cn --arg runtime "$runtime" '{state:"unavailable", runtime:$runtime}'
        return
    fi
    manifest="$root/mefisto-manifest.json"
    if [ ! -e "$manifest" ] && [ ! -L "$manifest" ]; then
        jq -cn --arg runtime "$runtime" '{state:"metadata_missing", runtime:$runtime}'
        return
    fi
    if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
        jq -cn --arg runtime "$runtime" '{state:"metadata_invalid", runtime:$runtime}'
        return
    fi
    if jq -e --arg runtime "$runtime" --arg semver "$SEMVER_PATTERN" --arg commit "$COMMIT_PATTERN" '
        .schemaVersion == 1 and .runtime == $runtime and
        (.version | type == "string" and test($semver)) and
        (.commit | type == "string" and test($commit))
    ' "$manifest" >/dev/null 2>&1; then
        jq -c '{state:"available", runtime, version, commit}' "$manifest"
    else
        jq -cn --arg runtime "$runtime" '{state:"metadata_invalid", runtime:$runtime}'
    fi
}

CLAUDE_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
OPENCODE_ROOT="$(opencode_data_root)/active"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --claude-root) [ "$#" -ge 2 ] || usage_error; CLAUDE_ROOT="$2"; shift 2 ;;
        --opencode-root) [ "$#" -ge 2 ] || usage_error; OPENCODE_ROOT="$2"; shift 2 ;;
        --help) printf 'uso: diagnose-installation-identity.sh [--claude-root <ruta>] [--opencode-root <ruta>]\n'; exit 0 ;;
        *) usage_error ;;
    esac
done

command -v jq >/dev/null 2>&1 || { printf 'ERROR: jq es requerido para leer los manifiestos de identidad\n' >&2; exit 69; }
CLAUDE="$(read_identity claude "$CLAUDE_ROOT")"
OPENCODE="$(read_identity opencode "$OPENCODE_ROOT")"

jq -cn --argjson claude "$CLAUDE" --argjson opencode "$OPENCODE" '
  def available($identity): $identity.state == "available";
  def has_state($state): $claude.state == $state or $opencode.state == $state;
  if available($claude) and available($opencode) then
    if $claude.version == $opencode.version and $claude.commit == $opencode.commit then
      {schemaVersion:1, status:"aligned", claude:$claude, opencode:$opencode}
    else
      {schemaVersion:1, status:"drift", claude:$claude, opencode:$opencode,
       actions:{claude:"actualizar el plugin Claude", opencode:"activar la release OpenCode con la misma version y commit"},
       message:("DEGRADACION VISIBLE: Claude version=" + $claude.version + " commit=" + $claude.commit +
                "; OpenCode version=" + $opencode.version + " commit=" + $opencode.commit +
                ". Accion: actualice el plugin Claude y active la release OpenCode de la misma version y commit; no se selecciono ninguna instalacion.")}
    end
  elif has_state("metadata_invalid") then
    {schemaVersion:1, status:"metadata_invalid", claude:$claude, opencode:$opencode,
     message:"DEGRADACION VISIBLE: la metadata generada indicada es ilegible o invalida; corrija esa instalacion antes de compararlas."}
  elif has_state("metadata_missing") then
    {schemaVersion:1, status:"metadata_missing", claude:$claude, opencode:$opencode,
     message:"DEGRADACION VISIBLE: falta la metadata generada indicada; reinstale esa distribucion antes de compararlas."}
  elif available($claude) then
    {schemaVersion:1, status:"claude_only", claude:$claude, opencode:$opencode,
     message:"DEGRADACION VISIBLE: solo esta disponible Claude; instale y active una release OpenCode para comparar identidades."}
  elif available($opencode) then
    {schemaVersion:1, status:"opencode_only", claude:$claude, opencode:$opencode,
     message:"DEGRADACION VISIBLE: solo esta disponible OpenCode; actualice o active el plugin Claude para comparar identidades."}
  else
    {schemaVersion:1, status:"none_available", claude:$claude, opencode:$opencode,
     message:"DEGRADACION VISIBLE: no hay instalaciones Claude ni OpenCode disponibles para inspeccionar."}
  end
'
