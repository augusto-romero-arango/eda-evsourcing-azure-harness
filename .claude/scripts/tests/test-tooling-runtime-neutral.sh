#!/usr/bin/env bash
# test-tooling-runtime-neutral.sh -- E2E del pipeline interno de tooling POR
# RUNTIME, con CLIs falsas en PATH (MEF-ADR-0049, MEF-ADR-0031, issue #912).
#
# Hijo 3/3 de #879: #910 conecto run_agent al runner neutral
# (mefisto-run-agent.sh), pero solo lo cubrian los tests unitarios ajustados
# (retry, stage-models, variant, state-paths). Esta suite corre el PIPELINE
# REAL (src/internal/scripts/mefisto-tooling-pipeline.sh, via el shim
# .claude/scripts/mefisto-tooling-pipeline.sh) de punta a punta, con CLIs
# falsas de `claude` y `opencode` en PATH que reproducen tal cual el formato
# crudo congelado de fixtures/runtime-{claude,opencode}/*.jsonl -- ningun CLI
# real hace falta instalado.
#
# Arnes (bloque [A], funcion setup_harness): mismo layout canonico que el
# bloque [G] de test-tooling-state-paths.sh (origin bare + clon "fake-mefisto"
# + stubs de PATH), extendido con runtime-opencode.sh/.jq y un stub `opencode`
# ademas del `claude` -- y con `gh pr create`/`gh issue comment` respondiendo
# (URL falsa) para que los escenarios de exito lleguen hasta la creacion del
# PR, a diferencia del bloque [G] (que corta a proposito en el gate de
# changelog.d/). No se comparte codigo con ese archivo -- los tests internos
# no comparten helpers entre si (ver notas tecnicas de #912) -- el arnes vive
# en funciones de ESTE archivo.
#
# Escenarios (CA-1), cada uno una corrida real distinta del pipeline sobre el
# MISMO origin/clon (issue de mentira propio por escenario, para que las
# ramas/worktrees no colisionen):
#   (a) [B] MEFISTO_RUNTIME=claude,   exito de punta a punta.
#   (b) [C] MEFISTO_RUNTIME=opencode, exito de punta a punta.
#   (c) [D] MEFISTO_RUNTIME=opencode, fallo terminal del writer en Stage 1 --
#       el CLI falso reproduce fixtures/runtime-opencode/empty-1.18.29.jsonl
#       (stream vacio, fixture congelado) y sale con exit 1, sin resumen.
#   (d) [E] Defaults: sin .mefisto/models.json ni --models, OpenCode recibe
#       Terra para writer y Sol para reviewer; Claude conserva sonnet para
#       writer y herencia para reviewer deep.
#   (e) [F] Gate de neutralidad (issue #914): MEFISTO_RUNTIME=claude, el CLI
#       falso del writer introduce ademas una fuga real -- un archivo nuevo
#       src/internal/agents/fx-leak.md con `"model": "sonnet"` en el
#       frontmatter -- dentro del scope permitido (src/internal/**), asi que
#       el gate de scope da via libre y el UNICO gate que puede frenar la
#       corrida es mefisto-neutrality-gate.sh. Stage 1 aborta citando la
#       violacion 'src/internal/agents/fx-leak.md:<linea>: R1' y el comando
#       de retoma --from-stage 1, sin llegar a crear PR.
#
# CA-2 (evidencia verificable, MEF-ADR-0031 -- los artefactos de una corrida
# real, no la lectura del codigo): <log_base>.events.jsonl de cada stage
# termina en run.completed{status:"success"} con el runtime del escenario; el
# archivo de metricas de cada stage lleva runtime/status; pipeline-history.jsonl
# registra runtime a nivel de corrida y en agents.writer/agents.reviewer; en
# (b) el CLI falso de cada stage fue invocado con `--agent mefisto-writer` /
# `--agent mefisto-reviewer` (flag y valor ADYACENTES en el argv); en (c) el
# pipeline aborta en Stage 1, `gh pr create` nunca se invoca, el status queda
# failed y no hay entrada completed en el historial para ese issue.
#
# CA-3: toda la suite corre con CLIs falsas (sin red, sin claude/opencode
# reales instalados -- los stubs preceden en PATH) y
# MEFISTO_AGENT_RETRY_BACKOFF_SECONDS=0; limpia sus temporales via trap (el
# worktree que crea el pipeline nace como hermano del clon, o sea dentro de
# $TMP). Bash 3.2 (sin arrays asociativos, sin mapfile) + jq 1.7 (baseline
# de MEF-ADR-0049 CA-6; `jq --args ... -- "$@"` necesita el terminador `--`
# porque el argv capturado trae flags).
#
# Uso: .claude/scripts/tests/test-tooling-runtime-neutral.sh
# Exit code: 0 si todos los chequeos pasan (o si jq/python3 no estan
# disponibles -- SKIP de la suite completa), 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

