#!/usr/bin/env bash
# test-herdr-workspace.sh -- Funciones puras y montaje de filas de runtime
# mediante un stub determinista de herdr (issues #691, #875 y #958).

set -uo pipefail

# La suite compara argv literal: no debe heredar configuracion del checkout que
# la ejecuta.
unset MEFISTO_MODELS_FILE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/herdr-workspace.sh"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

extract_fn() {
    local name="$1" file="$2"
    awk -v fn="$name" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p{print} p && /^}/{p=0}' "$file"
}

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "[A] Funciones puras"
for fn in workspace_slug agent_name_for_role planner_agent_for_repo runtimes_for_repo; do
    body=$(extract_fn "$fn" "$TARGET")
    if [ -n "$body" ]; then
        eval "$body"
        pass "$fn se puede extraer y cargar"
    else
        fail "$fn no se pudo extraer"
    fi
done

[ "$(workspace_slug 'Bitakora.ControlAsistencia')" = "bitakora-controlasis" ] \
    && pass "workspace_slug conserva su contrato" \
    || fail "workspace_slug cambio su contrato"
[ "$(agent_name_for_role ejecucion eda-evsourcing-azure-harness opencode)" = "ejecucion-eda-evsourcin-opencode" ] \
    && pass "agent_name_for_role conserva el tope de 32 caracteres" \
    || fail "agent_name_for_role produjo un nombre inesperado"

unset MEFISTO_RUNTIMES MEFISTO_RUNTIME
[ "$(runtimes_for_repo mefisto-planner)" = $'claude\nopencode' ] \
    && pass "default de Mefisto: claude + opencode" \
    || fail "default de Mefisto inesperado: $(runtimes_for_repo mefisto-planner)"
MEFISTO_RUNTIME=codex
export MEFISTO_RUNTIME
[ "$(runtimes_for_repo mefisto-planner)" = "codex" ] \
    && pass "MEFISTO_RUNTIME produce una lista de un elemento" \
    || fail "MEFISTO_RUNTIME no produjo un elemento"
MEFISTO_RUNTIMES=' opencode, claude ,opencode,, codex, claude '
export MEFISTO_RUNTIMES
[ "$(runtimes_for_repo mefisto-planner)" = $'opencode\nclaude\ncodex' ] \
    && pass "MEFISTO_RUNTIMES recorta, descarta vacios y colapsa duplicados" \
    || fail "normalizacion inesperada: $(runtimes_for_repo mefisto-planner)"
[ "$(runtimes_for_repo mefisto:planner)" = $'claude\nopencode' ] \
    && pass "consumidor ignora ambas variables y conserva Claude + OpenCode" \
    || fail "el consumidor leyo configuracion de runtimes"
MEFISTO_RUNTIMES=''
export MEFISTO_RUNTIMES
[ -z "$(runtimes_for_repo mefisto-planner)" ] \
    && pass "MEFISTO_RUNTIMES definida vacia conserva precedencia" \
    || fail "MEFISTO_RUNTIMES vacia cayo en MEFISTO_RUNTIME"
unset MEFISTO_RUNTIMES MEFISTO_RUNTIME

FAKE_MEFISTO="$TMP/fake-mefisto-repo"
FAKE_CONSUMER="$TMP/fake consumer repo"
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_MEFISTO/.claude-plugin" "$FAKE_CONSUMER/.claude" "$FAKE_BIN"
printf '{}\n' > "$FAKE_MEFISTO/.claude-plugin/plugin.json"
printf '{}\n' > "$FAKE_CONSUMER/.claude/harness.config.json"
(cd "$FAKE_MEFISTO" && git init -q && git -c user.email=test@example.com -c user.name=Test commit --allow-empty -q -m inicial)
(cd "$FAKE_CONSUMER" && git init -q && git -c user.email=test@example.com -c user.name=Test commit --allow-empty -q -m inicial)
FAKE_MEFISTO=$(cd "$FAKE_MEFISTO" && pwd -P)
FAKE_CONSUMER=$(cd "$FAKE_CONSUMER" && pwd -P)

