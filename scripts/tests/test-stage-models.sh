#!/usr/bin/env bash
# test-stage-models.sh -- Tests del mecanismo de asignacion de modelo por stage
# (--models, issue #708) en scripts/_pipeline-common.sh y scripts/tmux-pipeline.sh.
#
# Cubre:
#   parse_stage_models    - spec vacio (no --models: comportamiento actual
#                            intacto), spec valido de 1 y N entradas, y las tres
#                            formas de entrada malformada (CA-1: sin '=', clave o
#                            valor vacio, agente repetido) -- todas abortan con un
#                            mensaje en PIPELINE_STAGE_MODELS_ERROR, sin imprimir
#                            nada por si misma.
#   resolve_stage_model    - override por clave exacta, sin match cae al default,
#                            y sin --models (mapa vacio) siempre el default (CA-2:
#                            byte a byte el comportamiento previo al flag).
#   format_stage_models_for_log - formato de auditoria (CA-4), vacio sin mapa.
#   tmux-pipeline.sh        - --tooling reenvia --models intacto al send-keys
#                            (CA-3); el resto de los modos lo rechazan con
#                            mensaje explicito en vez de tragarselo en silencio.
#
# Uso: scripts/tests/test-stage-models.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Las funciones viven en _pipeline-common.sh; sourcearlo solo las define (es una
# libreria, no ejecuta nada), asi que es seguro incluso dentro del repo de Mefisto.
set +u
source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null
set -u

echo "[1] parse_stage_models: spec vacio deja el mapa vacio y no aborta (CA-2: sin --models, nada cambia)"
if parse_stage_models ""; then pass "spec vacio retorna 0"; else fail "spec vacio no deberia abortar"; fi
if [ -z "$PIPELINE_STAGE_MODELS" ]; then pass "mapa vacio"; else fail "mapa deberia quedar vacio (obtenido '$PIPELINE_STAGE_MODELS')"; fi

echo ""
echo "[2] parse_stage_models: spec valido de una entrada"
if parse_stage_models "reviewer=opus"; then pass "una entrada retorna 0"; else fail "una entrada valida no deberia abortar"; fi
if [ "$PIPELINE_STAGE_MODELS" = "reviewer=opus" ]; then pass "mapa contiene la entrada"; else fail "mapa incorrecto: '$PIPELINE_STAGE_MODELS'"; fi

echo ""
echo "[3] parse_stage_models: spec valido de N entradas, separadas por coma"
if parse_stage_models "writer=sonnet,reviewer=opus"; then pass "dos entradas retorna 0"; else fail "dos entradas validas no deberia abortar"; fi
R=$(resolve_stage_model "writer" "default-no-usado")
if [ "$R" = "sonnet" ]; then pass "writer resuelve a sonnet"; else fail "writer deberia resolver a sonnet (obtenido '$R')"; fi
R=$(resolve_stage_model "reviewer" "default-no-usado")
if [ "$R" = "opus" ]; then pass "reviewer resuelve a opus"; else fail "reviewer deberia resolver a opus (obtenido '$R')"; fi

echo ""
echo "[4] parse_stage_models: id de modelo completo con caracteres especiales (sin allowlist de nombres)"
if parse_stage_models 'writer=claude-opus-5[1m]'; then pass "id completo con [] retorna 0"; else fail "un id de modelo completo no deberia abortar (sin allowlist propia)"; fi
R=$(resolve_stage_model "writer" "default-no-usado")
if [ "$R" = "claude-opus-5[1m]" ]; then pass "resuelve el id completo tal cual"; else fail "deberia resolver 'claude-opus-5[1m]' (obtenido '$R')"; fi

echo ""
echo "[5] parse_stage_models: entrada sin '=' aborta con mensaje claro (CA-1)"
if parse_stage_models "reviewer-opus"; then fail "entrada sin '=' no deberia retornar 0"; else pass "entrada sin '=' aborta"; fi
if printf '%s' "$PIPELINE_STAGE_MODELS_ERROR" | grep -q "reviewer-opus"; then pass "el error nombra la entrada malformada"; else fail "PIPELINE_STAGE_MODELS_ERROR no menciona la entrada: '$PIPELINE_STAGE_MODELS_ERROR'"; fi

