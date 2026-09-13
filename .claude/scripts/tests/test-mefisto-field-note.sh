#!/usr/bin/env bash
# test-mefisto-field-note.sh -- Tests del pipeline de entrega aislada de field
# notes (issue #1295).
#
# Cubre:
#   [pre] mefisto-field-note.sh vive en src/internal/scripts/ con sintaxis
#         bash valida; su shim en .claude/scripts/ sigue la plantilla exacta
#         de exec de 3 lineas (R4) y reenvia de verdad; el gate de
#         neutralidad (mefisto-neutrality-gate.sh) sale 0 sobre el repo real.
#   [A]   Validacion de argumentos (CA-1): --agent/--session-id con '/', '..'
#         o espacios, --timestamp mal formado y argumentos faltantes abortan
#         (exit != 0) SIN tocar git -- ni worktree ni rama se crean.
#   [B]   Guard de regresion estatico (CA-4): el script canonico nunca invoca
#         'git switch'/'git add'/'git commit' contra MEFISTO_REPO_ROOT.
#   [C]   Primera entrega end-to-end (CA-2/CA-3/CA-4) sobre un repo Git
#         temporal con checkout principal SUCIO, un remote BARE real y un
#         'gh' controlado: se confirma la llamada real a 'gh pr create' (el
#         defecto original -- @tsv emitiendo tabuladores para el PR nulo, que
#         '[ -n "$PR_DATA" ]' tomaba como PR existente -- queda corregido),
#         unico path entregado (docs/bitacora/field-notes/...), checkout
#         principal sin cambios (ref/sha/status identicos, incluido el
#         archivo sucio preexistente) y worktree temporal limpiado.
#
# Uso: .claude/scripts/tests/test-mefisto-field-note.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

CANON="$REPO_ROOT/src/internal/scripts/mefisto-field-note.sh"
SHIM="$REPO_ROOT/.claude/scripts/mefisto-field-note.sh"
CANON_LIB="$REPO_ROOT/src/internal/scripts/lib/_mefisto-common.sh"
CANON_STATE_LIB="$REPO_ROOT/src/internal/scripts/lib/mefisto-state.sh"
CANON_RUNTIME="$REPO_ROOT/src/runtime"
GATE="$REPO_ROOT/src/internal/scripts/mefisto-neutrality-gate.sh"

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# -------- Bloque pre: presencia, sintaxis, shim conforme, gate real --------

echo "[pre] mefisto-field-note.sh y su shim existen, con sintaxis valida"
for f in "$CANON" "$SHIM"; do
    if [ -f "$f" ]; then
        pass "$(basename "$f") ($f): presente"
    else
        fail "$f: ausente"
    fi
    if bash -n "$f" 2>/dev/null; then
        pass "$(basename "$f") ($f): sintaxis bash valida"
    else
        fail "$(basename "$f") ($f): sintaxis bash invalida"
    fi
done

if [ -x "$CANON" ] && [ -x "$SHIM" ]; then
    pass "canonico y shim tienen bit de ejecucion"
else
    fail "canonico o shim sin bit de ejecucion"
fi

EXPECTED_SHIM='#!/usr/bin/env bash
# Shim de compatibilidad (MEF-ADR-0049): la implementacion canonica vive en src/internal/scripts/. No editar.
exec "$(cd "$(dirname "$0")/../.." && pwd)/src/internal/scripts/$(basename "$0")" "$@"'

if printf '%s\n' "$EXPECTED_SHIM" | cmp -s - "$SHIM"; then
    pass "shim: byte a byte igual a la plantilla R4 de src/internal/scripts/README.md"
else
    fail "shim: no coincide byte a byte con la plantilla R4"
fi

# El shim reenvia de verdad: se invoca sin argumentos (camino inocuo -- solo
# imprime 'usage' y sale con error, sin tocar disco ni red) y se compara el
# exit code observado entre shim y canonico.
( cd "$REPO_ROOT" && "$SHIM" ) </dev/null >/dev/null 2>&1; SHIM_RC=$?
( cd "$REPO_ROOT" && "$CANON" ) </dev/null >/dev/null 2>&1; CANON_RC=$?
if [ "$SHIM_RC" -ne 0 ] && [ "$SHIM_RC" -eq "$CANON_RC" ]; then
    pass "shim: reenvia al canonico (ambos exit $SHIM_RC sin argumentos obligatorios)"
