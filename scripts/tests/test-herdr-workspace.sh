#!/usr/bin/env bash
# test-herdr-workspace.sh -- Tests de herdr-workspace.sh: funciones puras
# (issue #691) + subproceso real con stub de `herdr` para la seleccion de
# runtime (MEFISTO_RUNTIME, issue #875) y las dos filas por runtime
# (issue #931).
#
# Dos estilos combinados:
#   - Funciones puras (bloques [A]/[B], estilo test-stream-watch.sh): se
#     extrae SOLO el cuerpo de cada funcion (awk sobre "nombre() {" .. "}" en
#     columna 0) y se evalua en este proceso, sin sourcing el archivo
#     completo (su main llama a herdr; estas piezas no).
#   - Subproceso real con stub (bloques [C]-[J], estilo
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
#       para planner/ejecucion recortado por el prefijo mas largo, y piso del
#       tope ante un kind absurdamente largo (#930 CA-2, CA-4).
#   [B] planner_agent_for_repo: mefisto-planner en el repo del plugin
#       (.claude-plugin/plugin.json presente), mefisto:planner en un consumidor.
#   [C] Repo de Mefisto, primera invocacion (workspace inexistente), runtime
#       default (MEFISTO_RUNTIME sin fijar): orden y argumentos completos --
#       workspace create CON --env (siempre, issue #931), split down (ancla,
#       sin --env), rename ancla "fila libre", split right (ejecucion, CON
#       --env), renames "planner [claude]"/"ejecucion [claude]" (#931 CA-1).
#   [D] Igual que [C] pero con MEFISTO_RUNTIME=opencode: mismo shape con el
#       kind sufijado en labels/nombres/--env (CA-1).
#   [E] Repo de Mefisto, segunda invocacion (workspace ya montado con la fila
#       de "claude", sin fila "opencode"): localiza el ancla, monta la fila
#       nueva encadenada (ancla -> planner -> ejecucion), cierra el ancla, y
#       no toca ningun pane de la fila 1 (CA-2).
#   [F] Repo de Mefisto, reinvocar un runtime cuya fila YA existe: solo
#       enfoca -- sin split, sin agent start, deteccion por label de pane
#       (CA-3; reemplaza el test [G] de la version anterior).
#   [G] Repo de Mefisto, falta el pane ancla ('fila libre') al pedir una fila
#       nueva: aborta con un mensaje que indica cerrar y reabrir el
#       workspace, SIN ningun pane split (CA-4).
#   [H] Repo consumidor con MEFISTO_RUNTIME=opencode: aviso + fallback a
#       claude, sin ancla, un solo split right, sin --env, labels sin sufijo
#       -- layout de hoy byte a byte (CA-5).
#   [I] Repo consumidor: reabrir un workspace ya montado solo lo enfoca (sin
#       pane split ni agent start), con cualquier runtime.
#   [J] Fallo de `herdr agent start` en los 2 intentos (fila 1 del repo de
#       Mefisto): reintenta una vez y degrada con aviso sin abortar el
#       workspace (mecanica de #875, preservada tras el ancla de #931).
#   [K] Fallo del primer `pane split` al montar la fila 2: aborta con el
#       aviso accionable (no con un "unbound variable" de bash) y NO cierra
#       el ancla, para que reinvocar siga siendo la salida.
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
echo "[A] workspace_slug: minusculas, caracteres raros a '-', extremos limpios, tope de 20 parametrizable"

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
echo "[A2] agent_name_for_role: rol-slug[-kind], mismo slug para planner/ejecucion (#930 CA-2, CA-4)"

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

NAME_A2_4=$(agent_name_for_role "planner" "eda-evsourcing-azure-harness" "unruntimeconunnombrelarguisimo" 2>&1)
RC_A2_4=$?
if [ "$RC_A2_4" -eq 0 ] && [ "$NAME_A2_4" = "planner-e-unruntimeconunnombrelarguisimo" ]; then
    pass "A2-4: un kind absurdamente largo no rompe el calculo del tope (piso de 1, sin error de cut)"
else
    fail "A2-4: rc=$RC_A2_4, salida: '$NAME_A2_4'"
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