echo ""
echo "[6] parse_stage_models: clave o valor vacio aborta (CA-1)"
if parse_stage_models "=opus"; then fail "clave vacia no deberia retornar 0"; else pass "clave vacia aborta"; fi
if parse_stage_models "reviewer="; then fail "valor vacio no deberia retornar 0"; else pass "valor vacio aborta"; fi

echo ""
echo "[7] parse_stage_models: agente repetido aborta (CA-1)"
if parse_stage_models "writer=sonnet,writer=opus"; then fail "agente repetido no deberia retornar 0"; else pass "agente repetido aborta"; fi
if printf '%s' "$PIPELINE_STAGE_MODELS_ERROR" | grep -q "writer"; then pass "el error nombra el agente repetido"; else fail "PIPELINE_STAGE_MODELS_ERROR no menciona 'writer': '$PIPELINE_STAGE_MODELS_ERROR'"; fi

echo ""
echo "[8] resolve_stage_model: sin match en el mapa, cae al default"
parse_stage_models "reviewer=opus" >/dev/null
R=$(resolve_stage_model "writer" "sonnet")
if [ "$R" = "sonnet" ]; then pass "writer sin override resuelve al default"; else fail "deberia caer al default 'sonnet' (obtenido '$R')"; fi

echo ""
echo "[9] resolve_stage_model: sin --models (mapa vacio), siempre el default -- byte a byte el comportamiento previo (CA-2)"
parse_stage_models "" >/dev/null
R=$(resolve_stage_model "reviewer" "opus")
if [ "$R" = "opus" ]; then pass "reviewer sin mapa resuelve al default 'opus'"; else fail "deberia resolver al default (obtenido '$R')"; fi
R=$(resolve_stage_model "writer" "sonnet")
if [ "$R" = "sonnet" ]; then pass "writer sin mapa resuelve al default 'sonnet'"; else fail "deberia resolver al default (obtenido '$R')"; fi
R=$(resolve_stage_model "merge-writer" "sonnet")
if [ "$R" = "sonnet" ]; then pass "la etapa de merge (default '*' del case) tambien resuelve al default"; else fail "deberia resolver al default (obtenido '$R')"; fi

echo ""
echo "[10] format_stage_models_for_log: vacio sin mapa, formateado con mapa (CA-4)"
parse_stage_models "" >/dev/null
R=$(format_stage_models_for_log)
if [ -z "$R" ]; then pass "sin mapa, formato vacio"; else fail "deberia ser vacio sin --models (obtenido '$R')"; fi
parse_stage_models "writer=sonnet,reviewer=opus" >/dev/null
R=$(format_stage_models_for_log)
if [ "$R" = "writer=sonnet, reviewer=opus" ]; then pass "formato de auditoria: 'writer=sonnet, reviewer=opus'"; else fail "formato incorrecto: '$R'"; fi

echo ""
echo "----------------------------------------"
echo "  _pipeline-common.sh: $PASS pass, $FAIL fail (hasta aqui)"
echo "----------------------------------------"

# --- tmux-pipeline.sh: reenvio/rechazo de --models por modo (CA-3) -----------
#
# Mismo arnes que test-tmux-preparse.sh: consumidor falso (git init sin
# .claude-plugin/plugin.json) para pasar el guard defensivo, stub de tmux en
# PATH que nunca toca un servidor real, y MEFISTO_UI=tmux para no delegar a la
# interfaz herdr si el test corre dentro de un pane herdr.
export MEFISTO_UI=tmux
TMUX_SCRIPT="$REPO_ROOT/scripts/tmux-pipeline.sh"

FAKE_CONSUMER="$(mktemp -d)"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
trap 'rm -rf "$FAKE_CONSUMER" "$TMP_DIR"' EXIT

(cd "$FAKE_CONSUMER" && git init -q)

cat > "$FAKE_BIN/tmux" <<'STUB'
#!/usr/bin/env bash
set -u
echo "tmux $*" >> "$TMUX_STUB_LOG"
case "${1:-}" in
    has-session)
        exit 1
        ;;
    list-panes)
        for a in "$@"; do
            if [ "$a" = "#{pane_dead}" ]; then
                echo "0"
                exit 0
            fi
        done
        echo "%0"
        ;;
    split-window)
        echo "%1"
        ;;
    *)
        exit 0
        ;;
esac
STUB
chmod +x "$FAKE_BIN/tmux"

