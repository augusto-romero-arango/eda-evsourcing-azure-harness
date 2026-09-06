#!/usr/bin/env bash
# test-mefisto-models.sh -- Tests de la resolucion de perfiles logicos de
# modelo por runtime (MEF-ADR-0049 CA-4 enmendada, issue #857):
# src/internal/scripts/lib/mefisto-models.sh, la tabla por adaptador
# (adapter_claude_default_model / adapter_opencode_default_model) y la
# emision de `model:` del generador (generate-internal-adapters.sh, #854).
#
# Cubre:
#   [pre] La libreria, el schema y el ejemplo existen, tienen sintaxis/JSON
#         valido, y models.example.json pasa el schema y solo tiene
#         placeholders (CA-6, grep de CA-1).
#   [1-4] Precedencia completa: tabla del adaptador (paso 3, Claude vs
#         OpenCode), mapping local por profile (paso 2), mapping local por
#         agent-id por encima de profiles (desempate paso 2), override
#         --models por encima de todo (paso 1, via resolve_stage_model).
#   [5]   Archivo ausente no es error (CA-5).
#   [6]   Perfiles parciales: solo 'deep' en profiles.
#   [7]   'agents' sin 'profiles' es valido.
#   [8]   Ids con caracteres especiales viajan intactos (sin allowlist).
#   [9]   Perfil desconocido aborta con '<origen>: <motivo>', sin stdout.
#   [10]  models.json no-JSON aborta citando el archivo.
#   [11]  models.json mal tipado (additionalProperties) aborta citando el
#         campo, via jsonschema-lite.jq.
#   [12]  El generador emite/omite `model:` segun CA-3: fast/balanced en
#         Claude, nada en deep ni en OpenCode (ningun perfil).
#   [13]  El mapping local de OpenCode resuelve aunque el adaptador no tenga
#         tabla; sin entrada, OpenCode sigue heredando.
#   [14]  Un valor de `agents` que no es un string no vacio aborta -- el guard
#         que cubre lo que jsonschema-lite.jq no puede expresar (CA-4).
#   [15]  Sin el adaptador sourceado, aborta con motivo -- nunca con
#         MEFISTO_MODELS_ERROR vacio (CA-5).
#
# Uso: .claude/scripts/tests/test-mefisto-models.sh
# Exit code: 0 si todos los checks pasan, 1 si alguno falla.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LIB_DIR="$REPO_ROOT/src/internal/scripts/lib"
CONTRACT_DIR="$REPO_ROOT/src/internal/contract"
GENERATOR="$REPO_ROOT/src/internal/scripts/generate-internal-adapters.sh"
EXAMPLE_FILE="$REPO_ROOT/src/internal/models.example.json"
SCHEMA_FILE="$CONTRACT_DIR/models.schema.json"
JSONSCHEMA_LITE="$LIB_DIR/jsonschema-lite.jq"
MODELS_LIB="$LIB_DIR/mefisto-models.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "[pre] La libreria, el schema y el ejemplo existen y tienen sintaxis/JSON validos"
for f in "$MODELS_LIB" "$LIB_DIR/adapter-claude.sh" "$LIB_DIR/adapter-opencode.sh"; do
    if [ -f "$f" ]; then pass "existe: ${f#"$REPO_ROOT"/}"; else fail "no existe: ${f#"$REPO_ROOT"/}"; fi
    if bash -n "$f" 2>/dev/null; then pass "sintaxis bash valida: ${f#"$REPO_ROOT"/}"; else fail "sintaxis bash invalida: ${f#"$REPO_ROOT"/}"; fi
done
if [ -f "$SCHEMA_FILE" ]; then pass "existe: models.schema.json"; else fail "no existe: models.schema.json"; fi
if jq empty "$SCHEMA_FILE" 2>/dev/null; then pass "models.schema.json es JSON valido"; else fail "models.schema.json NO es JSON valido"; fi
if [ -f "$EXAMPLE_FILE" ]; then pass "existe: models.example.json"; else fail "no existe: models.example.json"; fi
if jq empty "$EXAMPLE_FILE" 2>/dev/null; then pass "models.example.json es JSON valido"; else fail "models.example.json NO es JSON valido"; fi

