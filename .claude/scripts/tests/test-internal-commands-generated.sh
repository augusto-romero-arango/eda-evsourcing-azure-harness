#!/usr/bin/env bash
# test-internal-commands-generated.sh -- Tests de la migracion de los diez
# comandos internos a la fuente neutral: los cinco de analisis y seguimiento
# (plan, bug, bitacora, work-status, fix-review, issue #866) y los cinco de
# ejecucion (tooling, tooling-verbose, sequential, merge, release, issue
# #867) (MEF-ADR-0049).
#
# Cubre:
#   [sources] Las diez src/internal/commands/mefisto-{plan,bug,bitacora,
#         work-status,fix-review,tooling,tooling-verbose,sequential,merge,
#         release}.md existen y pasan validate-internal-artifacts.sh (#853).
#   [ca-3] Ninguna fuente ni salida generada contiene `claude --agent`,
#         `.claude/pipeline`, `.claude/agents` ni `.claude/commands` (CA-3);
#         la salida Claude de plan/bug/bitacora invoca
#         `claude --agent <agente> "$ARGUMENTS"` y la de OpenCode lleva
#         `agent: "<agente>"` + la frase de la directiva.
#   [check] generate-internal-adapters.sh --check esta en verde: los
#         adaptadores versionados en .claude/commands/ y .opencode/commands/
#         coinciden byte-a-byte con lo que la fuente neutral produce (CA-1).
#   [claude-output] La salida Claude de los cuatro comandos `fast` lleva
#         `model: "haiku"`; la de `fix-review` (`deep`) omite `model:` (CA-2).
#   [opencode-output] La salida OpenCode omite `model:` para heredar la
#         configuracion del usuario (issue #961).
#   [guard] El bloque del guard inverso (`.claude-plugin/plugin.json`) es
#         identico byte-a-byte entre la salida Claude y la OpenCode de cada
#         uno de los cinco comandos (CA-2).
#   [ca-5] Ninguna fuente cita `CLAUDE.md` como referencia de gobierno: si
#         aparece, la linea debe describirlo como shim de compatibilidad.
#   [command-path] mefisto-bitacora encadena mefisto-merge via
#         `{{mefisto:command-path}}`: cada salida apunta a su propio
#         directorio de comandos (CA-4).
#   [work-status-paths] mefisto-work-status describe las rutas de estado
#         como `.mefisto/pipeline/...` con nota de fallback legacy (CA-4).
#   [opencode-cli] Si el CLI `opencode` esta instalado, `opencode debug
#         config` corrido en la raiz del repo lista los cinco ids bajo
#         `.command`; si no esta instalado, se omite con aviso (CA-6).
#   [exec-sources] Los cinco comandos de ejecucion (issue #867) existen y
#         pasan validate-internal-artifacts.sh.
#   [exec-ca-3] La salida Claude y OpenCode de tooling/tooling-verbose/
#         sequential/release invoca el script real con `MEFISTO_RUNTIME=
#         <runtime> ./.claude/scripts/<script>` (CA-3, issue #867).
#   [exec-command-path] mefisto-tooling-verbose encadena mefisto-tooling via
#         `{{mefisto:command-path}}` (issue #867).
#   [exec-claude-output] La salida Claude de los cuatro comandos de
#         ejecucion `fast` lleva `model: "haiku"`; la de `release`
#         (`balanced`) lleva `model: "sonnet"` (CA-5, issue #867).
#   [ca-4] mefisto-tooling no prescribe un alias Anthropic concreto en sus
#         ejemplos de `--models` y remite a models.example.json (CA-4, issue
#         #867).
#   [run-quoting] {{mefisto:run}} preserva sin alterar un argumento con
#         espacios y comillas (`--models 'writer=a b'`) en ambos runtimes
#         (CA-6, issue #867).
#
# Uso: .claude/scripts/tests/test-internal-commands-generated.sh
# Exit code: 0 si todos los checks pasan, 1 si alguno falla.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
COMMANDS_DIR="$REPO_ROOT/src/internal/commands"
VALIDATOR="$REPO_ROOT/src/internal/scripts/validate-internal-artifacts.sh"
GENERATOR="$REPO_ROOT/src/internal/scripts/generate-internal-adapters.sh"

