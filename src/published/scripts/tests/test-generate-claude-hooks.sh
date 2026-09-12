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
jq -e '(. | keys) == ["hooks"] and (.hooks | keys | sort) == ["PostToolUse","SessionStart","Stop"] and (.hooks.SessionStart | length) == 1 and (.hooks.SessionStart[0] | keys) == ["hooks"] and ([.hooks.SessionStart[0].hooks[]] | length) == 2 and (.hooks.Stop | length) == 1 and ([.hooks.Stop[0].hooks[]] | length) == 1 and ([.hooks.PostToolUse[].matcher] == ["ExitPlanMode", "Write|Edit", "Bash"]) and ([.hooks.PostToolUse[] | .hooks[]] | length) == 4 and ([.hooks.SessionStart[0].hooks[], .hooks.Stop[0].hooks[], .hooks.PostToolUse[].hooks[]] | all(keys == ["command","type"] and .type == "command" and (.command | type) == "string" and (has("async") | not) and (has("timeout") | not)))' "$HOOKS" >/dev/null && pass "estructura completa, sync implicito y timeout omitido" || fail "topologia Claude invalida"

command_at() { jq -r "$1" "$HOOKS"; }
RELEASE_CMD="$(command_at '.hooks.SessionStart[0].hooks[0].command')"
SESSION_CMD="$(command_at '.hooks.SessionStart[0].hooks[1].command')"
MODEL_CMD="$(command_at '.hooks.Stop[0].hooks[0].command')"
REMINDER_CMD="$(command_at '.hooks.PostToolUse[0].hooks[0].command')"
FILE_CMD="$(command_at '.hooks.PostToolUse[1].hooks[0].command')"
TEST_CMD="$(command_at '.hooks.PostToolUse[2].hooks[0].command')"
TERRAFORM_CMD="$(command_at '.hooks.PostToolUse[2].hooks[1].command')"
run_fixture() { local dir="$1" cmd="$2" fixture="$3"; mkdir -p "$dir"; (cd "$dir" && /bin/sh -c "$cmd" < "$FIXTURES/$fixture"); }