ERRORS=$(jq -n --argjson schema "$(cat "$SCHEMA_FILE")" --argjson instance "$(cat "$EXAMPLE_FILE")" -f "$JSONSCHEMA_LITE" 2>/dev/null)
if [ "$(printf '%s' "$ERRORS" | jq 'length' 2>/dev/null)" = "0" ]; then
    pass "models.example.json pasa models.schema.json"
else
    fail "models.example.json no pasa el schema: $ERRORS"
fi
if grep -qE '"(claude-|gpt-|opus|sonnet|haiku|fable)[^"]*"' "$EXAMPLE_FILE"; then
    fail "models.example.json contiene un id de modelo real (deberia tener solo placeholders)"
else
    pass "models.example.json solo contiene placeholders"
fi
# CA-1: ningun id provider/model real en src/internal/ (grep de la exclusion).
if grep -rE '"(claude-(opus|sonnet|haiku)|gpt-[0-9])[^"]*"' "$REPO_ROOT/src/internal" 2>/dev/null | grep -v '\.md:'; then
    fail "src/internal/ contiene un id de modelo real fuera de un .md"
else
    pass "src/internal/ (fuera de .md) no contiene ids de modelo reales"
fi

echo ""
echo "[1] tabla del adaptador (paso 3): Claude fast/balanced/deep, OpenCode siempre vacio"
(
    source "$LIB_DIR/adapter-claude.sh"
    source "$LIB_DIR/adapter-opencode.sh"
    source "$MODELS_LIB"
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    export MEFISTO_MODELS_FILE="$TMP/no-existe.json"

    R=$(mefisto_resolve_model claude mefisto-planner fast)
    [ "$R" = "haiku" ] && echo "PASS:claude/fast -> haiku" || echo "FAIL:claude/fast deberia ser 'haiku' (obtenido '$R')"
    R=$(mefisto_resolve_model claude mefisto-planner balanced)
    [ "$R" = "sonnet" ] && echo "PASS:claude/balanced -> sonnet" || echo "FAIL:claude/balanced deberia ser 'sonnet' (obtenido '$R')"
    R=$(mefisto_resolve_model claude mefisto-planner deep)
    [ -z "$R" ] && echo "PASS:claude/deep -> cadena vacia (hereda)" || echo "FAIL:claude/deep deberia ser vacio (obtenido '$R')"
    R=$(mefisto_resolve_model opencode mefisto-planner fast)
    [ -z "$R" ] && echo "PASS:opencode/fast -> cadena vacia (sin tabla)" || echo "FAIL:opencode/fast deberia ser vacio (obtenido '$R')"
    R=$(mefisto_resolve_model opencode mefisto-planner balanced)
    [ -z "$R" ] && echo "PASS:opencode/balanced -> cadena vacia (sin tabla)" || echo "FAIL:opencode/balanced deberia ser vacio (obtenido '$R')"
    R=$(mefisto_resolve_model opencode mefisto-planner deep)
    [ -z "$R" ] && echo "PASS:opencode/deep -> cadena vacia (sin tabla)" || echo "FAIL:opencode/deep deberia ser vacio (obtenido '$R')"
) > "$SCRIPT_DIR/.tmp-out-1" 2>&1
while IFS= read -r line; do
    case "$line" in
        PASS:*) pass "${line#PASS:}" ;;
        FAIL:*) fail "${line#FAIL:}" ;;
    esac
done < "$SCRIPT_DIR/.tmp-out-1"
rm -f "$SCRIPT_DIR/.tmp-out-1"

