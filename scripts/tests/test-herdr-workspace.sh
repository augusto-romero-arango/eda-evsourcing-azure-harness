#!/usr/bin/env bash
# test-herdr-workspace.sh -- Tests de herdr-workspace.sh: funciones puras
# (issue #691) + subproceso real con stub de `herdr` para la seleccion de
# runtime (MEFISTO_RUNTIME, issue #875).
#
# Dos estilos combinados:
#   - Funciones puras (bloques [A]/[B], estilo test-stream-watch.sh): se
#     extrae SOLO el cuerpo de cada funcion (awk sobre "nombre() {" .. "}" en
#     columna 0) y se evalua en este proceso, sin sourcing el archivo
#     completo (su main llama a herdr; estas piezas no).
#   - Subproceso real con stub (bloques [C]-[F], estilo
#     test-herdr-parallel.sh): repos de mentira (mktemp -d + git init, con y
#     sin .claude-plugin/plugin.json) y un stub de `herdr` en PATH que
#     registra cada invocacion y devuelve JSON determinista -- nunca toca un
#     servidor herdr real.
#
# Casos cubiertos:
#   [pre] Las funciones bajo prueba se pueden extraer y cargar.
#   [A] workspace_slug: minusculas, caracteres raros a '-', sin guiones en
#       los extremos, tope de 20 caracteres por default y parametrizable
#       (los nombres de agente de herdr admiten 32 y el prefijo mas largo
#       ocupa 10).
#   [A2] agent_name_for_role: nombre completo rol-slug[-kind], mismo slug
#       para planner/ejecucion recortado por el prefijo mas largo (CA-2, CA-4).
#   [B] planner_agent_for_repo: mefisto-planner en el repo del plugin
#       (.claude-plugin/plugin.json presente), mefisto:planner en un consumidor.
#   [C] Workspace Mefisto con MEFISTO_RUNTIME=opencode: ambos panes arrancan
#       con --kind opencode, nombre de agente sufijado con "-opencode" y
#       heredan MEFISTO_RUNTIME via --env en `workspace create`/`pane split`
#       (CA-1, CA-2).
#   [D] Workspace Mefisto sin MEFISTO_RUNTIME: --kind claude, nombre de
#       agente sufijado con "-claude" (issue #930: siempre, incluso con el
#       runtime default) y ningun --env (CA-1).
#   [E] Repo consumidor con MEFISTO_RUNTIME=opencode: aviso + fallback a
#       claude, sin --env -- la rama consumidor no cambia (CA-3).
#   [F] Fallo de `herdr agent start` en los 2 intentos: reintenta una vez y
#       degrada con aviso sin abortar el workspace (mecanica actual,
#       preservada tras parametrizar --kind).
#   [G] Reabrir un workspace ya montado con MEFISTO_RUNTIME=opencode: solo lo
#       enfoca -- ni pane split ni agent start, con cualquier runtime (CA-5).
#
# Uso: scripts/tests/test-herdr-workspace.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/herdr-workspace.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

extract_fn() {
    local name="$1" file="$2"
    awk -v fn="$name" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p{print} p && /^}/{p=0}' "$file"
}

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "[pre] Las funciones bajo prueba se pueden extraer y cargar desde herdr-workspace.sh"
ALL_LOADED=1
for fn in workspace_slug agent_name_for_role planner_agent_for_repo; do
    body=$(extract_fn "$fn" "$TARGET")
    if [ -n "$body" ]; then
        eval "$body"
        if declare -F "$fn" >/dev/null; then
            pass "$fn definida y cargable"
        else
            fail "$fn: eval no la dejo definida"
            ALL_LOADED=0
        fi
    else
        fail "$fn: no se pudo extraer el cuerpo"
        ALL_LOADED=0
    fi
done

if [ "$ALL_LOADED" -ne 1 ]; then
    echo "Abortando: no se pudieron cargar todas las funciones bajo prueba."
    exit 1
fi

# -------- Bloque A: workspace_slug --------

echo ""
echo "[A] workspace_slug: minusculas, caracteres raros a '-', extremos limpios, tope de 20"

SLUG_A1=$(workspace_slug "Bitakora.ControlAsistencia")
if [ "$SLUG_A1" = "bitakora-controlasis" ] && [ "${#SLUG_A1}" -le 20 ]; then
    pass "A-1: 'Bitakora.ControlAsistencia' -> '$SLUG_A1' (minusculas, punto a guion, 20 max)"
