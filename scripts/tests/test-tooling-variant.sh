#!/usr/bin/env bash
# test-tooling-variant.sh -- Tests del modo --variant (corridas paralelas del
# mismo issue, issue #710) en scripts/_pipeline-common.sh, scripts/tmux-pipeline.sh
# y scripts/herdr-pipeline.sh.
#
# Cubre:
#   validate_variant_label - vacio, longitud (40 chars limite, 41 rechazado),
#                            caracteres validos ([a-z0-9-]) e invalidos
#                            (mayusculas, espacios, guion bajo, unicode) -- todos
#                            los casos invalidos dejan el motivo en
#                            PIPELINE_VARIANT_LABEL_ERROR (CA-1), sin imprimir
#                            nada por si misma.
#   tmux-pipeline.sh        - --tooling reenvia --variant intacto al send-keys,
#                            combinado con --from-stage/--models en orden, y el
#                            nombre de sesion tmux lleva el sufijo -<label>
#                            (CA-2). --variant sin valor aborta. El enrutamiento
#                            automatico de un unico issue (sin --tooling
#                            explicito) TAMBIEN lo acepta y lo reenvia (issue
#                            #713: tdd-pipeline.sh suma el flag, ya no es
#                            exclusivo de --tooling/tooling-pipeline.sh) --
#                            cubierto en detalle por test-tdd-variant.sh. El
#                            resto de los modos (--infra, --scaffold, --batch,
#                            --parallel, --attach, multiples issues) lo sigue
#                            rechazando con mensaje explicito: serian ambiguos
#                            sobre un lote, o el sub-script destino no
#                            implementa el flag.
#   herdr-pipeline.sh       - misma superficie que tmux-pipeline.sh: --tooling
#                            y el enrutamiento automatico reenvian --variant al
#                            pane run (con --models combinado), y el resto de
#                            los modos lo rechaza.
#
# Uso: scripts/tests/test-tooling-variant.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# validate_variant_label vive en _pipeline-common.sh; sourcearlo solo la
# define (es una libreria, no ejecuta nada), asi que es seguro incluso dentro
# del repo de Mefisto.
set +u
source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null
set -u

echo "[1] validate_variant_label: label vacio se rechaza (CA-1)"
if validate_variant_label ""; then fail "label vacio no deberia retornar 0"; else pass "label vacio aborta"; fi
if printf '%s' "$PIPELINE_VARIANT_LABEL_ERROR" | grep -qi "vacio"; then pass "el error menciona 'vacio'"; else fail "PIPELINE_VARIANT_LABEL_ERROR inesperado: '$PIPELINE_VARIANT_LABEL_ERROR'"; fi

echo ""
echo "[2] validate_variant_label: label valido de una letra"
if validate_variant_label "a"; then pass "label de 1 char retorna 0"; else fail "'a' no deberia rechazarse"; fi

echo ""
echo "[3] validate_variant_label: slug tipico valido"
if validate_variant_label "experimento-a"; then pass "'experimento-a' retorna 0"; else fail "'experimento-a' no deberia rechazarse"; fi

echo ""
echo "[4] validate_variant_label: limite de longitud (40 OK, 41 rechazado)"
LABEL_40=$(printf 'a%.0s' $(seq 1 40))
LABEL_41=$(printf 'a%.0s' $(seq 1 41))
if [ "${#LABEL_40}" -eq 40 ] && [ "${#LABEL_41}" -eq 41 ]; then pass "fixtures de longitud correctas"; else fail "fixtures mal construidas"; fi
if validate_variant_label "$LABEL_40"; then pass "label de 40 chars retorna 0"; else fail "40 chars no deberia rechazarse"; fi
if validate_variant_label "$LABEL_41"; then fail "label de 41 chars no deberia retornar 0"; else pass "41 chars aborta"; fi
if printf '%s' "$PIPELINE_VARIANT_LABEL_ERROR" | grep -q "40 caracteres"; then pass "el error menciona el limite de 40 caracteres"; else fail "PIPELINE_VARIANT_LABEL_ERROR inesperado: '$PIPELINE_VARIANT_LABEL_ERROR'"; fi

