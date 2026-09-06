#!/usr/bin/env bash
# test-tooling-state-paths.sh -- Tests del traslado de mefisto-tooling-pipeline.sh
# y _mefisto-common.sh al layout canonico, con rutas de estado neutrales
# (MEF-ADR-0049, issue #869).
#
# Cubre:
#   [pre] Los canonicos existen en src/internal/scripts/{,lib/} con sintaxis
#         bash valida; los shims de .claude/scripts/ tambien (CA-1).
#   [A]   Los shims son EXACTAMENTE la plantilla documentada en
#         src/internal/scripts/README.md: exec de 3 lineas para el pipeline,
#         source de una linea para la lib (CA-1).
#   [B]   El pipeline canonico no contiene la ruta legacy ".claude/pipeline"
#         (CA-2).
#   [C]   El pipeline canonico resuelve su estado con MEFISTO_STATE_DIR /
#         mefisto_state_path, no con una ruta hardcodeada (CA-2).
#   [D]   collect_summary() y el SUMMARY_FILE de run_agent() resuelven el
#         resumen de stage con mefisto_state_path "summaries/..." "$WORKTREE_PATH"
#         (CA-2).
#   [E]   Los prompts de stage 1/2 le piden al agente escribir su resumen bajo
#         .mefisto/pipeline/summaries/, nunca bajo .claude/pipeline/ (CA-2).
#   [F]   MEFISTO_RUNTIME se registra en events.log/status/historial, pero la
#         invocacion de `claude` no cambia en este issue (CA-4; #879 la conecta).
#   [G]   Corrida real con stubs (claude/gh) contra un origin bare: al cerrar
#         Stage 1 y Stage 2, logs/, metrics/, pipeline-status-*.json y
#         pipeline-history.jsonl (con una linea "failed") quedan bajo
#         .mefisto/pipeline/ del clon, el directorio de summaries del worktree
#         nace bajo .mefisto/pipeline/summaries/, y nada nuevo aparece bajo
#         .claude/pipeline/ (CA-6). El corte lo da el gate de changelog.d/
#         (ningun fragmento creado): no hace falta stub de push/PR.
#   [H]   mefisto-metrics-report.sh agrega el historial de AMBAS ubicaciones:
#         el legacy (.claude/pipeline/, que ya no recibe corridas nuevas y no se
#         migra) y el canonico (.mefisto/pipeline/), corriendo el CLI real
#         contra un repo de mentira con una corrida en cada una (CA-6).
#   [I]   Los lanzadores que aun viven en .claude/scripts/ (tmux, herdr)
#         resuelven events.log y logs/ con mefisto_state_path, de modo que el
#         traslado del pipeline no los deja vigilando archivos que ya nadie
#         escribe (CA-3; el porte completo de ambos es #871/#872).
#
# Uso: .claude/scripts/tests/test-tooling-state-paths.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

CANON_PIPE="$REPO_ROOT/src/internal/scripts/mefisto-tooling-pipeline.sh"
CANON_LIB="$REPO_ROOT/src/internal/scripts/lib/_mefisto-common.sh"
SHIM_PIPE="$REPO_ROOT/.claude/scripts/mefisto-tooling-pipeline.sh"
SHIM_LIB="$REPO_ROOT/.claude/scripts/_mefisto-common.sh"

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# -------- Bloque pre --------

echo "[pre] Canonicos y shims existen, con sintaxis bash valida"
for f in "$CANON_PIPE" "$CANON_LIB" "$SHIM_PIPE" "$SHIM_LIB"; do
    if [ -f "$f" ]; then
        pass "$(basename "$(dirname "$f")")/$(basename "$f"): presente"
    else
        fail "$f: ausente"
        echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
        exit 1
    fi
    if bash -n "$f" 2>/dev/null; then
        pass "$(basename "$f") ($f): sintaxis bash valida"
    else
        fail "$(basename "$f") ($f): sintaxis bash invalida"
    fi
done

# -------- Bloque A: los shims son la plantilla exacta --------

echo ""
echo "[A] Los shims siguen la plantilla documentada (CA-1)"

