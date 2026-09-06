#!/usr/bin/env bash
# test-opencode-permissions.sh -- Tests del bloque `permission` de OpenCode
# generado desde capacidades neutrales (issue #862, MEF-ADR-0049 decision 5).
#
# Cubre (CA-6, mas CA-1/CA-5 desde el mismo arnes):
#   [empty] Un agente con `capabilities: []` obtiene todo deny, incluidos
#       bash/read/edit (CA-1).
#   [read] Lectura de `.env` -> deny (CA-2) con la capacidad `read`.
#   [edit] Edicion de `src/Foo.cs` -> deny, de `commands/x.md` -> allow y de
#       `.mefisto/pipeline/summaries/stage-1-writer.md` -> allow (CA-2).
#   [bash] `rm -rf x` -> deny y `git status` -> allow (CA-3) con la capacidad
#       `shell`.
#   [question] `allow` solo en `mode: primary`, `deny` en `subagent` (CA-4).
#   [mcp-abort] La capacidad `mcp` aborta con "capacidad mcp sin mapeo
#       OpenCode", sin escribir nada (CA-5).
#   [parity] Paridad `edit` vs `is_path_in_mefisto_scope` sobre 10 rutas
#       (CA-6): defensa en profundidad, mismo veredicto que el gate real.
#
# Los agentes de prueba se generan con el generador real
# (generate-internal-adapters.sh), no invocando las funciones del adaptador
# sueltas: ejercita la integracion completa (frontmatter.sh + adapter-opencode.sh
# + opencode-permissions.json), igual que test-generate-internal-adapters.sh.
# La evaluacion de "ultima coincidencia gana" usa
# src/internal/scripts/lib/opencode-permission-eval.jq (issue #862 notas
# tecnicas: ese evaluador reproduce solo la regla de orden, no el motor real
# de OpenCode -- una discrepancia del dogfooding #874 se corrige en el
# mapping, nunca aqui).
#
# Uso: .claude/scripts/tests/test-opencode-permissions.sh
# Exit code: 0 si todos los checks pasan, 1 si alguno falla.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GENERATOR="$REPO_ROOT/src/internal/scripts/generate-internal-adapters.sh"
EVALUATOR="$REPO_ROOT/src/internal/scripts/lib/opencode-permission-eval.jq"