echo "[comandos] destinos canonicos, filtros y tolerancia"
DIR="$TMP/directorio con espacios"
SUBDIR="$DIR/infra/environments/dev"
PLUGIN_ROOT="$TMP/distribucion con espacios"
mkdir -p "$PLUGIN_ROOT"
printf '%s\n' '{"schemaVersion":1,"runtime":"claude","version":"1.2.3","commit":"0123456789abcdef0123456789abcdef01234567"}' > "$PLUGIN_ROOT/mefisto-manifest.json"
mkdir -p "$DIR/.claude/pipeline" "$SUBDIR" && git -C "$DIR" init -q && printf '%s' anterior > "$DIR/.claude/pipeline/.plugin-root.previous" && printf '%s' conservar > "$DIR/.claude/pipeline/otro-estado"
CLAUDE_PLUGIN_ROOT="/plugins/con espacios/1.2.3" run_fixture "$SUBDIR" "$RELEASE_CMD" empty.json && [ "$(< "$DIR/.mefisto/pipeline/.plugin-root")" = "/plugins/con espacios/1.2.3" ] && cmp -s "$DIR/.mefisto/pipeline/.plugin-root" "$DIR/.claude/pipeline/.plugin-root" && [ ! -e "$DIR/.claude/pipeline/.plugin-root.previous" ] && [ "$(< "$DIR/.claude/pipeline/otro-estado")" = conservar ] && pass "release ancla ambos markers a la raiz Git" || fail "release no conserva el mirror autorizado en la raiz"
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" run_fixture "$SUBDIR" "$SESSION_CMD" startup-model.json && jq -e 'keys == ["cwd","harness_commit","harness_version","model","record_type","runtime","session_id","source","timestamp","transcript_path"] and .record_type == "session.started" and .runtime == "claude" and .model == "claude-sonnet-4-6" and .harness_version == "1.2.3" and .harness_commit == "0123456789abcdef0123456789abcdef01234567" and (has("prompt") | not) and (has("token") | not)' "$DIR/.mefisto/pipeline/sessions.jsonl" >/dev/null && [ ! -e "$DIR/.claude/pipeline/sessions.jsonl" ] && pass "sesion conserva modelo inicial e identidad allowlisted" || fail "sesion o datos sensibles fuera de contrato: $(jq -c . "$DIR/.mefisto/pipeline/sessions.jsonl" 2>/dev/null)"
run_fixture "$SUBDIR" "$SESSION_CMD" session.json && jq -s -e '.[1].record_type == "session.started" and .[1].source == "clear" and .[1].model == null and .[1].harness_version == null and .[1].harness_commit == null' "$DIR/.mefisto/pipeline/sessions.jsonl" >/dev/null && pass "clear sin modelo y manifiesto ausente degradan a null" || fail "degradacion de inicio invalida"
printf '%s\n' '{"malformado":true}' > "$PLUGIN_ROOT/mefisto-manifest.json"
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" run_fixture "$SUBDIR" "$SESSION_CMD" session.json && jq -s -e '.[2].harness_version == null and .[2].harness_commit == null' "$DIR/.mefisto/pipeline/sessions.jsonl" >/dev/null && pass "manifiesto malformado degrada a null" || fail "manifiesto malformado invento identidad"
printf '%s\n' '{"schemaVersion":1,"runtime":"claude","version":"1.2.3","commit":"0123456789abcdef0123456789abcdef01234567"}' > "$PLUGIN_ROOT/mefisto-manifest.json"
cp "$FIXTURES/transcript-model-a.jsonl" "$DIR/transcript con espacios.jsonl"
payload="$(jq -cn --arg session_id modelo --arg transcript_path "$DIR/transcript con espacios.jsonl" '{session_id:$session_id,transcript_path:$transcript_path,prompt:"SENTINELA_PROMPT",token:"SENTINELA_TOKEN"}')"
(cd "$SUBDIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" /bin/sh -c "$MODEL_CMD" <<< "$payload") && (cd "$SUBDIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" /bin/sh -c "$MODEL_CMD" <<< "$payload") && cp "$FIXTURES/transcript-model-b.jsonl" "$DIR/transcript con espacios.jsonl" && (cd "$SUBDIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" /bin/sh -c "$MODEL_CMD" <<< "$payload") && jq -s -e '[.[] | select(.session_id == "modelo")] | length == 2 and [.[].model] == ["claude-sonnet-4-6","claude-opus-4-6"] and all(.[]; keys == ["harness_commit","harness_version","model","record_type","runtime","session_id","timestamp"] and .record_type == "session.model-observed" and .runtime == "claude")' "$DIR/.mefisto/pipeline/sessions.jsonl" >/dev/null && ! grep -q 'SENTINELA' "$DIR/.mefisto/pipeline/sessions.jsonl" && pass "Stop observa transcript, deduplica consecutivos y conserva cambios" || fail "observacion de modelo invalida"
payload_empty="$(jq -cn --arg session_id vacio --arg transcript_path "$DIR/transcript vacio.jsonl" '{session_id:$session_id,transcript_path:$transcript_path}')"
cp "$FIXTURES/transcript-no-assistant.jsonl" "$DIR/transcript vacio.jsonl"
before=$(wc -l < "$DIR/.mefisto/pipeline/sessions.jsonl" | tr -d ' ')
payload_missing="$(jq -cn --arg session_id ausente --arg transcript_path "$DIR/no existe.jsonl" '{session_id:$session_id,transcript_path:$transcript_path}')"
cp "$FIXTURES/transcript-malformed.jsonl" "$DIR/transcript ilegible.jsonl"
payload_malformed="$(jq -cn --arg session_id ilegible --arg transcript_path "$DIR/transcript ilegible.jsonl" '{session_id:$session_id,transcript_path:$transcript_path}')"
if (cd "$SUBDIR" && /bin/sh -c "$MODEL_CMD" <<< "$payload_empty") \
    && (cd "$SUBDIR" && /bin/sh -c "$MODEL_CMD" <<< "$payload_missing") \
    && (cd "$SUBDIR" && /bin/sh -c "$MODEL_CMD" <<< "$payload_malformed"); then
    after=$(wc -l < "$DIR/.mefisto/pipeline/sessions.jsonl" | tr -d ' ')
    [ "$before" = "$after" ] && pass "transcript sin respuesta, ausente o ilegible no aborta ni escribe" || fail "degradacion Stop escribio una observacion"
else
    fail "degradacion Stop propago un fallo"
