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
# en una funcion de ESTE archivo.
#
# Escenarios (CA-1), cada uno una corrida real distinta del pipeline sobre el
# MISMO origin/clon (issue de mentira propio por escenario, para que las
# ramas/worktrees no colisionen):
#   (a) [B] MEFISTO_RUNTIME=claude,   exito de punta a punta.
#   (b) [C] MEFISTO_RUNTIME=opencode, exito de punta a punta.
#   (c) [D] MEFISTO_RUNTIME=opencode, fallo terminal del writer en Stage 1 --
#       el CLI falso reproduce fixtures/runtime-opencode/empty-1.18.29.jsonl
#       (stream vacio, fixture congelado) y sale con exit 1, sin resumen.
#   (d) [E] Modelo heredado: sin .mefisto/models.json ni --models, la linea de
#       comando capturada del CLI falso para el reviewer (perfil deep) no
#       trae --model ni -m. Se verifica sobre la corrida (b): el perfil deep
#       hereda en los DOS adaptadores (adapter_claude_default_model y
#       adapter_opencode_default_model dejan cadena vacia = heredar), asi que
#       una quinta corrida no aportaria nada nuevo.
#
# CA-2 (evidencia verificable, MEF-ADR-0031 -- los artefactos de una corrida
# real, no la lectura del codigo): <log_base>.events.jsonl de cada stage
# termina en run.completed{status:"success"} con el runtime del escenario; el
# archivo de metricas de cada stage lleva runtime/status; pipeline-history.jsonl
# registra runtime a nivel de corrida y en agents.writer/agents.reviewer; en
# (b) el CLI falso de cada stage fue invocado con --agent mefisto-writer /
# --agent mefisto-reviewer; en (c) el pipeline aborta en Stage 1, `gh pr
# create` nunca se invoca, el status queda failed y no hay entrada completed
# en el historial para ese issue.
#
# CA-3: toda la suite corre con CLIs falsas (sin red, sin claude/opencode
# reales instalados -- los stubs preceden en PATH) y
# MEFISTO_AGENT_RETRY_BACKOFF_SECONDS=0; limpia sus temporales via trap.
# Bash 3.2 (sin arrays asociativos, sin mapfile).
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
mkdir -p "$FAKE_BIN"