if [ -x "$SHIM_PIPE" ]; then pass "el shim del pipeline tiene bit de ejecucion"; else fail "el shim del pipeline no es ejecutable"; fi

EXPECTED_EXEC_SHIM='exec "$(cd "$(dirname "$0")/../.." && pwd)/src/internal/scripts/$(basename "$0")" "$@"'
if grep -qF "$EXPECTED_EXEC_SHIM" "$SHIM_PIPE"; then
    pass "el shim del pipeline usa 'exec' con la forma documentada"
else
    fail "el shim del pipeline no coincide con la plantilla de exec de src/internal/scripts/README.md"
fi
if [ "$(grep -cv '^\s*#' "$SHIM_PIPE" | grep -cv '^\s*$')" -le 2 ]; then
    pass "el shim del pipeline no tiene logica propia (solo shebang + exec)"
else
    fail "el shim del pipeline tiene mas codigo del esperado"
fi

if grep -q '^source ' "$SHIM_LIB"; then
    pass "el shim de la lib usa 'source' (no 'exec': se sourcea, no se ejecuta)"
else
    fail "el shim de la lib no usa 'source'"
fi
if grep -qF 'src/internal/scripts/lib/_mefisto-common.sh' "$SHIM_LIB"; then
    pass "el shim de la lib apunta al canonico en src/internal/scripts/lib/"
else
    fail "el shim de la lib no referencia la ruta canonica"
fi
if grep -q 'BASH_SOURCE\[0\]' "$SHIM_LIB"; then
    pass "el shim de la lib resuelve via BASH_SOURCE (correcto para un archivo sourceado, no ejecutado)"
else
    fail "el shim de la lib no usa BASH_SOURCE -- '\$0' resolveria mal cuando se sourcea"
fi

# -------- Bloque B: sin la ruta legacy --------

echo ""
echo "[B] El pipeline canonico no contiene la ruta legacy '.claude/pipeline' (CA-2)"
if grep -q '\.claude/pipeline' "$CANON_PIPE"; then
    fail "el pipeline canonico todavia contiene '.claude/pipeline'"
    grep -n '\.claude/pipeline' "$CANON_PIPE"
else
    pass "el pipeline canonico no contiene '.claude/pipeline'"
fi

# -------- Bloque C: el estado se resuelve via el helper neutral --------

echo ""
echo "[C] El pipeline resuelve su estado con MEFISTO_STATE_DIR / mefisto_state_path (CA-2)"

if grep -qF 'PIPELINE_DIR="$MEFISTO_STATE_DIR"' "$CANON_PIPE"; then
    pass "PIPELINE_DIR se resuelve desde MEFISTO_STATE_DIR (mefisto-state.sh)"
else
    fail "PIPELINE_DIR ya no se resuelve desde MEFISTO_STATE_DIR"
fi
if grep -qF 'mkdir -p "$WORKTREE_PATH/.mefisto/pipeline/summaries"' "$CANON_PIPE"; then
    pass "el directorio de summaries del worktree se crea bajo .mefisto/pipeline/"
else
    fail "el directorio de summaries del worktree no se crea bajo .mefisto/pipeline/"
fi

# -------- Bloque D: collect_summary/SUMMARY_FILE via mefisto_state_path --------

echo ""
echo "[D] collect_summary() y SUMMARY_FILE resuelven con mefisto_state_path \"summaries/...\" \"\$WORKTREE_PATH\" (CA-2)"

MEFISTO_STATE_PATH_SUMMARY_HITS=$(grep -c 'mefisto_state_path "summaries/stage-\${stage}-\${agent}\.md" "\$WORKTREE_PATH"' "$CANON_PIPE")
if [ "$MEFISTO_STATE_PATH_SUMMARY_HITS" -ge 2 ]; then
    pass "collect_summary() y run_agent() resuelven el resumen via mefisto_state_path (>=2 usos, obtenido $MEFISTO_STATE_PATH_SUMMARY_HITS)"