echo ""
echo "[2] mapping local (paso 2): profiles.<profile> gana sobre la tabla del adaptador"
(
    source "$LIB_DIR/adapter-claude.sh"
    source "$LIB_DIR/adapter-opencode.sh"
    source "$MODELS_LIB"
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    export MEFISTO_MODELS_FILE="$TMP/models.json"
    cat > "$MEFISTO_MODELS_FILE" <<'EOF'
{ "claude": { "profiles": { "fast": "claude-custom-fast", "deep": "claude-custom-deep" } } }
EOF
    R=$(mefisto_resolve_model claude mefisto-planner fast)
    [ "$R" = "claude-custom-fast" ] && echo PASS1 || echo "FAIL1:$R"
    R=$(mefisto_resolve_model claude mefisto-planner deep)
    [ "$R" = "claude-custom-deep" ] && echo PASS2 || echo "FAIL2:$R"
    R=$(mefisto_resolve_model claude mefisto-planner balanced)
    [ "$R" = "sonnet" ] && echo PASS3 || echo "FAIL3:$R"
) > "$SCRIPT_DIR/.tmp-out-2" 2>&1
while IFS= read -r line; do
    case "$line" in
        PASS1) pass "profiles.fast gana sobre la tabla del adaptador (haiku)" ;;
        FAIL1:*) fail "profiles.fast deberia ganar -- obtenido '${line#FAIL1:}'" ;;
        PASS2) pass "profiles.deep resuelve donde la tabla del adaptador hereda" ;;
        FAIL2:*) fail "profiles.deep deberia resolver -- obtenido '${line#FAIL2:}'" ;;
        PASS3) pass "un perfil sin entrada en el mapping cae en la tabla del adaptador" ;;
        FAIL3:*) fail "deberia caer en la tabla -- obtenido '${line#FAIL3:}'" ;;
    esac
done < "$SCRIPT_DIR/.tmp-out-2"
rm -f "$SCRIPT_DIR/.tmp-out-2"

echo ""
echo "[3] mapping local (desempate paso 2): agents.<agent-id> gana sobre profiles.<profile>"
(
    source "$LIB_DIR/adapter-claude.sh"
    source "$LIB_DIR/adapter-opencode.sh"
    source "$MODELS_LIB"
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    export MEFISTO_MODELS_FILE="$TMP/models.json"
    cat > "$MEFISTO_MODELS_FILE" <<'EOF'
{
  "claude": {
    "profiles": { "deep": "claude-profile-deep" },
    "agents": { "mefisto-planner": "claude-agent-override" }
  }
}
EOF
    R=$(mefisto_resolve_model claude mefisto-planner deep)
    [ "$R" = "claude-agent-override" ] && echo PASS1 || echo "FAIL1:$R"
    R=$(mefisto_resolve_model claude otro-agente deep)
    [ "$R" = "claude-profile-deep" ] && echo PASS2 || echo "FAIL2:$R"
) > "$SCRIPT_DIR/.tmp-out-3" 2>&1
while IFS= read -r line; do
    case "$line" in
        PASS1) pass "agents.<agent-id> gana sobre profiles.<profile> para el mismo agente" ;;
        FAIL1:*) fail "agents deberia ganar -- obtenido '${line#FAIL1:}'" ;;
        PASS2) pass "un agente sin entrada propia cae en profiles.<profile>" ;;
        FAIL2:*) fail "deberia caer en profiles -- obtenido '${line#FAIL2:}'" ;;
    esac
done < "$SCRIPT_DIR/.tmp-out-3"
rm -f "$SCRIPT_DIR/.tmp-out-3"

echo ""
echo "[4] override --models (paso 1) gana sobre mapping local y tabla del adaptador"
(
    source "$LIB_DIR/adapter-claude.sh"
    source "$LIB_DIR/adapter-opencode.sh"
    source "$REPO_ROOT/.claude/scripts/_mefisto-common.sh" 2>/dev/null
    source "$MODELS_LIB"
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    export MEFISTO_MODELS_FILE="$TMP/models.json"
    cat > "$MEFISTO_MODELS_FILE" <<'EOF'
{ "claude": { "agents": { "mefisto-planner": "claude-agent-override" } } }
EOF
    parse_stage_models "mefisto-planner=claude-opus-5[1m]" >/dev/null
    R=$(mefisto_resolve_model claude mefisto-planner deep)
    [ "$R" = "claude-opus-5[1m]" ] && echo PASS || echo "FAIL:$R"
) > "$SCRIPT_DIR/.tmp-out-4" 2>&1
while IFS= read -r line; do
    case "$line" in
        PASS) pass "override --models (resolve_stage_model) gana sobre mapping local" ;;
        FAIL:*) fail "override deberia ganar -- obtenido '${line#FAIL:}'" ;;
    esac
