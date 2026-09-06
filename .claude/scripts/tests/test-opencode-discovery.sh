#!/usr/bin/env bash
# test-opencode-discovery.sh -- Chequeo local de descubrimiento OpenCode del
# propio checkout de Mefisto para dogfooding interno (issue #868, MEF-ADR-0049).
#
# Lista y resuelve todos los artefactos SIN invocar ningun modelo. Cubre:
#   [CA-1] Todo agente y todo comando de la fuente neutral (`src/internal/`)
#       tiene su salida `.opencode/` -- hoy cinco agentes (#865/#909) y diez
#       comandos (#866/#867) -- y si el CLI `opencode` esta instalado,
#       ademas se listan via `opencode agent list` y `opencode debug config`.
#   [CA-2] `opencode.json` declara unicamente `$schema` (y `instructions`, si
#       algun dia hiciera falta acotarlo): nunca `plugin`, `provider`,
#       `model`, `permission` global, tokens, API keys ni rutas al auth
#       store.
#   [CA-3] `opencode.json` no define `MEFISTO_RUNTIME`; cada salida
#       `.opencode/commands/*.md` cuya fuente use `{{mefisto:run}}` conserva
#       el prefijo `MEFISTO_RUNTIME=opencode` (issue #867).
#   [CA-4] Cada `.opencode/agents/*.md` trae bloque `permission` con
#       `external_directory` en `deny`.
#   [CA-5] Las fuentes neutrales (#853) pasan el validador,
#       `generate-internal-adapters.sh --check` (#854) esta en verde, y
#       `opencode.json`/`AGENTS.md` existen en la raiz del repo.
#
# CA-6 (Claude Code sigue cargando .claude/agents, .claude/commands y
# CLAUDE.md sin leer opencode.json) lo cubren scripts/tests/test-guards.sh y
# .claude/scripts/tests/test-agents-md-shim.sh; no se duplica aqui.
#
# Uso: .claude/scripts/tests/test-opencode-discovery.sh
# Exit code: 0 si todos los checks pasan, 1 si alguno falla.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OPENCODE_JSON="$REPO_ROOT/opencode.json"
AGENTS_MD="$REPO_ROOT/AGENTS.md"
VALIDATOR="$REPO_ROOT/src/internal/scripts/validate-internal-artifacts.sh"
GENERATOR="$REPO_ROOT/src/internal/scripts/generate-internal-adapters.sh"

# Los ids salen de la fuente neutral (#853), no de una lista fija: este test
# pregunta si TODO artefacto interno es descubrible por OpenCode, asi que los
# agentes que sumen issues futuros (#879) quedan cubiertos sin tocarlo.
ids_de() {
    local f id
    for f in "$1"/*.md; do
        [ -f "$f" ] || continue
        id="${f##*/}"
        printf '%s ' "${id%.md}"
    done
}
AGENT_IDS=$(ids_de "$REPO_ROOT/src/internal/agents")
COMMAND_IDS=$(ids_de "$REPO_ROOT/src/internal/commands")
AGENT_COUNT=$(printf '%s' "$AGENT_IDS" | wc -w | tr -d ' ')
COMMAND_COUNT=$(printf '%s' "$COMMAND_IDS" | wc -w | tr -d ' ')

# `mode` tambien sale de la fuente neutral (issue #909: mefisto-writer/
# mefisto-reviewer nacen en `subagent`, no todos los agentes son `primary`).
# Extrae el frontmatter con el mismo `awk` de una pasada que documenta
# src/internal/contract/README.md.
mode_de() {
    awk 'NR==1 && $0!="---"{exit 1} NR>1 && $0=="---"{exit} NR>1' "$REPO_ROOT/src/internal/agents/$1.md" \
        | jq -r '.mode // "primary"'
}

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "[CA-1] Los agentes y comandos internos generados existen"
if [ "$AGENT_COUNT" -ge 3 ]; then
    pass "src/internal/agents aporta $AGENT_COUNT agentes (>= 3, los de #865)"
