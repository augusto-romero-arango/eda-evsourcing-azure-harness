#!/usr/bin/env bash
# Pruebas de generacion y contrato observable del adaptador Claude (Bash 3.2 + jq).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-claude-hooks.sh"
HOOKS="$REPO_ROOT/hooks/hooks.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq no instalado"; exit 0; }
echo "[generacion] salida determinista y topologia Claude"
bash -n "$GENERATOR" && pass "generador Bash valido" || fail "generador Bash invalido"
bash "$GENERATOR" --check >/dev/null && pass "--check acepta la salida vigente" || fail "--check rechazo la salida vigente"
out=$(bash "$GENERATOR" --check --out "$TMP/vacio" 2>&1); [ $? -ne 0 ] && [ "$out" = "hooks/hooks.json: faltante" ] && pass "--check informa salida faltante sin escribir" || fail "--check faltante: $out"
mkdir -p "$TMP/render" && bash "$GENERATOR" --out "$TMP/render" && cmp -s "$HOOKS" "$TMP/render/hooks/hooks.json" && pass "render alternativo coincide byte a byte" || fail "render alternativo divergente"
jq -e '(.hooks.SessionStart | length) == 1 and ([.hooks.SessionStart[].hooks[]] | length) == 2 and ([.hooks.PostToolUse[].matcher] == ["ExitPlanMode", "Write|Edit", "Bash"]) and ([.hooks.PostToolUse[] | .hooks[]] | length) == 4 and ([.. | objects | select(.type? == "command")] | all((has("async") | not) and (has("timeout") | not)))' "$HOOKS" >/dev/null && pass "topologia, sync implicito y timeout omitido" || fail "topologia Claude invalida"

command_at() { jq -r "$1" "$HOOKS"; }
RELEASE_CMD="$(command_at '.hooks.SessionStart[0].hooks[0].command')"
SESSION_CMD="$(command_at '.hooks.SessionStart[0].hooks[1].command')"
REMINDER_CMD="$(command_at '.hooks.PostToolUse[0].hooks[0].command')"
FILE_CMD="$(command_at '.hooks.PostToolUse[1].hooks[0].command')"
TEST_CMD="$(command_at '.hooks.PostToolUse[2].hooks[0].command')"
TERRAFORM_CMD="$(command_at '.hooks.PostToolUse[2].hooks[1].command')"
run() { local dir="$1" cmd="$2" payload="$3"; mkdir -p "$dir"; (cd "$dir" && printf '%s' "$payload" | /bin/sh -c "$cmd"); }

echo "[comandos] destinos canonicos, filtros y tolerancia"
DIR="$TMP/directorio con espacios"
CLAUDE_PLUGIN_ROOT="/plugins/con espacios/1.2.3" run "$DIR" "$RELEASE_CMD" '{}' && [ "$(< "$DIR/.mefisto/pipeline/.plugin-root")" = "/plugins/con espacios/1.2.3" ] && cmp -s "$DIR/.mefisto/pipeline/.plugin-root" "$DIR/.claude/pipeline/.plugin-root" && [ ! -e "$DIR/.claude/pipeline/.plugin-root.previous" ] && pass "release refleja la misma identidad y solo limpia marker legacy" || fail "release no conserva el mirror autorizado"
run "$DIR" "$SESSION_CMD" '{"session_id":"s","transcript_path":"/tmp/x","cwd":"/tmp","source":"start","prompt":"SENTINELA"}' && jq -e 'keys == ["cwd","harness_version","session_id","source","timestamp","transcript_path"] and has("prompt") | not' "$DIR/.mefisto/pipeline/sessions.jsonl" >/dev/null && [ ! -e "$DIR/.claude/pipeline/sessions.jsonl" ] && pass "sesion allowlisted solo en estado canonico" || fail "sesion o datos sensibles fuera de contrato"
run "$DIR" "$REMINDER_CMD" '{}' && [ ! -e "$DIR/.mefisto/pipeline/events.log" ] && pass "recordatorio no persiste datos" || fail "recordatorio persistio datos"
run "$DIR" "$FILE_CMD" '{"tool_input":{"file_path":"/tmp/con espacios.txt","command":"SENTINELA"}}' && run "$DIR" "$TEST_CMD" '{"tool_input":{"command":"dotnet test"},"tool_result":"Passed"}' && run "$DIR" "$TEST_CMD" '{"tool_input":{"command":"echo SENTINELA"},"tool_result":"Passed"}' && run "$DIR" "$TERRAFORM_CMD" '{"tool_input":{"command":"terraform plan -var token=SENTINELA"},"tool_result":{"exitCode":0}}' && ! grep -q 'SENTINELA' "$DIR/.mefisto/pipeline/events.log" && [ ! -e "$DIR/.claude/pipeline/events.log" ] && pass "handlers filtran y anexan resumenes solo canonicos" || fail "handlers filtraron o persistieron datos indebidos"
unset CLAUDE_PLUGIN_ROOT
DIR_EMPTY="$TMP/sin-plugin"
run "$DIR_EMPTY" "$RELEASE_CMD" '{}' && [ ! -e "$DIR_EMPTY/.mefisto/pipeline/.plugin-root" ] && pass "release tolera plugin root ausente" || fail "release no tolera plugin root ausente"
DIR_NO_JQ="$TMP/sin-jq"
mkdir -p "$TMP/bin-sin-jq"
for bin in mkdir basename; do source_bin="$(command -v "$bin")" && ln -sf "$source_bin" "$TMP/bin-sin-jq/$bin"; done
mkdir -p "$DIR_NO_JQ"
if env PATH="$TMP/bin-sin-jq" /bin/sh -c 'command -v jq' >/dev/null 2>&1; then
    fail "sandbox sin jq no fue hermetico"
elif (cd "$DIR_NO_JQ" && printf '%s' '{}' | env PATH="$TMP/bin-sin-jq" /bin/sh -c "$SESSION_CMD") && [ ! -s "$DIR_NO_JQ/.mefisto/pipeline/sessions.jsonl" ]; then
    pass "append-session degrada sin jq sin dejar una entrada JSONL corrupta"
else
    fail "append-session no degrada correctamente sin jq"
fi
echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