done < "$SCRIPT_DIR/.tmp-out-4"
rm -f "$SCRIPT_DIR/.tmp-out-4"

echo ""
echo "[5] archivo ausente no es error (CA-5)"
(
    source "$LIB_DIR/adapter-claude.sh"
    source "$LIB_DIR/adapter-opencode.sh"
    source "$MODELS_LIB"
    export MEFISTO_MODELS_FILE="/no/existe/models.json"
    mefisto_resolve_model claude mefisto-planner fast >/dev/null 2>&1
    echo "rc=$?"
) > "$SCRIPT_DIR/.tmp-out-5"
if grep -q "rc=0" "$SCRIPT_DIR/.tmp-out-5"; then pass "archivo ausente retorna 0"; else fail "archivo ausente no deberia abortar: $(cat "$SCRIPT_DIR/.tmp-out-5")"; fi
rm -f "$SCRIPT_DIR/.tmp-out-5"

echo ""
echo "[6] perfiles parciales: solo 'deep' declarado en profiles"
(
    source "$LIB_DIR/adapter-claude.sh"
    source "$LIB_DIR/adapter-opencode.sh"
    source "$MODELS_LIB"
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    export MEFISTO_MODELS_FILE="$TMP/models.json"
    cat > "$MEFISTO_MODELS_FILE" <<'EOF'
{ "claude": { "profiles": { "deep": "claude-solo-deep" } } }
EOF
    R=$(mefisto_resolve_model claude mefisto-planner deep)
    [ "$R" = "claude-solo-deep" ] && echo PASS1 || echo "FAIL1:$R"
    R=$(mefisto_resolve_model claude mefisto-planner fast)
    [ "$R" = "haiku" ] && echo PASS2 || echo "FAIL2:$R"
) > "$SCRIPT_DIR/.tmp-out-6" 2>&1
while IFS= read -r line; do
    case "$line" in
        PASS1) pass "profiles parcial ('deep' solo) resuelve la clave presente" ;;
        FAIL1:*) fail "deberia resolver 'deep' -- obtenido '${line#FAIL1:}'" ;;
        PASS2) pass "un perfil ausente del mapping parcial cae en la tabla del adaptador" ;;
        FAIL2:*) fail "deberia caer en la tabla -- obtenido '${line#FAIL2:}'" ;;
    esac
done < "$SCRIPT_DIR/.tmp-out-6"
rm -f "$SCRIPT_DIR/.tmp-out-6"

echo ""
echo "[7] 'agents' sin 'profiles' es valido"
(
    source "$LIB_DIR/adapter-claude.sh"
    source "$LIB_DIR/adapter-opencode.sh"
    source "$MODELS_LIB"
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    export MEFISTO_MODELS_FILE="$TMP/models.json"
    cat > "$MEFISTO_MODELS_FILE" <<'EOF'
{ "claude": { "agents": { "mefisto-planner": "claude-solo-agents" } } }
EOF
    R=$(mefisto_resolve_model claude mefisto-planner deep)
    echo "rc=$? val=$R"
) > "$SCRIPT_DIR/.tmp-out-7"
if grep -q "rc=0 val=claude-solo-agents" "$SCRIPT_DIR/.tmp-out-7"; then
    pass "'agents' sin 'profiles' resuelve sin error"
else
    fail "obtenido: $(cat "$SCRIPT_DIR/.tmp-out-7")"
fi
rm -f "$SCRIPT_DIR/.tmp-out-7"