else
    fail "A-1: slug inesperado para el nombre real de un consumidor: '$SLUG_A1'"
fi

SLUG_A2=$(workspace_slug "eda-evsourcing-azure-harness")
if [ "$SLUG_A2" = "eda-evsourcing-azure" ] && [ "${#SLUG_A2}" -le 20 ]; then
    pass "A-2: el nombre del repo de Mefisto se trunca a 20 sin guion colgante"
else
    fail "A-2: slug inesperado para el repo de Mefisto: '$SLUG_A2'"
fi

SLUG_A3=$(workspace_slug "__Mi  Proyecto!!")
case "$SLUG_A3" in
    -*|*-) fail "A-3: el slug conserva guiones en los extremos: '$SLUG_A3'" ;;
    mi-proyecto) pass "A-3: espacios y simbolos colapsan a '-' y los extremos quedan limpios" ;;
    *) fail "A-3: slug inesperado: '$SLUG_A3'" ;;
esac

SLUG_A4=$(workspace_slug "abc")
if [ "$SLUG_A4" = "abc" ]; then
    pass "A-4: un nombre ya valido se devuelve intacto"
else
    fail "A-4: se esperaba 'abc', se obtuvo '$SLUG_A4'"
fi

SLUG_A5=$(workspace_slug "eda-evsourcing-azure-harness" 13)
if [ "$SLUG_A5" = "eda-evsourcin" ] && [ "${#SLUG_A5}" -le 13 ]; then
    pass "A-5: el tope es parametrizable (max=13) sin guion colgante"
else
    fail "A-5: slug inesperado con max=13: '$SLUG_A5'"
fi

# -------- Bloque A2: agent_name_for_role --------

echo ""
echo "[A2] agent_name_for_role: rol-slug[-kind], mismo slug para planner/ejecucion (CA-2, CA-4)"

NAME_A2_1=$(agent_name_for_role "ejecucion" "eda-evsourcing-azure-harness" "opencode")
if [ "$NAME_A2_1" = "ejecucion-eda-evsourcin-opencode" ] && [ "${#NAME_A2_1}" -le 32 ]; then
    pass "A2-1: ejecucion con kind=opencode y el label real de Mefisto -> '$NAME_A2_1' (32 chars)"
else
    fail "A2-1: nombre inesperado: '$NAME_A2_1'"
fi

NAME_A2_2=$(agent_name_for_role "planner" "eda-evsourcing-azure-harness" "opencode")
if [ "$NAME_A2_2" = "planner-eda-evsourcin-opencode" ]; then
    pass "A2-2: planner comparte el MISMO slug que ejecucion (recortado por el prefijo mas largo)"
else
    fail "A2-2: nombre inesperado: '$NAME_A2_2'"
fi

NAME_A2_3=$(agent_name_for_role "planner" "Bitakora.ControlAsistencia" "")
if [ "$NAME_A2_3" = "planner-bitakora-controlasis" ]; then
    pass "A2-3: kind vacio (consumidor) no agrega sufijo, tope de 20 (CA-3)"
else
    fail "A2-3: nombre inesperado: '$NAME_A2_3'"
fi

# -------- Bloque B: planner_agent_for_repo --------

echo ""
echo "[B] planner_agent_for_repo: interno con plugin.json, publicado sin el"

mkdir -p "$TMP/mefisto/.claude-plugin" "$TMP/consumidor"
echo '{}' > "$TMP/mefisto/.claude-plugin/plugin.json"

if [ "$(planner_agent_for_repo "$TMP/mefisto")" = "mefisto-planner" ]; then
    pass "B-1: con .claude-plugin/plugin.json el planner es el interno (mefisto-planner)"
else
    fail "B-1: se esperaba mefisto-planner, se obtuvo '$(planner_agent_for_repo "$TMP/mefisto")'"
fi

if [ "$(planner_agent_for_repo "$TMP/consumidor")" = "mefisto:planner" ]; then
    pass "B-2: sin plugin.json el planner es el publicado calificado por plugin (mefisto:planner)"
else
    fail "B-2: se esperaba mefisto:planner, se obtuvo '$(planner_agent_for_repo "$TMP/consumidor")'"
fi

