#!/usr/bin/env bash
# Genera el adaptador Claude Code de los hooks interactivos publicados.
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
VALIDATOR="$SCRIPT_DIR/validate-interactive-hooks.sh"
CONTRACT="$REPO_ROOT/src/published/hooks/interactive-hooks.json"
CHECK_MODE=0
OUT_ROOT="$REPO_ROOT"

usage_error() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check) CHECK_MODE=1; shift ;;
        --out)
            [ "$#" -ge 2 ] || usage_error "--out requiere una raiz"
            OUT_ROOT="$2"; shift 2 ;;
        --*) usage_error "opcion desconocida: $1" ;;
        *) usage_error "argumento inesperado: $1" ;;
    esac
done

# La validacion debe ocurrir antes de preparar temporales o inspeccionar la salida.
[ -x "$VALIDATOR" ] || usage_error "no existe o no es ejecutable validate-interactive-hooks.sh"
VALIDATION="$($VALIDATOR "$CONTRACT" 2>&1)"; VALIDATION_RC=$?
if [ "$VALIDATION_RC" -ne 0 ]; then
    [ -z "$VALIDATION" ] || printf '%s\n' "$VALIDATION" >&2
    exit 1
fi
command -v jq >/dev/null 2>&1 || usage_error "jq no esta instalado (MEF-ADR-0049: bash + jq)"

# El descriptor validado es neutral; esta comprobacion evita omitir bindings en
# silencio al materializar sus dos hechos de sesion en los eventos Claude.
EXPECTED='append-dotnet-test-result append-file-change append-session append-session-model append-terraform-result record-active-release remind-field-notes'
ACTUAL="$(jq -r '[.bindings[].id] | sort | join(" ")' "$CONTRACT")"
[ "$ACTUAL" = "$EXPECTED" ] || usage_error "el contrato no contiene el conjunto exacto de siete bindings publicados"