cat > "$FAKE_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
set -u
echo "herdr $*" >> "$HERDR_STUB_LOG"

option_value() {
    local wanted="$1"
    shift
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "$wanted" ]; then
            [ "$#" -gt 1 ] || return 1
            printf '%s\n' "$2"
            return 0
        fi
        shift
    done
    return 1
}

if [ -n "${HERDR_STUB_EXPECT_CWD:-}" ] \
    && { [ "${1:-} ${2:-}" = "workspace create" ] || [ "${1:-} ${2:-}" = "pane split" ]; }; then
    actual_cwd=$(option_value --cwd "$@")
    if [ "$actual_cwd" != "$HERDR_STUB_EXPECT_CWD" ]; then
        printf 'cwd recibido como argv distinto: <%s>\n' "$actual_cwd" >&2
        exit 64
    fi
fi
case "${1:-} ${2:-}" in
    "status server") exit 0 ;;
    "workspace list")
        if [ -n "${HERDR_STUB_EXISTING_LABEL:-}" ]; then
            printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"%s"}]}}\n' "$HERDR_STUB_EXISTING_LABEL"
        else
            echo '{"result":{"workspaces":[]}}'
        fi
        ;;
    "workspace create")
        echo '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:p1"}}}'
        ;;
    "pane split")
        n=$(cat "$HERDR_STUB_SPLIT_COUNTER")
        echo $((n + 1)) > "$HERDR_STUB_SPLIT_COUNTER"
        printf '{"result":{"pane":{"pane_id":"w1:p%s"}}}\n' "$n"
        ;;
    "pane list")
        printf '{"result":{"panes":['
        first=1
        items=()
        IFS=';' read -ra items <<< "${HERDR_STUB_PANES:-}"
        for item in "${items[@]+"${items[@]}"}"; do
            [ -n "$item" ] || continue
            label="${item%%=*}"
            pane="${item#*=}"
            [ "$first" -eq 1 ] || printf ','
            first=0
            printf '{"pane_id":"%s","label":"%s"}' "$pane" "$label"
        done
        echo ']}}'
        ;;
    "pane process-info")
        echo '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":100}}}'
        ;;
    "agent start") echo '{"result":{"type":"ok"}}' ;;
    "agent get") exit 1 ;;
    *) echo '{"result":{"type":"ok"}}' ;;
esac
STUB
chmod +x "$FAKE_BIN/herdr"

HERDR_STUB_LOG="$TMP/herdr.log"
HERDR_STUB_SPLIT_COUNTER="$TMP/split-counter"
export HERDR_STUB_LOG HERDR_STUB_SPLIT_COUNTER MEFISTO_AGENT_START_RETRY_PAUSE=0
LAST_STDOUT=""
LAST_STDERR=""
LAST_RC=0

run_workspace() {
    local repo="$1" split_start="${2:-2}"
    : > "$HERDR_STUB_LOG"
    printf '%s\n' "$split_start" > "$HERDR_STUB_SPLIT_COUNTER"
    PATH="$FAKE_BIN:$PATH" "$TARGET" "$repo" >"$TMP/stdout" 2>"$TMP/stderr"
    LAST_RC=$?
    LAST_STDOUT=$(cat "$TMP/stdout")
    LAST_STDERR=$(cat "$TMP/stderr")
}

assert_no_anchor_protocol() {
    local block="$1"
    if grep -qE 'pane close|pane rename .*fila libre' "$HERDR_STUB_LOG"; then
        fail "$block: aparecio el protocolo de ancla: $(cat "$HERDR_STUB_LOG")"
    else
        pass "$block: no usa pane close ni fila libre"
    fi
}

