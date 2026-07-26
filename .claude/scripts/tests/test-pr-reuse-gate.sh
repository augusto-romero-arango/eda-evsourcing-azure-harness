#!/usr/bin/env bash
# test-pr-reuse-gate.sh -- Tests del helper de deteccion de PR existente (issue #378).
#
# Valida find_open_pr_for_branch en _mefisto-common.sh (gemela en scripts/_pipeline-common.sh
# del lado publicado, misma implementacion): antes de `gh pr create`, el bloque "Creando PR" de
# cada pipeline consulta si ya existe un PR abierto para la rama y lo reutiliza en vez de
# abortar (incidente del batch mefisto-batch-125628: un agente hizo push y creo el PR el
# mismo, y `gh pr create` del pipeline abortaba con "a pull request ... already exists").
#
# Casos cubiertos (CA-6):
#   - PR abierto existente -> devuelve la URL
#   - Sin PR abierto       -> devuelve vacio sin fallar
#   - gh falla (error)     -> degrada a vacio sin abortar el pipeline por el chequeo
#   - gh no disponible     -> degrada a vacio sin abortar el pipeline por el chequeo
#   - rama vacia           -> vacio sin fallar (guard defensivo)
#   - gh emite "null"      -> se normaliza a vacio (`.[0].url` sobre `[]` es null en jq)
#   - filtro por base      -> '--base main' por defecto; base explicita se propaga
#   - paridad de gemelas   -> el cuerpo de la funcion es identico en ambos paquetes
#
# Uso: .claude/scripts/tests/test-pr-reuse-gate.sh
# Exit code: 0 si todos los chequeos pasan, 1 si alguno falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# shellcheck source=/dev/null
source "$REPO_ROOT/.claude/scripts/_mefisto-common.sh" 2>/dev/null

echo "[pre] find_open_pr_for_branch esta definida"
if declare -F find_open_pr_for_branch >/dev/null; then
    pass "find_open_pr_for_branch definida en _mefisto-common.sh"
else
    fail "find_open_pr_for_branch NO definida"
fi

FAKE_BIN=$(mktemp -d)
cleanup() { rm -rf "$FAKE_BIN"; }
trap cleanup EXIT

# --- Caso: PR abierto existente -> devuelve la URL ---
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    echo "https://github.com/owner/repo/pull/42"
    exit 0
fi
exit 1
EOF
chmod +x "$FAKE_BIN/gh"

RESULT=$(PATH="$FAKE_BIN:$PATH" find_open_pr_for_branch "worktree-issue-1-x")
RC=$?
if [ "$RESULT" = "https://github.com/owner/repo/pull/42" ] && [ "$RC" -eq 0 ]; then
    pass "PR existente: devuelve la URL correctamente"
else
    fail "PR existente: se esperaba la URL, se obtuvo '$RESULT' (rc=$RC)"
fi

# --- Caso: sin PR abierto -> vacio sin fallar ---
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    exit 0
fi
exit 1
EOF
chmod +x "$FAKE_BIN/gh"

RESULT=$(PATH="$FAKE_BIN:$PATH" find_open_pr_for_branch "worktree-issue-2-y")
RC=$?
if [ -z "$RESULT" ] && [ "$RC" -eq 0 ]; then
    pass "Sin PR: devuelve vacio sin fallar"
else
    fail "Sin PR: se esperaba vacio y exit 0, se obtuvo '$RESULT' (rc=$RC)"
fi

# --- Caso: gh falla (error real, p. ej. auth/red) -> degrada a vacio sin abortar ---
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "error: not authenticated" >&2
exit 1
EOF
chmod +x "$FAKE_BIN/gh"

RESULT=$(PATH="$FAKE_BIN:$PATH" find_open_pr_for_branch "worktree-issue-3-z")
RC=$?
if [ -z "$RESULT" ] && [ "$RC" -eq 0 ]; then
    pass "gh falla: degrada a vacio sin abortar"
else
    fail "gh falla: se esperaba vacio y exit 0, se obtuvo '$RESULT' (rc=$RC)"
fi

# --- Caso: gh no disponible -> degrada a vacio sin abortar ---
EMPTY_BIN=$(mktemp -d)
RESULT=$(PATH="$EMPTY_BIN" find_open_pr_for_branch "worktree-issue-4-w" 2>/dev/null)
RC=$?
rm -rf "$EMPTY_BIN"
if [ -z "$RESULT" ] && [ "$RC" -eq 0 ]; then
    pass "gh no disponible: degrada a vacio sin abortar"
else
    fail "gh no disponible: se esperaba vacio y exit 0, se obtuvo '$RESULT' (rc=$RC)"
fi

# --- Caso: rama vacia -> vacio sin fallar (guard defensivo, no llega a invocar gh) ---
RESULT=$(find_open_pr_for_branch "")
RC=$?
if [ -z "$RESULT" ] && [ "$RC" -eq 0 ]; then
    pass "Rama vacia: devuelve vacio sin fallar"