# -------- Bloques C-F: subproceso real con stub de herdr (MEFISTO_RUNTIME) --------
#
# Repos de mentira y stub dentro de $TMP (compartiendo el trap de limpieza de
# arriba). El stub registra "herdr $*" en HERDR_STUB_LOG y devuelve JSON
# determinista; el propio proceso real (no una funcion extraida) corre con
# ese stub primero en PATH -- jq real sigue resolviendo del PATH original,
# antepuesto solo con FAKE_BIN.

FAKE_MEFISTO="$TMP/fake-mefisto-repo"
FAKE_CONSUMER="$TMP/fake-consumer-repo"
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_MEFISTO/.claude-plugin" "$FAKE_CONSUMER/.claude" "$FAKE_BIN"
echo '{}' > "$FAKE_MEFISTO/.claude-plugin/plugin.json"
echo '{}' > "$FAKE_CONSUMER/.claude/harness.config.json"
(cd "$FAKE_MEFISTO" && git init -q && git -c user.email="test@example.com" -c user.name="Test" commit --allow-empty -q -m "commit inicial")
(cd "$FAKE_CONSUMER" && git init -q && git -c user.email="test@example.com" -c user.name="Test" commit --allow-empty -q -m "commit inicial")

# git -C rev-parse --show-toplevel resuelve symlinks (en macOS /var -> /private/var):
# el script bajo prueba reporta ese repo_root RESUELTO como --cwd, asi que las
# aserciones de linea exacta deben compararse contra la misma forma resuelta.
FAKE_MEFISTO=$(cd "$FAKE_MEFISTO" && pwd -P)
FAKE_CONSUMER=$(cd "$FAKE_CONSUMER" && pwd -P)

# Stub de herdr: registra cada invocacion y responde JSON determinista.
#   status server     -> ok (exit 0, sin cuerpo)
#   workspace list    -> sin workspaces, salvo HERDR_STUB_EXISTING_LABEL, que
#                        devuelve uno con ese label (rama de idempotencia)
#   workspace create  -> workspace_id w1, root_pane w1:p1
#   pane split        -> pane_id w1:p2
#   agent start       -> ok, salvo HERDR_STUB_AGENT_START_FAIL=1 (falla siempre)
#   agent get         -> falla salvo HERDR_STUB_AGENT_GET_OK=1
#   pane process-info -> pane libre (foreground == shell), sin espera
cat > "$FAKE_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
set -u
echo "herdr $*" >> "$HERDR_STUB_LOG"
case "${1:-} ${2:-}" in
    "status server")
        exit 0
        ;;
    "workspace list")
        if [ -n "${HERDR_STUB_EXISTING_LABEL:-}" ]; then
            echo "{\"result\":{\"workspaces\":[{\"workspace_id\":\"w-existente\",\"label\":\"$HERDR_STUB_EXISTING_LABEL\"}]}}"
        else
            echo '{"result":{"workspaces":[]}}'
        fi
        ;;
    "workspace create")
        echo '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:p1"}}}'
        ;;
    "pane split")
        echo '{"result":{"pane":{"pane_id":"w1:p2"}}}'
        ;;
    "pane process-info")
        echo '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":100}}}'
        ;;
    "agent start")
        if [ "${HERDR_STUB_AGENT_START_FAIL:-0}" = "1" ]; then
            echo '{"error":"agent_not_ready (stub)"}' >&2
            exit 1
        fi
        echo '{"result":{"type":"ok"}}'
        ;;
    "agent get")
        if [ "${HERDR_STUB_AGENT_GET_OK:-0}" = "1" ]; then
            echo '{"result":{"type":"ok"}}'
        else
            exit 1
        fi
        ;;
    *)
        echo '{"result":{"type":"ok"}}'
        ;;
esac
STUB
chmod +x "$FAKE_BIN/herdr"

TARGET_SCRIPT="$REPO_ROOT/scripts/herdr-workspace.sh"
HERDR_STUB_LOG="$TMP/herdr-invocations.log"
export HERDR_STUB_LOG

# Seam de la pausa entre el start fallido y el `agent get` que lo confirma: en
# produccion son 3s, y el bloque [F] la pagaria cuatro veces (2 intentos x 2
# agentes = 12s de reloj) sin ejercitar nada distinto.
export MEFISTO_AGENT_START_RETRY_PAUSE=0

LAST_STDOUT=""
LAST_STDERR=""
LAST_RC=0