echo ""
echo "[B] Workspace nuevo de Mefisto: default de dos filas, orden byte a byte"
unset MEFISTO_RUNTIMES MEFISTO_RUNTIME HERDR_STUB_EXISTING_LABEL HERDR_STUB_PANES
run_workspace "$FAKE_MEFISTO"
EXPECTED=$(cat <<EOF
herdr status server
herdr workspace list
herdr workspace create --cwd $FAKE_MEFISTO --label fake-mefisto-repo --env MEFISTO_RUNTIME=claude
herdr pane split --pane w1:p1 --direction down --cwd $FAKE_MEFISTO --no-focus --env MEFISTO_RUNTIME=opencode
herdr pane split --pane w1:p1 --direction right --cwd $FAKE_MEFISTO --no-focus --env MEFISTO_RUNTIME=claude
herdr pane split --pane w1:p2 --direction right --cwd $FAKE_MEFISTO --no-focus --env MEFISTO_RUNTIME=opencode
herdr pane rename w1:p1 planner [claude]
herdr pane rename w1:p3 ejecucion [claude]
herdr pane process-info --pane w1:p1
herdr agent start planner-fake-mefisto-re-claude --kind claude --pane w1:p1 --timeout 90000 -- --agent mefisto-planner
herdr pane process-info --pane w1:p3
herdr agent start ejecucion-fake-mefisto-re-claude --kind claude --pane w1:p3 --timeout 90000
herdr pane rename w1:p2 planner [opencode]
herdr pane rename w1:p4 ejecucion [opencode]
herdr pane process-info --pane w1:p2
herdr agent start planner-fake-mefisto-opencode --kind opencode --pane w1:p2 --timeout 90000 -- --agent mefisto-planner
herdr pane process-info --pane w1:p4
herdr agent start ejecucion-fake-mefisto-opencode --kind opencode --pane w1:p4 --timeout 90000
EOF
)
[ "$LAST_RC" -eq 0 ] && pass "B-1: monta dos filas sin abortar" || fail "B-1: rc=$LAST_RC, stderr=$LAST_STDERR"
[ "$(cat "$HERDR_STUB_LOG")" = "$EXPECTED" ] \
    && pass "B-2: downs antes de rights y argumentos exactos" \
    || fail "B-2: log inesperado. Esperado:\n$EXPECTED\nObtenido:\n$(cat "$HERDR_STUB_LOG")"
assert_no_anchor_protocol B-3

echo ""
echo "[C] Workspace nuevo de Mefisto: MEFISTO_RUNTIMES=claude"
export MEFISTO_RUNTIMES=claude
run_workspace "$FAKE_MEFISTO"
unset MEFISTO_RUNTIMES
EXPECTED=$(cat <<EOF
herdr status server
herdr workspace list
herdr workspace create --cwd $FAKE_MEFISTO --label fake-mefisto-repo --env MEFISTO_RUNTIME=claude
herdr pane split --pane w1:p1 --direction right --cwd $FAKE_MEFISTO --no-focus --env MEFISTO_RUNTIME=claude
herdr pane rename w1:p1 planner [claude]
herdr pane rename w1:p2 ejecucion [claude]
herdr pane process-info --pane w1:p1
herdr agent start planner-fake-mefisto-re-claude --kind claude --pane w1:p1 --timeout 90000 -- --agent mefisto-planner
herdr pane process-info --pane w1:p2
herdr agent start ejecucion-fake-mefisto-re-claude --kind claude --pane w1:p2 --timeout 90000
EOF
)
[ "$(cat "$HERDR_STUB_LOG")" = "$EXPECTED" ] \
    && pass "C-1: una fila tiene cero splits down y conserva --env/--kind" \
    || fail "C-1: log inesperado. Esperado:\n$EXPECTED\nObtenido:\n$(cat "$HERDR_STUB_LOG")"
assert_no_anchor_protocol C-2

