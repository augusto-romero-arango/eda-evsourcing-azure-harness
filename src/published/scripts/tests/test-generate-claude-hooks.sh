#!/usr/bin/env bash
# Pruebas de generacion y contrato observable del adaptador Claude (Bash 3.2 + jq).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-claude-hooks.sh"
HOOKS="$REPO_ROOT/hooks/hooks.json"
FIXTURES="$HERE/fixtures/claude-hooks"
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
printf '%s\n' '{"distinta":true}' > "$TMP/render/hooks/hooks.json"
out=$(bash "$GENERATOR" --check --out "$TMP/render" 2>&1); [ $? -ne 0 ] && [ "$out" = "hooks/hooks.json: distinta" ] && [ "$(jq -r '.distinta' "$TMP/render/hooks/hooks.json")" = true ] && pass "--check informa diferencia sin escribir" || fail "--check distinta: $out"
jq -e '(. | keys) == ["hooks"] and (.hooks | keys | sort) == ["PostToolUse","SessionStart"] and (.hooks.SessionStart | length) == 1 and (.hooks.SessionStart[0] | keys) == ["hooks"] and ([.hooks.SessionStart[0].hooks[]] | length) == 2 and ([.hooks.PostToolUse[].matcher] == ["ExitPlanMode", "Write|Edit", "Bash"]) and ([.hooks.PostToolUse[] | .hooks[]] | length) == 4 and ([.hooks.SessionStart[0].hooks[], .hooks.PostToolUse[].hooks[]] | all(keys == ["command","type"] and .type == "command" and (.command | type) == "string" and (has("async") | not) and (has("timeout") | not)))' "$HOOKS" >/dev/null && pass "estructura completa, sync implicito y timeout omitido" || fail "topologia Claude invalida"

command_at() { jq -r "$1" "$HOOKS"; }
RELEASE_CMD="$(command_at '.hooks.SessionStart[0].hooks[0].command')"
SESSION_CMD="$(command_at '.hooks.SessionStart[0].hooks[1].command')"
REMINDER_CMD="$(command_at '.hooks.PostToolUse[0].hooks[0].command')"
FILE_CMD="$(command_at '.hooks.PostToolUse[1].hooks[0].command')"
TEST_CMD="$(command_at '.hooks.PostToolUse[2].hooks[0].command')"
TERRAFORM_CMD="$(command_at '.hooks.PostToolUse[2].hooks[1].command')"
run_fixture() { local dir="$1" cmd="$2" fixture="$3"; mkdir -p "$dir"; (cd "$dir" && /bin/sh -c "$cmd" < "$FIXTURES/$fixture"); }

