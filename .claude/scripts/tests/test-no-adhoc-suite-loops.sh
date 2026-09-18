#!/usr/bin/env bash
# test-no-adhoc-suite-loops.sh -- Guard estatico contra bucles completos ad
# hoc sobre la suite de tests (issue #1471).
#
# Con #1416 (runner .claude/scripts/mefisto-test-suite.sh) y #1439 (doctrina
# interna + prompts del pipeline que remiten a el) el repo tiene un unico
# destino canonico para la regresion completa. Nada impide que un script, un
# workflow o un prompt futuro reconstruya a mano el bucle
# 'for t in scripts/tests/test-*.sh .claude/scripts/tests/test-*.sh',
# saltandose el inventario (#1438) y el ejecutor (#1440: sin continuidad ante
# rojo, sin CANCELLED, sin semantica de senales). Este guard congela el
# estado actual (sin infractores) para que la regresion no vuelva en
# silencio.
#
# Detecta, sobre los archivos VERSIONADOS del repo (git ls-files, NUNCA el
# working tree sin trackear -- un borrador a medio escribir no debe hacer
# fallar el guard):
#   [1] 'for ... in' cuyo iterable contiene alguno de los 4 globs de la suite
#       completa: scripts/tests/test-*.sh, scripts/tests/*.sh,
#       .claude/scripts/tests/test-*.sh, .claude/scripts/tests/*.sh.
#   [2] 'find'/'ls' sobre esos directorios con -name/glob '*.sh' encadenado a
#       -exec, | xargs, | while o | parallel (dirigido a esos mismos globs).
#   [3] 'bash'/'sh' invocado con uno de esos globs como argumento.
#
# NO flaggea (ver EXEMPT_PATH_REGEXES mas abajo): invocaciones individuales de
# un test concreto, discovery de tests relevantes al diff via 'grep -l'
# (idioma que los prompts del pipeline recomiendan), ni menciones en
# prosa/comentarios (una linea cuyo primer caracter no-blanco es '#' nunca se
# clasifica como infraccion, aunque contenga el glob literal -- mismo
# criterio que test-mefisto-test-inventory.sh: se juzga sobre codigo, no
# sobre la prosa que describe la prohibicion).
#
# Rendimiento: UNA sola pasada de 'git ls-files -z | xargs -0 grep -nHE' por
# cada una de las 4 formas de infraccion (nunca un grep por archivo) -- con
# miles de archivos versionados, invocar grep archivo-por-archivo es
# ordenes de magnitud mas lento y en bash 3.2 arriesga agotar descriptores
# via process-substitution anidada dentro de un bucle largo.
#
# Uso: .claude/scripts/tests/test-no-adhoc-suite-loops.sh
# Exit code: 0 si el guard sale limpio sobre el repo real Y todos los casos
# del auto-test (fixture temporal) se comportan como se espera; 1 si alguno
# falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# --- Rutas exentas (CA-2, unica variable, comentada) ---------------------
#
# src/internal/scripts/lib/mefisto-test-inventory.sh y
#   src/internal/scripts/mefisto-test-suite.sh: las dos fuentes canonicas que
#   SI conocen los cuatro globs (inventario #1438 + runner #1416) -- son la
#   implementacion legitima que este guard protege, no la infraccion.
# (^|/)tests/: cualquier archivo bajo un directorio 'tests/' -- incluye este
#   mismo guard (que menciona los 4 globs en sus propios comentarios y
#   regexes, mismo razonamiento que la autoexencion de mefisto-neutrality-
#   gate.sh en neutrality-allowlist.json) y todo fixture bajo 'fixtures/'.
# ^dist/: salida generada de adaptadores publicados -- puede contener
#   'for proj in tests/<RootNamespace>.*.Tests/' del CONSUMIDOR .NET (no es
#   la suite de Mefisto, y ademas ya esta exenta por ruta).
# ^docs/, ^changelog\.d/, ^CHANGELOG\.md$: prosa/bitacora, nunca ejecutable.
EXEMPT_PATH_REGEXES='
^src/internal/scripts/lib/mefisto-test-inventory\.sh$
^src/internal/scripts/mefisto-test-suite\.sh$
(^|/)tests/
^dist/
^docs/
^changelog\.d/
^CHANGELOG\.md$
'