echo ""
echo "[8] ids con caracteres especiales viajan intactos (sin allowlist propia)"
(
    source "$LIB_DIR/adapter-claude.sh"
    source "$LIB_DIR/adapter-opencode.sh"
    source "$MODELS_LIB"
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    export MEFISTO_MODELS_FILE="$TMP/models.json"
    cat > "$MEFISTO_MODELS_FILE" <<'EOF'
{
  "claude": { "agents": { "mefisto-planner": "claude-opus-5[1m]" } },
  "opencode": { "agents": { "mefisto-planner": "openai/gpt-x: variante con espacios" } }
}
EOF
    R=$(mefisto_resolve_model claude mefisto-planner deep)
    [ "$R" = "claude-opus-5[1m]" ] && echo PASS1 || echo "FAIL1:$R"
    R=$(mefisto_resolve_model opencode mefisto-planner deep)
    [ "$R" = "openai/gpt-x: variante con espacios" ] && echo PASS2 || echo "FAIL2:$R"
) > "$SCRIPT_DIR/.tmp-out-8" 2>&1
while IFS= read -r line; do
    case "$line" in
        PASS1) pass "id con '[' ']' viaja intacto (sin globbing)" ;;
        FAIL1:*) fail "id con corchetes alterado -- obtenido '${line#FAIL1:}'" ;;
        PASS2) pass "id con ':' y espacios viaja intacto" ;;
        FAIL2:*) fail "id con ':' y espacios alterado -- obtenido '${line#FAIL2:}'" ;;
    esac
done < "$SCRIPT_DIR/.tmp-out-8"
rm -f "$SCRIPT_DIR/.tmp-out-8"

echo ""
echo "[9] perfil desconocido aborta con '<origen>: <motivo>', sin imprimir nada por stdout"
(
    source "$LIB_DIR/adapter-claude.sh"
    source "$LIB_DIR/adapter-opencode.sh"
    source "$MODELS_LIB"
    OUT_FILE="$(mktemp)"
    # Redirect simple (>), NO "$(...)": una sustitucion de comando forkearia un
    # subshell y MEFISTO_MODELS_ERROR, asignada dentro de mefisto_resolve_model,
    # se perderia al volver -- el mismo bug que el fix de
    # _mefisto_models_validate_local_file existe para evitar en la libreria.
    mefisto_resolve_model claude mefisto-planner ultra > "$OUT_FILE"
    RC=$?
    OUT="$(cat "$OUT_FILE")"
    rm -f "$OUT_FILE"
    echo "rc=$RC out=[$OUT] err=[$MEFISTO_MODELS_ERROR]"
) > "$SCRIPT_DIR/.tmp-out-9"
CONTENT=$(cat "$SCRIPT_DIR/.tmp-out-9")
if printf '%s' "$CONTENT" | grep -q "rc=1"; then pass "perfil desconocido -> exit 1"; else fail "deberia abortar: $CONTENT"; fi
if printf '%s' "$CONTENT" | grep -q "out=\[\]"; then pass "sin salida por stdout"; else fail "no deberia imprimir nada: $CONTENT"; fi
if printf '%s' "$CONTENT" | grep -qF "err=[profile: 'ultra' no esta en el vocabulario fast|balanced|deep]"; then
    pass "MEFISTO_MODELS_ERROR con formato '<origen>: <motivo>'"
else
    fail "mensaje de error inesperado: $CONTENT"
fi
rm -f "$SCRIPT_DIR/.tmp-out-9"

echo ""
echo "[10] models.json no-JSON aborta citando el archivo"
(
    source "$LIB_DIR/adapter-claude.sh"
    source "$LIB_DIR/adapter-opencode.sh"
    source "$MODELS_LIB"
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    export MEFISTO_MODELS_FILE="$TMP/models.json"
    echo "esto no es json" > "$MEFISTO_MODELS_FILE"
    mefisto_resolve_model claude mefisto-planner fast >/dev/null
    echo "rc=$? err=[$MEFISTO_MODELS_ERROR]"
) > "$SCRIPT_DIR/.tmp-out-10"
CONTENT=$(cat "$SCRIPT_DIR/.tmp-out-10")
if printf '%s' "$CONTENT" | grep -q "rc=1" && printf '%s' "$CONTENT" | grep -qF "models.json: no es JSON valido"; then
    pass "JSON invalido -- aborta citando el archivo"
else
    fail "obtenido: $CONTENT"
fi
rm -f "$SCRIPT_DIR/.tmp-out-10"

