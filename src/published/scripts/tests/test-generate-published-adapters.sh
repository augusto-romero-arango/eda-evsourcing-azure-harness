#!/usr/bin/env bash
# Suite aislada del motor publicado: usa una copia temporal del script, un
# validador fixture y dos adaptadores fixture; nunca toca dist/ real.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
SOURCE_GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
FIXTURES="$HERE/fixtures/adapters"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_rc() { [ "$1" -eq "$2" ] && pass "$3" || fail "$3 (exit $1)"; }

setup_repo() {
    local name="$1"
    TEST_REPO="$WORK/$name"
    mkdir -p "$TEST_REPO/src/published/scripts/adapters" "$TEST_REPO/src/published/agents"
    cp "$SOURCE_GENERATOR" "$TEST_REPO/src/published/scripts/generate-published-adapters.sh"
    cp "$FIXTURES"/adapter-*.sh "$TEST_REPO/src/published/scripts/adapters/"
    chmod +x "$TEST_REPO/src/published/scripts/"*.sh "$TEST_REPO/src/published/scripts/adapters/"*.sh
    cat > "$TEST_REPO/src/published/scripts/validate-published-artifacts.sh" <<'EOF'
#!/usr/bin/env bash
set -u
for file in "$@"; do case "$file" in *invalida*) echo "$file: invalida"; exit 1;; esac; done
exit 0
EOF
    chmod +x "$TEST_REPO/src/published/scripts/validate-published-artifacts.sh"
    cat > "$TEST_REPO/src/published/agents/valida con espacios.md" <<'EOF'
---
{}
---
fixture
EOF
}

echo '[pre] sintaxis y ejecutable'
if bash -n "$SOURCE_GENERATOR" && [ -x "$SOURCE_GENERATOR" ]; then pass 'generador valido'; else fail 'generador invalido'; fi

setup_repo valido
GEN="$TEST_REPO/src/published/scripts/generate-published-adapters.sh"
OUT="$WORK/salida con espacios"
"$GEN" --out "$OUT" "$TEST_REPO/src/published/agents/valida con espacios.md"; rc=$?
assert_rc "$rc" 0 'dos adaptadores procesan fuente y paths con espacios'
[ -f "$OUT/dist/alpha/artefactos/valida con espacios.md" ] && [ -f "$OUT/dist/beta/artefactos/valida con espacios.md" ] && pass 'salidas de ambos adaptadores' || fail 'faltan salidas'

check_out="$("$GEN" --check --out "$OUT" "$TEST_REPO/src/published/agents/valida con espacios.md")"; rc=$?
[ "$rc" -eq 0 ] && pass '--check al dia' || fail "--check al dia (exit $rc: $check_out)"
printf 'cambio\n' >> "$OUT/dist/alpha/artefactos/valida con espacios.md"
check_out="$("$GEN" --check --out "$OUT" "$TEST_REPO/src/published/agents/valida con espacios.md")"; rc=$?
assert_rc "$rc" 1 '--check distinta'; case "$check_out" in *'dist/alpha/artefactos/valida con espacios.md: distinta'*) pass 'diagnostico distinta';; *) fail 'sin diagnostico distinta';; esac
rm "$OUT/dist/beta/artefactos/valida con espacios.md"
check_out="$("$GEN" --check --out "$OUT" "$TEST_REPO/src/published/agents/valida con espacios.md")"; rc=$?
assert_rc "$rc" 1 '--check faltante'; case "$check_out" in *'dist/beta/artefactos/valida con espacios.md: faltante'*) pass 'diagnostico faltante';; *) fail 'sin diagnostico faltante';; esac
mkdir -p "$OUT/dist/alpha/artefactos"; printf '<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde x. No editar a mano. -->\n' > "$OUT/dist/alpha/artefactos/huerfana.md"
printf 'manual\n' > "$OUT/dist/beta/artefactos/manual.md"
check_out="$("$GEN" --check --out "$OUT" "$TEST_REPO/src/published/agents/valida con espacios.md")"; rc=$?
case "$check_out" in *'huerfana.md: huerfana'*) pass 'diagnostico huerfana';; *) fail 'sin diagnostico huerfana';; esac
case "$check_out" in *'manual.md: sin marcador'*) pass 'diagnostico sin marcador';; *) fail 'sin diagnostico sin marcador';; esac

setup_repo invalida
GEN="$TEST_REPO/src/published/scripts/generate-published-adapters.sh"; OUT="$WORK/invalida-out"
"$GEN" --out "$OUT" "$TEST_REPO/src/published/agents/invalida.md" >/dev/null 2>&1; assert_rc "$?" 1 'validador rechaza antes de crear salida'
[ ! -e "$OUT" ] && pass 'fuente invalida no crea salida' || fail 'fuente invalida creo salida'

setup_repo fallo
GEN="$TEST_REPO/src/published/scripts/generate-published-adapters.sh"; OUT="$WORK/fallo-out"
cp "$TEST_REPO/src/published/agents/valida con espacios.md" "$TEST_REPO/src/published/agents/fallar.md"
"$GEN" --out "$OUT" "$TEST_REPO/src/published/agents/fallar.md" >/dev/null 2>&1; assert_rc "$?" 1 'fallo del segundo adaptador aborta'
[ ! -e "$OUT" ] && pass 'fallo no deja salida parcial' || fail 'fallo dejo salida parcial'
rm "$TEST_REPO/src/published/scripts/adapters/"adapter-*.sh
"$GEN" --out "$WORK/sin-adaptadores" "$TEST_REPO/src/published/agents/valida con espacios.md" >/dev/null 2>&1; assert_rc "$?" 1 'cero adaptadores con fuente explicita falla'
rm "$TEST_REPO/src/published/agents/"*.md
"$GEN" --out "$WORK/sin-adaptadores-vacio" >/dev/null 2>&1; assert_rc "$?" 0 'cero adaptadores sin fuentes termina verde'

setup_repo determinismo
GEN="$TEST_REPO/src/published/scripts/generate-published-adapters.sh"; OUT="$WORK/determinismo"
"$GEN" --out "$OUT" "$TEST_REPO/src/published/agents/valida con espacios.md" && first="$(shasum "$OUT"/dist/*/artefactos/* | shasum)"
touch "$TEST_REPO/src/published/agents/valida con espacios.md"
"$GEN" --out "$OUT" "$TEST_REPO/src/published/agents/valida con espacios.md" && second="$(shasum "$OUT"/dist/*/artefactos/* | shasum)"
[ "$first" = "$second" ] && pass 'determinismo independiente de mtime' || fail 'salida no determinista'

printf '\nResultado: %s PASS, %s FAIL\n' "$PASS" "$FAIL"
exit "$FAIL"
