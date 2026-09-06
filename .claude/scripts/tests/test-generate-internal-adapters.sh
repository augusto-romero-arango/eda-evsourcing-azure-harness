#!/usr/bin/env bash
# test-generate-internal-adapters.sh -- Tests del generador de adaptadores
# internos (MEF-ADR-0049 CA-2/CA-3/CA-4/CA-5/CA-6, issue #854).
#
# Cubre:
#   [pre] El generador y sus libs existen, tienen sintaxis valida y el
#         generador es ejecutable.
#   [valid-fixtures] Los fixtures de fixtures/valid/ (#853) generan los 4
#         archivos (Claude/OpenCode x agente/comando) con exit 0.
#   [claude-exact]/[opencode-exact] Contenido byte-a-byte esperado para un
#         agente y un comando minimos, en ambos runtimes.
#   [directives] Las tres directivas de body ({{mefisto:launch-agent}},
#         {{mefisto:run}}, {{mefisto:command-path}}) traducidas correctamente
#         en ambos runtimes, incluida una embebida dentro de otro comando.
#   [unknown-directive] Una directiva desconocida aborta sin escribir nada.
#   [invalid-source] Un fixture invalido de #853 aborta sin escribir nada.
#   [determinism] CA-4: dos corridas consecutivas y una tercera tras tocar el
#         mtime de las fuentes producen el mismo arbol de salida (shasum).
#   [check] --check en sus cuatro estados: al dia, distinta, huerfana y sin
#         marcador (issue #913: la toleracion residual del archivo sin
#         marcador se retira -- ahora es divergencia, no un caso tolerado).
#   [escaping] id con muchos guiones y description con ':' y comillas.
#   [mcp-capability] CA-2: la capacidad `mcp` no tiene mapeo Claude definido y
#         aborta con ese motivo, sin escribir nada.
#   [no-sources] Regresion bash 3.2: sin argumentos (el modo por defecto) la
#         lista de fuentes esta vacia hoy, y expandir un array vacio bajo
#         `set -u` aborta con "unbound variable" hasta bash 4.4.
#   [check-no-write] CA-5: --check no crea ni el directorio de salida.
#
# Uso: .claude/scripts/tests/test-generate-internal-adapters.sh
# Exit code: 0 si todos los checks pasan, 1 si alguno falla.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GENERATOR="$REPO_ROOT/src/internal/scripts/generate-internal-adapters.sh"
LIB_DIR="$REPO_ROOT/src/internal/scripts/lib"
CONTRACT_DIR="$REPO_ROOT/src/internal/contract"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# assert_eq <esperado> <obtenido> <etiqueta>
assert_eq() {
    if [ "$1" = "$2" ]; then
        pass "$3"
    else
        fail "$3 -- esperado:
---
$1
---
obtenido:
---
$2
---"
    fi
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
SRC_DIR="$WORKDIR/src"
mkdir -p "$SRC_DIR"

echo "[pre] El generador y sus libs existen y tienen sintaxis valida"
for f in "$GENERATOR" "$LIB_DIR/frontmatter.sh" "$LIB_DIR/adapter-claude.sh" "$LIB_DIR/adapter-opencode.sh"; do
    if [ -f "$f" ]; then
        pass "existe: ${f#"$REPO_ROOT"/}"
    else
        fail "no existe: ${f#"$REPO_ROOT"/}"
    fi
    if bash -n "$f" 2>/dev/null; then
        pass "sintaxis bash valida: ${f#"$REPO_ROOT"/}"
    else
        fail "sintaxis bash invalida: ${f#"$REPO_ROOT"/}"
    fi
done
if [ -x "$GENERATOR" ]; then
    pass "generate-internal-adapters.sh es ejecutable"
else
    fail "generate-internal-adapters.sh no es ejecutable"
fi

# --- Fixtures propios de este test ------------------------------------------

cat > "$SRC_DIR/mefisto-fx-agent-basic.md" <<'EOF'
---
{
  "kind": "agent",
  "id": "mefisto-fx-agent-basic",
  "description": "Agente de prueba minimo para el generador de adaptadores (issue #854).",
  "mode": "subagent",
  "capabilities": ["read", "edit"],
  "skills": ["agent-skill-authoring", "comment-cleanup"]
}
---

Cuerpo de prueba.
EOF

cat > "$SRC_DIR/mefisto-fx-command-basic.md" <<'EOF'
---
{
  "kind": "command",
  "id": "mefisto-fx-command-basic",
  "description": "Comando de prueba minimo para el generador (issue #854).",
  "capabilities": ["shell"],
  "arguments": "<issue> -- numero del issue"
}
---

Procesa el issue $ARGUMENTS.
EOF

cat > "$SRC_DIR/mefisto-fx-command-directives.md" <<'EOF'
---
{
  "kind": "command",
  "id": "mefisto-fx-command-directives",
  "description": "Comando de prueba, cubre las tres directivas de body (issue #854)."
}
---

Invoca al agente:

{{mefisto:launch-agent mefisto-fx-agent-basic}}

Corre el script auxiliar:

```bash
{{mefisto:run some-script.sh --flag value}}
```

Lee el comando hermano:

```bash
cat "{{mefisto:command-path mefisto-fx-command-basic}}"
```
EOF

cat > "$SRC_DIR/mefisto-fx-unknown-directive.md" <<'EOF'
---
{
  "kind": "command",
  "id": "mefisto-fx-unknown-directive",
  "description": "Comando con una directiva de body desconocida."
}
---

{{mefisto:frobnicate foo}}
EOF

cat > "$SRC_DIR/mefisto-fx-id-with-many-hyphens-here.md" <<'EOF'
---
{
  "kind": "command",
  "id": "mefisto-fx-id-with-many-hyphens-here",
  "description": "Hace X: paso \"importante\" para el usuario."
}
---

Cuerpo.
EOF

echo ""
echo "[valid-fixtures] fixtures/valid/*.md (#853) generan los 4 archivos con exit 0"
OUT_VALID="$WORKDIR/out-valid"
OUT=$("$GENERATOR" --out "$OUT_VALID" \
    "$CONTRACT_DIR/fixtures/valid/mefisto-example-agent.md" \
    "$CONTRACT_DIR/fixtures/valid/mefisto-example-command.md" 2>&1)
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "exit 0. Salida: $OUT"
else
    fail "exit $RC (esperaba 0). Salida: $OUT"
fi
for relpath in ".claude/agents/mefisto-example-agent.md" ".claude/commands/mefisto-example-command.md" \
               ".opencode/agents/mefisto-example-agent.md" ".opencode/commands/mefisto-example-command.md"; do
    if [ -f "$OUT_VALID/$relpath" ]; then
        pass "existe: $relpath"
    else
        fail "no existe: $relpath"
    fi
done
if grep -q '^tools: "Read, Glob, Grep, Edit, Write, Bash"$' "$OUT_VALID/.claude/agents/mefisto-example-agent.md" 2>/dev/null; then
    pass "tools derivado de capabilities en el agente Claude"
else
    fail "tools no coincide en el agente Claude"
fi
if grep -q '^agent: "mefisto-example-agent"$' "$OUT_VALID/.opencode/commands/mefisto-example-command.md" 2>/dev/null; then
    pass "agent propagado al comando OpenCode desde el campo neutral 'agent'"
else
    fail "agent no se propago al comando OpenCode"
fi

echo ""
echo "[claude-exact] contenido byte-a-byte esperado del agente y comando minimos (Claude)"
OUT_BASIC="$WORKDIR/out-basic"
OUT=$("$GENERATOR" --out "$OUT_BASIC" "$SRC_DIR/mefisto-fx-agent-basic.md" "$SRC_DIR/mefisto-fx-command-basic.md" 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "generacion basica -> exit $RC. Salida: $OUT"

EXPECTED_CLAUDE_AGENT="---
name: \"mefisto-fx-agent-basic\"
description: \"Agente de prueba minimo para el generador de adaptadores (issue #854).\"
tools: \"Read, Glob, Grep, Edit, Write\"
skills: [\"agent-skill-authoring\",\"comment-cleanup\"]
---
<!-- GENERADO por src/internal/scripts/generate-internal-adapters.sh desde $SRC_DIR/mefisto-fx-agent-basic.md. No editar a mano. -->

Cuerpo de prueba."
assert_eq "$EXPECTED_CLAUDE_AGENT" "$(cat "$OUT_BASIC/.claude/agents/mefisto-fx-agent-basic.md" 2>/dev/null)" "agente Claude: contenido exacto"

# El bloque `permission` esperado se DERIVA del adaptador (con el mismo
# mapping que consume el generador) en vez de repetir aqui sus ~3 KB de JSON:
# lo que este check fija es el LAYOUT del frontmatter -- orden de los campos y
# `permission` como flow mapping de una sola linea (issue #862). El contenido
# del bloque lo cubre .claude/scripts/tests/test-opencode-permissions.sh, que
# es tambien el unico lugar donde hay que tocar tests si el mapping cambia.
source "$LIB_DIR/adapter-opencode.sh"
EXPECTED_OPENCODE_PERMISSION_BASIC="$(opencode_permission_json "$SRC_DIR/mefisto-fx-agent-basic.md" '["read","edit"]' "subagent")"
EXPECTED_OPENCODE_AGENT="---
description: \"Agente de prueba minimo para el generador de adaptadores (issue #854).\"
mode: \"subagent\"
permission: $EXPECTED_OPENCODE_PERMISSION_BASIC
---
<!-- GENERADO por src/internal/scripts/generate-internal-adapters.sh desde $SRC_DIR/mefisto-fx-agent-basic.md. No editar a mano. -->

Cuerpo de prueba."
assert_eq "$EXPECTED_OPENCODE_AGENT" "$(cat "$OUT_BASIC/.opencode/agents/mefisto-fx-agent-basic.md" 2>/dev/null)" "agente OpenCode: contenido exacto"

EXPECTED_CLAUDE_COMMAND="---
description: \"Comando de prueba minimo para el generador (issue #854).\"
argument-hint: \"<issue> -- numero del issue\"
allowed-tools: \"Bash\"
---
<!-- GENERADO por src/internal/scripts/generate-internal-adapters.sh desde $SRC_DIR/mefisto-fx-command-basic.md. No editar a mano. -->

Procesa el issue \$ARGUMENTS."
assert_eq "$EXPECTED_CLAUDE_COMMAND" "$(cat "$OUT_BASIC/.claude/commands/mefisto-fx-command-basic.md" 2>/dev/null)" "comando Claude: contenido exacto"

EXPECTED_OPENCODE_COMMAND="---
description: \"Comando de prueba minimo para el generador (issue #854).\"
---
<!-- GENERADO por src/internal/scripts/generate-internal-adapters.sh desde $SRC_DIR/mefisto-fx-command-basic.md. No editar a mano. -->

Procesa el issue \$ARGUMENTS."
assert_eq "$EXPECTED_OPENCODE_COMMAND" "$(cat "$OUT_BASIC/.opencode/commands/mefisto-fx-command-basic.md" 2>/dev/null)" "comando OpenCode: contenido exacto (sin agent/subtask)"

echo ""
echo "[directives] las tres directivas de body traducidas en ambos runtimes"
OUT_DIR="$WORKDIR/out-directives"
OUT=$("$GENERATOR" --out "$OUT_DIR" "$SRC_DIR/mefisto-fx-agent-basic.md" "$SRC_DIR/mefisto-fx-command-directives.md" 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "generacion con directivas -> exit $RC. Salida: $OUT"

EXPECTED_CLAUDE_DIRECTIVES="---
description: \"Comando de prueba, cubre las tres directivas de body (issue #854).\"
---
<!-- GENERADO por src/internal/scripts/generate-internal-adapters.sh desde $SRC_DIR/mefisto-fx-command-directives.md. No editar a mano. -->

Invoca al agente:

\`\`\`bash
claude --agent mefisto-fx-agent-basic \"\$ARGUMENTS\"
\`\`\`

Corre el script auxiliar:

\`\`\`bash
MEFISTO_RUNTIME=claude ./.claude/scripts/some-script.sh --flag value
\`\`\`

Lee el comando hermano:

\`\`\`bash
cat \".claude/commands/mefisto-fx-command-basic.md\"
\`\`\`"
assert_eq "$EXPECTED_CLAUDE_DIRECTIVES" "$(cat "$OUT_DIR/.claude/commands/mefisto-fx-command-directives.md" 2>/dev/null)" "directivas traducidas para Claude"

EXPECTED_OPENCODE_DIRECTIVES="---
description: \"Comando de prueba, cubre las tres directivas de body (issue #854).\"
agent: \"mefisto-fx-agent-basic\"
subtask: true
---
<!-- GENERADO por src/internal/scripts/generate-internal-adapters.sh desde $SRC_DIR/mefisto-fx-command-directives.md. No editar a mano. -->

Invoca al agente:

Actua como \`mefisto-fx-agent-basic\` con este mensaje inicial: \$ARGUMENTS

Corre el script auxiliar:

\`\`\`bash
MEFISTO_RUNTIME=opencode ./.claude/scripts/some-script.sh --flag value
\`\`\`

Lee el comando hermano:

\`\`\`bash
cat \".opencode/commands/mefisto-fx-command-basic.md\"
\`\`\`"
assert_eq "$EXPECTED_OPENCODE_DIRECTIVES" "$(cat "$OUT_DIR/.opencode/commands/mefisto-fx-command-directives.md" 2>/dev/null)" "directivas traducidas para OpenCode (agent inferido de launch-agent)"

echo ""
echo "[unknown-directive] una directiva desconocida aborta sin escribir nada"
OUT_UNKNOWN="$WORKDIR/out-unknown"
OUT=$("$GENERATOR" --out "$OUT_UNKNOWN" "$SRC_DIR/mefisto-fx-unknown-directive.md" 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
    pass "exit != 0 ($RC)"
else
    fail "exit 0 (deberia abortar)"
fi
if printf '%s' "$OUT" | grep -q "directiva de body desconocida"; then
    pass "mensaje cita la directiva desconocida"
else
    fail "el mensaje no cita la directiva desconocida. Salida: $OUT"
fi
if [ ! -e "$OUT_UNKNOWN/.claude" ] && [ ! -e "$OUT_UNKNOWN/.opencode" ]; then
    pass "no escribio nada (.claude/.opencode no existen)"
else
    fail "escribio algo pese al abort"
fi

echo ""
echo "[invalid-source] un fixture invalido de #853 aborta sin escribir nada"
OUT_INVALID="$WORKDIR/out-invalid"
OUT=$("$GENERATOR" --out "$OUT_INVALID" "$CONTRACT_DIR/fixtures/invalid/mismatched-id.md" 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
    pass "exit != 0 ($RC)"
else
    fail "exit 0 (deberia abortar)"
fi
if printf '%s' "$OUT" | grep -q "distinto del nombre de archivo"; then
    pass "propaga el motivo del validador (#853)"
else
    fail "no propago el motivo del validador. Salida: $OUT"
fi
if [ ! -e "$OUT_INVALID/.claude" ] && [ ! -e "$OUT_INVALID/.opencode" ]; then
    pass "no escribio nada (.claude/.opencode no existen)"
else
    fail "escribio algo pese al abort"
fi

echo ""
echo "[determinism] CA-4: dos corridas + una tercera tras tocar el mtime -> mismo shasum"
DIR_A="$WORKDIR/det-a"
DIR_B="$WORKDIR/det-b"
DIR_C="$WORKDIR/det-c"
"$GENERATOR" --out "$DIR_A" "$SRC_DIR/mefisto-fx-agent-basic.md" "$SRC_DIR/mefisto-fx-command-directives.md" >/dev/null 2>&1
"$GENERATOR" --out "$DIR_B" "$SRC_DIR/mefisto-fx-agent-basic.md" "$SRC_DIR/mefisto-fx-command-directives.md" >/dev/null 2>&1
touch "$SRC_DIR/mefisto-fx-agent-basic.md" "$SRC_DIR/mefisto-fx-command-directives.md"
"$GENERATOR" --out "$DIR_C" "$SRC_DIR/mefisto-fx-agent-basic.md" "$SRC_DIR/mefisto-fx-command-directives.md" >/dev/null 2>&1
SUM_A="$(find "$DIR_A" -type f | sort | xargs shasum | awk '{print $1}' | shasum)"
SUM_B="$(find "$DIR_B" -type f | sort | xargs shasum | awk '{print $1}' | shasum)"
SUM_C="$(find "$DIR_C" -type f | sort | xargs shasum | awk '{print $1}' | shasum)"
assert_eq "$SUM_A" "$SUM_B" "dos corridas consecutivas producen el mismo arbol"
assert_eq "$SUM_B" "$SUM_C" "una tercera corrida tras tocar el mtime de las fuentes produce el mismo arbol"

echo ""
echo "[check] --check en sus tres estados"
CHECK_DIR="$WORKDIR/check-dir"
"$GENERATOR" --out "$CHECK_DIR" "$SRC_DIR/mefisto-fx-agent-basic.md" "$SRC_DIR/mefisto-fx-command-basic.md" >/dev/null 2>&1

OUT=$("$GENERATOR" --check --out "$CHECK_DIR" "$SRC_DIR/mefisto-fx-agent-basic.md" "$SRC_DIR/mefisto-fx-command-basic.md" 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    pass "al dia -> exit 0 sin divergencias"
else
    fail "al dia -> exit $RC (esperaba 0), salida: '$OUT'"
fi

printf '%s\n' "corrupcion manual" >> "$CHECK_DIR/.claude/agents/mefisto-fx-agent-basic.md"
OUT=$("$GENERATOR" --check --out "$CHECK_DIR" "$SRC_DIR/mefisto-fx-agent-basic.md" "$SRC_DIR/mefisto-fx-command-basic.md" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF ".claude/agents/mefisto-fx-agent-basic.md: distinta"; then
    pass "distinta -> exit != 0 con la linea esperada"
else
    fail "distinta -> no reporto la divergencia esperada. exit=$RC salida: $OUT"
fi
# Deshace la corrupcion para no interferir con el chequeo de huerfanos.
"$GENERATOR" --out "$CHECK_DIR" "$SRC_DIR/mefisto-fx-agent-basic.md" "$SRC_DIR/mefisto-fx-command-basic.md" >/dev/null 2>&1

mkdir -p "$CHECK_DIR/.claude/commands"
{
    echo '---'
    echo 'description: "huerfano de prueba"'
    echo '---'
    echo '<!-- GENERADO por src/internal/scripts/generate-internal-adapters.sh desde fake/source.md. No editar a mano. -->'
    echo 'contenido huerfano'
} > "$CHECK_DIR/.claude/commands/mefisto-fx-orphan.md"
echo 'archivo de autoria manual, sin marcador' > "$CHECK_DIR/.claude/commands/mefisto-manual.md"

OUT=$("$GENERATOR" --check --out "$CHECK_DIR" "$SRC_DIR/mefisto-fx-agent-basic.md" "$SRC_DIR/mefisto-fx-command-basic.md" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF ".claude/commands/mefisto-fx-orphan.md: huerfana"; then
    pass "huerfana -> exit != 0 con la linea esperada"
else
    fail "huerfana -> no reporto la divergencia esperada. exit=$RC salida: $OUT"
fi
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF ".claude/commands/mefisto-manual.md: sin marcador"; then
    pass "sin marcador -> exit != 0 con la linea esperada (issue #913, ya no se tolera)"
else
    fail "sin marcador -> no reporto la divergencia esperada. exit=$RC salida: $OUT"
fi

echo ""
echo "[escaping] id con muchos guiones y description con ':' y comillas"
OUT_ESC="$WORKDIR/out-escaping"
OUT=$("$GENERATOR" --out "$OUT_ESC" "$SRC_DIR/mefisto-fx-id-with-many-hyphens-here.md" 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "generacion con id/description especiales -> exit $RC. Salida: $OUT"
if [ -f "$OUT_ESC/.claude/commands/mefisto-fx-id-with-many-hyphens-here.md" ]; then
    pass "el id con guiones produce el nombre de archivo esperado"
else
    fail "no se genero el archivo con el id de guiones esperado"
fi
if grep -qF 'description: "Hace X: paso \"importante\" para el usuario."' "$OUT_ESC/.claude/commands/mefisto-fx-id-with-many-hyphens-here.md" 2>/dev/null; then
    pass "description con ':' y comillas escapado correctamente (Claude)"
else
    fail "description mal escapado (Claude). Contenido:
$(cat "$OUT_ESC/.claude/commands/mefisto-fx-id-with-many-hyphens-here.md" 2>/dev/null)"
fi
if grep -qF 'description: "Hace X: paso \"importante\" para el usuario."' "$OUT_ESC/.opencode/commands/mefisto-fx-id-with-many-hyphens-here.md" 2>/dev/null; then
    pass "description con ':' y comillas escapado correctamente (OpenCode)"
else
    fail "description mal escapado (OpenCode)"
fi

echo ""
echo "[mcp-capability] CA-2: la capacidad mcp aborta sin mapeo Claude definido"
cat > "$SRC_DIR/mefisto-fx-mcp-capability.md" <<'EOF'
---
{
  "kind": "agent",
  "id": "mefisto-fx-mcp-capability",
  "description": "Agente que declara la capacidad mcp, sin mapeo Claude (issue #854).",
  "mode": "subagent",
  "capabilities": ["read", "mcp"]
}
---

Cuerpo.
EOF
OUT_MCP="$WORKDIR/out-mcp"
OUT=$("$GENERATOR" --out "$OUT_MCP" "$SRC_DIR/mefisto-fx-mcp-capability.md" 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
    pass "exit != 0 ($RC)"
else
    fail "exit 0 (deberia abortar)"
fi
if printf '%s' "$OUT" | grep -qF "capacidad mcp sin mapeo Claude definido"; then
    pass "mensaje exacto de CA-2"
else
    fail "el mensaje no es el de CA-2. Salida: $OUT"
fi
if [ ! -e "$OUT_MCP/.claude" ] && [ ! -e "$OUT_MCP/.opencode" ]; then
    pass "no escribio nada (.claude/.opencode no existen)"
else
    fail "escribio algo pese al abort"
fi

echo ""
echo "[no-sources] sin argumentos, con la fuente neutral vacia, no revienta en bash 3.2"
# `for x in "${a[@]}"` con `a` vacio es un "unbound variable" bajo `set -u` en
# bash 3.2 (macOS). Desde #865-#867 src/internal/{agents,commands} ya esta
# poblado, asi que este bloque ejerce el modo por defecto sobre la fuente real:
# lo que fija es que el scan por defecto no revienta, poblado o vacio.
OUT=$("$GENERATOR" --out "$WORKDIR/out-nosources" 2>&1)
RC=$?
if printf '%s' "$OUT" | grep -q "unbound variable"; then
    fail "aborto con 'unbound variable' (bash 3.2, array vacio bajo set -u). Salida: $OUT"
else
    pass "sin 'unbound variable' en la generacion por defecto (exit $RC)"
fi
OUT=$("$GENERATOR" --check --out "$WORKDIR/out-nosources" 2>&1)
RC=$?
if printf '%s' "$OUT" | grep -q "unbound variable"; then
    fail "--check aborto con 'unbound variable'. Salida: $OUT"
else
    pass "sin 'unbound variable' en --check por defecto (exit $RC)"
fi

echo ""
echo "[check-no-write] CA-5: --check no crea ni el directorio de salida"
NEVER_DIR="$WORKDIR/never-created"
OUT=$("$GENERATOR" --check --out "$NEVER_DIR" "$SRC_DIR/mefisto-fx-agent-basic.md" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF ".claude/agents/mefisto-fx-agent-basic.md: faltante"; then
    pass "reporta 'faltante' con exit != 0"
else
    fail "no reporto 'faltante'. exit=$RC salida: $OUT"
fi
if [ ! -e "$NEVER_DIR" ]; then
    pass "no creo el directorio de salida"
else
    fail "creo '$NEVER_DIR' pese a --check (CA-5: no escribe nada)"
fi

echo ""
echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