else
    fail "solo $MEFISTO_STATE_PATH_SUMMARY_HITS uso(s) de mefisto_state_path para el resumen de stage: se esperaban >=2 (collect_summary + run_agent)"
fi

# -------- Bloque E: los prompts de stage referencian la ruta canonica --------

echo ""
echo "[E] Los prompts de stage 1/2 le piden al agente escribir en .mefisto/pipeline/summaries/ (CA-2)"

if grep -qF '.mefisto/pipeline/summaries/stage-1-writer.md' "$CANON_PIPE"; then
    pass "el prompt de stage 1 referencia .mefisto/pipeline/summaries/stage-1-writer.md"
else
    fail "el prompt de stage 1 no referencia la ruta canonica del resumen"
fi
if grep -qF '.mefisto/pipeline/summaries/stage-2-reviewer.md' "$CANON_PIPE"; then
    pass "el prompt de stage 2 referencia .mefisto/pipeline/summaries/stage-2-reviewer.md"
else
    fail "el prompt de stage 2 no referencia la ruta canonica del resumen"
fi

# -------- Bloque F: MEFISTO_RUNTIME se registra, sin seleccionar CLI (CA-4) --------

echo ""
echo "[F] MEFISTO_RUNTIME se registra en status/historial; la invocacion de claude no cambia (CA-4)"

if grep -qF 'MEFISTO_RUNTIME_RECEIVED="${MEFISTO_RUNTIME:-}"' "$CANON_PIPE"; then
    pass "el pipeline captura MEFISTO_RUNTIME del entorno"
else
    fail "el pipeline no captura MEFISTO_RUNTIME"
fi
if grep -qF '"runtime": ${MEFISTO_RUNTIME_JSON:-null}' "$CANON_PIPE"; then
    pass "el status declara el campo runtime"
else
    fail "el status no declara el campo runtime"
fi
RUNTIME_HISTORY_HITS=$(grep -cF '\"runtime\":${MEFISTO_RUNTIME_JSON:-null}' "$CANON_PIPE")
if [ "$RUNTIME_HISTORY_HITS" -ge 2 ]; then
    pass "las 2 lineas de historial (completed y failed) llevan runtime ($RUNTIME_HISTORY_HITS)"
else
    fail "solo $RUNTIME_HISTORY_HITS linea(s) de historial llevan runtime: se esperan 2"
fi
if grep -qE '^\s*claude -p "\$prompt" --model "\$AGENT_MODEL"' "$CANON_PIPE"; then
    pass "la invocacion de 'claude -p' no cambio en este issue (#879 la conecta al runner neutral)"
else
    fail "la invocacion de 'claude -p' cambio de forma inesperada para este issue"
fi

# -------- Bloque G: corrida real con stubs, estado bajo .mefisto/pipeline/ --------

echo ""
echo "[G] Corrida real con stubs: logs/metrics/status/historial quedan bajo .mefisto/pipeline/ (CA-6)"