# run_workspace <repo>
#
# Corre el script REAL (no una funcion extraida) contra el repo indicado,
# con el stub de herdr primero en PATH. MEFISTO_RUNTIME/HERDR_STUB_* se
# heredan si el caller los exporto antes de llamar (mismo criterio que
# test-mefisto-herdr-pipeline.sh).
run_workspace() {
    local target="$1"
    : > "$HERDR_STUB_LOG"
    local out="$TMP/stdout" err="$TMP/stderr"
    (
        PATH="$FAKE_BIN:$PATH" "$TARGET_SCRIPT" "$target"
    ) </dev/null >"$out" 2>"$err"
    LAST_RC=$?
    LAST_STDOUT=$(cat "$out")
    LAST_STDERR=$(cat "$err")
}

echo ""
echo "[C] Workspace Mefisto con MEFISTO_RUNTIME=opencode: --kind opencode, nombre sufijado y --env en ambos panes"

export MEFISTO_RUNTIME=opencode
run_workspace "$FAKE_MEFISTO"
unset MEFISTO_RUNTIME

if [ "$LAST_RC" -eq 0 ]; then
    pass "C-1: corre sin abortar (rc=$LAST_RC)"
else
    fail "C-1: no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"
fi
if grep -qxF "herdr agent start planner-fake-mefisto-opencode --kind opencode --pane w1:p1 --timeout 90000 -- --agent mefisto-planner" "$HERDR_STUB_LOG"; then
    pass "C-2: el pane planner arranca --kind opencode con nombre sufijado y --agent mefisto-planner"
else
    fail "C-2: no se encontro la invocacion esperada -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qxF "herdr agent start ejecucion-fake-mefisto-opencode --kind opencode --pane w1:p2 --timeout 90000" "$HERDR_STUB_LOG"; then
    pass "C-3: el pane ejecucion arranca --kind opencode con nombre sufijado sin --agent"
else
    fail "C-3: no se encontro la invocacion esperada -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qxF "herdr workspace create --cwd $FAKE_MEFISTO --label fake-mefisto-repo --env MEFISTO_RUNTIME=opencode" "$HERDR_STUB_LOG"; then
    pass "C-4: workspace create hereda MEFISTO_RUNTIME=opencode via --env"
else
    fail "C-4: workspace create no llevo --env MEFISTO_RUNTIME=opencode -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qxF "herdr pane split --pane w1:p1 --direction right --cwd $FAKE_MEFISTO --no-focus --env MEFISTO_RUNTIME=opencode" "$HERDR_STUB_LOG"; then
    pass "C-5: pane split hereda MEFISTO_RUNTIME=opencode via --env"
else
    fail "C-5: pane split no llevo --env MEFISTO_RUNTIME=opencode -- log: $(cat "$HERDR_STUB_LOG")"
fi

echo ""
echo "[D] Workspace Mefisto sin MEFISTO_RUNTIME: --kind claude, nombre sufijado igual (issue #930) y sin --env"

run_workspace "$FAKE_MEFISTO"

if [ "$LAST_RC" -eq 0 ]; then
    pass "D-1: corre sin abortar (rc=$LAST_RC)"
else
    fail "D-1: no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"
fi
if grep -qxF "herdr agent start planner-fake-mefisto-re-claude --kind claude --pane w1:p1 --timeout 90000 -- --agent mefisto-planner" "$HERDR_STUB_LOG"; then
    pass "D-2: el pane planner arranca --kind claude (default) con el sufijo -claude en el nombre"
else
    fail "D-2: no se encontro la invocacion esperada -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qxF "herdr workspace create --cwd $FAKE_MEFISTO --label fake-mefisto-repo" "$HERDR_STUB_LOG"; then
    pass "D-3: workspace create sin --env (MEFISTO_RUNTIME ausente)"
else
    fail "D-3: workspace create no coincide byte a byte -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qxF "herdr pane split --pane w1:p1 --direction right --cwd $FAKE_MEFISTO --no-focus" "$HERDR_STUB_LOG"; then
    pass "D-4: pane split sin --env (MEFISTO_RUNTIME ausente)"
else
    fail "D-4: pane split no coincide byte a byte -- log: $(cat "$HERDR_STUB_LOG")"
fi

echo ""
echo "[E] Repo consumidor con MEFISTO_RUNTIME=opencode: aviso + fallback a claude, sin --env (CA-3)"

