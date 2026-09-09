#!/usr/bin/env bash
# test-agent-resume.sh -- Tests de la reanudacion de sesion truncada tras un
# hold en los pipelines publicados (issue #972).
#
# Contexto: hasta este issue, la sonda de hold (issue #971) reenviaba el
# prompt original completo del stage en cada reintento -- si el stage ya
# habia avanzado antes de tropezar con RATE_LIMIT/PROVIDER_UNAVAILABLE, ese
# progreso se pagaba dos veces. Este issue hace que la sonda continue
# (`-c`/`--continue`) la conversacion truncada del propio worktree en vez de
# repetir el stage desde cero -- atajo que evita capturar `session_id` (solo
# confiable con PIPELINE_CAPTURE_STREAM=true, MEF-ADR-0051): `-c` resuelve
# "la conversacion mas reciente del directorio actual" (`claude --help`), y
# cada `run_agent` ya hace `cd "$WORKTREE_PATH"` antes de invocar el CLI.
#
# La afirmacion de que "la mas reciente del directorio" resuelve la sesion
# correcta cuando dos agentes distintos corrieron en secuencia en el mismo
# worktree (CA-4, el riesgo real del atajo) se verifico A MANO con el CLI
# real, no se asume: dos sesiones consecutivas de `claude -p` en el mismo
# directorio (simulando dos agentes de un stage TDD), seguidas de un tercer
# `claude -c -p "cual era el numero secreto?"` en ese mismo directorio --
# la respuesta y el `session_id` correspondieron a la SEGUNDA sesion, nunca a
# la primera. Repetirlo en cada corrida de esta suite costaria una llamada
# real de API por chequeo (lento, no determinista, requiere red) -- lo que
# esta suite cubre en cambio es la mecanica de bash que decide CUANDO pasar
# `-c` y COMO degrada, con un `claude` fake que no golpea la red.
#
# Casos cubiertos:
#   [1] agent_resume_prompt: el texto menciona el stage/agente correctos, la
#       ruta exacta del resumen del stage, y la instruccion de continuar sin
#       reiniciar el analisis.
#   [2] CA-1 (estatico): tdd-pipeline.sh, tooling-pipeline.sh e
#       iac-pipeline.sh invocan agent_resume_prompt dentro de su bucle de
#       hold y pasan $RESUME_ARGS (vacio o "-c") a la sonda -- ninguna sonda
#       reenvia "$prompt" a secas sin pasar por RESUME_ARGS/attempt_prompt.
#   [3] CA-1 (comportamiento, con `claude` fake): la PRIMERA sonda del hold
#       pasa "-c" antes de "-p" y usa el prompt corto de continuacion, nunca
#       el prompt original completo -- si esa sonda tiene exito, el bucle
#       termina sin degradar.
#   [4] CA-2 (comportamiento, con `claude` fake): cuando la sonda resumida
#       vuelve a fallar sin dejar el resumen del stage, la SIGUIENTE sonda
#       corre SIN "-c" (RESUME_DEGRADED permanente) y con el prompt original
#       completo -- nunca se vuelve a intentar reanudar en ese run_agent.
#   [5] CA-2 (degradacion "sin conversacion previa"): cuando el intento muerto
#       no dejo transcript en el worktree, NINGUNA sonda usa "-c" (aterrizaria
#       en la sesion de otro stage anterior del mismo worktree) -- reenvia el
#       prompt original completo, nombra el motivo en el warning y en el log
#       de eventos, y NO marca RESUME_DEGRADED permanente. Esta degradacion no
#       se delega al CLI a proposito: `claude -c` sin sesion previa arranca una
#       sesion nueva con exit 0, pero IGNORANDO EN SILENCIO `--agent`
#       (verificado con el CLI real: `-c --agent <nombre inexistente>` no falla
#       y responde como Claude generico, mientras que sin `-c` aborta con "not
#       found") -- delegarla mandaria el prompt de continuacion a una sesion
#       virgen y sin la definicion del agente, con bypassPermissions activo.
#       agent_session_transcript_count cubre la precondicion; el bloque [1b]
#       la testea directo y el prompt trae ademas un corte de seguridad.
#   [6] Nunca se usa --fork-session en la sonda de ningun pipeline (notas
#       tecnicas del issue: reusar la sesion mantiene un solo transcript por
#       stage).
#
# Uso: scripts/tests/test-agent-resume.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null