# is_exempt_path <ruta-relativa>
is_exempt_path() {
    local p="$1" pat
    while IFS= read -r pat; do
        [ -n "$pat" ] || continue
        [[ "$p" =~ $pat ]] && return 0
    done <<EOF
$EXEMPT_PATH_REGEXES
EOF
    return 1
}

# --- Las 3 formas de infraccion (CA-1) ------------------------------------
#
# Cada regex se mantiene SEPARADA (nunca combinada con '|' en una sola
# invocacion de grep): BSD grep (macOS, /usr/bin/grep) mezcla groups
# anidados con '.*' y alternancia de forma inconsistente cuando se combinan
# demasiadas alternativas en un solo patron -- verificado empiricamente que
# una version combinada de las 4 deja de matchear casos que SI matchea por
# separado. Ejecutar 4 pasadas es la forma robusta, no una optimizacion.
FOR_LOOP_RE='for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]].*(\.claude/)?scripts/tests/(test-)?\*\.sh'
FIND_LS_GLOB_RE='(^|[;&|[:space:]])(find|ls)[[:space:]]+.*(\.claude/)?scripts/tests/(test-)?\*\.sh.*(-exec|\|[[:space:]]*xargs|\|[[:space:]]*while|\|[[:space:]]*parallel)'
FIND_LS_NAME_RE='(^|[;&|[:space:]])(find|ls)[[:space:]]+.*(\.claude/)?scripts/tests\b.*-name[[:space:]]+.*(test-)?\*\.sh.*(-exec|\|[[:space:]]*xargs|\|[[:space:]]*while|\|[[:space:]]*parallel)'
BASH_SH_RE='(^|[;&|[:space:]])(bash|sh)[[:space:]]+.*(\.claude/)?scripts/tests/(test-)?\*\.sh'

REASON_FOR="bucle 'for ... in' que reconstruye el glob de la suite completa (usa .claude/scripts/mefisto-test-suite.sh)"
REASON_FINDLS="find/ls sobre scripts/tests encadenado a -exec/xargs/while/parallel: reconstruye la suite completa a mano (usa .claude/scripts/mefisto-test-suite.sh)"
REASON_BASHSH="bash/sh invocado con el glob de la suite completa como argumento (usa .claude/scripts/mefisto-test-suite.sh)"