# -------- Bloques C-J: subproceso real con stub de herdr --------
#
# Repos de mentira y stub dentro de $TMP (compartiendo el trap de limpieza de
# arriba). El stub registra "herdr $*" en HERDR_STUB_LOG y devuelve JSON
# determinista -- nunca toca un servidor herdr real. Todo corre sobre el
# workspace fijo "w1": el estado previo del workspace (que panes/labels ya
# existen) se inyecta con HERDR_STUB_EXISTING_LABEL/HERDR_STUB_PANES en vez
# de hacer correr el script dos veces, para que cada bloque quede
# independiente de los demas.

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
#                        devuelve uno con ese label bajo workspace_id "w1"
#   workspace create  -> workspace_id w1, root_pane w1:p1
#   pane split        -> pane_id w1:p<N>, con N un contador que arranca en
#                        HERDR_STUB_SPLIT_START (default 2) y sube en cada
#                        split -- asi cada bloque controla que ids son
#                        "nuevos" sin chocar con los que ya inyecto via
#                        HERDR_STUB_PANES
#   pane list         -> panes de HERDR_STUB_PANES ("label1=pane_id1;...")
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
            echo "{\"result\":{\"workspaces\":[{\"workspace_id\":\"w1\",\"label\":\"$HERDR_STUB_EXISTING_LABEL\"}]}}"
        else
            echo '{"result":{"workspaces":[]}}'
        fi
        ;;
    "workspace create")
        echo '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:p1"}}}'
        ;;
    "pane split")
        if [ "${HERDR_STUB_SPLIT_FAIL:-0}" = "1" ]; then
            echo '{"error":"split_failed (stub)"}' >&2
            exit 1
        fi
        n=$(cat "$HERDR_STUB_SPLIT_COUNTER" 2>/dev/null || echo "${HERDR_STUB_SPLIT_START:-2}")
        echo $((n+1)) > "$HERDR_STUB_SPLIT_COUNTER"
        echo "{\"result\":{\"pane\":{\"pane_id\":\"w1:p$n\"}}}"
        ;;
    "pane list")
        {
            printf '{"result":{"panes":['
            first=1
            items=()
            IFS=';' read -ra items <<< "${HERDR_STUB_PANES:-}"
            # bash 3.2 (el /bin/bash de macOS) trata un array vacio como no
            # definido bajo `set -u`: sin el idiom `${a[@]+...}` este for
            # aborta el stub cuando HERDR_STUB_PANES no esta fijada.
            for item in "${items[@]+"${items[@]}"}"; do
                [ -n "$item" ] || continue
                lbl="${item%%=*}"
                pid="${item#*=}"
                [ "$first" -eq 1 ] || printf ','
                first=0
                printf '{"pane_id":"%s","label":"%s"}' "$pid" "$lbl"
            done
            printf ']}}'
        }
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
HERDR_STUB_SPLIT_COUNTER="$TMP/split-counter"
export HERDR_STUB_LOG HERDR_STUB_SPLIT_COUNTER

# Seam de la pausa entre el start fallido y el `agent get` que lo confirma: en
# produccion son 3s, y el bloque [J] la pagaria cuatro veces (2 intentos x 2
# agentes = 12s de reloj) sin ejercitar nada distinto.
export MEFISTO_AGENT_START_RETRY_PAUSE=0

LAST_STDOUT=""
LAST_STDERR=""
LAST_RC=0

# run_workspace <repo> [split_start]
#
# Corre el script REAL (no una funcion extraida) contra el repo indicado,
# con el stub de herdr primero en PATH. MEFISTO_RUNTIME/HERDR_STUB_* se
# heredan si el caller los exporto antes de llamar (mismo criterio que
# test-mefisto-herdr-pipeline.sh). Reinicia el log y el contador de split en
# cada corrida para que los bloques no se contaminen entre si.
run_workspace() {
    local target="$1" split_start="${2:-2}"
    : > "$HERDR_STUB_LOG"
    echo "$split_start" > "$HERDR_STUB_SPLIT_COUNTER"
    local out="$TMP/stdout" err="$TMP/stderr"
    (
        PATH="$FAKE_BIN:$PATH" "$TARGET_SCRIPT" "$target"
    ) </dev/null >"$out" 2>"$err"
    LAST_RC=$?
    LAST_STDOUT=$(cat "$out")
    LAST_STDERR=$(cat "$err")
}

echo ""
echo "[C] Repo de Mefisto, primera invocacion, runtime default (sin MEFISTO_RUNTIME): orden y args completos (CA-1)"

unset MEFISTO_RUNTIME HERDR_STUB_EXISTING_LABEL HERDR_STUB_PANES
run_workspace "$FAKE_MEFISTO"

if [ "$LAST_RC" -eq 0 ]; then
    pass "C-1: corre sin abortar (rc=$LAST_RC)"