else
    fail "Rama vacia: se esperaba vacio y exit 0, se obtuvo '$RESULT' (rc=$RC)"
fi

# --- Caso: repo_slug opcional se propaga a --repo ---
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    for arg in "$@"; do
        if [ "$arg" = "owner/repo" ]; then
            echo "https://github.com/owner/repo/pull/7"
            exit 0
        fi
    done
    echo "ERROR: --repo owner/repo no fue pasado a gh pr list: $*" >&2
    exit 1
fi
exit 1
EOF
chmod +x "$FAKE_BIN/gh"

RESULT=$(PATH="$FAKE_BIN:$PATH" find_open_pr_for_branch "worktree-issue-5-v" "owner/repo")
RC=$?
if [ "$RESULT" = "https://github.com/owner/repo/pull/7" ] && [ "$RC" -eq 0 ]; then
    pass "repo_slug opcional: se propaga como --repo a gh pr list"
else
    fail "repo_slug opcional: se esperaba la URL con --repo propagado, se obtuvo '$RESULT' (rc=$RC)"
fi

# --- Caso: gh emite el literal "null" -> se normaliza a vacio ---
# `.[0].url` sobre una lista vacia es `null` en jq. gh 2.92 lo imprime como cadena vacia, pero el
# helper no debe depender de ese detalle: un "null" con fuga haria que el pipeline "reutilizara" un
# PR inexistente y reportara la URL literal "null" en el issue y en pipeline-history.jsonl.
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    echo "null"
    exit 0
fi
exit 1
EOF
chmod +x "$FAKE_BIN/gh"

RESULT=$(PATH="$FAKE_BIN:$PATH" find_open_pr_for_branch "worktree-issue-6-u")
RC=$?
if [ -z "$RESULT" ] && [ "$RC" -eq 0 ]; then
    pass "gh emite 'null': se normaliza a vacio (no se reutiliza un PR inexistente)"
else
    fail "gh emite 'null': se esperaba vacio, se obtuvo '$RESULT' (rc=$RC)"
fi

# --- Caso: filtro por rama base ---
# La unicidad de GitHub es por par (head, base) -- el error que este gate esquiva dice
# literalmente 'into branch "main"'. Sin --base, un PR de la misma rama hacia otra base se
# devolveria como si fuera el del pipeline y el `gh pr create --base main` valido nunca correria.
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    base=""
    prev=""
    for arg in "$@"; do
        [ "$prev" = "--base" ] && base="$arg"
        prev="$arg"
    done
    if [ -z "$base" ]; then
        echo "ERROR: --base no fue pasado a gh pr list: $*" >&2
        exit 1
    fi
    echo "https://github.com/owner/repo/pull/base-${base}"
    exit 0
fi
exit 1
EOF
chmod +x "$FAKE_BIN/gh"

RESULT=$(PATH="$FAKE_BIN:$PATH" find_open_pr_for_branch "worktree-issue-7-t")
RC=$?
if [ "$RESULT" = "https://github.com/owner/repo/pull/base-main" ] && [ "$RC" -eq 0 ]; then
    pass "base por defecto: se filtra por '--base main'"
else
    fail "base por defecto: se esperaba base-main, se obtuvo '$RESULT' (rc=$RC)"
fi

RESULT=$(PATH="$FAKE_BIN:$PATH" find_open_pr_for_branch "worktree-issue-8-s" "" "develop")
RC=$?
if [ "$RESULT" = "https://github.com/owner/repo/pull/base-develop" ] && [ "$RC" -eq 0 ]; then
    pass "base explicita: el tercer argumento se propaga como --base"
else
    fail "base explicita: se esperaba base-develop, se obtuvo '$RESULT' (rc=$RC)"
fi

# --- Caso: paridad de las gemelas publicada/interna (MEF-ADR-0019) ---
# El helper vive duplicado a proposito: los paquetes publicado e interno no cruzan dependencias.
# Ese duplicado solo es seguro si no deriva, y nada mas en el repo lo verifica -- si alguien
# corrige un bug en una copia y olvida la otra, los consumidores del plugin se quedan con el bug.
extract_helper_body() {
    awk '/^find_open_pr_for_branch\(\) \{/,/^\}/' "$1"
}
INTERNAL_BODY=$(extract_helper_body "$REPO_ROOT/.claude/scripts/_mefisto-common.sh")
PUBLISHED_BODY=$(extract_helper_body "$REPO_ROOT/scripts/_pipeline-common.sh")

if [ -z "$INTERNAL_BODY" ] || [ -z "$PUBLISHED_BODY" ]; then
    fail "paridad de gemelas: no se pudo extraer el cuerpo de find_open_pr_for_branch de ambas copias"
elif [ "$INTERNAL_BODY" = "$PUBLISHED_BODY" ]; then
    pass "paridad de gemelas: el cuerpo es identico en _mefisto-common.sh y _pipeline-common.sh"
else
    fail "paridad de gemelas: las copias interna y publicada del helper DERIVARON"
    diff <(echo "$INTERNAL_BODY") <(echo "$PUBLISHED_BODY") || true
fi

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