else
    fail "shim: shim exit $SHIM_RC, canonico exit $CANON_RC (se esperaba el mismo exit != 0 en ambos)"
fi

echo ""
echo "[pre] mefisto-neutrality-gate.sh sale 0 sobre el repo real"
if GATE_OUT=$(bash "$GATE" 2>&1); then
    pass "mefisto-neutrality-gate.sh: exit 0"
else
    fail "mefisto-neutrality-gate.sh: exit != 0 -- $GATE_OUT"
fi

# -------- Bloque A: validacion de argumentos, sin tocar git (CA-1) --------

echo ""
echo "[A] Validacion de argumentos (CA-1): abortan SIN tocar git"

ARGTEST_DIR="$TMP/argtest"
mkdir -p "$ARGTEST_DIR"

run_argtest() {
    # cwd SIN repo git: si la validacion tocara git antes de rechazar el
    # valor, fallaria de otra forma (p. ej. "no estas en un repositorio git")
    # en vez del mensaje de validacion esperado.
    ( cd "$ARGTEST_DIR" && printf 'contenido\n' | "$CANON" "$@" ) >"$TMP/argtest.out" 2>"$TMP/argtest.err"
    ARGTEST_RC=$?
}

run_argtest
if [ "$ARGTEST_RC" -ne 0 ] && grep -qF "son obligatorios" "$TMP/argtest.err"; then
    pass "sin argumentos: aborta (rc=$ARGTEST_RC) pidiendo los tres obligatorios"
else
    fail "sin argumentos: se esperaba abort pidiendo los obligatorios, rc=$ARGTEST_RC, stderr=$(cat "$TMP/argtest.err")"
fi

run_argtest --agent "../evil" --timestamp "2026-09-13-1530" --session-id "abc123"
if [ "$ARGTEST_RC" -ne 0 ] && grep -qF "invalido" "$TMP/argtest.err"; then
    pass "--agent con '..': aborta (rc=$ARGTEST_RC) sin tocar git"
else
    fail "--agent con '..': se esperaba abort, rc=$ARGTEST_RC, stderr=$(cat "$TMP/argtest.err")"
fi

run_argtest --agent "a/b" --timestamp "2026-09-13-1530" --session-id "abc123"
if [ "$ARGTEST_RC" -ne 0 ]; then
    pass "--agent con '/': aborta (rc=$ARGTEST_RC)"
else
    fail "--agent con '/': deberia abortar, rc=$ARGTEST_RC"
fi

run_argtest --agent "mefisto-planner" --timestamp "2026-09-13-1530" --session-id "sesion con espacios"
if [ "$ARGTEST_RC" -ne 0 ]; then
    pass "--session-id con espacios: aborta (rc=$ARGTEST_RC)"
else
    fail "--session-id con espacios: deberia abortar, rc=$ARGTEST_RC"
fi

run_argtest --agent "-mefisto-planner" --timestamp "2026-09-13-1530" --session-id "abc123"
if [ "$ARGTEST_RC" -ne 0 ]; then
    pass "--agent que empieza con '-': aborta (rc=$ARGTEST_RC)"
else
    fail "--agent que empieza con '-': deberia abortar, rc=$ARGTEST_RC"
fi

run_argtest --agent "mefisto-planner" --timestamp "13-09-2026" --session-id "abc123"
if [ "$ARGTEST_RC" -ne 0 ] && grep -qF "YYYY-MM-DD-HHMM" "$TMP/argtest.err"; then
    pass "--timestamp mal formado: aborta (rc=$ARGTEST_RC) indicando el formato esperado"
else
    fail "--timestamp mal formado: se esperaba abort, rc=$ARGTEST_RC, stderr=$(cat "$TMP/argtest.err")"
fi

if [ -z "$(find "$ARGTEST_DIR" -mindepth 1 2>/dev/null)" ]; then
    pass "ningun caso de validacion toco el sistema de archivos (directorio de prueba sigue vacio)"
else
    fail "algun caso de validacion escribio en el directorio de prueba: $(find "$ARGTEST_DIR" -mindepth 1)"
fi

# -------- Bloque B: guard de regresion estatico (CA-4) --------