echo ""
echo "[5] validate_variant_label: caracteres invalidos se rechazan (CA-1)"
for bad in "Experimento" "experimento_a" "experimento a" "experimento.a" "a/b"; do
    if validate_variant_label "$bad"; then
        fail "'$bad' no deberia retornar 0"
    else
        pass "'$bad' aborta"
    fi
    if printf '%s' "$PIPELINE_VARIANT_LABEL_ERROR" | grep -qF "$bad"; then
        pass "el error nombra el label invalido '$bad'"
    else
        fail "PIPELINE_VARIANT_LABEL_ERROR no menciona '$bad': '$PIPELINE_VARIANT_LABEL_ERROR'"
    fi
done

echo ""
echo "[6] validate_variant_label: digitos y guiones solos son validos"
if validate_variant_label "123-456"; then pass "'123-456' retorna 0"; else fail "'123-456' no deberia rechazarse"; fi

echo ""
echo "----------------------------------------"
echo "  _pipeline-common.sh: $PASS pass, $FAIL fail (hasta aqui)"
echo "----------------------------------------"

# --- tmux-pipeline.sh: reenvio/rechazo de --variant por modo (CA-2/CA-5) -----
#
# Mismo arnes que test-stage-models.sh: consumidor falso (git init sin
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
echo "[7] --tooling reenvia --variant intacto al send-keys, y el nombre de sesion lleva el sufijo (CA-2)"
run_wrapper --tooling 253 --variant experimento-a
if [ "$LAST_RC" -eq 0 ]; then pass "--tooling + --variant corre sin abortar (rc=$LAST_RC)"; else fail "--tooling + --variant no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
if grep -qF "253 --variant 'experimento-a'" "$TMUX_STUB_LOG"; then
    pass "send-keys incluye el issue y --variant con comillas simples intacto"
else
    fail "send-keys no compuso '253 --variant ...' -- log: $(cat "$TMUX_STUB_LOG")"
fi
if grep -qF "new-session -d -s tooling-253-experimento-a" "$TMUX_STUB_LOG"; then
    pass "la sesion tmux lleva el sufijo -experimento-a"
else
    fail "la sesion no lleva el sufijo -- log: $(cat "$TMUX_STUB_LOG")"
fi

echo ""
echo "[8] --tooling combina --from-stage, --models y --variant en orden"
run_wrapper --tooling 253 --from-stage 2 --models "reviewer=opus" --variant b
if [ "$LAST_RC" -eq 0 ]; then pass "combinado corre sin abortar"; else fail "no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
if grep -qF "253 --from-stage 2 --models 'reviewer=opus' --variant 'b'" "$TMUX_STUB_LOG"; then
    pass "send-keys combina los tres flags en orden"
else
    fail "orden incorrecto -- log: $(cat "$TMUX_STUB_LOG")"
fi
if grep -qF "new-session -d -s tooling-253-b" "$TMUX_STUB_LOG"; then
    pass "la sesion tmux lleva el sufijo -b"
else
    fail "la sesion no lleva el sufijo -- log: $(cat "$TMUX_STUB_LOG")"
fi

echo ""
echo "[9] --variant sin valor aborta con mensaje claro"
run_wrapper --tooling 253 --variant
if [ "$LAST_RC" -eq 1 ]; then pass "--variant sin valor aborta"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "Falta el valor de --variant"; then pass "mensaje: falta el valor"; else fail "mensaje inesperado: $LAST_STDERR"; fi

echo ""
echo "[10] --variant se rechaza (nunca se traga en silencio) en modos sin soporte"

run_wrapper --infra 253 --variant a
if [ "$LAST_RC" -eq 1 ]; then pass "--infra + --variant aborta"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "no es valido con --infra"; then pass "mensaje: no valido con --infra"; else fail "mensaje inesperado: $LAST_STDERR"; fi

run_wrapper --scaffold 253 --domain miDominio --variant a
if [ "$LAST_RC" -eq 1 ]; then pass "--scaffold + --variant aborta"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "no es valido con --scaffold"; then pass "mensaje: no valido con --scaffold"; else fail "mensaje inesperado: $LAST_STDERR"; fi

run_wrapper --batch 253 254 --variant a --pipeline tooling
if [ "$LAST_RC" -eq 1 ]; then pass "--batch + --variant aborta"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "no es valido con --batch"; then pass "mensaje: no valido con --batch"; else fail "mensaje inesperado: $LAST_STDERR"; fi