else
    fail "C-1: no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"
fi

EXPECTED_C=$(cat <<EOF
herdr status server
herdr workspace list
herdr workspace create --cwd $FAKE_MEFISTO --label fake-mefisto-repo --env MEFISTO_RUNTIME=claude
herdr pane split --pane w1:p1 --direction down --cwd $FAKE_MEFISTO --no-focus
herdr pane rename w1:p2 fila libre
herdr pane split --pane w1:p1 --direction right --cwd $FAKE_MEFISTO --no-focus --env MEFISTO_RUNTIME=claude
herdr pane rename w1:p1 planner [claude]
herdr pane rename w1:p3 ejecucion [claude]
herdr pane process-info --pane w1:p1
herdr agent start planner-fake-mefisto-re-claude --kind claude --pane w1:p1 --timeout 90000 -- --agent mefisto-planner
herdr pane process-info --pane w1:p3
herdr agent start ejecucion-fake-mefisto-re-claude --kind claude --pane w1:p3 --timeout 90000
EOF
)
if [ "$(cat "$HERDR_STUB_LOG")" = "$EXPECTED_C" ]; then
    pass "C-2: orden y argumentos de TODAS las invocaciones calzan byte a byte (ancla + fila + agentes)"
else
    fail "C-2: log distinto del esperado.
--- esperado ---
$EXPECTED_C
--- obtenido ---
$(cat "$HERDR_STUB_LOG")"
fi

echo ""
echo "[D] Igual que [C] pero con MEFISTO_RUNTIME=opencode: mismo shape con el kind sufijado (CA-1)"

export MEFISTO_RUNTIME=opencode
run_workspace "$FAKE_MEFISTO"
unset MEFISTO_RUNTIME

if [ "$LAST_RC" -eq 0 ]; then
    pass "D-1: corre sin abortar (rc=$LAST_RC)"
else
    fail "D-1: no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"
fi
if grep -qxF "herdr pane split --pane w1:p1 --direction down --cwd $FAKE_MEFISTO --no-focus" "$HERDR_STUB_LOG"; then
    pass "D-2: el split del ancla nunca lleva --env, tampoco con opencode"
else
    fail "D-2: el split del ancla no calzo -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qxF "herdr pane rename w1:p2 fila libre" "$HERDR_STUB_LOG"; then
    pass "D-3: el ancla se etiqueta 'fila libre'"
else
    fail "D-3: no se encontro el rename del ancla -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qxF "herdr pane split --pane w1:p1 --direction right --cwd $FAKE_MEFISTO --no-focus --env MEFISTO_RUNTIME=opencode" "$HERDR_STUB_LOG"; then
    pass "D-4: el split de ejecucion lleva --env MEFISTO_RUNTIME=opencode"
else
    fail "D-4: no se encontro el split de ejecucion -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qxF "herdr pane rename w1:p1 planner [opencode]" "$HERDR_STUB_LOG" \
    && grep -qxF "herdr pane rename w1:p3 ejecucion [opencode]" "$HERDR_STUB_LOG"; then
    pass "D-5: los labels de la fila llevan el kind sufijado"
else
    fail "D-5: labels inesperados -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qxF "herdr agent start planner-fake-mefisto-opencode --kind opencode --pane w1:p1 --timeout 90000 -- --agent mefisto-planner" "$HERDR_STUB_LOG"; then
    pass "D-6: el agente del planner arranca --kind opencode con nombre sufijado"
else
    fail "D-6: no se encontro la invocacion esperada -- log: $(cat "$HERDR_STUB_LOG")"
fi

echo ""
echo "[E] Repo de Mefisto, segunda invocacion (fila 'claude' montada, sin fila 'opencode'): monta encadenado y cierra el ancla (CA-2)"

export HERDR_STUB_EXISTING_LABEL="fake-mefisto-repo"
export HERDR_STUB_PANES="planner [claude]=w1:p1;ejecucion [claude]=w1:p3;fila libre=w1:p2"
export MEFISTO_RUNTIME=opencode
run_workspace "$FAKE_MEFISTO" 4
unset HERDR_STUB_EXISTING_LABEL HERDR_STUB_PANES MEFISTO_RUNTIME

if [ "$LAST_RC" -eq 0 ]; then
    pass "E-1: corre sin abortar (rc=$LAST_RC)"
else
    fail "E-1: no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"