else
    fail "src/internal/agents aporta $AGENT_COUNT agentes (esperaba >= 3, los de #865)"
fi
if [ "$COMMAND_COUNT" -ge 10 ]; then
    pass "src/internal/commands aporta $COMMAND_COUNT comandos (>= 10, los de #866/#867)"
else
    fail "src/internal/commands aporta $COMMAND_COUNT comandos (esperaba >= 10, los de #866/#867)"
fi
for id in $AGENT_IDS; do
    if [ -f "$REPO_ROOT/.opencode/agents/$id.md" ]; then
        pass "$id: existe .opencode/agents/$id.md"
    else
        fail "$id: no existe .opencode/agents/$id.md"
    fi
done
for id in $COMMAND_IDS; do
    if [ -f "$REPO_ROOT/.opencode/commands/$id.md" ]; then
        pass "$id: existe .opencode/commands/$id.md"
    else
        fail "$id: no existe .opencode/commands/$id.md"
    fi
done

echo ""
echo "[CA-1] 'opencode agent list'/'opencode debug config' (se omite si el CLI no esta instalado)"
if command -v opencode >/dev/null 2>&1; then
    # Reintento unico: el CLI descubre los agentes/comandos leyendo .opencode/,
    # que un writer en curso puede estar regenerando en ese instante (mismo
    # riesgo de carrera que test-internal-agents-generated.sh).
    #
    # `grep -q` sobre here-string (<<<), nunca sobre un pipe. `grep -q` cierra
    # su stdin en el primer match; si el escritor del otro extremo del pipe
    # todavia no termino, muere con SIGPIPE y `pipefail` propaga ese 141
    # aunque grep haya salido en 0. Con tres agentes el volcado de 'opencode
    # agent list' cabia en el buffer del pipe (64KB en macOS) y el escritor
    # terminaba antes de que grep saliera; con cinco son ~98KB y el fallo se
    # vuelve determinista para todo id que aparezca temprano en el listado
    # (medido en #909: los tres `primary` fallaban con rc=141 y los dos
    # `subagent`, al final del volcado, pasaban). El here-string no tiene un
    # segundo proceso que pueda recibir la señal.
    agent_out=$(cd "$REPO_ROOT" && opencode agent list 2>&1)
    for id in $AGENT_IDS; do
        mode=$(mode_de "$id")
        grep -q "^$id ($mode)" <<<"$agent_out" || {
            agent_out=$(cd "$REPO_ROOT" && opencode agent list 2>&1)
            break
        }
    done
    for id in $AGENT_IDS; do
        mode=$(mode_de "$id")
        if grep -q "^$id ($mode)" <<<"$agent_out"; then
            pass "$id: listado por 'opencode agent list' como $mode"
        else
            fail "$id: NO aparece en 'opencode agent list' como $mode"
        fi
    done

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
echo "[CA-2] opencode.json declara unicamente \$schema (e instructions, si aplica)"
if [ -f "$OPENCODE_JSON" ]; then
    pass "opencode.json existe"
    if jq -e . "$OPENCODE_JSON" >/dev/null 2>&1; then
        pass "opencode.json es JSON valido"

        extra_keys=$(jq -r '(keys - ["$schema","instructions"]) | join(",")' "$OPENCODE_JSON" 2>/dev/null)
        if [ -z "$extra_keys" ]; then
            pass "opencode.json no declara claves fuera de \$schema/instructions"
        else
            fail "opencode.json declara claves no permitidas: $extra_keys"
        fi

        for forbidden in plugin provider model permission token apiKey apikey authPath; do
            if jq -e --arg k "$forbidden" 'has($k)' "$OPENCODE_JSON" >/dev/null 2>&1; then
                fail "opencode.json declara la clave prohibida '$forbidden'"
            else
                pass "opencode.json no declara '$forbidden'"
            fi
        done

        schema_val=$(jq -r '."$schema" // empty' "$OPENCODE_JSON")
        if [ -n "$schema_val" ]; then
            pass "opencode.json declara \$schema: $schema_val"
        else
            fail "opencode.json no declara \$schema"
        fi
    else
        fail "opencode.json no es JSON valido"
    fi
