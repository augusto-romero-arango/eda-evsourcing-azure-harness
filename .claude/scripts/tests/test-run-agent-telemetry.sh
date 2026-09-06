#!/usr/bin/env bash
# test-run-agent-telemetry.sh -- Tests de la telemetria de herramientas que
# mefisto-run-agent.sh emite a `--events-log` (issue #863, MEF-ADR-0049).
#
# Cubre:
#   [pre] El runner existe y tiene sintaxis bash valida.
#   [A] CA-1: formato de linea -- `[HH:MM:SS][tool] <agente> <tool>
#       <ok|fail> <ruta-o-resumen|->` por cada tool.completed, `[HH:MM:SS]
#       [archivo] <ruta>` por cada tool.started con input_summary no nulo, y
#       `[HH:MM:SS][stage] <agente> <status>` en el terminal. Ejercido contra
#       el adaptador fake (runtime-fake.sh, #858) para no depender de un CLI
#       real. Incluye el default `mefisto_state_path events.log` cuando no se
#       pasa `--events-log`.
#   [B] CA-1/CA-2: contra el fixture REAL de Claude Code
#       (fixtures/runtime-claude/success.jsonl, tool Read con
#       input.file_path:"x") -- el runner completo (stub `claude` en el PATH)
#       produce `[archivo] x` y `[tool] <agente> Read ok x`.
#   [C] CA-2: contra el fixture REAL de OpenCode
#       (fixtures/runtime-opencode/success-tool-1.18.29.jsonl, tool `glob`
#       sin mapeo de ruta) -- el runner completo (stub `opencode` en el PATH)
#       produce la MISMA forma de linea `[tool]`/`[stage]` que Claude (B), con
#       "-" como ruta-o-resumen (CA-2: campos ausentes nunca se inventan).
#   [D] CA-3: `--events-log` bajo un directorio sin permisos de escritura
#       degrada a un aviso en stderr, sin alterar el exit code del runner ni
#       el evento terminal ya escrito en `--event-log`.
#   [E] CA-6: el runner no lee contenido de archivos, variables de
#       credenciales ni auth stores para producir la telemetria (grep sobre
#       el propio script).
#
# Uso: .claude/scripts/tests/test-run-agent-telemetry.sh
# Exit code: 0 si todos los checks pasan, 1 si alguno falla.
# Bash 3.2 + jq 1.7 (MEF-ADR-0049 CA-6): sin arrays asociativos.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INTERNAL_SCRIPTS="$REPO_ROOT/src/internal/scripts"
RUNNER="$INTERNAL_SCRIPTS/mefisto-run-agent.sh"
CLAUDE_FIXTURES="$SCRIPT_DIR/fixtures/runtime-claude"
OPENCODE_FIXTURES="$SCRIPT_DIR/fixtures/runtime-opencode"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

WORKDIR="$TMP/wt"
mkdir -p "$WORKDIR"
PROMPT_FILE="$TMP/prompt.txt"
echo "prompt de prueba" > "$PROMPT_FILE"

# Formatos de linea esperados (CA-1): HH:MM:SS entre corchetes, seguido del
# tag del tipo de evento.
RE_TOOL='^\[[0-2][0-9]:[0-5][0-9]:[0-5][0-9]\]\[tool\] [^ ]+ [^ ]+ (ok|fail) .+$'
RE_ARCHIVO='^\[[0-2][0-9]:[0-5][0-9]:[0-5][0-9]\]\[archivo\] .+$'
RE_STAGE='^\[[0-2][0-9]:[0-5][0-9]:[0-5][0-9]\]\[stage\] [^ ]+ (success|failed|timeout|protocol_invalid)$'

echo "[pre] El runner existe y tiene sintaxis valida"
if [ -f "$RUNNER" ]; then
    pass "mefisto-run-agent.sh presente"
else
    fail "mefisto-run-agent.sh no existe"
    echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
    exit 1
fi

if bash -n "$RUNNER" 2>/dev/null; then
    pass "sintaxis bash valida"
else
    fail "sintaxis bash invalida"
fi

# ============================================================================
echo ""
echo "[A] CA-1: formato de linea contra el adaptador fake, con y sin --events-log explicito"

EV_A1_JSONL="$TMP/a1-event.jsonl"
EV_A1_LOG="$TMP/a1-events.log"
RC=$(MEFISTO_FAKE_SCRIPT=success "$RUNNER" --runtime fake --agent fx-agent \
    --cwd "$WORKDIR" --prompt-file "$PROMPT_FILE" --event-log "$EV_A1_JSONL" \
    --events-log "$EV_A1_LOG" >/dev/null 2>&1; echo $?)