fi
if grep -qxF "herdr pane split --pane w1:p2 --direction right --cwd $FAKE_MEFISTO --no-focus --env MEFISTO_RUNTIME=opencode" "$HERDR_STUB_LOG"; then
    pass "E-2: primer split parte del ANCLA (w1:p2), no de un pane de la fila 1"
else
    fail "E-2: no se encontro el split del ancla -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qxF "herdr pane split --pane w1:p4 --direction right --cwd $FAKE_MEFISTO --no-focus --env MEFISTO_RUNTIME=opencode" "$HERDR_STUB_LOG"; then
    pass "E-3: segundo split parte del planner NUEVO (w1:p4), encadenado -- no del ancla otra vez"
else
    fail "E-3: no se encontro el segundo split encadenado -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qxF "herdr pane close w1:p2" "$HERDR_STUB_LOG"; then
    pass "E-4: el ancla (w1:p2) se cierra tras montar la fila"
else
    fail "E-4: no se cerro el ancla -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qxF "herdr pane rename w1:p4 planner [opencode]" "$HERDR_STUB_LOG" \
    && grep -qxF "herdr pane rename w1:p5 ejecucion [opencode]" "$HERDR_STUB_LOG"; then
    pass "E-5: la fila nueva se etiqueta planner/ejecucion [opencode]"
else
    fail "E-5: labels inesperados -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qxF "herdr agent start planner-fake-mefisto-opencode --kind opencode --pane w1:p4 --timeout 90000 -- --agent mefisto-planner" "$HERDR_STUB_LOG" \
    && grep -qxF "herdr agent start ejecucion-fake-mefisto-opencode --kind opencode --pane w1:p5 --timeout 90000" "$HERDR_STUB_LOG"; then
    pass "E-6: los agentes de la fila nueva arrancan --kind opencode en los panes nuevos"
else
    fail "E-6: agent start inesperado -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qF "rename w1:p1" "$HERDR_STUB_LOG" || grep -qF "rename w1:p3" "$HERDR_STUB_LOG" \
    || grep -qF "close w1:p1" "$HERDR_STUB_LOG" || grep -qF "close w1:p3" "$HERDR_STUB_LOG" \
    || grep -qF "agent start planner-fake-mefisto-re-claude" "$HERDR_STUB_LOG" \
    || grep -qF "agent start ejecucion-fake-mefisto-re-claude" "$HERDR_STUB_LOG"; then
    fail "E-7: algo toco un pane de la fila 1 (claude) -- log: $(cat "$HERDR_STUB_LOG")"
else
    pass "E-7: ningun rename/close/agent start toca los panes de la fila 1"
fi

echo ""
echo "[F] Repo de Mefisto, reinvocar un runtime cuya fila YA existe: solo enfoca (CA-3)"

export HERDR_STUB_EXISTING_LABEL="fake-mefisto-repo"
export HERDR_STUB_PANES="planner [claude]=w1:p1;ejecucion [claude]=w1:p3;fila libre=w1:p2"
run_workspace "$FAKE_MEFISTO"
unset HERDR_STUB_EXISTING_LABEL HERDR_STUB_PANES

if [ "$LAST_RC" -eq 0 ]; then
    pass "F-1: sale limpio al enfocar la fila existente (rc=$LAST_RC)"
else
    fail "F-1: no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"
fi
if grep -qxF "herdr workspace focus w1" "$HERDR_STUB_LOG"; then
    pass "F-2: enfoca el workspace ya montado"
else
    fail "F-2: no enfoco el workspace -- log: $(cat "$HERDR_STUB_LOG")"
fi
if ! grep -qF "pane split" "$HERDR_STUB_LOG" && ! grep -qF "agent start" "$HERDR_STUB_LOG"; then
    pass "F-3: no duplica panes ni agentes (sin 'pane split' ni 'agent start')"
else
    fail "F-3: duplico panes o agentes -- log: $(cat "$HERDR_STUB_LOG")"
fi

echo ""
echo "[G] Repo de Mefisto, sin pane ancla al pedir una fila nueva: aborta sin ningun split (CA-4)"

export HERDR_STUB_EXISTING_LABEL="fake-mefisto-repo"
export HERDR_STUB_PANES="planner [claude]=w1:p1;ejecucion [claude]=w1:p3"
export MEFISTO_RUNTIME=opencode
run_workspace "$FAKE_MEFISTO"
unset HERDR_STUB_EXISTING_LABEL HERDR_STUB_PANES MEFISTO_RUNTIME