echo ""
echo "[C2] Workspace nuevo de Mefisto: tres runtimes"
export MEFISTO_RUNTIMES=claude,opencode,codex
run_workspace "$FAKE_MEFISTO"
unset MEFISTO_RUNTIMES
DOWNS=$(grep -F ' --direction down ' "$HERDR_STUB_LOG")
EXPECTED_DOWNS=$(cat <<EOF
herdr pane split --pane w1:p1 --direction down --cwd $FAKE_MEFISTO --no-focus --env MEFISTO_RUNTIME=codex
herdr pane split --pane w1:p1 --direction down --cwd $FAKE_MEFISTO --no-focus --env MEFISTO_RUNTIME=opencode
EOF
)
[ "$DOWNS" = "$EXPECTED_DOWNS" ] \
    && pass "C2-1: los down recorren tres runtimes en orden inverso" \
    || fail "C2-1: orden de down inesperado: $DOWNS"
FIRST_RIGHT_LINE=$(grep -nF ' --direction right ' "$HERDR_STUB_LOG" | cut -d: -f1 | head -1)
LAST_DOWN_LINE=$(grep -nF ' --direction down ' "$HERDR_STUB_LOG" | cut -d: -f1 | tail -1)
[ "$LAST_DOWN_LINE" -lt "$FIRST_RIGHT_LINE" ] \
    && pass "C2-2: todos los down ocurren antes de cualquier right" \
    || fail "C2-2: un right ocurrio antes de terminar los down"
grep -qxF 'herdr pane rename w1:p1 planner [claude]' "$HERDR_STUB_LOG" \
    && grep -qxF 'herdr pane rename w1:p3 planner [opencode]' "$HERDR_STUB_LOG" \
    && grep -qxF 'herdr pane rename w1:p2 planner [codex]' "$HERDR_STUB_LOG" \
    && pass "C2-3: las tres filas quedan asociadas al kind correcto" \
    || fail "C2-3: labels inesperados: $(cat "$HERDR_STUB_LOG")"
assert_no_anchor_protocol C2-4

echo ""
echo "[D] Workspace existente con todas las filas: solo focus"
export HERDR_STUB_EXISTING_LABEL=fake-mefisto-repo
export HERDR_STUB_PANES='planner [claude]=w1:p1;ejecucion [claude]=w1:p3;planner [opencode]=w1:p2;ejecucion [opencode]=w1:p4'
run_workspace "$FAKE_MEFISTO" 5
unset HERDR_STUB_EXISTING_LABEL HERDR_STUB_PANES
grep -qxF 'herdr workspace focus w1' "$HERDR_STUB_LOG" \
    && pass "D-1: enfoca el workspace existente" \
    || fail "D-1: no enfoco: $(cat "$HERDR_STUB_LOG")"
if grep -qE 'pane split|pane rename|agent start' "$HERDR_STUB_LOG"; then
    fail "D-2: modifico filas ya presentes: $(cat "$HERDR_STUB_LOG")"
else
    pass "D-2: no hace split, rename ni agent start"
fi
assert_no_anchor_protocol D-3

echo ""
echo "[E] Workspace existente con opencode faltante: toca solo la fila nueva"
export HERDR_STUB_EXISTING_LABEL=fake-mefisto-repo
export HERDR_STUB_PANES='planner [claude]=w1:p1;ejecucion [claude]=w1:p3'
run_workspace "$FAKE_MEFISTO" 4
unset HERDR_STUB_EXISTING_LABEL HERDR_STUB_PANES
grep -qxF "herdr pane split --pane w1:p1 --direction down --cwd $FAKE_MEFISTO --no-focus --env MEFISTO_RUNTIME=opencode" "$HERDR_STUB_LOG" \
    && grep -qxF "herdr pane split --pane w1:p4 --direction right --cwd $FAKE_MEFISTO --no-focus --env MEFISTO_RUNTIME=opencode" "$HERDR_STUB_LOG" \
    && pass "E-1: monta la faltante desde el ultimo planner existente" \
    || fail "E-1: splits inesperados: $(cat "$HERDR_STUB_LOG")"
if grep -qE 'rename w1:p1|rename w1:p3|agent start .*claude' "$HERDR_STUB_LOG"; then
    fail "E-2: toco la fila claude existente: $(cat "$HERDR_STUB_LOG")"
