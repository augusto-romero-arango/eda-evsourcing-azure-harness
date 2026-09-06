#!/usr/bin/env bash
# test-internal-commands-generated.sh -- Tests de la migracion de los cinco
# comandos internos de analisis y seguimiento (plan, bug, bitacora,
# work-status, fix-review) a la fuente neutral (MEF-ADR-0049, issue #866).
#
# Cubre:
#   [sources] Las cinco src/internal/commands/mefisto-{plan,bug,bitacora,
#         work-status,fix-review}.md existen y pasan
#         validate-internal-artifacts.sh (#853).
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
#   [command-path] mefisto-bitacora encadena mefisto-merge via
#         `{{mefisto:command-path}}`: cada salida apunta a su propio
#         directorio de comandos (CA-4).
#   [work-status-paths] mefisto-work-status describe las rutas de estado
#         como `.mefisto/pipeline/...` con nota de fallback legacy (CA-4).
#   [opencode-cli] Si el CLI `opencode` esta instalado, `opencode debug
#         config` corrido en la raiz del repo lista los cinco ids bajo
#         `.command`; si no esta instalado, se omite con aviso (CA-6).
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
for id in $COMMAND_IDS; do
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

for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
    for id in $COMMAND_IDS; do
        for out_file in "$REPO_ROOT/.claude/commands/$id.md" "$REPO_ROOT/.opencode/commands/$id.md"; do
            [ -f "$out_file" ] || continue
            # Las salidas SI referencian su propio runtime y sus propios
            # directorios (los introduce el generador) -- lo que CA-3 prohibe
            # es que la salida Claude mencione rutas de OpenCode y viceversa.
            other_dir=".opencode/commands"
            [[ "$out_file" == *".opencode/"* ]] && other_dir=".claude/commands"
            if grep -qF "$other_dir" "$out_file" 2>/dev/null; then
                fail "$out_file: menciona '$other_dir' (deberia apuntar solo a su propio directorio)"
            fi
        done
    done
done
pass "cada salida generada solo referencia su propio directorio de comandos"

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
echo "[opencode-cli] 'opencode debug config' lista los cinco comandos (se omite si el CLI no esta instalado)"
if command -v opencode >/dev/null 2>&1; then
    tmpf=$(mktemp)
    (cd "$REPO_ROOT" && opencode debug config >"$tmpf" 2>/dev/null)
    if [ -s "$tmpf" ] && jq -e '.command' "$tmpf" >/dev/null 2>&1; then
        for id in $COMMAND_IDS; do
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
echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