CANON_LIB="$REPO_ROOT/src/internal/scripts/lib/_mefisto-common.sh"
CANON_PIPE="$REPO_ROOT/src/internal/scripts/mefisto-tooling-pipeline.sh"
SHIM_LIB="$REPO_ROOT/.claude/scripts/_mefisto-common.sh"
SHIM_PIPE="$REPO_ROOT/.claude/scripts/mefisto-tooling-pipeline.sh"

FIXTURES_CLAUDE_DIR="$REPO_ROOT/.claude/scripts/tests/fixtures/runtime-claude"
FIXTURES_OPENCODE_DIR="$REPO_ROOT/.claude/scripts/tests/fixtures/runtime-opencode"

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: esta suite requiere jq y python3, no disponibles en este entorno"
    echo "----------------------------------------"
    echo "  Resumen: 0 pass, 0 fail"
    echo "----------------------------------------"
    exit 0
fi

for f in "$CANON_LIB" "$CANON_PIPE" "$SHIM_LIB" "$SHIM_PIPE" \
         "$FIXTURES_CLAUDE_DIR/success.jsonl" \
         "$FIXTURES_OPENCODE_DIR/success-tool-1.18.29.jsonl" \
         "$FIXTURES_OPENCODE_DIR/empty-1.18.29.jsonl"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: archivo requerido ausente: $f"
        exit 1
    fi
done

# ============================================================================
# [A] Arnes: origin bare + clon "fake-mefisto" + stubs de gh/claude/opencode
# ============================================================================

echo "[A] Montando arnes: origin bare + clon fake-mefisto + stubs de PATH"

FAKE_MEFISTO="$TMP/fake-mefisto"
FAKE_BIN="$TMP/bin"
STATE_DIR="$FAKE_MEFISTO/.mefisto/pipeline"
mkdir -p "$FAKE_BIN"