export MEFISTO_RUNTIME=opencode
run_workspace "$FAKE_CONSUMER"
unset MEFISTO_RUNTIME

if [ "$LAST_RC" -eq 0 ]; then
    pass "E-1: corre sin abortar (rc=$LAST_RC)"
else
    fail "E-1: no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"
fi
if printf '%s\n%s' "$LAST_STDOUT" "$LAST_STDERR" | grep -q "El plugin publicado aun no soporta OpenCode"; then
    pass "E-2: avisa que el plugin publicado aun no soporta OpenCode"
else
    fail "E-2: no aviso -- stdout: $LAST_STDOUT / stderr: $LAST_STDERR"
fi
if grep -qxF "herdr agent start planner-fake-consumer-repo --kind claude --pane w1:p1 --timeout 90000 -- --agent mefisto:planner" "$HERDR_STUB_LOG"; then
    pass "E-3: el pane planner arranca --kind claude (fallback) con el agente publicado mefisto:planner"
else
    fail "E-3: no se encontro la invocacion esperada -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qxF "herdr workspace create --cwd $FAKE_CONSUMER --label fake-consumer-repo" "$HERDR_STUB_LOG"; then
    pass "E-4: workspace create sin --env (el consumidor no cambia)"
else
    fail "E-4: workspace create no coincide byte a byte -- log: $(cat "$HERDR_STUB_LOG")"
fi

echo ""
echo "[F] Fallo de 'herdr agent start' en los 2 intentos: reintenta y degrada sin abortar (mecanica actual)"

export HERDR_STUB_AGENT_START_FAIL=1
run_workspace "$FAKE_MEFISTO"
unset HERDR_STUB_AGENT_START_FAIL

if [ "$LAST_RC" -eq 0 ]; then
    pass "F-1: el workspace se crea igual (rc=$LAST_RC) aunque el agente no arranque"
else
    fail "F-1: no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"
fi
ATTEMPTS_PLANNER=$(grep -cF "agent start planner-fake-mefisto-re-claude" "$HERDR_STUB_LOG")
if [ "$ATTEMPTS_PLANNER" -eq 2 ]; then
    pass "F-2: reintenta exactamente una vez tras el primer fallo (2 intentos)"
else
    fail "F-2: se esperaban 2 intentos, hubo $ATTEMPTS_PLANNER -- log: $(cat "$HERDR_STUB_LOG")"
fi
if printf '%s\n%s' "$LAST_STDOUT" "$LAST_STDERR" | grep -qF "No se pudo lanzar 'planner-fake-mefisto-re-claude'"; then
    pass "F-3: degrada con el aviso de fallo tras 2 intentos"
else
    fail "F-3: no aviso la degradacion -- stdout: $LAST_STDOUT / stderr: $LAST_STDERR"
fi
if printf '%s\n%s' "$LAST_STDOUT" "$LAST_STDERR" | grep -qF "lanza ahi 'claude --agent mefisto-planner' a mano"; then
    pass "F-4: el aviso nombra el runtime activo (claude) para lanzarlo a mano"
else
    fail "F-4: el aviso no nombro el runtime -- stdout: $LAST_STDOUT / stderr: $LAST_STDERR"
fi

echo ""
echo "[G] Reabrir un workspace ya montado con MEFISTO_RUNTIME=opencode: solo lo enfoca (CA-5)"

export MEFISTO_RUNTIME=opencode
export HERDR_STUB_EXISTING_LABEL="fake-mefisto-repo"
run_workspace "$FAKE_MEFISTO"
unset MEFISTO_RUNTIME HERDR_STUB_EXISTING_LABEL

if [ "$LAST_RC" -eq 0 ]; then
    pass "G-1: sale limpio al enfocar el workspace existente (rc=$LAST_RC)"
else
    fail "G-1: no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"
fi
if grep -qxF "herdr workspace focus w-existente" "$HERDR_STUB_LOG"; then
    pass "G-2: enfoca el workspace ya montado"
else
    fail "G-2: no enfoco el workspace existente -- log: $(cat "$HERDR_STUB_LOG")"
fi
if ! grep -qF "agent start" "$HERDR_STUB_LOG" && ! grep -qF "pane split" "$HERDR_STUB_LOG"; then
    pass "G-3: no duplica panes ni agentes (sin 'pane split' ni 'agent start')"
else
    fail "G-3: duplico panes o agentes -- log: $(cat "$HERDR_STUB_LOG")"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