echo "[1] agent_resume_prompt: contenido esperado"
PROMPT_TXT=$(agent_resume_prompt "2" "reviewer")
if echo "$PROMPT_TXT" | grep -q "stage 2, agente reviewer"; then
    pass "menciona el stage y el agente correctos"
else
    fail "no menciona 'stage 2, agente reviewer': $PROMPT_TXT"
fi
if echo "$PROMPT_TXT" | grep -qF ".claude/pipeline/summaries/stage-2-reviewer.md"; then
    pass "referencia la ruta exacta del resumen del stage"
else
    fail "no referencia .claude/pipeline/summaries/stage-2-reviewer.md"
fi
if echo "$PROMPT_TXT" | grep -qi "no reinicies tu analisis"; then
    pass "instruye continuar sin reiniciar el analisis"
else
    fail "no instruye continuar sin reiniciar el analisis"
fi
if echo "$PROMPT_TXT" | grep -q "gh pr create"; then
    pass "conserva la prohibicion de 'gh pr create'/'git push'"
else
    fail "no conserva la prohibicion de 'gh pr create'/'git push'"
fi
# Defensa en profundidad del aterrizaje equivocado: `-c` IGNORA en silencio
# `--agent` (verificado con el CLI real), asi que una reanudacion que caiga en
# una conversacion ajena correria sin la definicion del agente y con
# bypassPermissions -- el prompt tiene que ordenar cortar sin tocar archivos.
if echo "$PROMPT_TXT" | grep -q "SIN_SESION_PREVIA"; then
    pass "incluye el corte de seguridad si la reanudacion aterrizo en otra conversacion"
else
    fail "no incluye el corte de seguridad 'SIN_SESION_PREVIA'"
fi

echo ""
echo "[1b] agent_session_transcript_count: precondicion de -c"
CFG_DIR=$(mktemp -d)
WT_PROBE=$(mktemp -d)
_slug_for() {
    local real s
    real=$(cd "$1" && pwd -P)
    s="${real//\//-}"
    s="${s//./-}"
    printf '%s' "$s"
}
CFG_DIR_ORIG="${CLAUDE_CONFIG_DIR:-}"
export CLAUDE_CONFIG_DIR="$CFG_DIR"
if [ "$(agent_session_transcript_count "$WT_PROBE")" = "0" ]; then
    pass "sin store para el directorio -> 0 (fail-safe: no reanuda)"
else
    fail "sin store para el directorio deberia dar 0, dio $(agent_session_transcript_count "$WT_PROBE")"
fi
mkdir -p "$CFG_DIR/projects/$(_slug_for "$WT_PROBE")"
: > "$CFG_DIR/projects/$(_slug_for "$WT_PROBE")/aaa.jsonl"
: > "$CFG_DIR/projects/$(_slug_for "$WT_PROBE")/bbb.jsonl"
if [ "$(agent_session_transcript_count "$WT_PROBE")" = "2" ]; then
    pass "cuenta los transcripts del store del directorio (slug del path fisico)"
else
    fail "esperaba 2 transcripts, dio $(agent_session_transcript_count "$WT_PROBE")"
fi
if [ "$(agent_session_transcript_count "")" = "0" ]; then
    pass "directorio vacio como argumento -> 0"
else
    fail "directorio vacio como argumento deberia dar 0"
fi
if [ -n "$CFG_DIR_ORIG" ]; then export CLAUDE_CONFIG_DIR="$CFG_DIR_ORIG"; else unset CLAUDE_CONFIG_DIR; fi
rm -rf "$CFG_DIR" "$WT_PROBE"

echo ""
echo "[2] CA-1 (estatico): reanudacion legacy y neutral"
for p in tdd-pipeline.sh iac-pipeline.sh; do
    FILE="$REPO_ROOT/scripts/$p"
    if grep -q 'agent_resume_prompt "\$stage" "\$agent"' "$FILE" \
        && grep -q 'claude \$RESUME_ARGS -p "\$attempt_prompt"' "$FILE"; then
        pass "$p: usa agent_resume_prompt y \$RESUME_ARGS en la sonda"
    else
        fail "$p: no encontro el patron esperado de reanudacion en la sonda"
    fi
