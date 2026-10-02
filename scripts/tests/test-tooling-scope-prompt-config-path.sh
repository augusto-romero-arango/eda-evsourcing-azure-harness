#!/usr/bin/env bash
# test-tooling-scope-prompt-config-path.sh -- Contrato de config canonico en los
# prompts de ALCANCE PERMITIDO de tooling-pipeline.sh (#1512).
#
# El gate real (is_path_in_consumer_blocklist) no bloquea ninguna de las dos
# rutas de config: lo que decide que archivo toca el agente es el texto del
# prompt. Por eso el contrato se verifica prompt por prompt (writer y reviewer
# por separado, anclados en su encabezado), no por conteo global de
# ocurrencias: dos menciones en un mismo prompt dejarian el otro sin cubrir.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/tooling-pipeline.sh"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# bloque_desde <patron-encabezado> <n-lineas>
# Imprime las <n-lineas> siguientes al primer encabezado que casa el patron.
bloque_desde() {
    local patron="$1" n="$2" inicio
    inicio=$(grep -n "$patron" "$SCRIPT" | head -1 | cut -d: -f1)
    [ -n "$inicio" ] || return 1
    sed -n "${inicio},$((inicio + n))p" "$SCRIPT"
}

echo "[1] Prompt del writer: canonico listado, legacy calificado"
WRITER_BLOCK=$(bloque_desde '^ALCANCE PERMITIDO de escritura:$' 14)
if [ -z "$WRITER_BLOCK" ]; then
    fail "no se encontro el encabezado del ALCANCE PERMITIDO del writer"
else
    if printf '%s\n' "$WRITER_BLOCK" | grep -Fq '.mefisto/harness.config.json'; then
        pass "el writer lista .mefisto/harness.config.json"
    else
        fail "el writer no lista .mefisto/harness.config.json"
    fi
    if printf '%s\n' "$WRITER_BLOCK" | grep -F '.claude/harness.config.json' | grep -q 'solo si ya existe'; then
        pass "el writer califica .claude/harness.config.json con 'solo si ya existe'"
    else
        fail "el writer no califica .claude/harness.config.json con 'solo si ya existe'"
    fi
    CANON_POS=$(printf '%s\n' "$WRITER_BLOCK" | grep -nF '.mefisto/harness.config.json' | head -1 | cut -d: -f1)
    LEGACY_POS=$(printf '%s\n' "$WRITER_BLOCK" | grep -nF '.claude/harness.config.json' | head -1 | cut -d: -f1)
    if [ -n "$CANON_POS" ] && [ -n "$LEGACY_POS" ] && [ "$CANON_POS" -lt "$LEGACY_POS" ]; then
        pass "el canonico aparece antes que el legacy en el prompt del writer"
    else
        fail "orden inesperado en el writer: canonico=$CANON_POS legacy=$LEGACY_POS"
    fi
fi

echo "[2] Prompt del reviewer: paridad con el writer y mismo calificativo"
REVIEWER_BLOCK=$(bloque_desde '^ALCANCE PERMITIDO de escritura (igual al del writer):$' 4)
if [ -z "$REVIEWER_BLOCK" ]; then
    fail "no se encontro el encabezado 'igual al del writer' del reviewer"
else
    pass "el reviewer conserva la nota 'igual al del writer'"
    if printf '%s\n' "$REVIEWER_BLOCK" | grep -Fq '.mefisto/harness.config.json'; then
        pass "el reviewer enumera .mefisto/harness.config.json"
    else
        fail "el reviewer no enumera .mefisto/harness.config.json"
    fi
    if printf '%s\n' "$REVIEWER_BLOCK" | grep -F '.claude/harness.config.json' | grep -q 'solo si ya existe'; then
        pass "el reviewer califica .claude/harness.config.json con 'solo si ya existe'"
    else
        fail "el reviewer no califica .claude/harness.config.json con 'solo si ya existe'"
    fi
    # settings.json es configuracion propia del runtime, no una ruta legacy del
    # contrato del harness: sigue listada tal cual, sin calificativo (CA-2).
    if printf '%s\n' "$REVIEWER_BLOCK" | grep -Fq '.claude/settings.json'; then
        pass "el reviewer conserva .claude/settings.json tal cual"
    else
        fail "el reviewer dejo de listar .claude/settings.json"
    fi
fi

echo "[3] Anti-regresion: ninguna linea nombra el config legacy sin 'legacy'"
UNQUALIFIED=$(grep -n '\.claude/harness\.config\.json' "$SCRIPT" | grep -v 'legacy' || true)
if [ -z "$UNQUALIFIED" ]; then
    pass "toda mencion de .claude/harness.config.json lleva 'legacy' en la misma linea"
else
    fail "mencion sin calificar 'legacy': $UNQUALIFIED"
fi

echo "[4] Gate y prompt siguen coherentes: is_path_in_consumer_blocklist no bloquea ninguna ruta"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/_pipeline-common.sh"

if is_path_in_consumer_blocklist ".mefisto/harness.config.json"; then
    fail "is_path_in_consumer_blocklist bloquea .mefisto/harness.config.json (deberia devolver 1)"
else
    pass "is_path_in_consumer_blocklist no bloquea .mefisto/harness.config.json"
fi

if is_path_in_consumer_blocklist ".claude/harness.config.json"; then
    fail "is_path_in_consumer_blocklist bloquea .claude/harness.config.json (deberia devolver 1)"
else
    pass "is_path_in_consumer_blocklist no bloquea .claude/harness.config.json"
fi

echo "[5] .github/dependabot.yml declarado en writer y reviewer, sin abrir .github/ completo (#1782)"
W5=$(bloque_desde '^ALCANCE PERMITIDO de escritura:$' 14)
R5=$(bloque_desde '^ALCANCE PERMITIDO de escritura (igual al del writer):$' 4)
for quien in W5:writer R5:reviewer; do
    var="${quien%%:*}"; nombre="${quien##*:}"
    if printf '%s\n' "${!var}" | grep -Fq '.github/dependabot.yml'; then
        pass "el $nombre declara .github/dependabot.yml"
    else
        fail "el $nombre no declara .github/dependabot.yml"
    fi
    if printf '%s\n' "${!var}" | grep -Eq '(^|[ ,-])\.github/($|[ ,(])'; then
        fail "el $nombre declara .github/ completo"
    else
        pass "el $nombre no declara .github/ completo"
    fi
done

echo "[6] Gate: dependabot.yml no se bloquea y las rutas del plugin siguen bloqueadas"
if is_path_in_consumer_blocklist ".github/dependabot.yml"; then
    fail "el gate bloquea .github/dependabot.yml"
else
    pass "el gate no bloquea .github/dependabot.yml"
fi
for ruta in commands/x.md agents/x.md hooks/x.sh .claude-plugin/plugin.json; do
    if is_path_in_consumer_blocklist "$ruta"; then
        pass "el gate bloquea $ruta"
    else
        fail "el gate no bloquea $ruta"
    fi
done

echo "[7] Escenario: solo dependabot.yml deja diff reconocible y pasa el gate"
TMP7=$(mktemp -d)
(
    cd "$TMP7" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base \
        && mkdir -p .github && printf 'version: 2\n' > .github/dependabot.yml
)
if [ -n "$(git -C "$TMP7" status --porcelain)" ] && ! is_path_in_consumer_blocklist "$(git -C "$TMP7" status --porcelain -uall | awk '{print $2}')"; then
    pass "diff con solo dependabot.yml es visible y no bloqueado"
else
    fail "escenario dependabot.yml no reconocido"
fi
rm -rf "$TMP7"

echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
