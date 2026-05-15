#!/usr/bin/env bash
# eda-lint.sh — Valida consistencia del modelo EDA
#
# Chequeos:
#   1. Nombres duplicados en catalog.yaml (eventos, comandos, policies)
#   2. Objetos en flows que no están en el catálogo (huérfanos)
#   3. Topics referenciados en flows que no existen en messaging/topics.yaml
#   4. Value objects con source apuntando a archivos .cs que no existen
#   5. Convenciones de naming (heurísticas básicas)
#
# Requisito: yq >= 4.x  (brew install yq)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CATALOG="${PROJECT_ROOT}/docs/eda/catalog.yaml"
TOPICS="${PROJECT_ROOT}/docs/eda/messaging/topics.yaml"
FLOWS_DIR="${PROJECT_ROOT}/docs/eda/flows"

ERRORS=0
WARNINGS=0

# --- helpers ----------------------------------------------------------------

ok()   { echo "[OK]   $*"; }
warn() { echo "[WARN] $*"; WARNINGS=$((WARNINGS + 1)); }
fail() { echo "[ERR]  $*"; ERRORS=$((ERRORS + 1)); }

check_yq() {
  if ! command -v yq &>/dev/null; then
    echo ""
    echo "ERROR: yq no está instalado. Instálalo con:"
    echo "  brew install yq"
    echo ""
    exit 1
  fi
  local version major
  version=$(yq --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
  major=$(echo "$version" | cut -d. -f1)
  if [[ "$major" -lt 4 ]]; then
    echo "ERROR: se requiere yq >= 4.x (versión actual: $version)"
    exit 1
  fi
}

# Devuelve 0 si $1 está en la lista de palabras $2 (separada por |)
in_list() {
  local needle="$1" haystack="$2"
  [[ -n "$haystack" ]] && echo "|${haystack}" | grep -qF "|${needle}|"
}

# --- chequeo 1: duplicados en catalog.yaml ----------------------------------

check_duplicates() {
  local section
  for section in events commands policies; do
    local names dupes
    names=$(yq ".${section}[].name" "$CATALOG" 2>/dev/null || true)
    if [[ -z "$names" ]]; then continue; fi

    dupes=$(echo "$names" | sort | uniq -d)
    if [[ -n "$dupes" ]]; then
      while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        fail "Nombre duplicado en ${section}: '${name}'"
      done <<< "$dupes"
    fi
  done
}

# --- chequeo 2: objetos en flows que no están en el catálogo ----------------

check_orphan_objects() {
  if [[ ! -d "$FLOWS_DIR" ]]; then return; fi

  # Construir listas de nombres conocidos (separadas por |)
  local known_events known_commands known_policies
  known_events=$(yq ".events[].name" "$CATALOG" 2>/dev/null | paste -sd'|' - || true)
  known_commands=$(yq ".commands[].name" "$CATALOG" 2>/dev/null | paste -sd'|' - || true)
  known_policies=$(yq ".policies[].name" "$CATALOG" 2>/dev/null | paste -sd'|' - || true)

  local flow_file
  while IFS= read -r flow_file; do
    [[ -z "$flow_file" ]] && continue
    local flow_name
    flow_name=$(basename "$flow_file" .yaml)

    local step_count
    step_count=$(yq ".flow.steps | length" "$flow_file" 2>/dev/null || echo 0)
    [[ "$step_count" -eq 0 ]] && continue

    local i
    for ((i=0; i<step_count; i++)); do
      local step_type step_name
      step_type=$(yq ".flow.steps[$i].type" "$flow_file" 2>/dev/null || true)
      step_name=$(yq ".flow.steps[$i].name" "$flow_file" 2>/dev/null || true)
      [[ -z "$step_name" || "$step_name" == "null" ]] && continue

      case "$step_type" in
        event)
          if ! in_list "$step_name" "$known_events"; then
            warn "Evento '${step_name}' en flow '${flow_name}' no está en catalog.yaml"
          fi
          ;;
        command)
          if ! in_list "$step_name" "$known_commands"; then
            warn "Comando '${step_name}' en flow '${flow_name}' no está en catalog.yaml"
          fi
          ;;
        policy)
          if ! in_list "$step_name" "$known_policies"; then
            warn "Policy '${step_name}' en flow '${flow_name}' no está en catalog.yaml"
          fi
          ;;
      esac
    done
  done < <(find "$FLOWS_DIR" -name "*.yaml" 2>/dev/null)
}

# --- chequeo 3: topics en flows que no están en messaging/topics.yaml -------