record_active_release='[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && mkdir -p .mefisto/pipeline .claude/pipeline 2>/dev/null && printf "%s" "${CLAUDE_PLUGIN_ROOT}" > .mefisto/pipeline/.plugin-root 2>/dev/null && printf "%s" "${CLAUDE_PLUGIN_ROOT}" > .claude/pipeline/.plugin-root 2>/dev/null && rm -f .claude/pipeline/.plugin-root.previous 2>/dev/null || true'
release_identity='hr="${CLAUDE_PLUGIN_ROOT:-}"; hv=""; hc=""; if [ -n "$hr" ] && [ -f "$hr/mefisto-manifest.json" ]; then identity="$(jq -cer '\''if ((keys | sort) == ["commit","runtime","schemaVersion","version"] and .schemaVersion == 1 and .runtime == "claude" and (.version | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$")) and (.commit | type == "string" and test("^[0-9a-f]{40}$"))) then {version,commit} else empty end'\'' "$hr/mefisto-manifest.json" 2>/dev/null)" && hv="$(printf "%s" "$identity" | jq -r '\''.version'\'' 2>/dev/null)" && hc="$(printf "%s" "$identity" | jq -r '\''.commit'\'' 2>/dev/null)"; fi'
append_session="$release_identity; mkdir -p .mefisto/pipeline 2>/dev/null && jq -c --arg harness_version \"\$hv\" --arg harness_commit \"\$hc\" '{record_type: \"session.started\", session_id, transcript_path, cwd, source, timestamp: (now | strftime(\"%Y-%m-%dT%H:%M:%SZ\")), runtime: \"claude\", model: (.model | if type == \"string\" and length > 0 then . else null end), harness_version: (\$harness_version | if . == \"\" then null else . end), harness_commit: (\$harness_commit | if . == \"\" then null else . end)}' 2>/dev/null >> .mefisto/pipeline/sessions.jsonl || true"
append_session_model="payload=\"\$(jq -c '{session_id: (.session_id | if type == \"string\" and length > 0 then . else null end), transcript_path: (.transcript_path | if type == \"string\" and length > 0 then . else null end)}' 2>/dev/null)\"; sid=\"\$(printf '%s' \"\$payload\" | jq -r '.session_id // empty' 2>/dev/null)\"; transcript=\"\$(printf '%s' \"\$payload\" | jq -r '.transcript_path // empty' 2>/dev/null)\"; if [ -n \"\$sid\" ] && [ -n \"\$transcript\" ] && [ -f \"\$transcript\" ]; then model=\"\$(jq -r -s '[.[] | select(.type == \"assistant\") | .message.model? | select(type == \"string\" and length > 0)] | last // empty' \"\$transcript\" 2>/dev/null)\"; if [ -n \"\$model\" ]; then $release_identity; mkdir -p .mefisto/pipeline 2>/dev/null; previous=\"\$(jq -r --arg session_id \"\$sid\" '[select(.record_type == \"session.model-observed\" and .session_id == \$session_id and (.model | type) == \"string\" and (.model | length) > 0) | .model] | last // empty' .mefisto/pipeline/sessions.jsonl 2>/dev/null)\"; if [ \"\$model\" != \"\$previous\" ]; then jq -cn --arg session_id \"\$sid\" --arg model \"\$model\" --arg harness_version \"\$hv\" --arg harness_commit \"\$hc\" '{record_type: \"session.model-observed\", session_id: \$session_id, timestamp: (now | strftime(\"%Y-%m-%dT%H:%M:%SZ\")), runtime: \"claude\", model: \$model, harness_version: (\$harness_version | if . == \"\" then null else . end), harness_commit: (\$harness_commit | if . == \"\" then null else . end)}' >> .mefisto/pipeline/sessions.jsonl 2>/dev/null || true; fi; fi; fi; true"
remind_field_notes='echo "[recordatorio] Si esta sesion tuvo descubrimientos de dominio, decisiones o alternativas descartadas, considera escribir field notes en docs/bitacora/field-notes/ antes de continuar." || true'
append_file_change='mkdir -p .mefisto/pipeline 2>/dev/null && jq -r '\''"[" + (now | strftime("%H:%M:%S")) + "][archivo] " + (.tool_input.file_path // .tool_input.path // "(desconocido)")'\'' 2>/dev/null >> .mefisto/pipeline/events.log || true'
append_dotnet_test='mkdir -p .mefisto/pipeline 2>/dev/null && jq -r '\''if (.tool_input.command // "") | test("dotnet test") then "[" + (now | strftime("%H:%M:%S")) + "][test] " + (if (.tool_result // "") | test("passed|Passed|Superado|Correctas") then "PASS" else "FAIL" end) else empty end'\'' 2>/dev/null >> .mefisto/pipeline/events.log || true'
append_terraform='mkdir -p .mefisto/pipeline 2>/dev/null && jq -r '\''if (.tool_input.command // "") | test("terraform (plan|apply|init|validate)") then "[" + (now | strftime("%H:%M:%S")) + "][terraform] " + ((.tool_input.command | split(" ") | .[1]) // "?") + ": " + (if (.tool_result.exitCode // 0) == 0 then "OK" else "ERROR" end) else empty end'\'' 2>/dev/null >> .mefisto/pipeline/events.log || true'

STAGE="$(mktemp)" || usage_error "no se pudo crear el temporal"
trap 'rm -f "$STAGE"' EXIT
jq -n \
    --arg record_active_release "$record_active_release" \
    --arg append_session "$append_session" \
    --arg append_session_model "$append_session_model" \
    --arg remind_field_notes "$remind_field_notes" \
    --arg append_file_change "$append_file_change" \
    --arg append_dotnet_test "$append_dotnet_test" \
    --arg append_terraform "$append_terraform" \
    '{hooks: {SessionStart: [{hooks: [{type: "command", command: $record_active_release}, {type: "command", command: $append_session}]}], Stop: [{hooks: [{type: "command", command: $append_session_model}]}], PostToolUse: [{matcher: "ExitPlanMode", hooks: [{type: "command", command: $remind_field_notes}]}, {matcher: "Write|Edit", hooks: [{type: "command", command: $append_file_change}]}, {matcher: "Bash", hooks: [{type: "command", command: $append_dotnet_test}, {type: "command", command: $append_terraform}]}]}}' > "$STAGE" || usage_error "no se pudo renderizar hooks/hooks.json"

# JSON y topologia se validan antes de que una salida existente pueda reemplazarse.
jq -e '
  (. | keys) == ["hooks"] and
  (.hooks | keys | sort) == ["PostToolUse", "SessionStart", "Stop"] and
  (.hooks.SessionStart | type == "array" and length == 1) and
  (.hooks.SessionStart[0] | keys == ["hooks"] and (.hooks | type == "array" and length == 2)) and
  (.hooks.Stop | type == "array" and length == 1) and
  (.hooks.Stop[0] | keys == ["hooks"] and (.hooks | type == "array" and length == 1)) and
  (.hooks.PostToolUse | type == "array" and length == 3) and
  ([.hooks.PostToolUse[] | keys] | all(. == ["hooks", "matcher"])) and
  ([.hooks.PostToolUse[].matcher] == ["ExitPlanMode", "Write|Edit", "Bash"]) and
  ([.hooks.PostToolUse[].hooks | type] | all(. == "array")) and
  ([.hooks.PostToolUse[] | .hooks[]] | length) == 4 and
  ([.hooks.SessionStart[0].hooks[], .hooks.Stop[0].hooks[], .hooks.PostToolUse[].hooks[]] |
    all(keys == ["command", "type"] and .type == "command" and (.command | type) == "string" and
        (has("async") | not) and (has("timeout") | not)))
' "$STAGE" >/dev/null || usage_error "el adaptador Claude renderizado no cumple la estructura de hooks"

DESTINATION="$OUT_ROOT/hooks/hooks.json"
if [ "$CHECK_MODE" -eq 1 ]; then
    if [ ! -f "$DESTINATION" ]; then
        printf 'hooks/hooks.json: faltante\n'
        exit 1
    fi
    if ! cmp -s "$STAGE" "$DESTINATION"; then
        printf 'hooks/hooks.json: distinta\n'
        exit 1
    fi
    exit 0
fi

mkdir -p "$OUT_ROOT/hooks" || usage_error "no se pudo preparar hooks/"
PUBLISH="$(mktemp "$OUT_ROOT/hooks/.hooks.json.XXXXXX")" || usage_error "no se pudo preparar la salida temporal"
cp "$STAGE" "$PUBLISH" && mv -f "$PUBLISH" "$DESTINATION" || { rm -f "$PUBLISH"; usage_error "no se pudo publicar hooks/hooks.json"; }