fi
run_fixture "$SUBDIR" "$REMINDER_CMD" empty.json && [ ! -e "$DIR/.mefisto/pipeline/events.log" ] && (cd "$SUBDIR" && /bin/sh -c "$REMINDER_CMD" >&-) && pass "recordatorio no persiste y tolera fallo de salida" || fail "recordatorio persistio o propago un fallo interno"
run_fixture "$SUBDIR" "$FILE_CMD" file-change.json && run_fixture "$SUBDIR" "$TEST_CMD" dotnet-pass.json && BEFORE_NEGATIVE=$(wc -l < "$DIR/.mefisto/pipeline/events.log" | tr -d ' ') && run_fixture "$SUBDIR" "$TEST_CMD" bash-negative.json && run_fixture "$SUBDIR" "$TERRAFORM_CMD" terraform-error.json && run_fixture "$SUBDIR" "$TERRAFORM_CMD" bash-negative.json && AFTER_NEGATIVE=$(wc -l < "$DIR/.mefisto/pipeline/events.log" | tr -d ' ') && [ "$BEFORE_NEGATIVE" -eq 2 ] && [ "$AFTER_NEGATIVE" -eq 3 ] && grep -q '\[archivo\] /tmp/con espacios.txt' "$DIR/.mefisto/pipeline/events.log" && grep -q '\[test\] PASS' "$DIR/.mefisto/pipeline/events.log" && grep -q '\[terraform\] apply: ERROR' "$DIR/.mefisto/pipeline/events.log" && ! grep -q 'SENTINELA' "$DIR/.mefisto/pipeline/events.log" && [ ! -e "$DIR/.claude/pipeline/events.log" ] && [ ! -e "$SUBDIR/.mefisto/pipeline" ] && pass "handlers desde subdirectorio anexan solo resumenes en la raiz Git" || fail "handlers filtraron o persistieron datos fuera de la raiz"
unset CLAUDE_PLUGIN_ROOT
DIR_EMPTY="$TMP/sin-plugin"
mkdir -p "$DIR_EMPTY"
cp "$FIXTURES/transcript-model-a.jsonl" "$DIR_EMPTY/transcript.jsonl"
payload_no_repo="$(jq -cn --arg session_id sin-repo --arg transcript_path "$DIR_EMPTY/transcript.jsonl" '{session_id:$session_id,transcript_path:$transcript_path}')"
run_fixture "$DIR_EMPTY" "$RELEASE_CMD" empty.json && run_fixture "$DIR_EMPTY" "$SESSION_CMD" session.json && (cd "$DIR_EMPTY" && /bin/sh -c "$MODEL_CMD" <<< "$payload_no_repo") && run_fixture "$DIR_EMPTY" "$FILE_CMD" file-change.json && run_fixture "$DIR_EMPTY" "$TEST_CMD" dotnet-pass.json && run_fixture "$DIR_EMPTY" "$TERRAFORM_CMD" terraform-error.json && [ ! -e "$DIR_EMPTY/.mefisto" ] && [ ! -e "$DIR_EMPTY/.claude" ] && pass "handlers sin raiz Git terminan sin crear estado relativo" || fail "un handler sin raiz Git creo estado relativo"
DIR_NO_JQ="$TMP/sin-jq"
mkdir -p "$TMP/bin-sin-jq"
for bin in mkdir basename; do source_bin="$(command -v "$bin")" && ln -sf "$source_bin" "$TMP/bin-sin-jq/$bin"; done
mkdir -p "$DIR_NO_JQ" && git -C "$DIR_NO_JQ" init -q
if env PATH="$TMP/bin-sin-jq" /bin/sh -c 'command -v jq' >/dev/null 2>&1; then
    fail "sandbox sin jq no fue hermetico"
elif (cd "$DIR_NO_JQ" && env PATH="$TMP/bin-sin-jq" /bin/sh -c "$SESSION_CMD" < "$FIXTURES/session.json") && (cd "$DIR_NO_JQ" && env PATH="$TMP/bin-sin-jq" /bin/sh -c "$MODEL_CMD" < "$FIXTURES/session.json") && (cd "$DIR_NO_JQ" && env PATH="$TMP/bin-sin-jq" /bin/sh -c "$FILE_CMD" < "$FIXTURES/file-change.json") && (cd "$DIR_NO_JQ" && env PATH="$TMP/bin-sin-jq" /bin/sh -c "$TEST_CMD" < "$FIXTURES/dotnet-pass.json") && (cd "$DIR_NO_JQ" && env PATH="$TMP/bin-sin-jq" /bin/sh -c "$TERRAFORM_CMD" < "$FIXTURES/terraform-error.json") && [ ! -s "$DIR_NO_JQ/.mefisto/pipeline/sessions.jsonl" ] && [ ! -s "$DIR_NO_JQ/.mefisto/pipeline/events.log" ]; then
    pass "los cinco handlers jq degradan con exit 0 sin anexar datos"
else
    fail "un handler jq no degrada correctamente sin jq"
fi
echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