if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP: el bloque G requiere jq y python3, no disponibles en este entorno"
else
    G_TMP="$TMP/g"
    mkdir -p "$G_TMP"

    # Origin bare + clon "fake-mefisto", con el mismo layout canonico que el
    # repo real (canonicos + shims + .gitignore con .mefisto/), para que
    # 'git worktree add ... origin/main' (el primer paso real del pipeline)
    # resuelva igual que en produccion.
    BARE="$G_TMP/origin.git"
    git init -q --bare "$BARE"
    FAKE_MEFISTO="$G_TMP/fake-mefisto"
    git clone -q "$BARE" "$FAKE_MEFISTO"

    mkdir -p "$FAKE_MEFISTO/.claude-plugin" "$FAKE_MEFISTO/.claude/scripts" \
             "$FAKE_MEFISTO/src/internal/scripts/lib" "$FAKE_MEFISTO/docs" \
             "$FAKE_MEFISTO/changelog.d"
    cat > "$FAKE_MEFISTO/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "mefisto",
  "version": "0.0.0"
}
EOF
    printf '.mefisto/\n.claude/pipeline/\n' > "$FAKE_MEFISTO/.gitignore"
    cp "$CANON_LIB" "$FAKE_MEFISTO/src/internal/scripts/lib/_mefisto-common.sh"
    cp "$REPO_ROOT/src/internal/scripts/lib/mefisto-state.sh" "$FAKE_MEFISTO/src/internal/scripts/lib/mefisto-state.sh"
    cp "$CANON_PIPE" "$FAKE_MEFISTO/src/internal/scripts/mefisto-tooling-pipeline.sh"
    cp "$SHIM_LIB" "$FAKE_MEFISTO/.claude/scripts/_mefisto-common.sh"
    cp "$SHIM_PIPE" "$FAKE_MEFISTO/.claude/scripts/mefisto-tooling-pipeline.sh"
    chmod +x "$FAKE_MEFISTO/.claude/scripts/mefisto-tooling-pipeline.sh" "$FAKE_MEFISTO/src/internal/scripts/mefisto-tooling-pipeline.sh"
    echo "# changelog.d" > "$FAKE_MEFISTO/changelog.d/README.md"

    (cd "$FAKE_MEFISTO" \
        && git add -A \
        && git -c user.email="test@example.com" -c user.name="Test" commit -q -m "base" \
        && git push -q origin main)

    FAKE_BIN="$G_TMP/bin"
    mkdir -p "$FAKE_BIN"

    # Stub de gh: solo 'issue view' responde algo util (un issue abierto). El
    # resto (repo view, etc.) falla -- el pipeline ya degrada con '|| echo ""'.
    # No hace falta stub de 'gh pr create' ni de push a origin: el gate de
    # changelog.d/ (ningun fragmento creado) corta la corrida ANTES de llegar
    # ahi.
    cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    printf '{"number":%s,"title":"E2E stub issue 869","body":"cuerpo de prueba stub","state":"OPEN"}\n' "$3"
    exit 0
fi
exit 1
STUB
    chmod +x "$FAKE_BIN/gh"

    # Stub de claude: cada invocacion (writer y reviewer) toca un archivo
    # NOTABLE fuera de changelog.d/ (para forzar el gate de changelog al
    # cerrar stage 2) y deja los dos resumenes de stage bajo la ruta canonica
    # -- auto_commit_if_needed del propio pipeline stagea y commitea el
    # cambio, el stub no necesita invocar git.
    cat > "$FAKE_BIN/claude" <<'STUB'