else
    fail "opencode.json no existe en la raiz del repo"
fi

echo ""
echo "[CA-3] MEFISTO_RUNTIME no vive en opencode.json; las salidas con {{mefisto:run}} lo conservan"
if [ -f "$OPENCODE_JSON" ] && grep -q "MEFISTO_RUNTIME" "$OPENCODE_JSON" 2>/dev/null; then
    fail "opencode.json menciona MEFISTO_RUNTIME (debe propagarlo solo el comando generado, issue #867)"
else
    pass "opencode.json no menciona MEFISTO_RUNTIME"
fi
for id in $COMMAND_IDS; do
    src="$REPO_ROOT/src/internal/commands/$id.md"
    out_file="$REPO_ROOT/.opencode/commands/$id.md"
    [ -f "$src" ] || continue
    if grep -qF '{{mefisto:run' "$src" 2>/dev/null; then
        if [ -f "$out_file" ] && grep -qF "MEFISTO_RUNTIME=opencode" "$out_file"; then
            pass "$id: salida OpenCode conserva MEFISTO_RUNTIME=opencode"
        else
            fail "$id: la fuente usa {{mefisto:run}} pero la salida OpenCode no lleva MEFISTO_RUNTIME=opencode ($out_file)"
        fi
    fi
done

echo ""
echo "[CA-4] Cada .opencode/agents/*.md trae permission con external_directory en deny"
for id in $AGENT_IDS; do
    out_file="$REPO_ROOT/.opencode/agents/$id.md"
    [ -f "$out_file" ] || { fail "$id: no existe $out_file"; continue; }
    if ! grep -q '^permission: {' "$out_file" 2>/dev/null; then
        fail "$id: $out_file no trae bloque 'permission:'"
        continue
    fi
    pass "$id: $out_file trae bloque 'permission:'"
    if grep -q '"external_directory":"deny"' "$out_file" 2>/dev/null; then
        pass "$id: external_directory en deny"
    else
        fail "$id: external_directory NO esta en deny"
    fi
done

echo ""
echo "[CA-5] Fuentes neutrales validas, generador en --check, opencode.json/AGENTS.md presentes"
for id in $AGENT_IDS; do
    src="$REPO_ROOT/src/internal/agents/$id.md"
    out=$("$VALIDATOR" "$src" 2>&1)
    if [ $? -eq 0 ]; then
        pass "$id: pasa validate-internal-artifacts.sh"
    else
        fail "$id: el validador rechazo la fuente. Salida: $out"
    fi
done
for id in $COMMAND_IDS; do
    src="$REPO_ROOT/src/internal/commands/$id.md"
    out=$("$VALIDATOR" "$src" 2>&1)
    if [ $? -eq 0 ]; then
        pass "$id: pasa validate-internal-artifacts.sh"
    else
        fail "$id: el validador rechazo la fuente. Salida: $out"
    fi
done

if [ -x "$GENERATOR" ]; then
    out=$("$GENERATOR" --check 2>&1)
    if [ $? -eq 0 ]; then
        pass "generate-internal-adapters.sh --check -> exit 0 (sin divergencias)"
    else
        fail "generate-internal-adapters.sh --check -> exit distinto de 0. Salida: $out"
    fi
else
    fail "$GENERATOR no existe o no es ejecutable"
fi

[ -f "$OPENCODE_JSON" ] && pass "opencode.json existe en la raiz" || fail "opencode.json no existe en la raiz"
[ -s "$AGENTS_MD" ] && pass "AGENTS.md existe y no esta vacio en la raiz" || fail "AGENTS.md no existe o esta vacio en la raiz"

echo ""
echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