done
TOOLING="$REPO_ROOT/scripts/tooling-pipeline.sh"
if grep -q 'agent_events_session_id' "$TOOLING" \
    && grep -q 'runtime_supports_resume' "$TOOLING" \
    && grep -q 'args+=(--resume-session "$resume_session")' "$TOOLING"; then
    pass "tooling-pipeline.sh: reanuda por session_id y capability neutrales"
else
    fail "tooling-pipeline.sh: perdio la reanudacion neutral"
fi

echo ""
echo "[6] Ningun pipeline publicado usa --fork-session en la sonda de hold"
# Excluye lineas de comentario ('#'): _pipeline-common.sh documenta la
# decision de NO usar --fork-session en un comentario, que menciona el flag
# sin invocarlo.
FORK_HITS=$(grep -n "fork-session" "$REPO_ROOT"/scripts/*.sh 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
if [ -z "$FORK_HITS" ]; then
    pass "cero invocaciones de --fork-session en scripts/*.sh (solo se documenta en comentarios)"
else
    fail "--fork-session invocado fuera de un comentario: $FORK_HITS"
fi

# -------- Arnes de comportamiento: extrae el bloque REAL del hold loop de --------
# -------- iac-pipeline.sh (el mas simple de los tres) y lo ejercita con un --------
# -------- 'claude' fake, sin tocar la red. -----------------------------------

echo ""
echo "[3]/[4] Comportamiento: bloque real del hold loop de iac-pipeline.sh"

IAC_SCRIPT="$REPO_ROOT/scripts/iac-pipeline.sh"
BLOCK=$(awk '
    /^        local HOLD_STARTED_TS="" HOLD_TOTAL_SECONDS=0 hold_attempt=0$/ && !started { started=1 }
    started { print; if (/^        done$/) exit }
' "$IAC_SCRIPT")

if [ -z "$BLOCK" ]; then
    fail "no se pudo extraer el bloque del hold loop de $IAC_SCRIPT (¿cambio de forma del script?)"
else
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    # run_hold_scenario <call_log> <count_file> <mode> <baseline> <transcripts>
    #   mode=succeed_on_resume  -> la sonda tiene exito en el primer intento
    #                              (resumido) -- CA-1.
    #   mode=fail_without_summary -> la sonda SIEMPRE falla con PROVIDER_UNAVAILABLE
    #                              y nunca deja el resumen del stage -- CA-2.
    #   mode=no_prior_session   -> la sonda falla siempre y el store del
    #                              worktree NO crecio respecto a <baseline>
    #                              (el intento muerto no dejo transcript) --
    #                              CA-2, primera degradacion.
    #
    # <baseline> es el valor de RESUME_BASELINE_SESSIONS que el pipeline
    # captura antes del intento original; <transcripts> cuantos archivos
    # `.jsonl` tiene el store falso del worktree cuando corre el hold. El
    # store es real (lo lee agent_session_transcript_count via
    # CLAUDE_CONFIG_DIR), solo su contenido es fabricado -- asi el test
    # ejercita el calculo de slug de verdad y no una funcion mockeada.
    run_hold_scenario() {
        local call_log="$1" count_file="$2" mode="$3" baseline="${4:-0}" transcripts="${5:-1}"
        local worktree="$TMP_DIR/wt-$mode"
        rm -rf "$worktree"
        mkdir -p "$worktree"
        : > "$call_log"
        echo 0 > "$count_file"

        local cfg_dir="$TMP_DIR/cfg-$mode"
        local wt_real slug
        wt_real=$(cd "$worktree" && pwd -P)
        slug="${wt_real//\//-}"
        slug="${slug//./-}"
        rm -rf "$cfg_dir"
        mkdir -p "$cfg_dir/projects/$slug"
        local i=0
        while [ "$i" -lt "$transcripts" ]; do
            : > "$cfg_dir/projects/$slug/sesion-$i.jsonl"
            i=$((i + 1))
        done

        local test_script="$TMP_DIR/block-$mode.sh"
        cat > "$test_script" <<EOF
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/_pipeline-common.sh" 2>/dev/null

export MEFISTO_HOLD_PROBE_SECONDS=1
export MEFISTO_HOLD_MAX_SECONDS=5
export CLAUDE_CONFIG_DIR="$cfg_dir"

RESUME_BASELINE_SESSIONS=$baseline
WORKTREE_PATH="$worktree"
LOG_DIR_ABS="$TMP_DIR"
TIMESTAMP="test"
ISSUE_NUM="999"
EVENTS_LOG_ABS="$TMP_DIR/events-$mode.log"
: > "\$EVENTS_LOG_ABS"
AGENT_TIMEOUT_SECONDS=5
PIPELINE_CAPTURE_STREAM=false
NONINTERACTIVE_SYSTEM="system"
agent="infra-writer"
stage="1"
prompt="PROMPT ORIGINAL COMPLETO DEL STAGE"
elapsed=0
CLAUDE_EXIT=1
failure_type="PROVIDER_UNAVAILABLE (exit 1)"

warn() { echo "WARN: \$1"; }
log() { echo "LOG: \$1"; }
derive_stage_log_from_stream() { :; }

claude() {
    # Un argumento (attempt_prompt) puede traer saltos de linea de sobra
    # (agent_resume_prompt es un heredoc multilinea) -- \$* los preservaria y
    # partiria "una llamada" en varias lineas fisicas del log. Cada arg va
    # entre corchetes con sus saltos de linea aplanados a espacio, asi una
    # llamada completa es SIEMPRE una sola linea fisica.
    {
        printf 'CALL:'
        for a in "\$@"; do
            printf ' [%s]' "\$(printf '%s' "\$a" | tr '\n' ' ')"
        done
        printf '\n'
    } >> "$call_log"
    local n
    n=\$(cat "$count_file")
    n=\$((n + 1))
    echo "\$n" > "$count_file"
    if [ "$mode" = "succeed_on_resume" ]; then
        echo "ok"
        return 0
    fi
    # fail_without_summary: siempre PROVIDER_UNAVAILABLE, nunca deja el resumen
    echo "API Error: 529 Service Unavailable"
    return 1
}

run_hold_block() {
$BLOCK
echo "FINAL_CLAUDE_EXIT=\$CLAUDE_EXIT"
echo "FINAL_RESUME_DEGRADED=\${RESUME_DEGRADED:-unset}"
}
run_hold_block
EOF
        bash "$test_script" 2>&1
    }

    CALL_LOG_A="$TMP_DIR/calls-succeed.log"
    COUNT_A="$TMP_DIR/count-succeed"
    OUT_A=$(run_hold_scenario "$CALL_LOG_A" "$COUNT_A" "succeed_on_resume" 0 1)

    # CA-1: la primera (y unica) sonda debe pasar "-c" ANTES de "-p", con el
    # prompt corto de continuacion -- nunca el prompt original completo.
    if [ -f "$CALL_LOG_A" ] && grep -qE '^CALL: \[-c\] \[-p\] ' "$CALL_LOG_A"; then
        pass "CA-1: la sonda resumida invoca 'claude -c -p ...' (continue antes de print)"
    else
        fail "CA-1: no se encontro 'claude -c -p ...' en $CALL_LOG_A: $(cat "$CALL_LOG_A" 2>/dev/null)"
    fi
    if [ -f "$CALL_LOG_A" ] && grep -q "PROMPT ORIGINAL COMPLETO DEL STAGE" "$CALL_LOG_A"; then
        fail "CA-1: la sonda resumida reenvio el prompt original completo (no deberia)"
    else
        pass "CA-1: la sonda resumida NO reenvia el prompt original completo"
    fi
    if echo "$OUT_A" | grep -q "FINAL_CLAUDE_EXIT=0"; then
        pass "CA-1: el hold termina en exito tras la sonda resumida"
    else
        fail "CA-1: el hold no termino en exito: $OUT_A"
    fi

    CALL_LOG_B="$TMP_DIR/calls-degrade.log"
    COUNT_B="$TMP_DIR/count-degrade"
    OUT_B=$(run_hold_scenario "$CALL_LOG_B" "$COUNT_B" "fail_without_summary" 0 1)

    N_CALLS_B=$(wc -l < "$CALL_LOG_B" 2>/dev/null | tr -d ' ')
    if [ "${N_CALLS_B:-0}" -ge 2 ]; then
        pass "CA-2: el hold agotado (techo chico de prueba) dejo al menos 2 sondas"
    else
        fail "CA-2: se esperaban al menos 2 sondas, hubo ${N_CALLS_B:-0}: $(cat "$CALL_LOG_B" 2>/dev/null)"
    fi

    FIRST_CALL_B=$(sed -n '1p' "$CALL_LOG_B" 2>/dev/null || echo "")
    LAST_CALL_B=$(tail -n 1 "$CALL_LOG_B" 2>/dev/null || echo "")

    if echo "$FIRST_CALL_B" | grep -qE '^CALL: \[-c\] \[-p\] '; then
        pass "CA-2: la primera sonda (aun sin degradar) usa -c"
    else
        fail "CA-2: la primera sonda no uso -c: $FIRST_CALL_B"
    fi
    if echo "$LAST_CALL_B" | grep -qE '^CALL: \[-p\] '; then
        pass "CA-2: la ultima sonda (ya degradada) corre SIN -c"
    else
        fail "CA-2: la ultima sonda no degrado a 'claude -p ...' sin -c: $LAST_CALL_B"
    fi
    if echo "$LAST_CALL_B" | grep -q "PROMPT ORIGINAL COMPLETO DEL STAGE"; then
        pass "CA-2: la sonda degradada reenvia el prompt original completo del stage"
    else
        fail "CA-2: la sonda degradada no reenvio el prompt original completo: $LAST_CALL_B"
    fi
    if echo "$OUT_B" | grep -q "FINAL_RESUME_DEGRADED=true"; then
        pass "CA-2: RESUME_DEGRADED queda en true de forma permanente"
    else
        fail "CA-2: RESUME_DEGRADED no quedo en true: $OUT_B"
    fi

    # CA-2, primera degradacion: el intento muerto no dejo transcript en el
    # worktree (el store no crecio respecto a la linea base), asi que `-c`
    # aterrizaria en la sesion de otro stage anterior del mismo worktree --
    # y ahi `--agent` se ignora en silencio. NINGUNA sonda debe usar -c.
    CALL_LOG_C="$TMP_DIR/calls-noprior.log"
    COUNT_C="$TMP_DIR/count-noprior"
    OUT_C=$(run_hold_scenario "$CALL_LOG_C" "$COUNT_C" "no_prior_session" 1 1)

    if grep -q '^CALL: \[-c\]' "$CALL_LOG_C" 2>/dev/null; then
        fail "CA-2: hubo una sonda con -c sin conversacion previa de este stage: $(cat "$CALL_LOG_C")"
    else
        pass "CA-2: sin transcript nuevo del intento muerto, ninguna sonda usa -c"
    fi
    if grep -q "PROMPT ORIGINAL COMPLETO DEL STAGE" "$CALL_LOG_C" 2>/dev/null; then
        pass "CA-2: esas sondas reenvian el prompt original completo del stage"
    else
        fail "CA-2: la sonda sin reanudacion no reenvio el prompt original: $(cat "$CALL_LOG_C" 2>/dev/null)"
    fi
    if echo "$OUT_C" | grep -q "sin conversacion previa de este stage"; then
        pass "CA-2: el warning nombra el motivo de la degradacion"
    else
        fail "CA-2: no se emitio el warning que nombra el motivo: $OUT_C"
    fi
    if grep -q "no dejo transcript en el worktree" "$TMP_DIR/events-no_prior_session.log" 2>/dev/null; then
        pass "CA-2: el motivo queda en el log de eventos del pipeline"
    else
        fail "CA-2: el log de eventos no registro el motivo: $(cat "$TMP_DIR/events-no_prior_session.log" 2>/dev/null)"
    fi
    # La degradacion NO es permanente en este caso: solo se salta la
    # reanudacion mientras no haya nada que continuar (RESUME_DEGRADED, que si
    # es permanente, esta reservado al caso de la sesion que muere dos veces).
    if echo "$OUT_C" | grep -q "FINAL_RESUME_DEGRADED=false"; then
        pass "CA-2: 'sin conversacion previa' no marca RESUME_DEGRADED permanente"
    else
        fail "CA-2: 'sin conversacion previa' no debe degradar permanentemente: $OUT_C"
    fi
fi

echo ""
echo "=== Resumen: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