check_orphan_topics() {
  if [[ ! -d "$FLOWS_DIR" ]]; then return; fi
  if [[ ! -f "$TOPICS" ]]; then
    warn "No existe messaging/topics.yaml"
    return
  fi

  local known_topics
  known_topics=$(yq ".service_bus.topics[].name" "$TOPICS" 2>/dev/null | paste -sd'|' - || true)

  local flow_file
  while IFS= read -r flow_file; do
    [[ -z "$flow_file" ]] && continue
    local flow_name
    flow_name=$(basename "$flow_file" .yaml)

    local topic
    while IFS= read -r topic; do
      [[ -z "$topic" || "$topic" == "null" ]] && continue
      if ! in_list "$topic" "$known_topics"; then
        warn "Topic '${topic}' en flow '${flow_name}' no existe en messaging/topics.yaml"
      fi
    done < <(yq ".flow.steps[].published_to // empty" "$flow_file" 2>/dev/null || true)
  done < <(find "$FLOWS_DIR" -name "*.yaml" 2>/dev/null)
}

# --- chequeo 4: value objects con source inexistente ------------------------

check_value_object_sources() {
  local count
  count=$(yq ".value_objects | length" "$CATALOG" 2>/dev/null || echo 0)
  [[ "$count" -eq 0 ]] && return

  local i
  for ((i=0; i<count; i++)); do
    local name source
    name=$(yq ".value_objects[$i].name" "$CATALOG" 2>/dev/null || true)
    source=$(yq ".value_objects[$i].source" "$CATALOG" 2>/dev/null || true)
    [[ -z "$source" || "$source" == "null" ]] && continue
    if [[ ! -f "${PROJECT_ROOT}/${source}" ]]; then
      fail "Value object '${name}': source '${source}' no existe"
    fi
  done
}

# --- chequeo 5: convenciones de naming (heurísticas) ------------------------

check_naming_conventions() {
  local event_count
  event_count=$(yq ".events | length" "$CATALOG" 2>/dev/null || echo 0)

  local i
  for ((i=0; i<event_count; i++)); do
    local name
    name=$(yq ".events[$i].name" "$CATALOG" 2>/dev/null || true)
    [[ -z "$name" || "$name" == "null" ]] && continue
    # Heurística: eventos en infinitivo terminan en -Ar, -Er, -Ir (mayúscula por PascalCase)
    if echo "$name" | grep -qE '(Ar|Er|Ir)$'; then
      warn "Evento '${name}': parece infinitivo — los eventos deben ser en tiempo pasado"
    fi
  done
}

# --- main -------------------------------------------------------------------

main() {
  echo ""
  echo "EDA Lint - Validando consistencia del modelo"
  echo "============================================="

  check_yq

  if [[ ! -f "$CATALOG" ]]; then
    fail "No existe docs/eda/catalog.yaml"
    echo ""
    echo "Resultado: $ERRORS error(es), $WARNINGS advertencia(s)"
    exit 1
  fi

  local n_vo n_ev n_cmd n_pol
  n_vo=$(yq ".value_objects | length" "$CATALOG" 2>/dev/null || echo 0)
  n_ev=$(yq ".events | length" "$CATALOG" 2>/dev/null || echo 0)
  n_cmd=$(yq ".commands | length" "$CATALOG" 2>/dev/null || echo 0)
  n_pol=$(yq ".policies | length" "$CATALOG" 2>/dev/null || echo 0)
  ok "Catálogo: ${n_vo} value objects, ${n_ev} eventos, ${n_cmd} comandos, ${n_pol} policies"

  if [[ -f "$TOPICS" ]]; then
    local n_topics
    n_topics=$(yq ".service_bus.topics | length" "$TOPICS" 2>/dev/null || echo 0)
    ok "Topics: ${n_topics} topic(s) en messaging/topics.yaml"
  else
    warn "No existe messaging/topics.yaml"
  fi

  local n_flows=0
  if [[ -d "$FLOWS_DIR" ]]; then
    n_flows=$(find "$FLOWS_DIR" -name "*.yaml" 2>/dev/null | wc -l | tr -d ' ')
  fi
  ok "Flows: ${n_flows} flow(s) en docs/eda/flows/"

  echo ""
  echo "Chequeos:"

  check_duplicates
  check_orphan_objects
  check_orphan_topics
  check_value_object_sources
  check_naming_conventions

  echo ""
  if [[ $ERRORS -gt 0 ]]; then
    echo "Resultado: $ERRORS error(es), $WARNINGS advertencia(s) — FALLO"
    exit 1
  elif [[ $WARNINGS -gt 0 ]]; then
    echo "Resultado: 0 errores, $WARNINGS advertencia(s) — OK con advertencias"
    exit 0
  else
    echo "Resultado: sin problemas"
    exit 0
  fi
}

main "$@"
