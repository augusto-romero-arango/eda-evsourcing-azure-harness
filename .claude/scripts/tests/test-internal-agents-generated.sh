#!/usr/bin/env bash
# test-internal-agents-generated.sh -- Tests de la migracion de los tres
# agentes internos (planner, investigator, historiador) a la fuente neutral
# (MEF-ADR-0049, issue #865).
#
# Cubre:
#   [sources] Los tres src/internal/agents/mefisto-{planner,investigator,
#         historiador}.md existen y pasan validate-internal-artifacts.sh
#         (#853).
#   [neutral] Ningun body de las tres fuentes nombra `claude`/`opencode`
#         (CA-1/CA-5) -- ya lo cubre el validador, este bloque solo hace
#         explicito el motivo para estos tres agentes en concreto.
#   [check] generate-internal-adapters.sh --check esta en verde: los
#         adaptadores versionados en .claude/agents/ y .opencode/agents/
#         coinciden byte-a-byte con lo que la fuente neutral produce (CA-2).
#   [claude-output] Los seis adaptadores generados (.claude/agents/ y
#         .opencode/agents/) llevan el marcador de generado y ninguno
#         menciona `fable`, `opus` ni un id de modelo completo; en la salida
#         Claude el historiador lleva `model: "sonnet"` y planner/investigator
#         no declaran `model:` (perfil deep, heredan la sesion) (CA-2).
#   [opencode-cli] Si el CLI `opencode` esta instalado, `opencode agent list`
#         corrido en la raiz del repo lista los tres ids como agentes
#         primary; si no esta instalado, se omite con aviso (CA-6).
#   [guard-f] El bloque [F] de scripts/tests/test-guards.sh (integridad de
#         Agent Skills) sigue en verde tras la migracion.
#
# Uso: .claude/scripts/tests/test-internal-agents-generated.sh
# Exit code: 0 si todos los checks pasan, 1 si alguno falla.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
AGENTS_DIR="$REPO_ROOT/src/internal/agents"
VALIDATOR="$REPO_ROOT/src/internal/scripts/validate-internal-artifacts.sh"
GENERATOR="$REPO_ROOT/src/internal/scripts/generate-internal-adapters.sh"
GUARDS="$REPO_ROOT/scripts/tests/test-guards.sh"