echo ""
echo "[B] Guard de regresion (CA-4): el canonico nunca muta el checkout principal"

for needle in 'MEFISTO_REPO_ROOT" switch' 'MEFISTO_REPO_ROOT" add' 'MEFISTO_REPO_ROOT" commit'; do
    hits=$(grep -c "$needle" "$CANON" || true)
    if [ "$hits" -eq 0 ]; then
        pass "cero ocurrencias de '$needle' en mefisto-field-note.sh"
    else
        fail "$hits ocurrencia(s) de '$needle' en mefisto-field-note.sh"
        grep -n "$needle" "$CANON"
    fi
done

# -------- Bloque C: primera entrega end-to-end (CA-2/CA-3/CA-4) --------

echo ""
echo "[C] Primera entrega end-to-end: checkout sucio + remote bare + gh controlado"

MAIN_DIR="$TMP/main-checkout"
BARE_DIR="$TMP/origin.git"
mkdir -p "$MAIN_DIR"
git init -q "$MAIN_DIR"
git -C "$MAIN_DIR" symbolic-ref HEAD refs/heads/main
git -C "$MAIN_DIR" config user.email "test@mefisto.local"
git -C "$MAIN_DIR" config user.name "Mefisto Test"

mkdir -p "$MAIN_DIR/.claude-plugin" "$MAIN_DIR/src/internal/scripts/lib"
cat > "$MAIN_DIR/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "mefisto",
  "version": "0.0.0"
}
EOF
cp "$CANON_LIB" "$MAIN_DIR/src/internal/scripts/lib/_mefisto-common.sh"
cp "$CANON_STATE_LIB" "$MAIN_DIR/src/internal/scripts/lib/mefisto-state.sh"
cp -R "$CANON_RUNTIME" "$MAIN_DIR/src/runtime"
cp "$CANON" "$MAIN_DIR/src/internal/scripts/mefisto-field-note.sh"
chmod +x "$MAIN_DIR/src/internal/scripts/mefisto-field-note.sh"

git -C "$MAIN_DIR" add .
git -C "$MAIN_DIR" commit -q -m "base"

git init -q --bare "$BARE_DIR"
git -C "$MAIN_DIR" remote add origin "$BARE_DIR"
git -C "$MAIN_DIR" push -q origin main

# Checkout principal SUCIO: un cambio sin commitear que debe sobrevivir intacto.
echo "trabajo en progreso" >> "$MAIN_DIR/README-local.md"
DIRTY_STATUS_BEFORE=$(git -C "$MAIN_DIR" status --porcelain=v1 --untracked-files=all)
DIRTY_CONTENT_BEFORE=$(cat "$MAIN_DIR/README-local.md")
REF_BEFORE=$(git -C "$MAIN_DIR" symbolic-ref -q --short HEAD)
SHA_BEFORE=$(git -C "$MAIN_DIR" rev-parse HEAD)

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
GH_CALL_LOG="$TMP/gh-calls.log"
: > "$GH_CALL_LOG"
cat > "$FAKE_BIN/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GH_CALL_LOG"
if [ "\$1" = "repo" ] && [ "\$2" = "view" ]; then
    if printf '%s\n' "\$@" | grep -q "nameWithOwner"; then
        echo "acme/mefisto-fake"
        exit 0
    fi
    if printf '%s\n' "\$@" | grep -q "defaultBranchRef"; then
        echo "main"
        exit 0
    fi
    exit 1
fi
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
    exit 0
fi
if [ "\$1" = "pr" ] && [ "\$2" = "create" ]; then
    echo "https://github.com/acme/mefisto-fake/pull/123"
    exit 0
fi
exit 1
EOF
chmod +x "$FAKE_BIN/gh"

# PATH restringido a proposito (mismo motivo que test-batch-runtime.sh): solo
# el sistema base detras del stub de gh, para que git/jq reales resuelvan sin
# que ningun gh real instalado en esta maquina interfiera.
SAFE_SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

AGENT="mefisto-planner"
TIMESTAMP="2026-09-13-1530"
SESSION_ID="2026-09-13-1530-07-abc123def456-99999"
FIELD_NOTE_CONTENT_C='---
fecha: 2026-09-13
tema: prueba
---

## Contexto
Prueba de entrega aislada.'