#!/usr/bin/env bash
mkdir -p docs
echo "cambio del stub $(date +%s%N)" >> docs/869-e2e-marker.md
mkdir -p .mefisto/pipeline/summaries
echo "resumen stub writer" > .mefisto/pipeline/summaries/stage-1-writer.md
echo "resumen stub reviewer" > .mefisto/pipeline/summaries/stage-2-reviewer.md
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"duration_ms":10,"duration_api_ms":5,"total_cost_usd":0.0001,"usage":{"input_tokens":1,"output_tokens":1}}'
exit 0
STUB
    chmod +x "$FAKE_BIN/claude"

    G_OUT="$G_TMP/stdout"; G_ERR="$G_TMP/stderr"
    (
        cd "$FAKE_MEFISTO" || exit 99
        # -u de las MEFISTO_* de estado/repo: esta MISMA sesion corre dentro de
        # una invocacion real de mefisto-tooling-pipeline.sh (el repo principal
        # las exporta antes de invocar `claude -p`), y sin este `env -u` la
        # corrida contra FAKE_MEFISTO heredaria MEFISTO_STATE_DIR/MEFISTO_REPO_ROOT
        # del proceso PADRE -- escribiendo el estado de esta prueba en el
        # .mefisto/pipeline/ del repo real en vez del clon temporal.
        env -u MEFISTO_STATE_DIR -u MEFISTO_LEGACY_STATE_DIR -u MEFISTO_REPO_ROOT \
            -u MEFISTO_PROJECT_NAME -u MEFISTO_REPO_SLUG -u MEFISTO_RUNTIME \
            PATH="$FAKE_BIN:$PATH" MEFISTO_AGENT_RETRY_BACKOFF_SECONDS=0 \
            ./.claude/scripts/mefisto-tooling-pipeline.sh 869
    ) </dev/null >"$G_OUT" 2>"$G_ERR"
    G_RC=$?

    if [ "$G_RC" -ne 0 ]; then
        pass "G-1: la corrida aborta (rc=$G_RC) -- se espera el gate de changelog.d/ sin fragmento"
    else
        fail "G-1: se esperaba que la corrida abortara en el gate de changelog.d/ (rc=0)"
    fi
    if grep -q "Cambio notable sin fragmento en changelog.d/" "$G_ERR"; then
        pass "G-2: el motivo del aborto es el gate de changelog.d/ (confirma que Stage 1 y 2 corrieron)"
    else
        fail "G-2: el aborto no fue por el gate de changelog.d/ -- stderr: $(cat "$G_ERR")"
    fi

    STATE_DIR="$FAKE_MEFISTO/.mefisto/pipeline"
    if [ -d "$STATE_DIR/logs" ] && [ -n "$(find "$STATE_DIR/logs" -type f 2>/dev/null)" ]; then
        pass "G-3: .mefisto/pipeline/logs/ tiene archivos"
    else
        fail "G-3: .mefisto/pipeline/logs/ esta vacio o ausente"
    fi
    if [ -d "$STATE_DIR/metrics" ] && [ -n "$(find "$STATE_DIR/metrics" -type f 2>/dev/null)" ]; then
        pass "G-4: .mefisto/pipeline/metrics/ tiene archivos"
    else
        fail "G-4: .mefisto/pipeline/metrics/ esta vacio o ausente"
    fi
    if compgen -G "$STATE_DIR/pipeline-status-mefisto-tooling-869*.json" >/dev/null 2>&1; then
        pass "G-5: pipeline-status-mefisto-tooling-869*.json existe bajo .mefisto/pipeline/ (el abort no lo borra)"
    else
        fail "G-5: no se encontro pipeline-status-mefisto-tooling-869*.json bajo .mefisto/pipeline/"
    fi
    if [ -f "$STATE_DIR/pipeline-history.jsonl" ] && grep -q '"issue":"869".*"state":"failed"' "$STATE_DIR/pipeline-history.jsonl"; then
        pass "G-6: pipeline-history.jsonl registra la corrida con state=failed"
    else
        fail "G-6: pipeline-history.jsonl no registra la corrida fallida"
    fi
    if [ -f "$STATE_DIR/events.log" ] && grep -q "MEFISTO-TOOLING" "$STATE_DIR/events.log"; then
        pass "G-7: events.log de la corrida vive bajo .mefisto/pipeline/"
    else
        fail "G-7: no se encontro events.log bajo .mefisto/pipeline/"
    fi

    LEGACY_DIR="$FAKE_MEFISTO/.claude/pipeline"
    if [ ! -d "$LEGACY_DIR" ] || [ -z "$(find "$LEGACY_DIR" -type f 2>/dev/null)" ]; then
        pass "G-8: no aparecio nada nuevo bajo .claude/pipeline/"
    else
        fail "G-8: aparecieron archivos bajo .claude/pipeline/: $(find "$LEGACY_DIR" -type f 2>/dev/null)"
    fi

    if compgen -G "$FAKE_MEFISTO/../worktree-mefisto-issue-869-*" >/dev/null 2>&1; then
        WT_DIR=$(compgen -G "$FAKE_MEFISTO/../worktree-mefisto-issue-869-*" | head -n1)
        if [ -d "$WT_DIR/.mefisto/pipeline/summaries" ]; then
            pass "G-9: el worktree de la corrida tiene .mefisto/pipeline/summaries/ (creado al preparar el worktree)"
        else
            fail "G-9: el worktree de la corrida no tiene .mefisto/pipeline/summaries/"
        fi
        if [ -f "$WT_DIR/.mefisto/pipeline/summaries/stage-1-writer.md" ] && [ -f "$WT_DIR/.mefisto/pipeline/summaries/stage-2-reviewer.md" ]; then
            pass "G-10: los resumenes de stage 1 y 2 quedaron en la ruta canonica del worktree"
        else
            fail "G-10: faltan resumenes de stage en .mefisto/pipeline/summaries/ del worktree"
        fi
    else
        fail "G-9/G-10: no se encontro el worktree de la corrida (abort() lo deja en disco, ver nota tecnica del pipeline)"
    fi