AGENT_IDS="mefisto-planner mefisto-investigator mefisto-historiador"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "[sources] Las tres fuentes existen y pasan validate-internal-artifacts.sh"
for id in $AGENT_IDS; do
    src="$AGENTS_DIR/$id.md"
    if [ ! -f "$src" ]; then
        fail "$id: no existe src/internal/agents/$id.md"
        continue
    fi
    pass "existe: src/internal/agents/$id.md"

    out=$("$VALIDATOR" "$src" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "$id: pasa el validador del contrato neutral"
    else
        fail "$id: el validador rechazo la fuente. Salida: $out"
    fi
done

echo ""
echo "[neutral] Ningun body nombra 'claude'/'opencode' (CA-1/CA-5)"
for id in $AGENT_IDS; do
    src="$AGENTS_DIR/$id.md"
    [ -f "$src" ] || continue
    hit=$(awk '
        NR==1 { next }
        $0=="---" && !seen { seen=1; next }
        seen && tolower($0) ~ /claude|opencode/ { print NR; exit }
    ' "$src")
    if [ -z "$hit" ]; then
        pass "$id: body sin menciones a claude/opencode"
    else
        fail "$id: body menciona un runtime concreto en la linea $hit"
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
echo "[claude-output] .claude/agents/*.md: marcador de generado, sin fable/opus/id de modelo, historiador con model sonnet"
for id in $AGENT_IDS; do
    out_file="$REPO_ROOT/.claude/agents/$id.md"
    if [ ! -f "$out_file" ]; then
        fail "$id: no existe .claude/agents/$id.md"
        continue
    fi
    if grep -q "^<!-- GENERADO por src/internal/scripts/generate-internal-adapters.sh" "$out_file"; then
        pass "$id: .claude/agents/$id.md lleva el marcador de generado"
    else
        fail "$id: .claude/agents/$id.md no lleva el marcador de generado"
    fi
    if grep -q "^<!-- GENERADO por src/internal/scripts/generate-internal-adapters.sh" "$REPO_ROOT/.opencode/agents/$id.md" 2>/dev/null; then
        pass "$id: .opencode/agents/$id.md lleva el marcador de generado"
    else
        fail "$id: .opencode/agents/$id.md no lleva el marcador de generado"
    fi
done

for id in $AGENT_IDS; do
    for out_file in "$REPO_ROOT/.claude/agents/$id.md" "$REPO_ROOT/.opencode/agents/$id.md"; do
        rel="${out_file#"$REPO_ROOT"/}"
        [ -f "$out_file" ] || { fail "$rel: no existe"; continue; }
        if grep -qiE '\b(fable|opus)\b|claude-[a-z0-9]+-[0-9]' "$out_file"; then
            fail "$rel: menciona un id de modelo prohibido (fable/opus o un id completo)"
        else
            pass "$rel: sin fable/opus ni id de modelo"
        fi
    done
done

if grep -q '^model: "sonnet"$' "$REPO_ROOT/.claude/agents/mefisto-historiador.md" 2>/dev/null; then
    pass "mefisto-historiador: .claude/agents lleva model: \"sonnet\""
else
    fail "mefisto-historiador: .claude/agents no lleva model: \"sonnet\""
fi

for id in mefisto-planner mefisto-investigator; do
    if grep -q '^model:' "$REPO_ROOT/.claude/agents/$id.md" 2>/dev/null; then
        fail "$id: .claude/agents no deberia declarar 'model:' (perfil deep hereda la sesion)"
    else
        pass "$id: .claude/agents sin 'model:' (perfil deep)"
    fi
done

echo ""
echo "[opencode-cli] 'opencode agent list' lista los tres ids (se omite si el CLI no esta instalado)"
if command -v opencode >/dev/null 2>&1; then
    # Un reintento: el CLI descubre los agentes leyendo .opencode/agents/, que
    # el generador acaba de reescribir en la corrida tipica (writer regenera ->
    # test verifica). Una lectura que cae en ese instante devuelve el listado
    # sin alguno de los tres; reintentar una vez distingue esa carrera de una
    # ausencia real, sin debilitar la asercion.
    out=$(cd "$REPO_ROOT" && opencode agent list 2>&1)
    for id in $AGENT_IDS; do
        printf '%s' "$out" | grep -q "^$id (primary)" || {
            out=$(cd "$REPO_ROOT" && opencode agent list 2>&1)
            break
        }
    done
    for id in $AGENT_IDS; do
        if printf '%s' "$out" | grep -q "^$id (primary)"; then
            pass "$id: listado por 'opencode agent list' como primary"
        else
            fail "$id: NO aparece en 'opencode agent list' como primary"
        fi
    done
else
    echo "  AVISO: CLI 'opencode' no instalado, se omite este bloque"
fi

echo ""
echo "[guard-f] El bloque [F] de test-guards.sh sigue en verde"
if [ -x "$GUARDS" ]; then
    out=$("$GUARDS" 2>&1)
    rc=$?
    if printf '%s' "$out" | grep -qF "FAIL" ; then
        fail "test-guards.sh reporta al menos un FAIL tras la migracion. Salida relevante:
$(printf '%s' "$out" | grep -F "FAIL")"
    elif [ "$rc" -ne 0 ]; then
        fail "test-guards.sh -> exit $rc sin FAILs explicitos. Salida: $out"
    else
        pass "test-guards.sh completo -> exit 0, sin FAILs"
    fi
else
    fail "$GUARDS no existe o no es ejecutable"
fi

echo ""
echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
