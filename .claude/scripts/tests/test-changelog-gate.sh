#!/usr/bin/env bash
# test-changelog-gate.sh -- Tests del gate de CHANGELOG [Unreleased] (issue #70).
#
# Valida las funciones de _mefisto-common.sh que sostienen el gate cinturon +
# tirantes del pipeline interno mefisto-tooling:
#
#   [A] is_path_changelog_exempt clasifica rutas exentas vs notables (CA-1/CA-2).
#   [B] changes_require_changelog y la decision compuesta del gate sobre diffs
#       simulados en un repo git temporal:
#         - diff NOTABLE sin entrada  -> el gate ABORTA      (CA-4)
#         - diff EXENTO sin entrada   -> el gate PASA         (CA-5)
#         - diff NOTABLE con entrada  -> el gate PASA         (CA-6)
#
# La decision compuesta (gate_would_abort) replica EXACTAMENTE la del pipeline
# (.claude/scripts/mefisto-tooling-pipeline.sh, bloque "Verificando CHANGELOG").
#
# Uso: .claude/scripts/tests/test-changelog-gate.sh
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

# gate_would_abort <wt> <base>
# Replica la decision del gate del pipeline: aborta solo si el cambio es notable
# Y la seccion [Unreleased] no recibio contenido. Retorna 0 si abortaria, 1 si no.
gate_would_abort() {
    local wt="$1" base="$2"
    if check_unreleased_touched "$wt" "$base"; then return 1; fi          # tocada -> no aborta
    if ! changes_require_changelog "$wt" "$base"; then return 1; fi       # exento -> no aborta
    return 0                                                               # notable y sin entrada -> aborta
}

# -------- Bloque pre: funciones existen (CA-1) --------

echo "[pre] Las funciones del gate estan definidas (CA-1)"
for fn in is_path_changelog_exempt changes_require_changelog check_unreleased_touched; do
    if declare -F "$fn" >/dev/null; then
        pass "$fn definida en _mefisto-common.sh"
    else
        fail "$fn NO definida"
    fi
done

# -------- Bloque A: is_path_changelog_exempt (CA-2) --------

echo ""
echo "[A] is_path_changelog_exempt clasifica rutas exentas vs notables (CA-2)"

for exempt in "docs/bitacora/algo.md" "docs/bitacora/field-notes/2026-x.md" "README.md" "CLAUDE.md" ".gitignore"; do
    if is_path_changelog_exempt "$exempt"; then
        pass "'$exempt' exento (no exige entrada)"
    else
        fail "'$exempt' deberia ser exento"
    fi
done

for notable in "commands/x.md" "agents/y.md" "scripts/z.sh" ".claude/scripts/w.sh" "docs/adr/0021-x.md" "hooks/hooks.json" "CHANGELOG.md"; do
    if is_path_changelog_exempt "$notable"; then
        fail "'$notable' deberia ser NOTABLE (exige entrada)"
    else
        pass "'$notable' notable (exige entrada)"
    fi
done

# -------- Bloque B: gate sobre diffs simulados (CA-4/CA-5/CA-6) --------

echo ""
echo "[B] Gate sobre diffs simulados en un repo git temporal (CA-4/CA-5/CA-6)"

HAVE_PY=1
command -v python3 >/dev/null 2>&1 || HAVE_PY=0
[ "$HAVE_PY" -eq 0 ] && echo "  (sin python3: check_unreleased_touched degrada a 0; se omiten las aserciones que dependen de el)"

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

git -C "$TMP" init -q
git -C "$TMP" config user.email "t@t.test"
git -C "$TMP" config user.name "test"

# CHANGELOG base con [Unreleased] vacio (como llega un PR antes de redactar).
cat > "$TMP/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [0.1.0] - 2026-01-01

### Added

- inicial
EOF
mkdir -p "$TMP/commands" "$TMP/docs/bitacora"
echo "base" > "$TMP/commands/existente.md"
git -C "$TMP" add -A >/dev/null
git -C "$TMP" commit -qm "base"
BASE=$(git -C "$TMP" rev-parse HEAD)

reset_wt() { git -C "$TMP" reset -q --hard HEAD; git -C "$TMP" clean -qfd; }

# --- CA-4: diff NOTABLE sin entrada -> aborta ---
reset_wt
echo "nuevo skill" > "$TMP/commands/foo.md"
if changes_require_changelog "$TMP" "$BASE"; then
    pass "CA-4: cambio en commands/foo.md clasificado como notable"
else
    fail "CA-4: commands/foo.md deberia ser notable"
fi
if [ "$HAVE_PY" -eq 1 ]; then
    if check_unreleased_touched "$TMP" "$BASE"; then
        fail "CA-4: [Unreleased] vacio NO deberia contar como tocado"
    else
        pass "CA-4: [Unreleased] sigue sin contenido (no tocado)"
    fi
    if gate_would_abort "$TMP" "$BASE"; then
        pass "CA-4: el gate ABORTA ante cambio notable sin entrada"
    else
        fail "CA-4: el gate deberia abortar"
    fi
fi

# --- CA-5: diff EXENTO sin entrada -> pasa ---
reset_wt
mkdir -p "$TMP/docs/bitacora"
echo "nota de bitacora" > "$TMP/docs/bitacora/2026-x.md"
if changes_require_changelog "$TMP" "$BASE"; then
    fail "CA-5: solo docs/bitacora NO deberia ser notable"
else
    pass "CA-5: cambio exento (solo docs/bitacora) clasificado como no notable"
fi
if gate_would_abort "$TMP" "$BASE"; then
    fail "CA-5: el gate NO deberia abortar ante cambio exento"
else
    pass "CA-5: el gate PASA ante cambio exento sin entrada"
fi

# --- CA-6: diff NOTABLE con entrada -> pasa ---
reset_wt
echo "nuevo skill" > "$TMP/commands/foo.md"
cat > "$TMP/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

### Added

- Nueva funcionalidad de prueba.

## [0.1.0] - 2026-01-01

### Added

- inicial
EOF
if changes_require_changelog "$TMP" "$BASE"; then
    pass "CA-6: cambio notable detectado (commands/foo.md + CHANGELOG.md)"
else
    fail "CA-6: deberia ser notable"
fi
if [ "$HAVE_PY" -eq 1 ]; then
    if check_unreleased_touched "$TMP" "$BASE"; then
        pass "CA-6: [Unreleased] recibio contenido (tocado)"
    else
        fail "CA-6: la entrada anadida deberia contar como tocada"
    fi
fi
if gate_would_abort "$TMP" "$BASE"; then
    fail "CA-6: el gate NO deberia abortar cuando hay entrada"
else
    pass "CA-6: el gate PASA ante cambio notable con entrada"
fi

# -------- Resumen --------

echo ""
echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