echo ""
echo "[11] models.json mal tipado (additionalProperties) aborta via jsonschema-lite.jq"
(
    source "$LIB_DIR/adapter-claude.sh"
    source "$LIB_DIR/adapter-opencode.sh"
    source "$MODELS_LIB"
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    export MEFISTO_MODELS_FILE="$TMP/models.json"
    cat > "$MEFISTO_MODELS_FILE" <<'EOF'
{ "claude": { "profiles": { "ultra": "no-deberia-existir" } } }
EOF
    mefisto_resolve_model claude mefisto-planner fast >/dev/null
    echo "rc=$? err=[$MEFISTO_MODELS_ERROR]"
) > "$SCRIPT_DIR/.tmp-out-11"
CONTENT=$(cat "$SCRIPT_DIR/.tmp-out-11")
if printf '%s' "$CONTENT" | grep -q "rc=1" && printf '%s' "$CONTENT" | grep -qF "propiedad adicional no permitida"; then
    pass "mal tipado -- aborta con el motivo del schema"
else
    fail "obtenido: $CONTENT"
fi
rm -f "$SCRIPT_DIR/.tmp-out-11"

echo ""
echo "[12] el generador emite/omite 'model:' segun CA-3 (fast/balanced en Claude, nunca en OpenCode)"
FIX_DIR="$(mktemp -d)"
trap 'rm -rf "$FIX_DIR"' EXIT

cat > "$FIX_DIR/mefisto-fx-models-fast.md" <<'EOF'
---
{
  "kind": "command",
  "id": "mefisto-fx-models-fast",
  "description": "Fixture profile fast (issue #857).",
  "profile": "fast"
}
---

Cuerpo.
EOF
cat > "$FIX_DIR/mefisto-fx-models-balanced.md" <<'EOF'
---
{
  "kind": "agent",
  "id": "mefisto-fx-models-balanced",
  "description": "Fixture profile balanced (issue #857).",
  "mode": "subagent",
  "profile": "balanced"
}
---

Cuerpo.
EOF
cat > "$FIX_DIR/mefisto-fx-models-deep.md" <<'EOF'
---
{
  "kind": "command",
  "id": "mefisto-fx-models-deep",
  "description": "Fixture profile deep (issue #857).",
  "profile": "deep"
}
---

Cuerpo.
EOF
cat > "$FIX_DIR/mefisto-fx-models-none.md" <<'EOF'
---
{
  "kind": "command",
  "id": "mefisto-fx-models-none",
  "description": "Fixture sin profile (issue #857)."
}
---

Cuerpo.
EOF

OUT_DIR="$FIX_DIR/out"
OUT=$("$GENERATOR" --out "$OUT_DIR" \
    "$FIX_DIR/mefisto-fx-models-fast.md" \
    "$FIX_DIR/mefisto-fx-models-balanced.md" \
    "$FIX_DIR/mefisto-fx-models-deep.md" \
    "$FIX_DIR/mefisto-fx-models-none.md" 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "generacion de fixtures de profile -> exit $RC. Salida: $OUT"

if grep -q '^model: "haiku"$' "$OUT_DIR/.claude/commands/mefisto-fx-models-fast.md" 2>/dev/null; then
    pass "profile fast -> model: \"haiku\" en Claude"
else
    fail "profile fast no emitio model:\"haiku\" en Claude"
fi
if grep -q '^model: "sonnet"$' "$OUT_DIR/.claude/agents/mefisto-fx-models-balanced.md" 2>/dev/null; then
    pass "profile balanced -> model: \"sonnet\" en Claude"
else
    fail "profile balanced no emitio model:\"sonnet\" en Claude"
fi
if grep -q '^model:' "$OUT_DIR/.claude/commands/mefisto-fx-models-deep.md" 2>/dev/null; then
    fail "profile deep no deberia emitir model: en Claude"
else
    pass "profile deep -> sin model: en Claude (hereda)"
fi
if grep -q '^model:' "$OUT_DIR/.claude/commands/mefisto-fx-models-none.md" 2>/dev/null; then
    fail "sin profile no deberia emitir model: en Claude"
else
    pass "sin profile -> sin model: en Claude"
fi
for f in mefisto-fx-models-fast mefisto-fx-models-deep mefisto-fx-models-none; do
    if grep -q '^model:' "$OUT_DIR/.opencode/commands/$f.md" 2>/dev/null; then
        fail "$f: OpenCode no deberia emitir model: nunca"
    else
        pass "$f: OpenCode sin model: (nunca lo emite)"
    fi
done
if grep -q '^model:' "$OUT_DIR/.opencode/agents/mefisto-fx-models-balanced.md" 2>/dev/null; then
    fail "mefisto-fx-models-balanced: OpenCode no deberia emitir model: nunca"
else
    pass "mefisto-fx-models-balanced: OpenCode sin model: (nunca lo emite)"
fi

echo ""
echo "[13] mapping local de OpenCode por profile (la tabla del adaptador nunca lo tapa)"
(
    source "$LIB_DIR/adapter-claude.sh"
    source "$LIB_DIR/adapter-opencode.sh"
    source "$MODELS_LIB"
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    export MEFISTO_MODELS_FILE="$TMP/models.json"
    cat > "$MEFISTO_MODELS_FILE" <<'EOF'
{ "opencode": { "profiles": { "balanced": "vendor-x/modelo-medio" } } }
EOF
    R=$(mefisto_resolve_model opencode mefisto-planner balanced)
    [ "$R" = "vendor-x/modelo-medio" ] && echo PASS1 || echo "FAIL1:$R"
    R=$(mefisto_resolve_model opencode mefisto-planner fast)
    [ -z "$R" ] && echo PASS2 || echo "FAIL2:$R"
) > "$SCRIPT_DIR/.tmp-out-13" 2>&1
while IFS= read -r line; do
    case "$line" in
        PASS1) pass "opencode profiles.balanced resuelve desde el mapping local" ;;
        FAIL1:*) fail "opencode profiles.balanced -- obtenido '${line#FAIL1:}'" ;;
        PASS2) pass "opencode sin entrada en el mapping sigue heredando (sin tabla)" ;;
        FAIL2:*) fail "opencode deberia heredar -- obtenido '${line#FAIL2:}'" ;;
    esac