OUT="$TMP/c-stdout"
ERR="$TMP/c-stderr"
(
    cd "$MAIN_DIR" && \
    printf '%s\n' "$FIELD_NOTE_CONTENT_C" | \
    env -u MEFISTO_STATE_DIR -u MEFISTO_LEGACY_STATE_DIR -u MEFISTO_REPO_ROOT \
        -u MEFISTO_PROJECT_NAME -u MEFISTO_REPO_SLUG \
        PATH="$FAKE_BIN:$SAFE_SYSTEM_PATH" \
        ./src/internal/scripts/mefisto-field-note.sh \
            --agent "$AGENT" --timestamp "$TIMESTAMP" --session-id "$SESSION_ID"
) >"$OUT" 2>"$ERR"
C_RC=$?

if [ "$C_RC" -eq 0 ]; then
    pass "primera entrega: exit 0"
else
    fail "primera entrega: exit $C_RC. stdout=$(cat "$OUT") stderr=$(cat "$ERR")"
fi

if grep -qE '^pr create ' "$GH_CALL_LOG"; then
    pass "CA-3: 'gh pr create' SI se ejecuto (defecto de @tsv/tabuladores corregido)"
else
    fail "CA-3: 'gh pr create' nunca se ejecuto. Llamadas a gh: $(cat "$GH_CALL_LOG")"
fi

DOC_BRANCH="docs/${AGENT}-field-note-${SESSION_ID}"
FIELD_NOTE_REL="docs/bitacora/field-notes/${TIMESTAMP}-${AGENT}.md"

if git --git-dir="$BARE_DIR" show-ref --verify --quiet "refs/heads/$DOC_BRANCH"; then
    pass "CA-3: la rama '$DOC_BRANCH' fue empujada al remote bare"
else
    fail "CA-3: la rama '$DOC_BRANCH' NO existe en el remote bare"
fi

CHANGED_PATHS=$(git --git-dir="$BARE_DIR" diff --name-only main "$DOC_BRANCH" 2>/dev/null)
if [ "$CHANGED_PATHS" = "$FIELD_NOTE_REL" ]; then
    pass "CA-2: unico path entregado: '$FIELD_NOTE_REL'"
else
    fail "CA-2: se esperaba solo '$FIELD_NOTE_REL', se obtuvo: $CHANGED_PATHS"
fi

if git --git-dir="$BARE_DIR" cat-file -e "$DOC_BRANCH:$FIELD_NOTE_REL" 2>/dev/null; then
    pass "CA-2: la field note existe en el commit empujado al remote bare"
else
    fail "CA-2: la field note no existe en '$DOC_BRANCH:$FIELD_NOTE_REL' del remote bare"
fi

REF_AFTER=$(git -C "$MAIN_DIR" symbolic-ref -q --short HEAD)
SHA_AFTER=$(git -C "$MAIN_DIR" rev-parse HEAD)
STATUS_AFTER=$(git -C "$MAIN_DIR" status --porcelain=v1 --untracked-files=all)
CONTENT_AFTER=$(cat "$MAIN_DIR/README-local.md")

if [ "$REF_AFTER" = "$REF_BEFORE" ] && [ "$SHA_AFTER" = "$SHA_BEFORE" ] && [ "$STATUS_AFTER" = "$DIRTY_STATUS_BEFORE" ]; then
    pass "CA-4: el checkout principal quedo identico (ref/sha/status) al medido antes de la entrega"
else
    fail "CA-4: el checkout principal cambio. ref: '$REF_BEFORE'->'$REF_AFTER', sha: '$SHA_BEFORE'->'$SHA_AFTER', status: '$DIRTY_STATUS_BEFORE' -> '$STATUS_AFTER'"
fi

if [ "$CONTENT_AFTER" = "$DIRTY_CONTENT_BEFORE" ]; then
    pass "CA-4: el archivo sucio preexistente conserva su contenido"
else
    fail "CA-4: el archivo sucio preexistente cambio de contenido"
fi

WORKTREE_LIST_AFTER=$(git -C "$MAIN_DIR" worktree list)
if ! printf '%s\n' "$WORKTREE_LIST_AFTER" | grep -q "field-note-"; then
    pass "CA-4: el worktree temporal fue limpiado"
else
    fail "CA-4: quedo un worktree temporal registrado: $WORKTREE_LIST_AFTER"
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