else
    pass "E-2: la fila existente no recibe rename ni agent start"
fi
grep -qxF 'herdr pane rename w1:p4 planner [opencode]' "$HERDR_STUB_LOG" \
    && grep -qxF 'herdr pane rename w1:p5 ejecucion [opencode]' "$HERDR_STUB_LOG" \
    && pass "E-3: etiqueta solo los panes nuevos" \
    || fail "E-3: labels inesperados: $(cat "$HERDR_STUB_LOG")"
assert_no_anchor_protocol E-4

echo ""
echo "[F] Workspace existente con una lista disjunta: monta desde el ultimo planner disponible"
export HERDR_STUB_EXISTING_LABEL=fake-mefisto-repo
export HERDR_STUB_PANES='planner [codex]=w1:p7;ejecucion [codex]=w1:p8'
export MEFISTO_RUNTIMES=claude
run_workspace "$FAKE_MEFISTO" 9
unset HERDR_STUB_EXISTING_LABEL HERDR_STUB_PANES MEFISTO_RUNTIMES
grep -qxF "herdr pane split --pane w1:p7 --direction down --cwd $FAKE_MEFISTO --no-focus --env MEFISTO_RUNTIME=claude" "$HERDR_STUB_LOG" \
    && grep -qxF "herdr pane split --pane w1:p9 --direction right --cwd $FAKE_MEFISTO --no-focus --env MEFISTO_RUNTIME=claude" "$HERDR_STUB_LOG" \
    && pass "F-1: monta la fila pedida aunque ninguna configurada existiera antes" \
    || fail "F-1: no monto desde el planner disponible: $(cat "$HERDR_STUB_LOG")"
if grep -qE 'rename w1:p7|rename w1:p8|agent start .*codex' "$HERDR_STUB_LOG"; then
    fail "F-2: toco la fila codex existente: $(cat "$HERDR_STUB_LOG")"
else
    pass "F-2: no modifica la fila usada como base"
fi
assert_no_anchor_protocol F-3

echo ""
echo "[H] Consumidor nuevo: dos filas y path con espacios"
export MEFISTO_RUNTIME=opencode
export HERDR_STUB_EXPECT_CWD="$FAKE_CONSUMER"
run_workspace "$FAKE_CONSUMER"
unset MEFISTO_RUNTIME HERDR_STUB_EXPECT_CWD
EXPECTED=$(cat <<EOF
herdr status server
herdr workspace list
herdr workspace create --cwd $FAKE_CONSUMER --label fake consumer repo --env MEFISTO_RUNTIME=claude
herdr pane split --pane w1:p1 --direction down --cwd $FAKE_CONSUMER --no-focus --env MEFISTO_RUNTIME=opencode
herdr pane split --pane w1:p1 --direction right --cwd $FAKE_CONSUMER --no-focus --env MEFISTO_RUNTIME=claude
herdr pane split --pane w1:p2 --direction right --cwd $FAKE_CONSUMER --no-focus --env MEFISTO_RUNTIME=opencode
herdr pane rename w1:p1 planner [claude]
herdr pane rename w1:p3 ejecucion [claude]
herdr pane process-info --pane w1:p1
herdr agent start planner-fake-consumer-r-claude --kind claude --pane w1:p1 --timeout 90000 -- --agent mefisto:planner
herdr pane process-info --pane w1:p3
herdr agent start ejecucion-fake-consumer-r-claude --kind claude --pane w1:p3 --timeout 90000
herdr pane rename w1:p2 planner [opencode]
herdr pane rename w1:p4 ejecucion [opencode]
herdr pane process-info --pane w1:p2
herdr agent start planner-fake-consumer-opencode --kind opencode --pane w1:p2 --timeout 90000
herdr pane process-info --pane w1:p4
herdr agent start ejecucion-fake-consumer-opencode --kind opencode --pane w1:p4 --timeout 90000
EOF
)
[ "$LAST_RC" -eq 0 ] && [ "$(cat "$HERDR_STUB_LOG")" = "$EXPECTED" ] \
    && pass "H-1: filas Claude/OpenCode con labels, nombres, kind y env exactos" \
    || fail "H-1: rama consumidor cambio. Esperado:\n$EXPECTED\nObtenido:\n$(cat "$HERDR_STUB_LOG")"