if [ "$RC" = "0" ]; then
    pass "A-1: exit 0 con --events-log explicito"
else
    fail "A-1: exit $RC (esperaba 0)"
fi

if [ -f "$EV_A1_LOG" ] && grep -Eq "$RE_TOOL" "$EV_A1_LOG"; then
    pass "A-2: linea [tool] con el formato '[HH:MM:SS][tool] <agente> <tool> <ok|fail> <ruta-o-resumen>'"
else
    fail "A-2: no se encontro una linea [tool] con el formato esperado. Contenido: $(cat "$EV_A1_LOG" 2>/dev/null)"
fi

if grep -Eq "$RE_STAGE" "$EV_A1_LOG" && grep -q '\[stage\] fx-agent success' "$EV_A1_LOG"; then
    pass "A-3: linea [stage] final con el agente y el status del terminal"
else
    fail "A-3: no se encontro la linea [stage] esperada. Contenido: $(cat "$EV_A1_LOG" 2>/dev/null)"
fi

# El adaptador fake nunca puebla input_summary (runtime-fake.sh): la
# ruta-o-resumen del tool.completed tiene que caer en "-", nunca inventarse.
if grep -q '\[tool\] fx-agent demo ok -' "$EV_A1_LOG"; then
    pass "A-4: ruta-o-resumen ausente se escribe como '-' (CA-2), nunca inventada"
else
    fail "A-4: se esperaba '... demo ok -'. Contenido: $(cat "$EV_A1_LOG" 2>/dev/null)"
fi

# Default (sin --events-log): mefisto_state_path events.log, dentro de un
# MEFISTO_STATE_DIR de prueba para no tocar el repo real.
STATE_DIR="$TMP/state/.mefisto/pipeline"
EV_A5_JSONL="$TMP/a5-event.jsonl"
RC=$(MEFISTO_FAKE_SCRIPT=success MEFISTO_STATE_DIR="$STATE_DIR" "$RUNNER" \
    --runtime fake --agent fx-agent --cwd "$WORKDIR" --prompt-file "$PROMPT_FILE" \
    --event-log "$EV_A5_JSONL" >/dev/null 2>&1; echo $?)
if [ "$RC" = "0" ] && [ -f "$STATE_DIR/events.log" ]; then
    pass "A-5: sin --events-log, el default resuelve a mefisto_state_path events.log"
else
    fail "A-5: exit $RC, '$STATE_DIR/events.log' esperado (no encontrado)"
fi

# ============================================================================
echo ""
echo "[B] CA-1/CA-2: fixture REAL de Claude Code (tool_use Read con file_path:'x')"

B_STUB_BIN="$TMP/bin-claude"
mkdir -p "$B_STUB_BIN"
cat > "$B_STUB_BIN/claude" <<STUBEOF
#!/bin/sh
cat "$CLAUDE_FIXTURES/success.jsonl"
exit 0
STUBEOF
chmod +x "$B_STUB_BIN/claude"

ORIG_PATH="$PATH"
EV_B_JSONL="$TMP/b-event.jsonl"
EV_B_LOG="$TMP/b-events.log"
PATH="$B_STUB_BIN:$ORIG_PATH"
RC=$("$RUNNER" --runtime claude --agent writer \
    --cwd "$WORKDIR" --prompt-file "$PROMPT_FILE" --event-log "$EV_B_JSONL" \
    --events-log "$EV_B_LOG" >/dev/null 2>&1; echo $?)
PATH="$ORIG_PATH"

if grep -Eq "$RE_ARCHIVO" "$EV_B_LOG" && grep -q '\[archivo\] x' "$EV_B_LOG"; then
    pass "B-1: tool.started de un tool de archivo (Read) produce '[archivo] x'"
else
    fail "B-1: no se encontro '[archivo] x'. Contenido: $(cat "$EV_B_LOG" 2>/dev/null)"
fi

if grep -q '\[tool\] writer Read ok x' "$EV_B_LOG"; then
    pass "B-2: tool.completed de Read arrastra la ruta 'x' del tool_use emparejado"
else
    fail "B-2: no se encontro '... writer Read ok x'. Contenido: $(cat "$EV_B_LOG" 2>/dev/null)"
fi

if grep -Eq "$RE_STAGE" "$EV_B_LOG"; then
    pass "B-3: linea [stage] final presente"
else
    fail "B-3: no se encontro la linea [stage]. Contenido: $(cat "$EV_B_LOG" 2>/dev/null)"
fi

# ============================================================================
echo ""
echo "[C] CA-2: fixture REAL de OpenCode (tool_use 'glob', sin mapeo de ruta) -- misma forma que Claude"