done < "$SCRIPT_DIR/.tmp-out-13"
rm -f "$SCRIPT_DIR/.tmp-out-13"

echo ""
echo "[14] valor de 'agents' que no es un string no vacio aborta (CA-4, guard fuera del schema)"
(
    source "$LIB_DIR/adapter-claude.sh"
    source "$LIB_DIR/adapter-opencode.sh"
    source "$MODELS_LIB"
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    export MEFISTO_MODELS_FILE="$TMP/models.json"
    cat > "$MEFISTO_MODELS_FILE" <<'EOF'
{ "claude": { "agents": { "mefisto-planner": { "model": "anidado" } } } }
EOF
    mefisto_resolve_model claude mefisto-planner fast >/dev/null
    echo "rc=$? err=[$MEFISTO_MODELS_ERROR]"
) > "$SCRIPT_DIR/.tmp-out-14"
CONTENT=$(cat "$SCRIPT_DIR/.tmp-out-14")
if printf '%s' "$CONTENT" | grep -q "rc=1" && printf '%s' "$CONTENT" | grep -qF "claude.agents.mefisto-planner: se esperaba un string no vacio"; then
    pass "valor de agente no-string -- aborta citando la clave exacta"
else
    fail "obtenido: $CONTENT"
fi
rm -f "$SCRIPT_DIR/.tmp-out-14"

echo ""
echo "[15] adaptador no sourceado aborta con motivo (nunca con MEFISTO_MODELS_ERROR vacio)"
(
    source "$MODELS_LIB"
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    export MEFISTO_MODELS_FILE="$TMP/no-existe.json"
    mefisto_resolve_model claude mefisto-planner fast >/dev/null 2>&1
    echo "rc=$? err=[$MEFISTO_MODELS_ERROR]"
) > "$SCRIPT_DIR/.tmp-out-15"
CONTENT=$(cat "$SCRIPT_DIR/.tmp-out-15")
if printf '%s' "$CONTENT" | grep -q "rc=1" && printf '%s' "$CONTENT" | grep -qF "adapter_claude_default_model: no esta disponible"; then
    pass "sin adapter-claude.sh sourceado -- aborta con '<origen>: <motivo>'"
else
    fail "obtenido: $CONTENT"
fi
rm -f "$SCRIPT_DIR/.tmp-out-15"

echo ""
echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