printf '%s\n%s\n' "$LAST_STDOUT" "$LAST_STDERR" | grep -q 'Diagnostico de identidad: metadata_missing' \
    && printf '%s\n%s\n' "$LAST_STDOUT" "$LAST_STDERR" | grep -q 'planner \[opencode\].*sin --agent' \
    && pass "H-2: diagnostica identidad y declara la degradacion del planner OpenCode" \
    || fail "H-2: falta diagnostico o degradacion visible: $LAST_STDOUT$LAST_STDERR"
assert_no_anchor_protocol H-3

echo ""
echo "[I] Consumidor normalizado con OpenCode faltante: agrega solo la fila nueva"
export HERDR_STUB_EXISTING_LABEL='fake consumer repo'
export HERDR_STUB_PANES='planner [claude]=w1:p1;ejecucion [claude]=w1:p3'
run_workspace "$FAKE_CONSUMER"
unset HERDR_STUB_EXISTING_LABEL HERDR_STUB_PANES
grep -qxF "herdr pane split --pane w1:p1 --direction down --cwd $FAKE_CONSUMER --no-focus --env MEFISTO_RUNTIME=opencode" "$HERDR_STUB_LOG" \
    && grep -qxF 'herdr agent start planner-fake-consumer-opencode --kind opencode --pane w1:p2 --timeout 90000' "$HERDR_STUB_LOG" \
    && pass "I-1: agrega OpenCode sin tocar Claude y sin --agent del planner" \
    || fail "I-1: agregado inesperado: $(cat "$HERDR_STUB_LOG")"
assert_no_anchor_protocol I-3

echo ""
echo "[J] Consumidor legacy: normaliza Claude y agrega OpenCode; ambas filas convergen"
export HERDR_STUB_EXISTING_LABEL='fake consumer repo'
export HERDR_STUB_PANES='planner=w1:p1'
run_workspace "$FAKE_CONSUMER"
grep -qxF 'herdr pane rename w1:p1 planner [claude]' "$HERDR_STUB_LOG" \
    && ! grep -qE 'pane split|agent start|pane close' "$HERDR_STUB_LOG" \
    && pass "J-1: normaliza el planner legacy sin reconstruir el layout" \
    || fail "J-1: transicion legacy inesperada: $(cat "$HERDR_STUB_LOG")"
export HERDR_STUB_PANES='planner [claude]=w1:p1;ejecucion [claude]=w1:p2;planner [opencode]=w1:p3;ejecucion [opencode]=w1:p4'
run_workspace "$FAKE_CONSUMER"
FIRST_LOG=$(cat "$HERDR_STUB_LOG")
run_workspace "$FAKE_CONSUMER"
SECOND_LOG=$(cat "$HERDR_STUB_LOG")
unset HERDR_STUB_EXISTING_LABEL HERDR_STUB_PANES
[ "$SECOND_LOG" = "$FIRST_LOG" ] \
    && grep -qxF 'herdr workspace focus w1' <<< "$SECOND_LOG" \
    && ! grep -qE 'pane rename|pane split|agent start|pane close' <<< "$SECOND_LOG" \
    && pass "J-2: dos filas presentes solo enfocan byte a byte" \
    || fail "J-2: normalizado no converge: $SECOND_LOG"

echo ""
echo "[Z] Protocolo retirado del script"
if grep -qE 'mount_second_row|pane close|fila libre' "$TARGET"; then
    fail "Z-1: el script aun contiene referencias al protocolo de ancla"
else
    pass "Z-1: no quedan cierres, busquedas, renames ni menciones al ancla"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