C_STUB_BIN="$TMP/bin-opencode"
mkdir -p "$C_STUB_BIN"
cat > "$C_STUB_BIN/opencode" <<STUBEOF
#!/bin/sh
cat "$OPENCODE_FIXTURES/success-tool-1.18.29.jsonl"
exit 0
STUBEOF
chmod +x "$C_STUB_BIN/opencode"

EV_C_JSONL="$TMP/c-event.jsonl"
EV_C_LOG="$TMP/c-events.log"
PATH="$C_STUB_BIN:$ORIG_PATH"
RC=$("$RUNNER" --runtime opencode --agent writer \
    --cwd "$WORKDIR" --prompt-file "$PROMPT_FILE" --event-log "$EV_C_JSONL" \
    --events-log "$EV_C_LOG" >/dev/null 2>&1; echo $?)
PATH="$ORIG_PATH"

if grep -Eq "$RE_TOOL" "$EV_C_LOG"; then
    pass "C-1: OpenCode produce una linea [tool] con la MISMA forma que Claude (B-2)"
else
    fail "C-1: no se encontro una linea [tool] con el formato esperado. Contenido: $(cat "$EV_C_LOG" 2>/dev/null)"
fi

if grep -q '\[tool\] writer glob ok -' "$EV_C_LOG"; then
    pass "C-2: 'glob' (sin mapeo de ruta) escribe '-' como ruta-o-resumen, nunca inventada"
else
    fail "C-2: no se encontro '... glob ok -'. Contenido: $(cat "$EV_C_LOG" 2>/dev/null)"
fi

if grep -Eq "$RE_STAGE" "$EV_C_LOG"; then
    pass "C-3: linea [stage] final presente, misma forma que Claude (B-3)"
else
    fail "C-3: no se encontro la linea [stage]. Contenido: $(cat "$EV_C_LOG" 2>/dev/null)"
fi

# ============================================================================
echo ""
echo "[D] CA-3: --events-log bajo un directorio sin permisos degrada a un aviso, sin afectar exit/terminal"

D_BADDIR="$TMP/readonly"
mkdir -p "$D_BADDIR"
chmod 555 "$D_BADDIR"
EV_D_JSONL="$TMP/d-event.jsonl"
D_ERR="$TMP/d-stderr.txt"
RC=$(MEFISTO_FAKE_SCRIPT=success "$RUNNER" --runtime fake --agent fx-agent \
    --cwd "$WORKDIR" --prompt-file "$PROMPT_FILE" --event-log "$EV_D_JSONL" \
    --events-log "$D_BADDIR/sub/events.log" 2>"$D_ERR" >/dev/null; echo $?)
chmod 755 "$D_BADDIR"

if [ "$RC" = "0" ]; then
    pass "D-1: exit code de la corrida NO se altera pese al fallo de escritura"
else
    fail "D-1: exit $RC (esperaba 0, igual que sin --events-log)"
fi

if [ -s "$EV_D_JSONL" ] && jq -e 'select(.type=="run.completed" or .type=="run.failed")' "$EV_D_JSONL" >/dev/null 2>&1; then
    pass "D-2: el evento terminal de --event-log sigue escrito con normalidad"
else
    fail "D-2: --event-log no tiene el evento terminal esperado"
fi

if grep -qi "AVISO" "$D_ERR"; then
    pass "D-3: el fallo de escritura degrada a un aviso en stderr"
else
    fail "D-3: no se encontro un aviso en stderr. Contenido: $(cat "$D_ERR" 2>/dev/null)"
fi

# ============================================================================
echo ""
echo "[E] CA-6: el runner no lee contenido de archivos ni credenciales para la telemetria"

# La telemetria solo puede derivarse de los campos del JSONL neutral (ts,
# tool, input_summary, ok, status) -- nunca de una lectura de archivo, una
# variable de credenciales o un auth store. Mismo criterio de grep que
# test-runtime-opencode.sh [E] (CA-5 de #860), aplicado aqui al runner.
FORBIDDEN_PATTERNS=(
    "ANTHROPIC_API_KEY"
    "OPENAI_API_KEY"
    "auth\\.json"
    "\\.aws/"
    "\\.ssh/"
)
CLEAN=true
for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
    if grep -Eq "$pattern" "$RUNNER"; then
        CLEAN=false
        fail "E-1: el runner menciona un patron prohibido: $pattern"
    fi
done
if [ "$CLEAN" = "true" ]; then
    pass "E-1: ninguna variable de credenciales ni ruta de auth store aparece en el runner"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