run_wrapper --parallel 253 254 --variant a --pipeline tooling
if [ "$LAST_RC" -eq 1 ]; then pass "--parallel + --variant aborta"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "no es valido con --parallel"; then pass "mensaje: no valido con --parallel"; else fail "mensaje inesperado: $LAST_STDERR"; fi

run_wrapper --attach tooling-pipeline-253 --variant a
if [ "$LAST_RC" -eq 1 ]; then pass "--attach + --variant aborta"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "no aplica a --attach"; then pass "mensaje: no aplica a --attach"; else fail "mensaje inesperado: $LAST_STDERR"; fi

run_wrapper 253 254 --variant a
if [ "$LAST_RC" -eq 1 ]; then pass "multiples issues + --variant aborta"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "no es valido con multiples issues"; then pass "mensaje: no valido con multiples issues"; else fail "mensaje inesperado: $LAST_STDERR"; fi

echo ""
echo "[11] issue suelto (sin --tooling explicito), enrutado por --pipeline tooling, acepta --variant (issue #713: tdd-pipeline.sh tambien lo implementa, ya no es exclusivo de --tooling)"
run_wrapper 253 --variant a --pipeline tooling
if [ "$LAST_RC" -eq 0 ]; then pass "issue suelto + --pipeline tooling + --variant corre sin abortar (rc=$LAST_RC)"; else fail "no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
if grep -qF "253 --variant 'a'" "$TMUX_STUB_LOG"; then
    pass "send-keys incluye --variant con el valor intacto"
else
    fail "send-keys no compuso '253 --variant ...' -- log: $(cat "$TMUX_STUB_LOG")"
fi
if grep -qF "new-session -d -s tooling-pipeline-253-a" "$TMUX_STUB_LOG"; then
    pass "la sesion tmux lleva el sufijo -a"
else
    fail "la sesion no lleva el sufijo -- log: $(cat "$TMUX_STUB_LOG")"
fi

echo ""
echo "----------------------------------------"
echo "  tmux-pipeline.sh: $PASS pass, $FAIL fail (hasta aqui)"
echo "----------------------------------------"

# --- herdr-pipeline.sh: misma superficie, dentro de un pane herdr -----------

export HERDR_STUB_LOG="$TMP_DIR/herdr-invocations.log"
export HERDR_STUB_COUNTER="$TMP_DIR/herdr-pane-counter"
HERDR_SCRIPT="$REPO_ROOT/scripts/herdr-pipeline.sh"

cat > "$FAKE_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
set -u
echo "herdr $*" >> "$HERDR_STUB_LOG"
case "${1:-} ${2:-}" in
    "pane split")
        n=$(cat "$HERDR_STUB_COUNTER" 2>/dev/null || echo 0)
        n=$((n + 1))
        echo "$n" > "$HERDR_STUB_COUNTER"
        echo "{\"result\":{\"pane\":{\"pane_id\":\"w1:p$n\"}}}"
        ;;
    "pane get")
        echo '{"result":{"pane":{"pane_id":"stub"}}}'
        ;;
    "pane process-info")
        echo '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":100}}}'
        ;;
    *)
        echo '{"result":{"type":"ok"}}'
        ;;
esac
STUB
chmod +x "$FAKE_BIN/herdr"

cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -u
case "${3:-}" in
    253|254) printf 'OPEN|tipo:tooling\n' ;;
    *)       exit 1 ;;
esac
STUB
chmod +x "$FAKE_BIN/gh"

run_herdr() {
    : > "$HERDR_STUB_LOG"
    echo 0 > "$HERDR_STUB_COUNTER"
    local out="$TMP_DIR/stdout" err="$TMP_DIR/stderr"
    (
        cd "$FAKE_CONSUMER" || exit 99
        env -u MEFISTO_UI \
            PATH="$FAKE_BIN:$PATH" \
            HERDR_ENV=1 HERDR_PANE_ID="w1:p0" HERDR_WORKSPACE_ID="w1" \
            HERDR_STUB_LOG="$HERDR_STUB_LOG" HERDR_STUB_COUNTER="$HERDR_STUB_COUNTER" \
            "$HERDR_SCRIPT" "$@"
    ) </dev/null >"$out" 2>"$err"
    LAST_RC=$?
    LAST_STDOUT=$(cat "$out")
    LAST_STDERR=$(cat "$err")
}