COMMAND_IDS="mefisto-plan mefisto-bug mefisto-bitacora mefisto-work-status mefisto-fix-review"
EXEC_COMMAND_IDS="mefisto-tooling mefisto-tooling-verbose mefisto-sequential mefisto-merge mefisto-release"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "[sources] Las cinco fuentes existen y pasan validate-internal-artifacts.sh"
for id in $COMMAND_IDS; do
    src="$COMMANDS_DIR/$id.md"
    if [ ! -f "$src" ]; then
        fail "$id: no existe src/internal/commands/$id.md"
        continue
    fi
    pass "existe: src/internal/commands/$id.md"

    out=$("$VALIDATOR" "$src" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "$id: pasa el validador del contrato neutral"
    else
        fail "$id: el validador rechazo la fuente. Salida: $out"
    fi
done

echo ""
echo "[exec-sources] Los cinco comandos de ejecucion existen y pasan validate-internal-artifacts.sh (issue #867)"
for id in $EXEC_COMMAND_IDS; do
    src="$COMMANDS_DIR/$id.md"
    if [ ! -f "$src" ]; then
        fail "$id: no existe src/internal/commands/$id.md"
        continue
    fi
    pass "existe: src/internal/commands/$id.md"

    out=$("$VALIDATOR" "$src" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "$id: pasa el validador del contrato neutral"
    else
        fail "$id: el validador rechazo la fuente. Salida: $out"
    fi
done

echo ""
echo "[check] generate-internal-adapters.sh --check esta en verde"
if [ -x "$GENERATOR" ]; then
    out=$("$GENERATOR" --check 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "generate-internal-adapters.sh --check -> exit 0 (sin divergencias)"
    else
        fail "generate-internal-adapters.sh --check -> exit $rc. Salida: $out"
    fi
else
    fail "$GENERATOR no existe o no es ejecutable"
fi

echo ""
echo "[ca-3] Ninguna fuente ni salida contiene las referencias prohibidas; plan/bug/bitacora invocan su agente en ambos runtimes"
FORBIDDEN_PATTERNS=("claude --agent" "\.claude/pipeline" "\.claude/agents" "\.claude/commands")
ALL_SOURCES=()
for id in $COMMAND_IDS $EXEC_COMMAND_IDS; do
    ALL_SOURCES+=("$COMMANDS_DIR/$id.md")
done
for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
    hit=$(grep -inE "$pattern" "${ALL_SOURCES[@]}" 2>/dev/null)
    if [ -z "$hit" ]; then
        pass "ninguna fuente contiene '$pattern'"
    else
        fail "una fuente contiene '$pattern': $hit"
    fi
done
hit=$(grep -inE "opencode" "${ALL_SOURCES[@]}" 2>/dev/null)
if [ -z "$hit" ]; then
    pass "ninguna fuente nombra 'opencode'"
else
    fail "una fuente nombra 'opencode': $hit"
fi

declare_pairs="mefisto-plan:mefisto-planner mefisto-bug:mefisto-investigator mefisto-bitacora:mefisto-historiador"
for pair in $declare_pairs; do
    cmd_id="${pair%%:*}"
    agent_id="${pair##*:}"
    claude_out="$REPO_ROOT/.claude/commands/$cmd_id.md"
    opencode_out="$REPO_ROOT/.opencode/commands/$cmd_id.md"

    if [ -f "$claude_out" ] && grep -qF "claude --agent $agent_id \"\$ARGUMENTS\"" "$claude_out"; then
        pass "$cmd_id: salida Claude invoca 'claude --agent $agent_id \"\$ARGUMENTS\"'"
    else
        fail "$cmd_id: salida Claude NO invoca 'claude --agent $agent_id \"\$ARGUMENTS\"' ($claude_out)"
    fi

    if [ -f "$opencode_out" ] && grep -q "^agent: \"$agent_id\"$" "$opencode_out" \
        && grep -qF "Actua como \`$agent_id\` con este mensaje inicial: \$ARGUMENTS" "$opencode_out"; then
        pass "$cmd_id: salida OpenCode lleva agent: \"$agent_id\" y la frase de la directiva"
    else
        fail "$cmd_id: salida OpenCode NO lleva agent:/la frase de la directiva esperada ($opencode_out)"
    fi
done

# Las salidas SI referencian su propio runtime y su propio directorio de
# comandos (los introduce el generador). Lo que CA-3 prohibe en una salida es
# (a) que nombre el directorio de comandos del OTRO runtime, (b) que la salida
# OpenCode conserve la invocacion `claude --agent` de la variante Claude, y
# (c) que cualquiera de las dos siga citando `.claude/pipeline` o
# `.claude/agents` -- las dos rutas que este issue reemplazo por
# `.mefisto/pipeline` y `src/internal/agents`.
cross_ok=1
for id in $COMMAND_IDS $EXEC_COMMAND_IDS; do
    for out_file in "$REPO_ROOT/.claude/commands/$id.md" "$REPO_ROOT/.opencode/commands/$id.md"; do
        [ -f "$out_file" ] || { fail "no existe la salida generada $out_file"; cross_ok=0; continue; }
        if [[ "$out_file" == *".opencode/"* ]]; then
            other_dir=".claude/commands"
            if grep -qF "claude --agent" "$out_file" 2>/dev/null; then
                fail "$out_file: conserva 'claude --agent' (invocacion de la variante Claude)"
                cross_ok=0
            fi
        else
            other_dir=".opencode/commands"
        fi
        if grep -qF "$other_dir" "$out_file" 2>/dev/null; then
            fail "$out_file: menciona '$other_dir' (deberia apuntar solo a su propio directorio)"
            cross_ok=0
        fi
        for stale in ".claude/pipeline" ".claude/agents"; do
            if grep -qF "$stale" "$out_file" 2>/dev/null; then
                fail "$out_file: sigue citando '$stale' (CA-3)"
                cross_ok=0
            fi
        done
    done
done
[ "$cross_ok" -eq 1 ] && pass "cada salida generada referencia solo su propio runtime y ninguna ruta reemplazada por CA-3"

echo ""
echo "[guard] CA-2: el bloque del guard inverso es identico en ambas salidas de cada comando"
for id in $COMMAND_IDS $EXEC_COMMAND_IDS; do
    claude_guard=$(sed -n '/^\[ -f "\$REPO_ROOT\/\.claude-plugin\/plugin\.json" \]/,/^}$/p' "$REPO_ROOT/.claude/commands/$id.md" 2>/dev/null)
    opencode_guard=$(sed -n '/^\[ -f "\$REPO_ROOT\/\.claude-plugin\/plugin\.json" \]/,/^}$/p' "$REPO_ROOT/.opencode/commands/$id.md" 2>/dev/null)
    if [ -n "$claude_guard" ] && [ "$claude_guard" = "$opencode_guard" ]; then
        pass "$id: guard inverso presente e identico en ambos adaptadores"
    else
        fail "$id: guard inverso ausente o divergente entre .claude/commands y .opencode/commands"
    fi
done

echo ""
echo "[ca-5] Las referencias de gobierno usan AGENTS.md; CLAUDE.md solo como shim de compatibilidad"
ca5_ok=1
for src in "${ALL_SOURCES[@]}"; do
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        case "$hit" in
            *shim*) ;;
            *) fail "$(basename "$src"): cita CLAUDE.md fuera de un 'shim de compatibilidad': $hit"; ca5_ok=0 ;;
        esac
    done < <(grep -nF 'CLAUDE.md' "$src" 2>/dev/null)
done
[ "$ca5_ok" -eq 1 ] && pass "ninguna fuente cita CLAUDE.md como fuente de gobierno"

echo ""
echo "[claude-output] model: \"haiku\" en los cuatro fast; fix-review sin model:"
for id in mefisto-plan mefisto-bug mefisto-bitacora mefisto-work-status; do
    out_file="$REPO_ROOT/.claude/commands/$id.md"
    if grep -q '^model: "haiku"$' "$out_file" 2>/dev/null; then
        pass "$id: .claude/commands lleva model: \"haiku\""
    else
        fail "$id: .claude/commands NO lleva model: \"haiku\" ($out_file)"
    fi
done
if grep -q '^model:' "$REPO_ROOT/.claude/commands/mefisto-fix-review.md" 2>/dev/null; then
    fail "mefisto-fix-review: .claude/commands no deberia declarar 'model:' (perfil deep hereda la sesion)"
else
    pass "mefisto-fix-review: .claude/commands sin 'model:' (perfil deep)"
fi

echo ""
echo "[opencode-output] ningun comando OpenCode fija model:"
for id in $COMMAND_IDS $EXEC_COMMAND_IDS mefisto-next-order; do
    if grep -q '^model:' "$REPO_ROOT/.opencode/commands/$id.md" 2>/dev/null; then
        fail "$id: .opencode/commands no deberia fijar model:"
    else
        pass "$id: .opencode/commands sin model: (hereda la configuracion del usuario)"
    fi
done

echo ""
echo "[command-path] mefisto-bitacora encadena mefisto-merge apuntando al propio directorio de cada runtime (CA-4)"
claude_bitacora="$REPO_ROOT/.claude/commands/mefisto-bitacora.md"
opencode_bitacora="$REPO_ROOT/.opencode/commands/mefisto-bitacora.md"
if grep -qF '.claude/commands/mefisto-merge.md' "$claude_bitacora" 2>/dev/null; then
    pass "mefisto-bitacora: salida Claude apunta a .claude/commands/mefisto-merge.md"
else
    fail "mefisto-bitacora: salida Claude NO apunta a .claude/commands/mefisto-merge.md"
fi
if grep -qF '.opencode/commands/mefisto-merge.md' "$opencode_bitacora" 2>/dev/null; then
    pass "mefisto-bitacora: salida OpenCode apunta a .opencode/commands/mefisto-merge.md"
else
    fail "mefisto-bitacora: salida OpenCode NO apunta a .opencode/commands/mefisto-merge.md"
fi

echo ""
echo "[work-status-paths] mefisto-work-status describe .mefisto/pipeline/... con fallback legacy (CA-4)"
src_work_status="$COMMANDS_DIR/mefisto-work-status.md"
if grep -qF '.mefisto/pipeline/' "$src_work_status" 2>/dev/null && grep -qiF 'legacy' "$src_work_status" 2>/dev/null; then
    pass "mefisto-work-status: fuente describe .mefisto/pipeline/ con nota de fallback legacy"
else
    fail "mefisto-work-status: fuente NO describe .mefisto/pipeline/ con nota de fallback legacy"
fi

echo ""
echo "[opencode-cli] 'opencode debug config' lista los diez comandos (se omite si el CLI no esta instalado)"
if command -v opencode >/dev/null 2>&1; then
    tmpf=$(mktemp)
    (cd "$REPO_ROOT" && opencode debug config >"$tmpf" 2>/dev/null)
    if [ -s "$tmpf" ] && jq -e '.command' "$tmpf" >/dev/null 2>&1; then
        for id in $COMMAND_IDS $EXEC_COMMAND_IDS; do
            if jq -e --arg id "$id" '.command | has($id)' "$tmpf" >/dev/null 2>&1; then
                pass "$id: listado por 'opencode debug config' bajo .command"
            else
                fail "$id: NO aparece en 'opencode debug config' bajo .command"
            fi
        done
    else
        fail "'opencode debug config' no produjo un JSON valido con clave .command"
    fi
    rm -f "$tmpf"
else
    echo "  AVISO: CLI 'opencode' no instalado, se omite este bloque"
fi

echo ""
echo "[exec-ca-3] Las invocaciones de script de los comandos de ejecucion pasan por {{mefisto:run}} en ambos runtimes (issue #867)"
check_run_invocation() {
    local id="$1" invocation="$2"
    local claude_out="$REPO_ROOT/.claude/commands/$id.md"
    local opencode_out="$REPO_ROOT/.opencode/commands/$id.md"
    if [ -f "$claude_out" ] && grep -qF "MEFISTO_RUNTIME=claude ./.claude/scripts/$invocation" "$claude_out"; then
        pass "$id: salida Claude invoca 'MEFISTO_RUNTIME=claude ./.claude/scripts/$invocation'"
    else
        fail "$id: salida Claude NO invoca 'MEFISTO_RUNTIME=claude ./.claude/scripts/$invocation' ($claude_out)"
    fi
    if [ -f "$opencode_out" ] && grep -qF "MEFISTO_RUNTIME=opencode ./.claude/scripts/$invocation" "$opencode_out"; then
        pass "$id: salida OpenCode invoca 'MEFISTO_RUNTIME=opencode ./.claude/scripts/$invocation'"
    else
        fail "$id: salida OpenCode NO invoca 'MEFISTO_RUNTIME=opencode ./.claude/scripts/$invocation' ($opencode_out)"
    fi
}
check_run_invocation mefisto-tooling 'mefisto-tmux-pipeline.sh --tooling $ARGUMENTS'
check_run_invocation mefisto-tooling-verbose 'mefisto-tmux-pipeline.sh --tooling $ARGUMENTS --verbose'
check_run_invocation mefisto-sequential 'mefisto-validate-batch-deps.sh <issue1> <issue2> ...'
check_run_invocation mefisto-sequential 'mefisto-tmux-pipeline.sh --batch <issue1> <issue2> ...'
check_run_invocation mefisto-release 'mefisto-release.sh $ARGUMENTS'

echo ""
echo "[exec-command-path] mefisto-tooling-verbose encadena mefisto-tooling apuntando al propio directorio de cada runtime (issue #867)"
claude_tooling_verbose="$REPO_ROOT/.claude/commands/mefisto-tooling-verbose.md"
opencode_tooling_verbose="$REPO_ROOT/.opencode/commands/mefisto-tooling-verbose.md"
if grep -qF '.claude/commands/mefisto-tooling.md' "$claude_tooling_verbose" 2>/dev/null; then
    pass "mefisto-tooling-verbose: salida Claude apunta a .claude/commands/mefisto-tooling.md"
else
    fail "mefisto-tooling-verbose: salida Claude NO apunta a .claude/commands/mefisto-tooling.md"
fi
if grep -qF '.opencode/commands/mefisto-tooling.md' "$opencode_tooling_verbose" 2>/dev/null; then
    pass "mefisto-tooling-verbose: salida OpenCode apunta a .opencode/commands/mefisto-tooling.md"
else
    fail "mefisto-tooling-verbose: salida OpenCode NO apunta a .opencode/commands/mefisto-tooling.md"
fi

echo ""
echo "[exec-claude-output] model: \"haiku\" en los cuatro fast; release (balanced) con model: \"sonnet\" (issue #867)"
for id in mefisto-tooling mefisto-tooling-verbose mefisto-sequential mefisto-merge; do
    out_file="$REPO_ROOT/.claude/commands/$id.md"
    if grep -q '^model: "haiku"$' "$out_file" 2>/dev/null; then
        pass "$id: .claude/commands lleva model: \"haiku\""
    else
        fail "$id: .claude/commands NO lleva model: \"haiku\" ($out_file)"
    fi
done
if grep -q '^model: "sonnet"$' "$REPO_ROOT/.claude/commands/mefisto-release.md" 2>/dev/null; then
    pass "mefisto-release: .claude/commands lleva model: \"sonnet\""
else
    fail "mefisto-release: .claude/commands NO lleva model: \"sonnet\""
fi
echo ""
echo "[ca-4] mefisto-tooling no prescribe un alias Anthropic concreto en sus ejemplos de --models y remite a models.example.json (issue #867)"
src_tooling="$COMMANDS_DIR/mefisto-tooling.md"
if grep -qiE -- "--models[^\`]*=(opus|sonnet|haiku)" "$src_tooling" 2>/dev/null; then
    fail "mefisto-tooling: la fuente todavia prescribe un alias Anthropic concreto en un ejemplo --models"
else
    pass "mefisto-tooling: ningun ejemplo --models prescribe un alias Anthropic concreto"
fi
if grep -qF 'models.example.json' "$src_tooling" 2>/dev/null; then
    pass "mefisto-tooling: remite al models.example.json comun para la forma del mapping"
else
    fail "mefisto-tooling: NO remite a src/runtime/contract/models.example.json"
fi

echo ""
echo "[run-quoting] {{mefisto:run}} preserva sin alterar un argumento con espacios y comillas (CA-6, issue #867)"
FIXTURE_DIR=$(mktemp -d)
FIXTURE_OUT=$(mktemp -d)
trap 'rm -rf "$FIXTURE_DIR" "$FIXTURE_OUT"' EXIT
FIXTURE_FILE="$FIXTURE_DIR/mefisto-test-run-quoting.md"
cat > "$FIXTURE_FILE" <<'FIXTURE_EOF'
---
{
  "kind": "command",
  "id": "mefisto-test-run-quoting",
  "description": "Fixture de test: verifica que {{mefisto:run}} preserva argumentos con espacios y comillas (issue #867 CA-6). No se invoca en produccion."
}
---

Invocacion de prueba:

{{mefisto:run mefisto-tmux-pipeline.sh --tooling $ARGUMENTS --models 'writer=a b'}}
FIXTURE_EOF

if out=$("$VALIDATOR" "$FIXTURE_FILE" 2>&1); then
    pass "fixture de quoting: pasa el validador del contrato neutral"
else
    fail "fixture de quoting: el validador la rechazo. Salida: $out"
fi

if "$GENERATOR" --out "$FIXTURE_OUT" "$FIXTURE_FILE" >/dev/null 2>&1; then
    claude_fixture_out="$FIXTURE_OUT/.claude/commands/mefisto-test-run-quoting.md"
    opencode_fixture_out="$FIXTURE_OUT/.opencode/commands/mefisto-test-run-quoting.md"
    expected_claude="MEFISTO_RUNTIME=claude ./.claude/scripts/mefisto-tmux-pipeline.sh --tooling \$ARGUMENTS --models 'writer=a b'"
    expected_opencode="MEFISTO_RUNTIME=opencode ./.claude/scripts/mefisto-tmux-pipeline.sh --tooling \$ARGUMENTS --models 'writer=a b'"
    if grep -qF "$expected_claude" "$claude_fixture_out" 2>/dev/null; then
        pass "fixture de quoting: salida Claude conserva el argumento con espacios y comillas intacto"
    else
        fail "fixture de quoting: salida Claude altero el argumento con espacios/comillas ($claude_fixture_out)"
    fi
    if grep -qF "$expected_opencode" "$opencode_fixture_out" 2>/dev/null; then
        pass "fixture de quoting: salida OpenCode conserva el argumento con espacios y comillas intacto"
    else
        fail "fixture de quoting: salida OpenCode altero el argumento con espacios/comillas ($opencode_fixture_out)"
    fi
else
    fail "fixture de quoting: generate-internal-adapters.sh fallo al generarla"
fi
rm -rf "$FIXTURE_DIR" "$FIXTURE_OUT"

echo ""
echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