if [ "$LAST_RC" -ne 0 ]; then
    pass "G-1: aborta (rc=$LAST_RC)"
else
    fail "G-1: deberia abortar sin el ancla (rc=$LAST_RC)"
fi
if printf '%s\n%s' "$LAST_STDOUT" "$LAST_STDERR" | grep -qi "cierra.*workspace"; then
    pass "G-2: el mensaje indica cerrar y reabrir el workspace"
else
    fail "G-2: el mensaje no indico cerrar el workspace -- stdout: $LAST_STDOUT / stderr: $LAST_STDERR"
fi
if grep -qF "pane split" "$HERDR_STUB_LOG"; then
    fail "G-3: hizo un pane split sin ancla -- nunca deberia anidar la fila 2 bajo la fila 1 -- log: $(cat "$HERDR_STUB_LOG")"
else
    pass "G-3: ningun pane split -- nunca anida la fila 2 bajo la fila 1"
fi

echo ""
echo "[H] Repo consumidor con MEFISTO_RUNTIME=opencode: aviso + fallback a claude, layout de hoy byte a byte (CA-5)"

export MEFISTO_RUNTIME=opencode
run_workspace "$FAKE_CONSUMER"
unset MEFISTO_RUNTIME

if [ "$LAST_RC" -eq 0 ]; then
    pass "H-1: corre sin abortar (rc=$LAST_RC)"
else
    fail "H-1: no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"
fi
if printf '%s\n%s' "$LAST_STDOUT" "$LAST_STDERR" | grep -q "El plugin publicado aun no soporta OpenCode"; then
    pass "H-2: avisa que el plugin publicado aun no soporta OpenCode"
else
    fail "H-2: no aviso -- stdout: $LAST_STDOUT / stderr: $LAST_STDERR"
fi
if grep -qxF "herdr workspace create --cwd $FAKE_CONSUMER --label fake-consumer-repo" "$HERDR_STUB_LOG"; then
    pass "H-3: workspace create sin --env (el consumidor no cambia)"
else
    fail "H-3: workspace create no coincide byte a byte -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qF "pane split --pane w1:p1 --direction down" "$HERDR_STUB_LOG"; then
    fail "H-4: el consumidor NUNCA debe reservar un ancla -- log: $(cat "$HERDR_STUB_LOG")"
else
    pass "H-4: sin ancla -- un solo split (right)"
fi
if grep -qxF "herdr pane split --pane w1:p1 --direction right --cwd $FAKE_CONSUMER --no-focus" "$HERDR_STUB_LOG"; then
    pass "H-5: el unico split es right, sin --env"
else
    fail "H-5: el split no coincide byte a byte -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qxF "herdr pane rename w1:p1 planner" "$HERDR_STUB_LOG" && grep -qxF "herdr pane rename w1:p2 ejecucion" "$HERDR_STUB_LOG"; then
    pass "H-6: labels sin sufijo ('planner'/'ejecucion')"
else
    fail "H-6: labels inesperados -- log: $(cat "$HERDR_STUB_LOG")"
fi
if grep -qxF "herdr agent start planner-fake-consumer-repo --kind claude --pane w1:p1 --timeout 90000 -- --agent mefisto:planner" "$HERDR_STUB_LOG"; then
    pass "H-7: el planner arranca --kind claude (fallback) con el agente publicado mefisto:planner"
else
    fail "H-7: no se encontro la invocacion esperada -- log: $(cat "$HERDR_STUB_LOG")"
fi

echo ""
echo "[I] Repo consumidor: reabrir un workspace ya montado solo lo enfoca"

export HERDR_STUB_EXISTING_LABEL="fake-consumer-repo"
export MEFISTO_RUNTIME=opencode
run_workspace "$FAKE_CONSUMER"
unset HERDR_STUB_EXISTING_LABEL MEFISTO_RUNTIME

if [ "$LAST_RC" -eq 0 ]; then
    pass "I-1: sale limpio al enfocar el workspace existente (rc=$LAST_RC)"
else
    fail "I-1: no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"
fi
if grep -qxF "herdr workspace focus w1" "$HERDR_STUB_LOG"; then
    pass "I-2: enfoca el workspace ya montado"
else
    fail "I-2: no enfoco el workspace existente -- log: $(cat "$HERDR_STUB_LOG")"
fi
if ! grep -qF "agent start" "$HERDR_STUB_LOG" && ! grep -qF "pane split" "$HERDR_STUB_LOG"; then
    pass "I-3: no duplica panes ni agentes (sin 'pane split' ni 'agent start')"