echo "[comandos] destinos canonicos, filtros y tolerancia"
DIR="$TMP/directorio con espacios"
mkdir -p "$DIR/.claude/pipeline" && printf '%s' anterior > "$DIR/.claude/pipeline/.plugin-root.previous" && printf '%s' conservar > "$DIR/.claude/pipeline/otro-estado"
CLAUDE_PLUGIN_ROOT="/plugins/con espacios/1.2.3" run_fixture "$DIR" "$RELEASE_CMD" empty.json && [ "$(< "$DIR/.mefisto/pipeline/.plugin-root")" = "/plugins/con espacios/1.2.3" ] && cmp -s "$DIR/.mefisto/pipeline/.plugin-root" "$DIR/.claude/pipeline/.plugin-root" && [ ! -e "$DIR/.claude/pipeline/.plugin-root.previous" ] && [ "$(< "$DIR/.claude/pipeline/otro-estado")" = conservar ] && pass "release refleja la misma identidad y solo limpia marker legacy" || fail "release no conserva el mirror autorizado"
run_fixture "$DIR" "$SESSION_CMD" session.json && jq -e 'keys == ["cwd","harness_version","session_id","source","timestamp","transcript_path"] and (has("prompt") | not) and (has("token") | not) and .session_id == "s"' "$DIR/.mefisto/pipeline/sessions.jsonl" >/dev/null && [ ! -e "$DIR/.claude/pipeline/sessions.jsonl" ] && pass "sesion allowlisted solo en estado canonico" || fail "sesion o datos sensibles fuera de contrato"
run_fixture "$DIR" "$REMINDER_CMD" empty.json && [ ! -e "$DIR/.mefisto/pipeline/events.log" ] && (cd "$DIR" && /bin/sh -c "$REMINDER_CMD" >&-) && pass "recordatorio no persiste y tolera fallo de salida" || fail "recordatorio persistio o propago un fallo interno"
run_fixture "$DIR" "$FILE_CMD" file-change.json && run_fixture "$DIR" "$TEST_CMD" dotnet-pass.json && BEFORE_NEGATIVE=$(wc -l < "$DIR/.mefisto/pipeline/events.log" | tr -d ' ') && run_fixture "$DIR" "$TEST_CMD" bash-negative.json && run_fixture "$DIR" "$TERRAFORM_CMD" terraform-error.json && run_fixture "$DIR" "$TERRAFORM_CMD" bash-negative.json && AFTER_NEGATIVE=$(wc -l < "$DIR/.mefisto/pipeline/events.log" | tr -d ' ') && [ "$BEFORE_NEGATIVE" -eq 2 ] && [ "$AFTER_NEGATIVE" -eq 3 ] && grep -q '\[archivo\] /tmp/con espacios.txt' "$DIR/.mefisto/pipeline/events.log" && grep -q '\[test\] PASS' "$DIR/.mefisto/pipeline/events.log" && grep -q '\[terraform\] apply: ERROR' "$DIR/.mefisto/pipeline/events.log" && ! grep -q 'SENTINELA' "$DIR/.mefisto/pipeline/events.log" && [ ! -e "$DIR/.claude/pipeline/events.log" ] && pass "handlers aplican filtros y anexan solo resumenes canonicos" || fail "handlers filtraron o persistieron datos indebidos"
unset CLAUDE_PLUGIN_ROOT
DIR_EMPTY="$TMP/sin-plugin"
run_fixture "$DIR_EMPTY" "$RELEASE_CMD" empty.json && [ ! -e "$DIR_EMPTY/.mefisto/pipeline/.plugin-root" ] && pass "release tolera plugin root ausente" || fail "release no tolera plugin root ausente"
DIR_NO_JQ="$TMP/sin-jq"
mkdir -p "$TMP/bin-sin-jq"
for bin in mkdir basename; do source_bin="$(command -v "$bin")" && ln -sf "$source_bin" "$TMP/bin-sin-jq/$bin"; done
mkdir -p "$DIR_NO_JQ"
if env PATH="$TMP/bin-sin-jq" /bin/sh -c 'command -v jq' >/dev/null 2>&1; then
    fail "sandbox sin jq no fue hermetico"
elif (cd "$DIR_NO_JQ" && env PATH="$TMP/bin-sin-jq" /bin/sh -c "$SESSION_CMD" < "$FIXTURES/session.json") && (cd "$DIR_NO_JQ" && env PATH="$TMP/bin-sin-jq" /bin/sh -c "$FILE_CMD" < "$FIXTURES/file-change.json") && (cd "$DIR_NO_JQ" && env PATH="$TMP/bin-sin-jq" /bin/sh -c "$TEST_CMD" < "$FIXTURES/dotnet-pass.json") && (cd "$DIR_NO_JQ" && env PATH="$TMP/bin-sin-jq" /bin/sh -c "$TERRAFORM_CMD" < "$FIXTURES/terraform-error.json") && [ ! -s "$DIR_NO_JQ/.mefisto/pipeline/sessions.jsonl" ] && [ ! -s "$DIR_NO_JQ/.mefisto/pipeline/events.log" ]; then
    pass "los cuatro handlers jq degradan con exit 0 sin anexar datos"
else
    fail "un handler jq no degrada correctamente sin jq"
fi
echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