# _grep_pattern <root> <regex> <motivo>
#
# Imprime '<ruta>:<linea>: <motivo>' por cada linea de un archivo VERSIONADO
# de <root> que matchea <regex>, salvo que su ruta este exenta o la linea sea
# un comentario completo (primer caracter no-blanco '#').
#
# grep corre con -I: un archivo binario versionado emitiria 'Binary file X
# matches', una linea SIN numero que corromperia el parseo posicional
# '<ruta>:<linea>:<contenido>' de mas abajo. Con -I esos archivos no producen
# salida, y ninguna infraccion ejecutable puede vivir en un binario.
_grep_pattern() {
    local root="$1" re="$2" reason="$3"
    local line relpath rest lineno content
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        relpath="${line%%:*}"
        rest="${line#*:}"
        lineno="${rest%%:*}"
        content="${rest#*:}"
        is_exempt_path "$relpath" && continue
        [[ "$content" =~ ^[[:space:]]*# ]] && continue
        printf '%s:%s: %s\n' "$relpath" "$lineno" "$reason"
    done < <(cd "$root" && git ls-files -z | xargs -0 grep -InHE -- "$re" 2>/dev/null)
}

# scan_adhoc_suite_loops <root>
#
# CA-1: imprime '<ruta>:<linea>: <motivo>' por cada infraccion. Exit 1 si
# imprimio algo, 0 si no.
scan_adhoc_suite_loops() {
    local root="$1" out
    out="$(
        _grep_pattern "$root" "$FOR_LOOP_RE" "$REASON_FOR"
        _grep_pattern "$root" "$FIND_LS_GLOB_RE" "$REASON_FINDLS"
        _grep_pattern "$root" "$FIND_LS_NAME_RE" "$REASON_FINDLS"
        _grep_pattern "$root" "$BASH_SH_RE" "$REASON_BASHSH"
    )"
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
        return 1
    fi
    return 0
}

# -------- CA-3: auto-test contra un repo fixture temporal -----------------

TMPDIR_ROOT=$(cd "$(mktemp -d)" && pwd -P)
cleanup() { rm -rf "$TMPDIR_ROOT"; }
trap cleanup EXIT

git init -q "$TMPDIR_ROOT"
mkdir -p "$TMPDIR_ROOT/scripts/ci" "$TMPDIR_ROOT/.github/workflows" \
    "$TMPDIR_ROOT/dist/claude" "$TMPDIR_ROOT/docs"

# [A] Casos positivos: los 3 patrones + el mismo bucle dentro de un .yml.

cat > "$TMPDIR_ROOT/scripts/ci/adhoc-for.sh" <<'EOF'
#!/usr/bin/env bash
set -e
for t in scripts/tests/test-*.sh .claude/scripts/tests/test-*.sh; do
    bash "$t"
done
EOF

cat > "$TMPDIR_ROOT/scripts/ci/adhoc-for-plain-glob.sh" <<'EOF'
#!/usr/bin/env bash
set -e
for f in .claude/scripts/tests/*.sh; do
    bash "$f"
done
EOF

cat > "$TMPDIR_ROOT/scripts/ci/adhoc-find.sh" <<'EOF'
#!/usr/bin/env bash
set -e
find scripts/tests .claude/scripts/tests -name 'test-*.sh' -exec bash {} \;
EOF

cat > "$TMPDIR_ROOT/scripts/ci/adhoc-xargs.sh" <<'EOF'
#!/usr/bin/env bash
set -e
ls scripts/tests/test-*.sh | xargs -n1 bash
EOF

cat > "$TMPDIR_ROOT/.github/workflows/regression.yml" <<'EOF'
name: Regression
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Run full suite
        run: |
          for t in scripts/tests/test-*.sh .claude/scripts/tests/test-*.sh; do
            bash "$t"
          done
EOF

# [B] Casos negativos (CA-2): invocacion individual, discovery via grep -l,
# el 'for proj in tests/X.Tests/' de la suite .NET del CONSUMIDOR (discrimina
# por REGEX, no por exencion de ruta: el archivo NO esta exento), y
# prosa/comentario.

cat > "$TMPDIR_ROOT/scripts/ci/individual.sh" <<'EOF'
#!/usr/bin/env bash
bash scripts/tests/test-guards.sh
bash .claude/scripts/tests/test-next-order.sh
EOF

cat > "$TMPDIR_ROOT/scripts/ci/discovery.sh" <<'EOF'
#!/usr/bin/env bash
grep -l archivo.sh scripts/tests/*.sh .claude/scripts/tests/*.sh
EOF

cat > "$TMPDIR_ROOT/scripts/ci/dotnet-tests.sh" <<'EOF'
#!/usr/bin/env bash
for proj in tests/Cosmos.Dominio.*.Tests/; do
    dotnet test "$proj"
done
EOF

cat > "$TMPDIR_ROOT/scripts/ci/prose.sh" <<'EOF'
#!/usr/bin/env bash
# No reconstruir el bucle 'for t in scripts/tests/test-*.sh .claude/scripts/tests/test-*.sh'.
exit 0
EOF

# [C] Casos negativos de ruta exenta (CA-3): el mismo bucle positivo copiado
# bajo dist/ y bajo docs/ -- debe seguir sin reportarse.

cp "$TMPDIR_ROOT/scripts/ci/adhoc-for.sh" "$TMPDIR_ROOT/dist/claude/adhoc-for.sh"
cp "$TMPDIR_ROOT/scripts/ci/adhoc-for.sh" "$TMPDIR_ROOT/docs/adhoc-for.md"

git -C "$TMPDIR_ROOT" add scripts .github dist docs

# [D] Archivo no trackeado con el bucle: tampoco se reporta (nunca aparece
# en 'git ls-files').

cat > "$TMPDIR_ROOT/scripts/ci/untracked.sh" <<'EOF'
#!/usr/bin/env bash
for t in scripts/tests/test-*.sh .claude/scripts/tests/test-*.sh; do
    bash "$t"
done
EOF

# Una UNICA invocacion por root: la asignacion desde una sustitucion de
# comando propaga el exit code del comando sustituido, asi que capturar '$?'
# acto seguido da el rc sin repetir las 4 pasadas de grep sobre todo el repo.
FIXTURE_OUT="$(scan_adhoc_suite_loops "$TMPDIR_ROOT" 2>&1)"
FIXTURE_RC=$?

echo "[A] Casos positivos: se reportan con <ruta>:<linea> exactos"

if [ "$FIXTURE_RC" -eq 1 ]; then
    pass "el fixture con infractores sale 1"
else
    fail "se esperaba rc=1 sobre el fixture con infractores, se obtuvo rc=$FIXTURE_RC"
fi

for expected in \
    "scripts/ci/adhoc-for.sh:3:" \
    "scripts/ci/adhoc-for-plain-glob.sh:3:" \
    "scripts/ci/adhoc-find.sh:3:" \
    "scripts/ci/adhoc-xargs.sh:3:" \
    ".github/workflows/regression.yml:9:"
do
    if printf '%s\n' "$FIXTURE_OUT" | grep -qF "$expected"; then
        pass "reporta '$expected' (linea exacta)"
    else
        fail "no reporta '$expected' -- salida completa: $FIXTURE_OUT"
    fi
done

echo ""
echo "[B] Casos negativos (CA-2): invocacion individual, grep -l, suite .NET del consumidor, prosa/comentario"

for negative in \
    "scripts/ci/individual.sh" \
    "scripts/ci/discovery.sh" \
    "scripts/ci/dotnet-tests.sh" \
    "scripts/ci/prose.sh"
do
    if printf '%s\n' "$FIXTURE_OUT" | grep -qF "$negative"; then
        fail "reporta '$negative' (no deberia: es un caso negativo de CA-2)"
    else
        pass "no reporta '$negative'"
    fi
done

echo ""
echo "[C] Casos negativos de ruta exenta (CA-3): el bucle copiado bajo dist/ y docs/"

for exempt in \
    "dist/claude/adhoc-for.sh" \
    "docs/adhoc-for.md"
do
    if printf '%s\n' "$FIXTURE_OUT" | grep -qF "$exempt"; then
        fail "reporta '$exempt' (esta bajo una ruta exenta)"
    else
        pass "no reporta '$exempt' (ruta exenta)"
    fi
done

echo ""
echo "[D] Archivo no trackeado con el bucle: no se reporta"

if printf '%s\n' "$FIXTURE_OUT" | grep -qF "scripts/ci/untracked.sh"; then
    fail "reporta scripts/ci/untracked.sh (nunca deberia: no esta trackeado por git)"
else
    pass "no reporta scripts/ci/untracked.sh (no trackeado)"
fi

# -------- [E] Smoke contra el repo REAL de Mefisto (CA-4) -----------------

echo ""
echo "[E] Smoke contra el repo REAL: scan_adhoc_suite_loops sale 0"

REAL_OUT="$(scan_adhoc_suite_loops "$REPO_ROOT" 2>&1)"
REAL_RC=$?

if [ "$REAL_RC" -eq 0 ]; then
    pass "scan_adhoc_suite_loops sale 0 sobre el repo real (sin infractores)"
else
    fail "scan_adhoc_suite_loops encontro infractores en el repo real:"
    printf '%s\n' "$REAL_OUT"
fi

echo ""
echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