source "$REPO_ROOT/.claude/scripts/_mefisto-common.sh" 2>/dev/null

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# assert_eq <esperado> <obtenido> <etiqueta>
assert_eq() {
    if [ "$1" = "$2" ]; then
        pass "$3"
    else
        fail "$3 -- esperado: '$1', obtenido: '$2'"
    fi
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
SRC_DIR="$WORKDIR/src"
OUT_DIR="$WORKDIR/out"
mkdir -p "$SRC_DIR"

# opencode_permission_line <id> -- imprime el JSON compacto del bloque
# `permission` ya generado para el agente <id>: opencode_render (issue #862)
# lo emite como una sola linea "permission: {...}" (jq -c), asi que basta con
# recortar el prefijo -- el resto del frontmatter es YAML de un solo campo por
# linea, no un objeto JSON completo, y no hace falta parsearlo entero.
opencode_permission_line() {
    local id="$1"
    sed -n 's/^permission: //p' "$OUT_DIR/.opencode/agents/$id.md"
}

# permission_of <id> <clave> -- imprime el valor (string o mapa JSON) de la
# clave <clave> del bloque `permission` generado para el agente <id>.
permission_of() {
    local id="$1" key="$2"
    opencode_permission_line "$id" | jq -c --arg k "$key" '.[$k]'
}

# eval_perm <id> <clave> <candidato> -- resuelve, con la regla de "ultima
# coincidencia gana", el valor efectivo de <clave> para <candidato> en el
# agente <id> ya generado.
eval_perm() {
    local id="$1" key="$2" input="$3"
    local perm
    perm="$(opencode_permission_line "$id")"
    jq -rn --argjson permission "$perm" --arg key "$key" --arg input "$input" -f "$EVALUATOR"
}

cat > "$SRC_DIR/mefisto-fx-perm-empty.md" <<'EOF'
---
{
  "kind": "agent",
  "id": "mefisto-fx-perm-empty",
  "description": "Agente sin capacidades, para CA-1 (issue #862).",
  "mode": "subagent",
  "capabilities": []
}
---

Cuerpo.
EOF

cat > "$SRC_DIR/mefisto-fx-perm-read.md" <<'EOF'
---
{
  "kind": "agent",
  "id": "mefisto-fx-perm-read",
  "description": "Agente solo-lectura, para CA-2 (issue #862).",
  "mode": "subagent",
  "capabilities": ["read"]
}
---

Cuerpo.
EOF

cat > "$SRC_DIR/mefisto-fx-perm-planner.md" <<'EOF'
---
{
  "kind": "agent",
  "id": "mefisto-fx-perm-planner",
  "description": "Agente estilo planner (read+shell, mode primary), para CA-3/CA-4 (issue #862).",
  "mode": "primary",
  "capabilities": ["read", "shell"]
}
---

Cuerpo.
EOF

cat > "$SRC_DIR/mefisto-fx-perm-writer.md" <<'EOF'
---
{
  "kind": "agent",
  "id": "mefisto-fx-perm-writer",
  "description": "Agente estilo writer/historiador (read+edit+shell, mode subagent), para CA-2/CA-4 (issue #862).",
  "mode": "subagent",
  "capabilities": ["read", "edit", "shell"]
}
---

Cuerpo.
EOF

cat > "$SRC_DIR/mefisto-fx-perm-web.md" <<'EOF'
---
{
  "kind": "agent",
  "id": "mefisto-fx-perm-web",
  "description": "Agente read+shell+web, para completar la matriz de CA-6 (issue #862).",
  "mode": "subagent",
  "capabilities": ["read", "shell", "web"]
}
---

Cuerpo.
EOF

echo "[generate] los 5 agentes de prueba generan con exit 0"
OUT=$("$GENERATOR" --out "$OUT_DIR" \
    "$SRC_DIR/mefisto-fx-perm-empty.md" \
    "$SRC_DIR/mefisto-fx-perm-read.md" \
    "$SRC_DIR/mefisto-fx-perm-planner.md" \
    "$SRC_DIR/mefisto-fx-perm-writer.md" \
    "$SRC_DIR/mefisto-fx-perm-web.md" 2>&1)
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "exit 0. Salida: $OUT"
else
    fail "exit $RC (esperaba 0). Salida: $OUT"
fi

echo ""
echo "[empty] CA-1: capabilities: [] -> bash/read/edit todo deny"
assert_eq "deny" "$(eval_perm mefisto-fx-perm-empty bash 'git status')" "bash deny pese a 'git status' (sin capacidad shell)"
assert_eq "deny" "$(eval_perm mefisto-fx-perm-empty read 'README.md')" "read deny pese a ruta inocua (sin capacidad read)"
assert_eq "deny" "$(eval_perm mefisto-fx-perm-empty edit 'commands/x.md')" "edit deny pese a ruta en scope (sin capacidad edit)"
assert_eq '"deny"' "$(permission_of mefisto-fx-perm-empty external_directory)" "external_directory deny"
assert_eq '"deny"' "$(permission_of mefisto-fx-perm-empty doom_loop)" "doom_loop deny"

echo ""
echo "[read] CA-2: lectura de .env -> deny con la capacidad read"
assert_eq "deny" "$(eval_perm mefisto-fx-perm-read read '.env')" "lectura de .env deniega"
assert_eq "allow" "$(eval_perm mefisto-fx-perm-read read 'README.md')" "lectura de una ruta comun permite (catch-all)"

echo ""
echo "[edit] CA-2: src/Foo.cs deny, commands/x.md allow, resumen de stage allow"
assert_eq "deny" "$(eval_perm mefisto-fx-perm-writer edit 'src/Foo.cs')" "edicion de src/Foo.cs deniega (fuera de la allowlist interna)"
assert_eq "allow" "$(eval_perm mefisto-fx-perm-writer edit 'commands/x.md')" "edicion de commands/x.md permite"
assert_eq "allow" "$(eval_perm mefisto-fx-perm-writer edit '.mefisto/pipeline/summaries/stage-1-writer.md')" "edicion del resumen de stage (.mefisto/) permite"
assert_eq "allow" "$(eval_perm mefisto-fx-perm-writer edit '.claude/pipeline/summaries/stage-1-writer.md')" "edicion del resumen de stage (.claude/) permite"

echo ""
echo "[bash] CA-3: rm -rf x deny, git status allow, con la capacidad shell"
assert_eq "deny" "$(eval_perm mefisto-fx-perm-planner bash 'rm -rf x')" "'rm -rf x' deniega aunque shell este presente"
assert_eq "allow" "$(eval_perm mefisto-fx-perm-planner bash 'git status')" "'git status' permite"
assert_eq "deny" "$(eval_perm mefisto-fx-perm-planner bash 'git push --force origin main')" "'git push --force' deniega pese al allow general de 'git *'"
assert_eq "deny" "$(eval_perm mefisto-fx-perm-planner bash 'curl https://example.com')" "'curl' deniega (no listado)"

echo ""
echo "[question] CA-4: allow solo en mode primary"
assert_eq '"allow"' "$(permission_of mefisto-fx-perm-planner question)" "question allow en mode primary"
assert_eq '"deny"' "$(permission_of mefisto-fx-perm-writer question)" "question deny en mode subagent"

echo ""
echo "[web-skill-task] CA-4: sin la capacidad correspondiente, deny"
assert_eq '"allow"' "$(permission_of mefisto-fx-perm-web webfetch)" "webfetch allow con capacidad web"
assert_eq '"allow"' "$(permission_of mefisto-fx-perm-web websearch)" "websearch allow con capacidad web"
assert_eq '"deny"' "$(permission_of mefisto-fx-perm-planner webfetch)" "webfetch deny sin capacidad web"
assert_eq '"deny"' "$(permission_of mefisto-fx-perm-planner skill)" "skill deny sin capacidad skill"
assert_eq '"deny"' "$(permission_of mefisto-fx-perm-planner task)" "task deny sin capacidad task"
assert_eq '"allow"' "$(permission_of mefisto-fx-perm-planner todowrite)" "todowrite allow con capacidad read"
assert_eq '"allow"' "$(permission_of mefisto-fx-perm-planner lsp)" "lsp allow con capacidad read"
assert_eq '"deny"' "$(permission_of mefisto-fx-perm-empty todowrite)" "todowrite deny sin capacidad read"

echo ""
echo "[mcp-abort] CA-5: la capacidad mcp aborta sin escribir nada"
# El generador real nunca llega a probar el abort propio de OpenCode para
# `mcp`: claude_render (adapter-claude.sh) corre primero y ya aborta por esa
# misma capacidad (CA-2 del lado Claude, issue #854) antes de que
# opencode_render tenga oportunidad de correr. Por eso este caso se ejercita
# invocando la funcion del adaptador OpenCode directamente (source, sin
# generador), la unica forma de observar el mensaje "sin mapeo OpenCode" de
# CA-5 en aislamiento.
source "$REPO_ROOT/src/internal/scripts/lib/adapter-opencode.sh"
OUT=$(opencode_permission_json "fake/mefisto-fx-perm-mcp.md" '["read","mcp"]' "subagent" 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
    pass "exit != 0 ($RC)"
else
    fail "exit 0 (deberia abortar)"
fi
if printf '%s' "$OUT" | grep -qF "fake/mefisto-fx-perm-mcp.md: capacidad mcp sin mapeo OpenCode"; then
    pass "mensaje exacto de CA-5"
else
    fail "el mensaje no es el de CA-5. Salida: $OUT"
fi

echo ""
echo "[parity] CA-6: paridad edit vs is_path_in_mefisto_scope sobre 10 rutas"
if declare -F is_path_in_mefisto_scope >/dev/null 2>&1; then
    PARITY_PATHS=(
        "commands/foo.md"
        "agents/foo.md"
        "scripts/foo.sh"
        "docs/adr/MEF-ADR-0001-foo.md"
        ".claude/scripts/foo.sh"
        "src/internal/scripts/lib/foo.sh"
        "README.md"
        "changelog.d/862.added.md"
        "src/Foo.cs"
        "tests/Foo.Tests.cs"
    )
    for p in "${PARITY_PATHS[@]}"; do
        expected="deny"
        if is_path_in_mefisto_scope "$p"; then
            expected="allow"
        fi
        actual="$(eval_perm mefisto-fx-perm-writer edit "$p")"
        assert_eq "$expected" "$actual" "paridad edit vs is_path_in_mefisto_scope: $p"
    done
else
    fail "is_path_in_mefisto_scope no disponible (no se pudo source-ar _mefisto-common.sh)"
fi

echo ""
echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