echo ""
echo "[12] herdr: --tooling reenvia --variant al pane run, con --models combinado"
run_herdr --tooling 253 --models "writer=sonnet" --variant experimento-a
HERDR_CALLS=$(cat "$HERDR_STUB_LOG")
if [ "$LAST_RC" -eq 0 ]; then pass "--tooling + --models + --variant corre sin abortar (rc=$LAST_RC)"; else fail "no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
HERDR_CALLS_UNQ=$(printf '%s' "$HERDR_CALLS" | tr -d '\\')
if printf '%s' "$HERDR_CALLS_UNQ" | grep -qF -- "--models writer=sonnet --variant experimento-a"; then
    pass "el pane run lleva --models y --variant, en ese orden, con el valor intacto"
else
    fail "el pane run no lleva la combinacion esperada -- log: $HERDR_CALLS"
fi

echo ""
echo "[13] herdr: --tooling reenvia --variant solo (sin --models)"
run_herdr --tooling 253 --variant b
HERDR_CALLS=$(cat "$HERDR_STUB_LOG")
HERDR_CALLS_UNQ=$(printf '%s' "$HERDR_CALLS" | tr -d '\\')
if [ "$LAST_RC" -eq 0 ]; then pass "--tooling + --variant corre sin abortar"; else fail "no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
if printf '%s' "$HERDR_CALLS_UNQ" | grep -qF -- "--variant b"; then
    pass "el pane run lleva --variant"
else
    fail "el pane run no lleva --variant -- log: $HERDR_CALLS"
fi

echo ""
echo "[14] herdr: --variant sin valor y rechazo por modo (nunca silencio)"
run_herdr --tooling 253 --variant
if [ "$LAST_RC" -eq 1 ]; then pass "--variant sin valor aborta"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q "Falta el valor de --variant"; then pass "mensaje: falta el valor"; else fail "mensaje inesperado: $LAST_STDERR"; fi

run_herdr --infra 253 --variant a
if [ "$LAST_RC" -eq 1 ]; then pass "--infra + --variant aborta"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$LAST_STDERR" | grep -q -- "--infra"; then pass "mensaje: nombra --infra"; else fail "mensaje inesperado: $LAST_STDERR"; fi

run_herdr --parallel 253 254 --variant a --pipeline tooling
if [ "$LAST_RC" -eq 1 ]; then pass "--parallel + --variant aborta"; else fail "deberia abortar (rc=$LAST_RC)"; fi
if printf '%s' "$(cat "$HERDR_STUB_LOG")" | grep -q "pane run"; then fail "no deberia despachar ningun pane"; else pass "ningun pane despachado"; fi

run_herdr --batch 253 254 --variant a --pipeline tooling
if [ "$LAST_RC" -eq 1 ]; then pass "--batch + --variant aborta"; else fail "deberia abortar (rc=$LAST_RC)"; fi

run_herdr 253 --variant a --pipeline tooling
if [ "$LAST_RC" -eq 0 ]; then pass "issue suelto + --pipeline tooling + --variant corre sin abortar (rc=$LAST_RC)"; else fail "no deberia abortar (rc=$LAST_RC, stderr: $LAST_STDERR)"; fi
HERDR_CALLS=$(cat "$HERDR_STUB_LOG")
HERDR_CALLS_UNQ=$(printf '%s' "$HERDR_CALLS" | tr -d '\\')
if printf '%s' "$HERDR_CALLS_UNQ" | grep -qF -- "--variant a"; then
    pass "el pane run lleva --variant (issue #713: ya no exclusivo de --tooling)"
else
    fail "el pane run no lleva --variant -- log: $HERDR_CALLS"
fi

# --- tooling-pipeline.sh: wiring del modo variante (CA-2/CA-3/CA-4) ---------
#
# Chequeos estaticos sobre el fuente, al estilo de los gates de test-guards.sh:
# correr el pipeline completo pediria stubs de claude/gh/dotnet, una config de
# consumidor y un worktree real, y lo que aqui importa no es la corrida sino
# DONDE quedan cableados el sufijo y las supresiones -- justamente lo que una
# refactorizacion futura puede mover de lugar sin que ningun test se queje.
PIPE="$REPO_ROOT/scripts/tooling-pipeline.sh"