export TMUX_STUB_LOG="$TMP_DIR/tmux.log"

LAST_STDOUT=""
LAST_STDERR=""
LAST_RC=0

run_wrapper() {
    : > "$TMUX_STUB_LOG"
    local out="$TMP_DIR/stdout" err="$TMP_DIR/stderr"
    (
        cd "$FAKE_CONSUMER" || exit 99
        PATH="$FAKE_BIN:$PATH" "$TMUX_SCRIPT" "$@"
    ) </dev/null >"$out" 2>"$err"
    LAST_RC=$?
    LAST_STDOUT=$(cat "$out")
    LAST_STDERR=$(cat "$err")
}

echo ""
echo "[11] --tooling reenvia --models intacto al send-keys (CA-3)"
run_wrapper --tooling 253 --models "writer=sonnet,reviewer=opus"
if [ "$LAST_RC" -eq 0 ]; then pass "--tooling + --models corre sin abortar (rc=$LAST_RC)"; else fail "--tooling + --models no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
if grep -qF "253 --models 'writer=sonnet,reviewer=opus'" "$TMUX_STUB_LOG"; then
    pass "send-keys incluye el issue y --models con comillas simples intacto"
else
    fail "send-keys no compuso '253 --models ...' -- log: $(cat "$TMUX_STUB_LOG")"
fi

echo ""
echo "[12] --tooling combina --from-stage y --models en orden"
run_wrapper --tooling 253 --from-stage 2 --models "reviewer=opus"
if [ "$LAST_RC" -eq 0 ]; then pass "combinado corre sin abortar"; else fail "no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
if grep -qF "253 --from-stage 2 --models 'reviewer=opus'" "$TMUX_STUB_LOG"; then
    pass "send-keys combina --from-stage y --models en orden"
else
    fail "orden incorrecto -- log: $(cat "$TMUX_STUB_LOG")"
fi

echo ""
echo "[13] --models sin valor aborta con mensaje claro"
run_wrapper --tooling 253 --models
if [ "$LAST_RC" -eq 1 ]; then pass "--models sin valor aborta"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "Falta el valor de --models"; then pass "mensaje: falta el valor"; else fail "mensaje inesperado: $LAST_STDERR"; fi

echo ""
echo "[14] --models se rechaza (nunca se traga en silencio) en modos sin soporte todavia"

run_wrapper --infra 253 --models "writer=sonnet"
if [ "$LAST_RC" -eq 1 ]; then pass "--infra + --models aborta"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "no es valido con --infra"; then pass "mensaje: no valido con --infra"; else fail "mensaje inesperado: $LAST_STDERR"; fi

run_wrapper --scaffold 253 --domain miDominio --models "writer=sonnet"
if [ "$LAST_RC" -eq 1 ]; then pass "--scaffold + --models aborta"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "no es valido con --scaffold"; then pass "mensaje: no valido con --scaffold"; else fail "mensaje inesperado: $LAST_STDERR"; fi

run_wrapper --batch 253 254 --models "writer=sonnet" --pipeline tooling
if [ "$LAST_RC" -eq 1 ]; then pass "--batch + --models aborta"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "no es valido con --batch"; then pass "mensaje: no valido con --batch"; else fail "mensaje inesperado: $LAST_STDERR"; fi

run_wrapper --parallel 253 254 --models "writer=sonnet" --pipeline tooling
if [ "$LAST_RC" -eq 1 ]; then pass "--parallel + --models aborta"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "no es valido con --parallel"; then pass "mensaje: no valido con --parallel"; else fail "mensaje inesperado: $LAST_STDERR"; fi

run_wrapper --attach tooling-pipeline-253 --models "writer=sonnet"
if [ "$LAST_RC" -eq 1 ]; then pass "--attach + --models aborta"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "no aplica a --attach"; then pass "mensaje: no aplica a --attach"; else fail "mensaje inesperado: $LAST_STDERR"; fi

run_wrapper 253 --models "writer=sonnet" --pipeline tooling
if [ "$LAST_RC" -eq 1 ]; then pass "issue suelto (sin --tooling) + --models aborta"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "solo esta soportado hoy via --tooling"; then pass "mensaje: solo soportado via --tooling"; else fail "mensaje inesperado: $LAST_STDERR"; fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