setup_harness() {
    local bare="$TMP/origin.git"
    git init -q --bare "$bare"
    git clone -q "$bare" "$FAKE_MEFISTO"

    mkdir -p "$FAKE_MEFISTO/.claude-plugin" "$FAKE_MEFISTO/.claude/scripts" \
             "$FAKE_MEFISTO/src/internal/scripts/lib" "$FAKE_MEFISTO/src/internal/prompts" \
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
    cp "$CANON_LIB" "$FAKE_MEFISTO/src/internal/scripts/lib/_mefisto-common.sh"
    cp "$REPO_ROOT/src/internal/scripts/lib/mefisto-state.sh" "$FAKE_MEFISTO/src/internal/scripts/lib/mefisto-state.sh"
    cp "$REPO_ROOT/src/internal/scripts/lib/runtime-claude.sh" "$FAKE_MEFISTO/src/internal/scripts/lib/runtime-claude.sh"
    cp "$REPO_ROOT/src/internal/scripts/lib/runtime-claude.jq" "$FAKE_MEFISTO/src/internal/scripts/lib/runtime-claude.jq"
    cp "$REPO_ROOT/src/internal/scripts/lib/runtime-opencode.sh" "$FAKE_MEFISTO/src/internal/scripts/lib/runtime-opencode.sh"
    cp "$REPO_ROOT/src/internal/scripts/lib/runtime-opencode.jq" "$FAKE_MEFISTO/src/internal/scripts/lib/runtime-opencode.jq"
    cp "$REPO_ROOT/src/internal/scripts/lib/mefisto-runtime.sh" "$FAKE_MEFISTO/src/internal/scripts/lib/mefisto-runtime.sh"
    cp "$REPO_ROOT/src/internal/scripts/lib/mefisto-models.sh" "$FAKE_MEFISTO/src/internal/scripts/lib/mefisto-models.sh"
    cp "$REPO_ROOT/src/internal/scripts/lib/adapter-claude.sh" "$FAKE_MEFISTO/src/internal/scripts/lib/adapter-claude.sh"
    cp "$REPO_ROOT/src/internal/scripts/lib/adapter-opencode.sh" "$FAKE_MEFISTO/src/internal/scripts/lib/adapter-opencode.sh"
    cp "$REPO_ROOT/src/internal/prompts/noninteractive-system.md" "$FAKE_MEFISTO/src/internal/prompts/noninteractive-system.md"
    cp "$REPO_ROOT/src/internal/scripts/mefisto-run-agent.sh" "$FAKE_MEFISTO/src/internal/scripts/mefisto-run-agent.sh"
    chmod +x "$FAKE_MEFISTO/src/internal/scripts/mefisto-run-agent.sh"
    cp "$CANON_PIPE" "$FAKE_MEFISTO/src/internal/scripts/mefisto-tooling-pipeline.sh"
    cp "$SHIM_LIB" "$FAKE_MEFISTO/.claude/scripts/_mefisto-common.sh"
    cp "$SHIM_PIPE" "$FAKE_MEFISTO/.claude/scripts/mefisto-tooling-pipeline.sh"
    chmod +x "$FAKE_MEFISTO/.claude/scripts/mefisto-tooling-pipeline.sh" "$FAKE_MEFISTO/src/internal/scripts/mefisto-tooling-pipeline.sh"
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

    # --- Stub de claude: reproduce tal cual (cat, sin editarlo) el fixture
    # crudo congelado que indique MEFISTO_TEST_FIXTURE, captura su propio argv
    # completo con jq --args (issue #863: el mensaje puede traer saltos de
    # linea, un separador de texto no serviria) y, en modo "success", escribe
    # el resumen de stage + un archivo notable dentro del scope + un fragmento
    # de changelog.d/ (para que el gate de CHANGELOG dado en el issue #380 dea
    # via libre hasta crear el PR).
    cat > "$FAKE_BIN/claude" <<'STUB'
#!/usr/bin/env bash
CAP="${MEFISTO_TEST_CAPTURE_DIR:?MEFISTO_TEST_CAPTURE_DIR sin fijar}"
N_FILE="$CAP/claude-call-count"
N=$(( $(cat "$N_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$N" > "$N_FILE"
jq -n --args '$ARGS.positional' -- "$@" > "$CAP/claude-call-$N.json" 2>/dev/null || true

if [ "${MEFISTO_TEST_MODE:-success}" = "success" ]; then
    mkdir -p .mefisto/pipeline/summaries docs changelog.d
    echo "resumen stub writer (claude)" > .mefisto/pipeline/summaries/stage-1-writer.md
    echo "resumen stub reviewer (claude)" > .mefisto/pipeline/summaries/stage-2-reviewer.md
    echo "cambio del stub e2e $(date +%s%N)" >> docs/912-e2e-marker.md
    echo "- cambio del stub e2e (runtime-neutral)" > changelog.d/912-e2e.added.md
fi

if [ -n "${MEFISTO_TEST_FIXTURE:-}" ]; then
    cat "$MEFISTO_TEST_FIXTURE"
fi
exit "${MEFISTO_TEST_EXIT_CODE:-0}"
STUB
    chmod +x "$FAKE_BIN/claude"

    # --- Stub de opencode: mismo idioma que el stub de claude de arriba,
    # sobre las fixtures de fixtures/runtime-opencode/ (formato --format json
    # de OpenCode 1.18.29, con --agent/--dir/-m como flags reales del argv en
    # vez de heredarse del cwd/entorno como hace claude).
    cat > "$FAKE_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
CAP="${MEFISTO_TEST_CAPTURE_DIR:?MEFISTO_TEST_CAPTURE_DIR sin fijar}"
N_FILE="$CAP/opencode-call-count"
N=$(( $(cat "$N_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$N" > "$N_FILE"
jq -n --args '$ARGS.positional' -- "$@" > "$CAP/opencode-call-$N.json" 2>/dev/null || true

if [ "${MEFISTO_TEST_MODE:-success}" = "success" ]; then
    mkdir -p .mefisto/pipeline/summaries docs changelog.d
    echo "resumen stub writer (opencode)" > .mefisto/pipeline/summaries/stage-1-writer.md
    echo "resumen stub reviewer (opencode)" > .mefisto/pipeline/summaries/stage-2-reviewer.md
    echo "cambio del stub e2e $(date +%s%N)" >> docs/912-e2e-marker.md
    echo "- cambio del stub e2e (runtime-neutral)" > changelog.d/912-e2e.added.md
fi

if [ -n "${MEFISTO_TEST_FIXTURE:-}" ]; then
    cat "$MEFISTO_TEST_FIXTURE"
fi
exit "${MEFISTO_TEST_EXIT_CODE:-0}"
STUB
    chmod +x "$FAKE_BIN/opencode"
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
# claude-call-N/opencode-call-N arranquen en 1 en cada corrida) y su propio
# numero de issue de mentira (para que rama/worktree no colisionen entre
# escenarios que reutilizan el mismo origin/clon). Deja SCEN_RC/SCEN_OUT/
# SCEN_ERR/SCEN_CAP/SCEN_STATE_DIR poblados para que el caller haga sus
# aserciones.
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
    SCEN_STATE_DIR="$FAKE_MEFISTO/.mefisto/pipeline"
}

# _events_file <issue_num> <stage> <agent> -- ruta del events.jsonl del stage
# (timestamp desconocido de antemano: se resuelve con find + comodin).
_events_file() {
    find "$SCEN_STATE_DIR/logs" -name "mefisto-tooling-stage-${2}-${3}-*-issue-${1}.events.jsonl" 2>/dev/null | head -n1
}

# _metrics_file <issue_num> <stage> <agent> -- ruta del metrics/*.json del stage.
_metrics_file() {
    find "$SCEN_STATE_DIR/metrics" -name "mefisto-tooling-*-issue-${1}-stage-${2}-${3}.json" 2>/dev/null | head -n1
}

# ============================================================================
# [B] Escenario (a): MEFISTO_RUNTIME=claude, exito de punta a punta
# ============================================================================

echo ""
echo "[B] Escenario (a): MEFISTO_RUNTIME=claude, exito de punta a punta (CA-1/CA-2)"

A_ISSUE="912101"
run_scenario claude "$A_ISSUE" success "$FIXTURES_CLAUDE_DIR/success.jsonl" 0
A_CAP="$SCEN_CAP"; A_STATE_DIR="$SCEN_STATE_DIR"

if [ "$SCEN_RC" -eq 0 ]; then
    pass "B-1: el pipeline completa con exito bajo runtime=claude (rc=0)"
else
    fail "B-1: rc=$SCEN_RC -- stderr: $(tail -n 20 "$SCEN_ERR")"
fi

for stage_agent in "1 writer" "2 reviewer"; do
    set -- $stage_agent
    stage="$1"; agent="$2"
    ev="$(_events_file "$A_ISSUE" "$stage" "$agent")"
    if [ -n "$ev" ] && [ -f "$ev" ]; then
        term="$(tail -n1 "$ev")"
        t_type="$(printf '%s' "$term" | jq -r '.type')"
        t_status="$(printf '%s' "$term" | jq -r '.status')"
        t_runtime="$(printf '%s' "$term" | jq -r '.runtime')"
        if [ "$t_type" = "run.completed" ] && [ "$t_status" = "success" ] && [ "$t_runtime" = "claude" ]; then
            pass "B-2: stage $stage ($agent) -- events.jsonl termina en run.completed{status:success, runtime:claude}"
        else
            fail "B-2: stage $stage ($agent) -- terminal inesperado: $term"
        fi
    else
        fail "B-2: stage $stage ($agent) -- no se encontro events.jsonl bajo $A_STATE_DIR/logs"
    fi

    mf="$(_metrics_file "$A_ISSUE" "$stage" "$agent")"
    if [ -n "$mf" ] && [ -f "$mf" ]; then
        m_runtime="$(jq -r '.runtime' "$mf")"
        m_status="$(jq -r '.status' "$mf")"
        if [ "$m_runtime" = "claude" ] && [ "$m_status" = "success" ]; then
            pass "B-3: stage $stage ($agent) -- metrics/*.json lleva runtime:claude, status:success"
        else
            fail "B-3: stage $stage ($agent) -- metrics con runtime='$m_runtime' status='$m_status'"
        fi
    else
        fail "B-3: stage $stage ($agent) -- no se encontro metrics/*.json bajo $A_STATE_DIR/metrics"
    fi
done

A_HIST="$A_STATE_DIR/pipeline-history.jsonl"
A_HIST_ENTRY="$(jq -c --arg issue "$A_ISSUE" 'select(.issue == $issue and .state == "completed")' "$A_HIST" 2>/dev/null | tail -n1)"
if [ -n "$A_HIST_ENTRY" ]; then
    A_H_RUNTIME="$(printf '%s' "$A_HIST_ENTRY" | jq -r '.runtime')"
    A_H_WR_RT="$(printf '%s' "$A_HIST_ENTRY" | jq -r '.agents.writer.runtime')"
    A_H_RV_RT="$(printf '%s' "$A_HIST_ENTRY" | jq -r '.agents.reviewer.runtime')"
    if [ "$A_H_RUNTIME" = "claude" ] && [ "$A_H_WR_RT" = "claude" ] && [ "$A_H_RV_RT" = "claude" ]; then
        pass "B-4: pipeline-history.jsonl registra runtime:claude a nivel de corrida y en agents.writer/agents.reviewer"
    else
        fail "B-4: runtime en historial -- corrida:'$A_H_RUNTIME' writer:'$A_H_WR_RT' reviewer:'$A_H_RV_RT'"
    fi
else
    fail "B-4: no se encontro entrada 'completed' del issue $A_ISSUE en pipeline-history.jsonl"
fi

if [ -f "$A_CAP/gh-pr-create.calls" ] && [ "$(wc -l < "$A_CAP/gh-pr-create.calls" | tr -d ' ')" = "1" ]; then
    pass "B-5: el stub de 'gh pr create' se invoco exactamente una vez (la corrida llego hasta crear el PR)"
else
    fail "B-5: 'gh pr create' no se invoco la cantidad esperada de veces"
fi

# ============================================================================
# [C] Escenario (b): MEFISTO_RUNTIME=opencode, exito de punta a punta
# ============================================================================

echo ""
echo "[C] Escenario (b): MEFISTO_RUNTIME=opencode, exito de punta a punta (CA-1/CA-2)"

B_ISSUE="912102"
run_scenario opencode "$B_ISSUE" success "$FIXTURES_OPENCODE_DIR/success-tool-1.18.29.jsonl" 0
B_CAP="$SCEN_CAP"; B_STATE_DIR="$SCEN_STATE_DIR"

if [ "$SCEN_RC" -eq 0 ]; then
    pass "C-1: el pipeline completa con exito bajo runtime=opencode (rc=0)"
else
    fail "C-1: rc=$SCEN_RC -- stderr: $(tail -n 20 "$SCEN_ERR")"
fi

for stage_agent in "1 writer" "2 reviewer"; do
    set -- $stage_agent
    stage="$1"; agent="$2"
    ev="$(_events_file "$B_ISSUE" "$stage" "$agent")"
    if [ -n "$ev" ] && [ -f "$ev" ]; then
        term="$(tail -n1 "$ev")"
        t_type="$(printf '%s' "$term" | jq -r '.type')"
        t_status="$(printf '%s' "$term" | jq -r '.status')"
        t_runtime="$(printf '%s' "$term" | jq -r '.runtime')"
        if [ "$t_type" = "run.completed" ] && [ "$t_status" = "success" ] && [ "$t_runtime" = "opencode" ]; then
            pass "C-2: stage $stage ($agent) -- events.jsonl termina en run.completed{status:success, runtime:opencode}"
        else
            fail "C-2: stage $stage ($agent) -- terminal inesperado: $term"
        fi
    else
        fail "C-2: stage $stage ($agent) -- no se encontro events.jsonl bajo $B_STATE_DIR/logs"
    fi

    mf="$(_metrics_file "$B_ISSUE" "$stage" "$agent")"
    if [ -n "$mf" ] && [ -f "$mf" ]; then
        m_runtime="$(jq -r '.runtime' "$mf")"
        m_status="$(jq -r '.status' "$mf")"
        if [ "$m_runtime" = "opencode" ] && [ "$m_status" = "success" ]; then
            pass "C-3: stage $stage ($agent) -- metrics/*.json lleva runtime:opencode, status:success"
        else
            fail "C-3: stage $stage ($agent) -- metrics con runtime='$m_runtime' status='$m_status'"
        fi
    else
        fail "C-3: stage $stage ($agent) -- no se encontro metrics/*.json bajo $B_STATE_DIR/metrics"
    fi
done

B_HIST="$B_STATE_DIR/pipeline-history.jsonl"
B_HIST_ENTRY="$(jq -c --arg issue "$B_ISSUE" 'select(.issue == $issue and .state == "completed")' "$B_HIST" 2>/dev/null | tail -n1)"
if [ -n "$B_HIST_ENTRY" ]; then
    B_H_RUNTIME="$(printf '%s' "$B_HIST_ENTRY" | jq -r '.runtime')"
    B_H_WR_RT="$(printf '%s' "$B_HIST_ENTRY" | jq -r '.agents.writer.runtime')"
    B_H_RV_RT="$(printf '%s' "$B_HIST_ENTRY" | jq -r '.agents.reviewer.runtime')"
    if [ "$B_H_RUNTIME" = "opencode" ] && [ "$B_H_WR_RT" = "opencode" ] && [ "$B_H_RV_RT" = "opencode" ]; then
        pass "C-4: pipeline-history.jsonl registra runtime:opencode a nivel de corrida y en agents.writer/agents.reviewer"
    else
        fail "C-4: runtime en historial -- corrida:'$B_H_RUNTIME' writer:'$B_H_WR_RT' reviewer:'$B_H_RV_RT'"
    fi
else
    fail "C-4: no se encontro entrada 'completed' del issue $B_ISSUE en pipeline-history.jsonl"
fi

if [ -f "$B_CAP/gh-pr-create.calls" ] && [ "$(wc -l < "$B_CAP/gh-pr-create.calls" | tr -d ' ')" = "1" ]; then
    pass "C-5: el stub de 'gh pr create' se invoco exactamente una vez (la corrida llego hasta crear el PR)"
else
    fail "C-5: 'gh pr create' no se invoco la cantidad esperada de veces"
fi

# CA-2(b): el CLI falso de opencode fue invocado con --agent mefisto-writer y
# --agent mefisto-reviewer. Se busca por CONTENIDO (no por orden de llamada):
# cada call-N.json es el array $ARGS.positional completo de una invocacion.
B_WRITER_CALL=""
B_REVIEWER_CALL=""
for f in "$B_CAP"/opencode-call-*.json; do
    [ -f "$f" ] || continue
    if jq -e 'index("mefisto-writer") != null' "$f" >/dev/null 2>&1; then
        B_WRITER_CALL="$f"
    elif jq -e 'index("mefisto-reviewer") != null' "$f" >/dev/null 2>&1; then
        B_REVIEWER_CALL="$f"
    fi
done
if [ -n "$B_WRITER_CALL" ] && jq -e 'index("--agent") != null' "$B_WRITER_CALL" >/dev/null 2>&1; then
    pass "C-6: el CLI falso de opencode se invoco con --agent mefisto-writer en Stage 1"
else
    fail "C-6: no se encontro una invocacion de opencode con --agent mefisto-writer"
fi
if [ -n "$B_REVIEWER_CALL" ] && jq -e 'index("--agent") != null' "$B_REVIEWER_CALL" >/dev/null 2>&1; then
    pass "C-7: el CLI falso de opencode se invoco con --agent mefisto-reviewer en Stage 2"
else
    fail "C-7: no se encontro una invocacion de opencode con --agent mefisto-reviewer"
fi

# ============================================================================
# [D] Escenario (c): MEFISTO_RUNTIME=opencode, fallo terminal del writer en
# Stage 1 (fixture congelado empty-1.18.29.jsonl: stream vacio + exit 1)
# ============================================================================

echo ""
echo "[D] Escenario (c): MEFISTO_RUNTIME=opencode, fallo terminal del writer en Stage 1 (CA-2)"

C_ISSUE="912103"
run_scenario opencode "$C_ISSUE" fail "$FIXTURES_OPENCODE_DIR/empty-1.18.29.jsonl" 1
C_CAP="$SCEN_CAP"; C_STATE_DIR="$SCEN_STATE_DIR"

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

C_STATUS_FILE="$C_STATE_DIR/pipeline-status-mefisto-tooling-${C_ISSUE}.json"
if [ -f "$C_STATUS_FILE" ] && [ "$(jq -r '.state' "$C_STATUS_FILE")" = "failed" ]; then
    pass "D-3: el status de la corrida queda en 'failed'"
else
    fail "D-3: no se encontro pipeline-status-mefisto-tooling-${C_ISSUE}.json con state:failed"
fi

C_HIST="$C_STATE_DIR/pipeline-history.jsonl"
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

# ============================================================================
# [E] Escenario (d): modelo heredado -- el reviewer (perfil deep) nunca ve
# --model ni -m. Se reutiliza la corrida (b): adapter_claude_default_model y
# adapter_opencode_default_model dejan cadena vacia (= heredar) para "deep" en
# los DOS runtimes, asi que no hace falta una quinta corrida (MEF-ADR-0049
# decision 4).
# ============================================================================

echo ""
echo "[E] Escenario (d): modelo heredado -- el reviewer nunca ve --model ni -m (CA-1)"

if [ -n "$B_REVIEWER_CALL" ]; then
    if jq -e '(index("-m") == null) and (index("--model") == null)' "$B_REVIEWER_CALL" >/dev/null 2>&1; then
        pass "E-1: la linea de comando capturada del reviewer (perfil deep) no contiene --model ni -m"
    else
        fail "E-1: la linea de comando del reviewer SI trae --model/-m: $(cat "$B_REVIEWER_CALL")"
    fi
else
    fail "E-1: no se pudo localizar la invocacion del reviewer de la corrida (b) para verificar el modelo heredado"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