echo ""
echo "[15] tooling-pipeline.sh: el sufijo -<label> llega a rama, worktree, status y logs (CA-2)"
if grep -qF 'BRANCH_NAME="${BRANCH_NAME}-${VARIANT_LABEL}"' "$PIPE"; then
    pass "la rama -- y con ella el path del worktree, derivado de BRANCH_NAME -- lleva el sufijo"
else
    fail "la rama no lleva el sufijo: dos variantes del mismo issue colisionarian"
fi
if grep -qF 'pipeline-status-tooling-${ISSUE_NUM}-${VARIANT_LABEL}.json' "$PIPE"; then
    pass "el archivo de status lleva el sufijo"
else
    fail "el status no lleva el sufijo: una variante pisaria el status de la otra"
fi
if grep -qF 'tooling-pipeline-${TIMESTAMP}-${VARIANT_LABEL}.log' "$PIPE"; then
    pass "el log del pipeline lleva el sufijo (dos variantes del mismo segundo comparten TIMESTAMP)"
else
    fail "el log del pipeline NO lleva el sufijo: dos variantes lanzadas en el mismo segundo escribirian al mismo archivo"
fi
if grep -qF 'issue-${ISSUE_NUM}.log' "$PIPE"; then
    fail "quedan nombres de log de stage derivados de ISSUE_NUM directo (colisionan entre variantes)"
else
    pass "ningun nombre de log de stage deriva de ISSUE_NUM directo"
fi
LOG_TAG_HITS=$(grep -cF 'ISSUE_LOG_TAG' "$PIPE")
if [ "$LOG_TAG_HITS" -ge 6 ]; then
    pass "ISSUE_LOG_TAG cablea los nombres de log de stage y sus reintentos ($LOG_TAG_HITS usos)"
else
    fail "solo $LOG_TAG_HITS usos de ISSUE_LOG_TAG: falta cablear algun nombre de log (base, retry, perm-retry, writer_log)"
fi

echo ""
echo "[16] tooling-pipeline.sh: en modo variante no hay push, ni PR, ni comentario al issue (CA-3)"
if grep -qF 'if [ -n "$VARIANT_LABEL" ]' "$PIPE"; then pass "existe el gate por VARIANT_LABEL"; else fail "no hay gate por VARIANT_LABEL"; fi
# Los tres efectos externos deben estar ANIDADOS (con sangria) bajo el gate: en
# el nivel superior (columna 0) correrian tambien en modo variante.
if grep -qE '^git -C "\$WORKTREE_PATH" push' "$PIPE"; then
    fail "el push de la rama esta en el nivel superior: correria tambien en modo variante"
else
    pass "el push no esta en el nivel superior"
fi
if grep -qE '^gh issue comment' "$PIPE"; then
    fail "el comentario al issue esta en el nivel superior: correria tambien en modo variante"
else
    pass "el comentario al issue no esta en el nivel superior"
fi
if grep -qE '^ +git -C "\$WORKTREE_PATH" push -u origin' "$PIPE" \
    && grep -qE '^ +PR_URL=\$\(gh pr create' "$PIPE" \
    && grep -qE '^ +gh issue comment' "$PIPE"; then
    pass "push, gh pr create y gh issue comment quedan anidados bajo el gate"
else
    fail "no se encontraron los tres efectos externos anidados bajo el gate (push / gh pr create / gh issue comment)"
fi

echo ""
echo "[17] tooling-pipeline.sh: el label viaja en el status y en el historial (CA-4)"
if grep -qF '"variant": ${VARIANT_LABEL_JSON:-null},' "$PIPE"; then
    pass "el JSON de status declara el campo variant"
else
    fail "el JSON de status no declara el campo variant"
fi
HISTORY_VARIANT_HITS=$(grep -cF '\"variant\":${VARIANT_LABEL_JSON:-null}' "$PIPE")
if [ "$HISTORY_VARIANT_HITS" -ge 2 ]; then
    pass "las dos lineas de pipeline-history.jsonl (completed y failed) llevan variant ($HISTORY_VARIANT_HITS)"
else
    fail "solo $HISTORY_VARIANT_HITS linea(s) de historial llevan variant: se esperan 2 (completed y failed)"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