# write_cli_stub <nombre> -- escribe en $FAKE_BIN un CLI falso llamado
# <nombre> (claude u opencode: el cuerpo es el mismo, el stub se identifica
# por basename "$0"). Reproduce tal cual (cat, sin editarlo) el fixture crudo
# congelado que indique MEFISTO_TEST_FIXTURE, captura su argv completo como
# array JSON con jq --args (issue #863: el prompt puede traer saltos de
# linea, un separador de texto no serviria) y, en modo "success" o "leak",
# escribe el resumen de AMBOS stages + un archivo notable dentro del scope +
# un fragmento de changelog.d/ (para que el gate de fragmentos del issue #380
# de via libre hasta crear el PR). En modo "leak" (issue #914) anade ademas
# una fuga real de neutralidad -- src/internal/agents/fx-leak.md con
# `"model": "sonnet"` en el frontmatter -- dentro del scope permitido, para
# que el UNICO gate que frene la corrida sea mefisto-neutrality-gate.sh, no el
# de scope. Sale con MEFISTO_TEST_EXIT_CODE.
write_cli_stub() {
    local name="$1"
    cat > "$FAKE_BIN/$name" <<'STUB'
#!/usr/bin/env bash
ME="$(basename "$0")"
CAP="${MEFISTO_TEST_CAPTURE_DIR:?MEFISTO_TEST_CAPTURE_DIR sin fijar}"
N_FILE="$CAP/$ME-call-count"
N=$(( $(cat "$N_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$N" > "$N_FILE"
jq -n --args '$ARGS.positional' -- "$@" > "$CAP/$ME-call-$N.json" 2>/dev/null || true

if [ "${MEFISTO_TEST_MODE:-success}" = "success" ] || [ "${MEFISTO_TEST_MODE:-success}" = "leak" ]; then
    mkdir -p .mefisto/pipeline/summaries docs changelog.d
    echo "resumen stub writer ($ME)" > .mefisto/pipeline/summaries/stage-1-writer.md
    echo "resumen stub reviewer ($ME)" > .mefisto/pipeline/summaries/stage-2-reviewer.md
    echo "cambio del stub e2e ($ME, llamada $N)" >> docs/912-e2e-marker.md
    echo "- cambio del stub e2e (runtime-neutral)" > changelog.d/912-e2e.added.md
fi

if [ "${MEFISTO_TEST_MODE:-success}" = "leak" ]; then
    mkdir -p src/internal/agents
    printf -- '---\n{"id": "fx-leak", "kind": "agent", "model": "sonnet"}\n---\n\nFuga de neutralidad de runtime para el escenario negativo (issue #914): el campo `model` no debe aparecer en la fuente neutral src/internal/**.\n' > src/internal/agents/fx-leak.md
fi

if [ -n "${MEFISTO_TEST_FIXTURE:-}" ]; then
    cat "$MEFISTO_TEST_FIXTURE"
fi
exit "${MEFISTO_TEST_EXIT_CODE:-0}"
STUB
    chmod +x "$FAKE_BIN/$name"
}

setup_harness() {
    local bare="$TMP/origin.git"
    git init -q --bare "$bare"
    git clone -q "$bare" "$FAKE_MEFISTO" 2>/dev/null

    mkdir -p "$FAKE_MEFISTO/.claude-plugin" "$FAKE_MEFISTO/.claude/scripts" \
             "$FAKE_MEFISTO/src/internal/scripts/lib" "$FAKE_MEFISTO/src/internal/prompts" \
             "$FAKE_MEFISTO/src/internal/contract" \
             "$FAKE_MEFISTO/docs" "$FAKE_MEFISTO/changelog.d"
    cat > "$FAKE_MEFISTO/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "mefisto",
  "version": "0.0.0"
}
EOF
    printf '.mefisto/\n.claude/pipeline/\n' > "$FAKE_MEFISTO/.gitignore"

    # Libs canonicas que el runner y el pipeline necesitan para resolver
    # runtime/modelo sin invocar ningun CLI real (issue #910): los DOS
    # adaptadores (claude Y opencode), a diferencia del bloque [G] de
    # test-tooling-state-paths.sh que solo ejercita MEFISTO_RUNTIME=claude.
    local lib
    for lib in _mefisto-common.sh mefisto-state.sh mefisto-runtime.sh mefisto-models.sh \
               runtime-claude.sh runtime-claude.jq adapter-claude.sh \
               runtime-opencode.sh runtime-opencode.jq adapter-opencode.sh; do
        cp "$REPO_ROOT/src/internal/scripts/lib/$lib" "$FAKE_MEFISTO/src/internal/scripts/lib/$lib"
    done
    cp "$REPO_ROOT/src/internal/prompts/noninteractive-system.md" "$FAKE_MEFISTO/src/internal/prompts/noninteractive-system.md"
    cp "$REPO_ROOT/src/internal/scripts/mefisto-run-agent.sh" "$FAKE_MEFISTO/src/internal/scripts/mefisto-run-agent.sh"
    # Gate de neutralidad (issue #914): el pipeline lo invoca tras cada stage
    # -- copias REALES (no un stub), byte-identicas al repo, para que el
    # escenario [F] ejercite el gate de verdad. La allowlist real trae las
    # excepciones (R1) de los propios adaptadores que setup_harness copia mas
    # abajo (adapter-claude.sh, adapter-opencode.sh...), asi que los
    # escenarios de exito ((a)/(b)) siguen pasando el gate en 0. No se copia
    # generate-internal-adapters.sh: sin el, el gate salta adapters-check en
    # silencio (guarda `[ -f "$ADAPTERS_SCRIPT" ]`), y ningun escenario de esta
    # suite necesita ejercer esa verificacion estructural (ya cubierta por
    # test-neutrality-gate.sh).
    cp "$REPO_ROOT/src/internal/scripts/mefisto-neutrality-gate.sh" "$FAKE_MEFISTO/src/internal/scripts/mefisto-neutrality-gate.sh"
    cp "$REPO_ROOT/src/internal/contract/neutrality-allowlist.json" "$FAKE_MEFISTO/src/internal/contract/neutrality-allowlist.json"
    chmod +x "$FAKE_MEFISTO/src/internal/scripts/mefisto-neutrality-gate.sh"
    cp "$CANON_PIPE" "$FAKE_MEFISTO/src/internal/scripts/mefisto-tooling-pipeline.sh"
    cp "$SHIM_LIB" "$FAKE_MEFISTO/.claude/scripts/_mefisto-common.sh"
    cp "$SHIM_PIPE" "$FAKE_MEFISTO/.claude/scripts/mefisto-tooling-pipeline.sh"
    chmod +x "$FAKE_MEFISTO/src/internal/scripts/mefisto-run-agent.sh" \
             "$FAKE_MEFISTO/src/internal/scripts/mefisto-tooling-pipeline.sh" \
             "$FAKE_MEFISTO/.claude/scripts/mefisto-tooling-pipeline.sh"
    echo "# changelog.d" > "$FAKE_MEFISTO/changelog.d/README.md"

    (cd "$FAKE_MEFISTO" \
        && git add -A \
        && git -c user.email="test@example.com" -c user.name="Test" commit -q -m "base" \
        && git push -q origin main)

    # --- Stub de gh: issue view responde un issue abierto; pr create responde
    # una URL falsa (y deja constancia de la llamada); issue comment succeed;
    # el resto (pr list, repo view...) falla -- el pipeline ya degrada esos
    # casos (find_open_pr_for_branch/assert_in_mefisto tratan un gh roto como
    # "sin dato", nunca abortan por eso).
    cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
CAP="${MEFISTO_TEST_CAPTURE_DIR:-}"
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    printf '{"number":%s,"title":"E2E stub issue runtime-neutral","body":"cuerpo de prueba stub","state":"OPEN"}\n' "$3"
    exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
    [ -n "$CAP" ] && echo "called" >> "$CAP/gh-pr-create.calls"
    echo "https://github.com/fake-org/fake-repo/pull/9999"
    exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "comment" ]; then
    [ -n "$CAP" ] && echo "called" >> "$CAP/gh-issue-comment.calls"
    exit 0
fi
exit 1
STUB
    chmod +x "$FAKE_BIN/gh"

    # --- Stubs de claude y opencode: mismo cuerpo (write_cli_stub), sobre las
    # fixtures de su propio runtime. La diferencia observable esta en el argv
    # que el runner les compone: opencode recibe --agent/--dir/-m como flags
    # reales; claude recibe -p <prompt> y --model solo cuando hay modelo.
    write_cli_stub claude
    write_cli_stub opencode
}

setup_harness
if [ -x "$FAKE_MEFISTO/.claude/scripts/mefisto-tooling-pipeline.sh" ] && [ -x "$FAKE_BIN/claude" ] && [ -x "$FAKE_BIN/opencode" ] && [ -x "$FAKE_BIN/gh" ]; then
    pass "A-1: arnes montado (clon fake-mefisto + stubs gh/claude/opencode ejecutables)"
else
    fail "A-1: el arnes no quedo montado correctamente"
fi

# run_scenario <runtime> <issue_num> <mode> <fixture_file> <exit_code>
#
# Corre el pipeline REAL (via el shim) contra el clon fake-mefisto, con
# env -u de todo el estado que esta MISMA sesion de test hereda (mismo motivo
# que el bloque [G] de test-tooling-state-paths.sh: sin esto, la corrida
# escribiria en el .mefisto/pipeline/ del repo real). Cada escenario usa su
# propio directorio de captura (para que los contadores de invocacion
# <cli>-call-N arranquen en 1 en cada corrida) y su propio numero de issue de
# mentira (para que rama/worktree no colisionen entre escenarios que
# reutilizan el mismo origin/clon). Deja SCEN_RC/SCEN_OUT/SCEN_ERR/SCEN_CAP
# poblados para que el caller haga sus aserciones.
run_scenario() {
    local runtime="$1" issue_num="$2" mode="$3" fixture="$4" exitcode="$5"
    local capdir="$TMP/capture-${issue_num}"
    mkdir -p "$capdir"
    local out="$TMP/scenario-${issue_num}.out"
    local err="$TMP/scenario-${issue_num}.err"

    (
        cd "$FAKE_MEFISTO" || exit 99
        env -u MEFISTO_STATE_DIR -u MEFISTO_LEGACY_STATE_DIR -u MEFISTO_REPO_ROOT \
            -u MEFISTO_PROJECT_NAME -u MEFISTO_REPO_SLUG \
            PATH="$FAKE_BIN:$PATH" MEFISTO_RUNTIME="$runtime" MEFISTO_AGENT_RETRY_BACKOFF_SECONDS=0 \
            MEFISTO_TEST_CAPTURE_DIR="$capdir" MEFISTO_TEST_MODE="$mode" \
            MEFISTO_TEST_FIXTURE="$fixture" MEFISTO_TEST_EXIT_CODE="$exitcode" \
            ./.claude/scripts/mefisto-tooling-pipeline.sh "$issue_num"
    ) </dev/null >"$out" 2>"$err"
    SCEN_RC=$?
    SCEN_OUT="$out"
    SCEN_ERR="$err"
    SCEN_CAP="$capdir"
}

# _events_file <issue_num> <stage> <agent> -- ruta del events.jsonl del stage
# (timestamp desconocido de antemano: se resuelve con find + comodin).
_events_file() {
    find "$STATE_DIR/logs" -name "mefisto-tooling-stage-${2}-${3}-*-issue-${1}.events.jsonl" 2>/dev/null | head -n1
}

# _metrics_file <issue_num> <stage> <agent> -- ruta del metrics/*.json del stage.
_metrics_file() {
    find "$STATE_DIR/metrics" -name "mefisto-tooling-*-issue-${1}-stage-${2}-${3}.json" 2>/dev/null | head -n1
}

# _find_call <capdir> <cli> <aguja> -- ruta del primer <cli>-call-N.json cuyo
# argv (array JSON) tiene algun elemento que CONTIENE <aguja>. Sirve para
# ubicar la invocacion de un stage por contenido, no por orden de llamada:
# en claude el agente no viaja como flag, pero el prompt del stage nombra
# su propio archivo de resumen (stage-1-writer.md / stage-2-reviewer.md).
_find_call() {
    local f
    for f in "$1/$2"-call-*.json; do
        [ -f "$f" ] || continue
        if jq -e --arg n "$3" 'any(.[]; contains($n))' "$f" >/dev/null 2>&1; then
            printf '%s' "$f"
            return 0
        fi
    done
    return 1
}

# _argv_has_flag_value <call.json> <flag> <valor> -- true si el argv trae
# <flag> seguido INMEDIATAMENTE por <valor> (adyacentes, no sueltos).
_argv_has_flag_value() {
    jq -e --arg f "$2" --arg v "$3" '(index($f)) as $i | $i != null and .[$i+1] == $v' "$1" >/dev/null 2>&1
}

# _argv_has_no_model_flag <call.json> -- true si el argv no trae --model ni
# -m y ningun elemento es la cadena vacia (un `--model ""` colado tambien
# fallaria aqui, MEF-ADR-0049 decision 4).
_argv_has_no_model_flag() {
    jq -e '(index("-m") == null) and (index("--model") == null) and all(.[]; . != "")' "$1" >/dev/null 2>&1
}

# assert_stage_artifacts <prefijo> <runtime> <issue> <stage> <agent> --
# chequeos -2 (events.jsonl terminal) y -3 (metrics) de un stage exitoso.
assert_stage_artifacts() {
    local prefix="$1" runtime="$2" issue="$3" stage="$4" agent="$5"
    local ev mf term t_type t_status t_runtime m_runtime m_status

    ev="$(_events_file "$issue" "$stage" "$agent")"
    if [ -n "$ev" ] && [ -f "$ev" ]; then
        term="$(tail -n1 "$ev")"
        t_type="$(printf '%s' "$term" | jq -r '.type')"
        t_status="$(printf '%s' "$term" | jq -r '.status')"
        t_runtime="$(printf '%s' "$term" | jq -r '.runtime')"
        if [ "$t_type" = "run.completed" ] && [ "$t_status" = "success" ] && [ "$t_runtime" = "$runtime" ]; then
            pass "$prefix-2: stage $stage ($agent) -- events.jsonl termina en run.completed{status:success, runtime:$runtime}"
        else
            fail "$prefix-2: stage $stage ($agent) -- terminal inesperado: $term"
        fi
    else
        fail "$prefix-2: stage $stage ($agent) -- no se encontro events.jsonl bajo $STATE_DIR/logs"
    fi

    mf="$(_metrics_file "$issue" "$stage" "$agent")"
    if [ -n "$mf" ] && [ -f "$mf" ]; then
        m_runtime="$(jq -r '.runtime' "$mf")"
        m_status="$(jq -r '.status' "$mf")"
        if [ "$m_runtime" = "$runtime" ] && [ "$m_status" = "success" ]; then
            pass "$prefix-3: stage $stage ($agent) -- metrics/*.json lleva runtime:$runtime, status:success"
        else
            fail "$prefix-3: stage $stage ($agent) -- metrics con runtime='$m_runtime' status='$m_status'"
        fi
    else
        fail "$prefix-3: stage $stage ($agent) -- no se encontro metrics/*.json bajo $STATE_DIR/metrics"
    fi
}

# assert_success_run <prefijo> <runtime> <issue> <capdir> -- aserciones CA-2
# comunes a los escenarios de exito (a) y (b), sobre la ultima run_scenario:
#   -1 rc=0; -2/-3 por stage (assert_stage_artifacts); -4 runtime en el
#   historial a nivel de corrida y por agente; -5 `gh pr create` exactamente
#   una vez.
assert_success_run() {
    local prefix="$1" runtime="$2" issue="$3" capdir="$4"
    local hist entry h_runtime h_wr h_rv

    if [ "$SCEN_RC" -eq 0 ]; then
        pass "$prefix-1: el pipeline completa con exito bajo runtime=$runtime (rc=0)"
    else
        fail "$prefix-1: rc=$SCEN_RC -- stderr: $(tail -n 20 "$SCEN_ERR")"
    fi

    assert_stage_artifacts "$prefix" "$runtime" "$issue" 1 writer
    assert_stage_artifacts "$prefix" "$runtime" "$issue" 2 reviewer

    hist="$STATE_DIR/pipeline-history.jsonl"
    entry="$(jq -c --arg issue "$issue" 'select(.issue == $issue and .state == "completed")' "$hist" 2>/dev/null | tail -n1)"
    if [ -n "$entry" ]; then
        h_runtime="$(printf '%s' "$entry" | jq -r '.runtime')"
        h_wr="$(printf '%s' "$entry" | jq -r '.agents.writer.runtime')"
        h_rv="$(printf '%s' "$entry" | jq -r '.agents.reviewer.runtime')"
        if [ "$h_runtime" = "$runtime" ] && [ "$h_wr" = "$runtime" ] && [ "$h_rv" = "$runtime" ]; then
            pass "$prefix-4: pipeline-history.jsonl registra runtime:$runtime a nivel de corrida y en agents.writer/agents.reviewer"
        else
            fail "$prefix-4: runtime en historial -- corrida:'$h_runtime' writer:'$h_wr' reviewer:'$h_rv'"
        fi
    else
        fail "$prefix-4: no se encontro entrada 'completed' del issue $issue en pipeline-history.jsonl"
    fi

    if [ -f "$capdir/gh-pr-create.calls" ] && [ "$(wc -l < "$capdir/gh-pr-create.calls" | tr -d ' ')" = "1" ]; then
        pass "$prefix-5: el stub de 'gh pr create' se invoco exactamente una vez (la corrida llego hasta crear el PR)"
    else
        fail "$prefix-5: 'gh pr create' no se invoco la cantidad esperada de veces"
    fi
}

# ============================================================================
# [B] Escenario (a): MEFISTO_RUNTIME=claude, exito de punta a punta
# ============================================================================

echo ""
echo "[B] Escenario (a): MEFISTO_RUNTIME=claude, exito de punta a punta (CA-1/CA-2)"

A_ISSUE="912101"
run_scenario claude "$A_ISSUE" success "$FIXTURES_CLAUDE_DIR/success.jsonl" 0
A_CAP="$SCEN_CAP"
assert_success_run B claude "$A_ISSUE" "$A_CAP"

# ============================================================================
# [C] Escenario (b): MEFISTO_RUNTIME=opencode, exito de punta a punta
# ============================================================================

echo ""
echo "[C] Escenario (b): MEFISTO_RUNTIME=opencode, exito de punta a punta (CA-1/CA-2)"

B_ISSUE="912102"
run_scenario opencode "$B_ISSUE" success "$FIXTURES_OPENCODE_DIR/success-tool-1.18.29.jsonl" 0
B_CAP="$SCEN_CAP"
assert_success_run C opencode "$B_ISSUE" "$B_CAP"

# CA-2(b): el CLI falso de opencode fue invocado con `--agent mefisto-writer`
# y `--agent mefisto-reviewer` -- flag y valor adyacentes en el argv, no
# sueltos. Se ubica cada invocacion por CONTENIDO (no por orden de llamada).
B_WRITER_CALL="$(_find_call "$B_CAP" opencode mefisto-writer || true)"
B_REVIEWER_CALL="$(_find_call "$B_CAP" opencode mefisto-reviewer || true)"
if [ -n "$B_WRITER_CALL" ] && _argv_has_flag_value "$B_WRITER_CALL" --agent mefisto-writer; then
    pass "C-6: el CLI falso de opencode se invoco con '--agent mefisto-writer' (adyacentes) en Stage 1"
else
    fail "C-6: no se encontro una invocacion de opencode con '--agent mefisto-writer': ${B_WRITER_CALL:+$(cat "$B_WRITER_CALL")}"
fi
if [ -n "$B_REVIEWER_CALL" ] && _argv_has_flag_value "$B_REVIEWER_CALL" --agent mefisto-reviewer; then
    pass "C-7: el CLI falso de opencode se invoco con '--agent mefisto-reviewer' (adyacentes) en Stage 2"
else
    fail "C-7: no se encontro una invocacion de opencode con '--agent mefisto-reviewer': ${B_REVIEWER_CALL:+$(cat "$B_REVIEWER_CALL")}"
fi

# ============================================================================
# [D] Escenario (c): MEFISTO_RUNTIME=opencode, fallo terminal del writer en
# Stage 1 (fixture congelado empty-1.18.29.jsonl: stream vacio + exit 1)
# ============================================================================

echo ""
echo "[D] Escenario (c): MEFISTO_RUNTIME=opencode, fallo terminal del writer en Stage 1 (CA-2)"

C_ISSUE="912103"
run_scenario opencode "$C_ISSUE" fail "$FIXTURES_OPENCODE_DIR/empty-1.18.29.jsonl" 1
C_CAP="$SCEN_CAP"

if [ "$SCEN_RC" -ne 0 ]; then
    pass "D-1: el pipeline aborta en Stage 1 (rc=$SCEN_RC != 0)"
else
    fail "D-1: se esperaba que el pipeline abortara (rc=0)"
fi

if [ ! -f "$C_CAP/gh-pr-create.calls" ]; then
    pass "D-2: el stub de 'gh pr create' nunca se invoco"
else
    fail "D-2: 'gh pr create' se invoco pese al fallo terminal en Stage 1"
fi

C_STATUS_FILE="$STATE_DIR/pipeline-status-mefisto-tooling-${C_ISSUE}.json"
if [ -f "$C_STATUS_FILE" ] && [ "$(jq -r '.state' "$C_STATUS_FILE")" = "failed" ]; then
    pass "D-3: el status de la corrida queda en 'failed'"
else
    fail "D-3: no se encontro pipeline-status-mefisto-tooling-${C_ISSUE}.json con state:failed"
fi

C_HIST="$STATE_DIR/pipeline-history.jsonl"
C_FAILED_COUNT="$(jq -c --arg issue "$C_ISSUE" 'select(.issue == $issue and .state == "failed")' "$C_HIST" 2>/dev/null | wc -l | tr -d ' ')"
C_COMPLETED_COUNT="$(jq -c --arg issue "$C_ISSUE" 'select(.issue == $issue and .state == "completed")' "$C_HIST" 2>/dev/null | wc -l | tr -d ' ')"
if [ "${C_FAILED_COUNT:-0}" -ge 1 ] && [ "${C_COMPLETED_COUNT:-0}" = "0" ]; then
    pass "D-4: pipeline-history.jsonl tiene una entrada 'failed' del issue $C_ISSUE y ninguna 'completed'"
else
    fail "D-4: historial inesperado -- failed=$C_FAILED_COUNT completed=$C_COMPLETED_COUNT"
fi

C_WRITER_EV="$(_events_file "$C_ISSUE" "1" "writer")"
if [ -n "$C_WRITER_EV" ] && [ -f "$C_WRITER_EV" ]; then
    C_TERM="$(tail -n1 "$C_WRITER_EV")"
    C_T_TYPE="$(printf '%s' "$C_TERM" | jq -r '.type')"
    if [ "$C_T_TYPE" = "run.failed" ]; then
        pass "D-5: events.jsonl de Stage 1 (writer) termina en run.failed (sin resumen, exit != 0)"
    else
        fail "D-5: terminal inesperado en events.jsonl de Stage 1: $C_TERM"
    fi
else
    fail "D-5: no se encontro events.jsonl de Stage 1 (writer) para el issue $C_ISSUE"
fi

if [ -z "$(_events_file "$C_ISSUE" "2" "reviewer")" ]; then
    pass "D-6: Stage 2 (reviewer) nunca arranco: no hay events.jsonl del reviewer para el issue $C_ISSUE"
else
    fail "D-6: el pipeline lanzo Stage 2 (reviewer) pese al fallo terminal de Stage 1"
fi

# ============================================================================
# [E] Escenario (d): sin mapping local ni --models se aplican las tablas de
# cada adaptador. Claude deep hereda; OpenCode usa Terra/Sol para los stages.
# ============================================================================

echo ""
echo "[E] Escenario (d): defaults de modelo por runtime y perfil (CA-1)"

if [ -n "$B_REVIEWER_CALL" ]; then
    if _argv_has_flag_value "$B_REVIEWER_CALL" -m openai/gpt-5.6-sol; then
        pass "E-1: opencode -- reviewer deep usa '-m openai/gpt-5.6-sol'"
    else
        fail "E-1: opencode -- reviewer deep no uso el default Sol: $(cat "$B_REVIEWER_CALL")"
    fi
else
    fail "E-1: no se pudo localizar la invocacion del reviewer de la corrida (b)"
fi

if [ -n "$B_WRITER_CALL" ]; then
    if _argv_has_flag_value "$B_WRITER_CALL" -m openai/gpt-5.6-terra; then
        pass "E-2: opencode -- writer balanced usa '-m openai/gpt-5.6-terra'"
    else
        fail "E-2: opencode -- writer balanced no uso el default Terra: $(cat "$B_WRITER_CALL")"
    fi
else
    fail "E-2: no se pudo localizar la invocacion del writer de la corrida (b)"
fi

# En claude el agente no viaja como flag: se ubica cada stage por el archivo
# de resumen que su prompt nombra.
A_WRITER_CALL="$(_find_call "$A_CAP" claude stage-1-writer.md || true)"
A_REVIEWER_CALL="$(_find_call "$A_CAP" claude stage-2-reviewer.md || true)"
if [ -n "$A_REVIEWER_CALL" ]; then
    if _argv_has_no_model_flag "$A_REVIEWER_CALL"; then
        pass "E-3: claude -- la linea de comando del reviewer (perfil deep) no contiene --model ni -m ni flags vacios"
    else
        fail "E-3: claude -- la linea de comando del reviewer SI trae --model/-m o un flag vacio: $(cat "$A_REVIEWER_CALL")"
    fi
else
    fail "E-3: no se pudo localizar la invocacion del reviewer de la corrida (a)"
fi

if [ -n "$A_WRITER_CALL" ]; then
    A_WR_MODEL="$(jq -r '(index("--model")) as $i | if $i == null then "" else .[$i+1] // "" end' "$A_WRITER_CALL" 2>/dev/null)"
    if [ -n "$A_WR_MODEL" ]; then
        pass "E-4: control positivo -- claude writer (perfil balanced) SI recibe '--model $A_WR_MODEL'"
    else
        fail "E-4: claude writer (perfil balanced) deberia recibir --model <no vacio>: $(cat "$A_WRITER_CALL")"
    fi
else
    fail "E-4: no se pudo localizar la invocacion del writer de la corrida (a)"
fi


# ============================================================================
# [F] Escenario (e): gate de neutralidad (issue #914) -- el CLI falso del
# writer introduce una fuga real (src/internal/agents/fx-leak.md con
# "model": "sonnet") DENTRO del scope permitido, asi que el gate de scope da
# via libre y Stage 1 aborta por mefisto-neutrality-gate.sh, sin PR.
# ============================================================================

echo ""
echo "[F] Escenario (e): MEFISTO_RUNTIME=claude, fuga de neutralidad en Stage 1 -- el gate la frena (CA-2)"

F_ISSUE="912104"
run_scenario claude "$F_ISSUE" leak "$FIXTURES_CLAUDE_DIR/success.jsonl" 0
F_CAP="$SCEN_CAP"

if [ "$SCEN_RC" -ne 0 ]; then
    pass "F-1: el pipeline aborta en Stage 1 por la fuga de neutralidad (rc=$SCEN_RC != 0)"
else
    fail "F-1: se esperaba que el pipeline abortara (rc=0)"
fi

if [ ! -f "$F_CAP/gh-pr-create.calls" ]; then
    pass "F-2: el stub de 'gh pr create' nunca se invoco"
else
    fail "F-2: 'gh pr create' se invoco pese a la fuga de neutralidad"
fi

F_STATUS_FILE="$STATE_DIR/pipeline-status-mefisto-tooling-${F_ISSUE}.json"
if [ -f "$F_STATUS_FILE" ] && [ "$(jq -r '.state' "$F_STATUS_FILE")" = "failed" ]; then
    pass "F-3: el status de la corrida queda en 'failed'"
else
    fail "F-3: no se encontro pipeline-status-mefisto-tooling-${F_ISSUE}.json con state:failed"
fi

if grep -qE 'src/internal/agents/fx-leak\.md:[0-9]+: R1' "$SCEN_ERR"; then
    pass "F-4: el mensaje de aborto incluye la violacion del gate ('src/internal/agents/fx-leak.md:<linea>: R1')"
else
    fail "F-4: el mensaje de aborto no incluye la violacion esperada. stderr: $(cat "$SCEN_ERR")"
fi

if grep -qF -- "--from-stage 1" "$SCEN_ERR"; then
    pass "F-5: el mensaje de aborto incluye el comando de retoma --from-stage 1"
else
    fail "F-5: el mensaje de aborto no incluye el comando de retoma. stderr: $(cat "$SCEN_ERR")"
fi

F_HIST="$STATE_DIR/pipeline-history.jsonl"
F_FAILED_COUNT="$(jq -c --arg issue "$F_ISSUE" 'select(.issue == $issue and .state == "failed")' "$F_HIST" 2>/dev/null | wc -l | tr -d ' ')"
F_COMPLETED_COUNT="$(jq -c --arg issue "$F_ISSUE" 'select(.issue == $issue and .state == "completed")' "$F_HIST" 2>/dev/null | wc -l | tr -d ' ')"
if [ "${F_FAILED_COUNT:-0}" -ge 1 ] && [ "${F_COMPLETED_COUNT:-0}" = "0" ]; then
    pass "F-6: pipeline-history.jsonl tiene una entrada 'failed' del issue $F_ISSUE y ninguna 'completed'"
else
    fail "F-6: historial inesperado -- failed=$F_FAILED_COUNT completed=$F_COMPLETED_COUNT"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