fi

# -------- Bloque H: el historial legado sigue leible, y el nuevo tambien --------

echo ""
echo "[H] mefisto-metrics-report.sh agrega el historial LEGACY y el CANONICO (CA-6)"

# Un grep sobre el script no alcanza para este CA: lo que hay que probar es que
# el reporte no se parte en dos por el traslado. Tras #869 el pipeline anota las
# corridas nuevas en .mefisto/pipeline/ mientras el historico se queda -- sin
# migracion automatica, MEF-ADR-0049 seccion 3 -- en .claude/pipeline/; leer una
# sola de las dos deja fuera, o bien toda corrida nueva, o bien los meses de
# historico contra los que el reporte existe para comparar. Se corre el CLI real
# contra un repo de mentira con UNA corrida en cada ubicacion.
METRICS_REPORT="$REPO_ROOT/.claude/scripts/mefisto-metrics-report.sh"

if ! command -v jq >/dev/null 2>&1; then
    echo "  SKIP: el bloque H requiere jq, no disponible en este entorno"
else
    H_REPO="$TMP/h/fake-mefisto"
    mkdir -p "$H_REPO/.claude-plugin" "$H_REPO/.claude/scripts" "$H_REPO/.claude/pipeline" \
             "$H_REPO/.mefisto/pipeline" "$H_REPO/src/internal/scripts/lib"
    git -C "$H_REPO" init -q
    echo '{"name":"mefisto","version":"0.0.0"}' > "$H_REPO/.claude-plugin/plugin.json"
    cp "$CANON_LIB" "$H_REPO/src/internal/scripts/lib/_mefisto-common.sh"
    cp "$REPO_ROOT/src/internal/scripts/lib/mefisto-state.sh" "$H_REPO/src/internal/scripts/lib/mefisto-state.sh"
    cp "$SHIM_LIB" "$H_REPO/.claude/scripts/_mefisto-common.sh"
    cp "$METRICS_REPORT" "$H_REPO/.claude/scripts/mefisto-metrics-report.sh"
    chmod +x "$H_REPO/.claude/scripts/mefisto-metrics-report.sh"

    # Una corrida en cada ubicacion. El historial legacy va SIN salto de linea
    # final a proposito: es como queda un archivo truncado a mano, y si la
    # concatenacion no lo separa del canonico las DOS corridas se pierden.
    printf '%s' '{"issue":"100","title":"Corrida legacy","pipeline":"mefisto-tooling","started":"20260505-090000","finished":"2026-05-05T09:07:00","state":"completed","agents":{"writer":{"duration":250},"reviewer":{"duration":170}},"pr":"https://github.com/x/x/pull/100"}' \
        > "$H_REPO/.claude/pipeline/pipeline-history.jsonl"
    printf '%s\n' '{"issue":"869","title":"Corrida canonica","pipeline":"mefisto-tooling","started":"20260906-090000","finished":"2026-09-06T09:07:00","state":"completed","agents":{"writer":{"duration":300},"reviewer":{"duration":200}},"pr":"https://github.com/x/x/pull/869"}' \
        > "$H_REPO/.mefisto/pipeline/pipeline-history.jsonl"

    # Mismo `env -u` que el bloque G: sin el, el reporte agregaria el historial
    # del repo REAL (esta suite corre dentro de una invocacion del pipeline, que
    # exporta MEFISTO_STATE_DIR).
    H_OUT=$(cd "$H_REPO" && env -u MEFISTO_STATE_DIR -u MEFISTO_LEGACY_STATE_DIR \
        -u MEFISTO_REPO_ROOT ./.claude/scripts/mefisto-metrics-report.sh 2>&1) || H_OUT="$H_OUT"

    if echo "$H_OUT" | grep -q "ventana: 2 "; then
        pass "H-1: el reporte agrega las 2 corridas (1 legacy + 1 canonica)"
    else
        fail "H-1: el reporte no agrego ambas ubicaciones -- salida: $(echo "$H_OUT" | head -n 12)"
    fi
    if echo "$H_OUT" | grep -q "#100" && echo "$H_OUT" | grep -q "#869"; then
        pass "H-2: ambas corridas aparecen individualmente en el reporte"
    else
        fail "H-2: falta alguna de las dos corridas en el detalle del reporte"
    fi

    # Solo legacy (el estado del repo antes de la primera corrida post-#869):
    # el historico tiene que seguir leyendose igual, sin exigir la canonica.
    rm -f "$H_REPO/.mefisto/pipeline/pipeline-history.jsonl"
    H_OUT_LEGACY=$(cd "$H_REPO" && env -u MEFISTO_STATE_DIR -u MEFISTO_LEGACY_STATE_DIR \
        -u MEFISTO_REPO_ROOT ./.claude/scripts/mefisto-metrics-report.sh 2>&1) || H_OUT_LEGACY="$H_OUT_LEGACY"
    if echo "$H_OUT_LEGACY" | grep -q "ventana: 1 "; then
        pass "H-3: con solo el historial legacy, el reporte lo sigue leyendo (CA-6)"
    else
        fail "H-3: el historial legacy dejo de leerse por si solo -- salida: $(echo "$H_OUT_LEGACY" | head -n 12)"
    fi