else
    fail "I-3: duplico panes o agentes -- log: $(cat "$HERDR_STUB_LOG")"
fi
if printf '%s\n%s' "$LAST_STDOUT" "$LAST_STDERR" | grep -q "El plugin publicado aun no soporta OpenCode"; then
    pass "I-4: avisa el MEFISTO_RUNTIME ignorado tambien al reenfocar (comportamiento de #875)"
else
    fail "I-4: no aviso al reenfocar -- stdout: $LAST_STDOUT / stderr: $LAST_STDERR"
fi

echo ""
echo "[J] Fallo de 'herdr agent start' en los 2 intentos (fila 1, repo de Mefisto): reintenta y degrada sin abortar"

unset MEFISTO_RUNTIME HERDR_STUB_EXISTING_LABEL HERDR_STUB_PANES
export HERDR_STUB_AGENT_START_FAIL=1
run_workspace "$FAKE_MEFISTO"
unset HERDR_STUB_AGENT_START_FAIL

if [ "$LAST_RC" -eq 0 ]; then
    pass "J-1: el workspace se crea igual (rc=$LAST_RC) aunque el agente no arranque"
else
    fail "J-1: no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"
fi
ATTEMPTS_PLANNER=$(grep -cF "agent start planner-fake-mefisto-re-claude" "$HERDR_STUB_LOG")
if [ "$ATTEMPTS_PLANNER" -eq 2 ]; then
    pass "J-2: reintenta exactamente una vez tras el primer fallo (2 intentos)"
else
    fail "J-2: se esperaban 2 intentos, hubo $ATTEMPTS_PLANNER -- log: $(cat "$HERDR_STUB_LOG")"
fi
if printf '%s\n%s' "$LAST_STDOUT" "$LAST_STDERR" | grep -qF "No se pudo lanzar 'planner-fake-mefisto-re-claude'"; then
    pass "J-3: degrada con el aviso de fallo tras 2 intentos"
else
    fail "J-3: no aviso la degradacion -- stdout: $LAST_STDOUT / stderr: $LAST_STDERR"
fi
if printf '%s\n%s' "$LAST_STDOUT" "$LAST_STDERR" | grep -qF "lanza ahi 'claude --agent mefisto-planner' a mano"; then
    pass "J-4: el aviso nombra el runtime activo (claude) para lanzarlo a mano"
else
    fail "J-4: el aviso no nombro el runtime -- stdout: $LAST_STDOUT / stderr: $LAST_STDERR"
fi

echo ""
echo "[K] Fallo del primer 'pane split' al montar la fila 2: aborta con aviso accionable y deja el ancla en pie"

export HERDR_STUB_EXISTING_LABEL="fake-mefisto-repo"
export HERDR_STUB_PANES="planner [claude]=w1:p1;ejecucion [claude]=w1:p3;fila libre=w1:p2"
export MEFISTO_RUNTIME=opencode
export HERDR_STUB_SPLIT_FAIL=1
run_workspace "$FAKE_MEFISTO"
unset HERDR_STUB_EXISTING_LABEL HERDR_STUB_PANES MEFISTO_RUNTIME HERDR_STUB_SPLIT_FAIL

if [ "$LAST_RC" -ne 0 ]; then
    pass "K-1: aborta cuando el split de la fila 2 falla (rc=$LAST_RC)"
else
    fail "K-1: deberia abortar (rc=$LAST_RC)"
fi
if printf '%s\n%s' "$LAST_STDOUT" "$LAST_STDERR" | grep -qF "No se pudo crear el pane del planner de la fila 'opencode'"; then
    pass "K-2: el aviso es el del script, no un 'unbound variable' de bash"
else
    fail "K-2: no salio el aviso del script -- stdout: $LAST_STDOUT / stderr: $LAST_STDERR"
fi
if printf '%s\n%s' "$LAST_STDOUT" "$LAST_STDERR" | grep -qi "unbound variable"; then
    fail "K-3: el script murio por 'unbound variable' -- stderr: $LAST_STDERR"
else
    pass "K-3: ningun 'unbound variable' (p_planner nace vacia, no solo declarada)"
fi
if grep -qF "pane close" "$HERDR_STUB_LOG"; then
    fail "K-4: cerro el ancla pese a no haber montado la fila -- log: $(cat "$HERDR_STUB_LOG")"
else
    pass "K-4: el ancla queda en pie: reinvocar sigue siendo la salida"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