fi

# -------- Bloque I: los lanzadores siguen viendo la corrida --------

echo ""
echo "[I] tmux/herdr resuelven el estado de la corrida con mefisto_state_path (CA-3)"

# El traslado del pipeline mueve events.log y logs/ a .mefisto/pipeline/. Los
# lanzadores que en ese momento vivian en .claude/scripts/ los componian a
# mano contra .claude/pipeline/, asi que -- sin cambiar una linea de su codigo
# -- pasaban a vigilar archivos que ya nadie escribe: el pane monitor de tmux
# tail-eando un archivo vacio toda la corrida, y el pane de reporte de herdr
# apuntando a un directorio de logs muerto. Ninguno de los dos falla ni avisa;
# simplemente no muestra nada. El porte de tmux se cerro en #871 (ya canonico
# en src/internal/scripts/); el de herdr sigue en #872. Esto solo fija que la
# resolucion no vuelva a quedarse atras.
TMUX_LAUNCHER="$REPO_ROOT/src/internal/scripts/mefisto-tmux-pipeline.sh"
HERDR_LAUNCHER="$REPO_ROOT/.claude/scripts/mefisto-herdr-pipeline.sh"

if grep -qF 'EVENTS_LOG="$(mefisto_state_path "events.log")"' "$TMUX_LAUNCHER"; then
    pass "I-1: el pane monitor de tmux tail-ea el events.log que el pipeline escribe hoy"
else
    fail "I-1: mefisto-tmux-pipeline.sh no resuelve events.log con mefisto_state_path"
fi
if grep -qF 'LOG_DIR_ABS="$(mefisto_state_path "logs")"' "$HERDR_LAUNCHER"; then
    pass "I-2: herdr busca los logs de la corrida donde el pipeline los deja"
else
    fail "I-2: mefisto-herdr-pipeline.sh no resuelve logs/ con mefisto_state_path"
fi
for launcher in "$TMUX_LAUNCHER" "$HERDR_LAUNCHER"; do
    name=$(basename "$launcher")
    # Solo lineas de CODIGO: los comentarios si pueden nombrar la ruta legacy al
    # explicar por que se dejo de usar.
    legacy_refs=$(grep -vE '^\s*#' "$launcher" | grep -c '\.claude/pipeline' || true)
    if [ "$legacy_refs" -eq 0 ]; then
        pass "I-3: $name no compone ninguna ruta .claude/pipeline en codigo"
    else
        fail "I-3: $name todavia compone $legacy_refs ruta(s) .claude/pipeline en codigo"
    fi
done

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
