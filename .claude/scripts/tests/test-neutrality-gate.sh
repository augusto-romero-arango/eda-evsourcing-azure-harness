#!/usr/bin/env bash
# test-neutrality-gate.sh -- Tests de mefisto-neutrality-gate.sh (MEF-ADR-0049,
# issue #911, hijo 1 de 3 de #873).
#
# Cubre:
#   [pre]           El gate existe, es ejecutable y tiene sintaxis valida.
#   [clean]         Un arbol positivo (shims conformes, salidas con marcador,
#                   una excepcion de la allowlist realmente filtrada, sin
#                   fugas) termina en exit 0 sin imprimir nada.
#   [R1]-[R4]       Un negativo por regla, cada uno con la linea
#                   "<ruta>:<linea>: <regla>" esperada.
#   [adapters-check] Una divergencia de generate-internal-adapters.sh --check
#                   se reemite como "<ruta>: <estado>: adapters-check".
#   [allowlist]     Una entrada de la allowlist sin 'motivo' hace abortar el
#                   gate (exit 1) antes de escanear nada.
#   [perf]          CA-3 con margen: una corrida completa contra el repo real
#                   termina en menos de 20s (el limite de CA-3 es 10s),
#                   exit 0 o 1 indistinto.
#
# Los arboles de fixture son repos git minimos bajo un directorio temporal
# propio (nunca el repo real, salvo en [perf]): cada uno solo necesita los
# archivos en el INDICE (`git add -A`, sin commit -- `git ls-files` no exige
# un commit) para que el gate los vea.
#
# Uso: .claude/scripts/tests/test-neutrality-gate.sh
# Exit code: 0 si todos los checks pasan, 1 si alguno falla.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GATE="$REPO_ROOT/src/internal/scripts/mefisto-neutrality-gate.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# new_tree <nombre> -- imprime la ruta de un repo git vacio nuevo bajo SCRATCH.
new_tree() {
    local dir="$SCRATCH/$1"
    mkdir -p "$dir"
    git -C "$dir" init -q >/dev/null 2>&1
    printf '%s' "$dir"
}

# write_allowlist <dir> <json> -- escribe la allowlist del arbol <dir>.
write_allowlist() {
    local dir="$1" json="$2"
    mkdir -p "$dir/src/internal/contract"
    printf '%s' "$json" > "$dir/src/internal/contract/neutrality-allowlist.json"
}

EMPTY_ALLOWLIST='{"scope_excluded": [], "exceptions": [], "not_migrated": []}'

# write_clean_generator <dir> -- stub de generate-internal-adapters.sh cuyo
# --check no reporta divergencias (exit 0, sin salida).
write_clean_generator() {
    local dir="$1"
    mkdir -p "$dir/src/internal/scripts"
    cat > "$dir/src/internal/scripts/generate-internal-adapters.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
}

# write_dirty_generator <dir> -- stub cuyo --check reporta una divergencia.
write_dirty_generator() {
    local dir="$1"
    mkdir -p "$dir/src/internal/scripts"
    cat > "$dir/src/internal/scripts/generate-internal-adapters.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--check" ]; then
    echo ".claude/agents/fx-agent.md: distinta"
    exit 1
fi
exit 0
EOF
}

# write_generic_shim <ruta> -- shim conforme a la plantilla generica de
# src/internal/scripts/README.md.
write_generic_shim() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'EOF'
#!/usr/bin/env bash
# Shim de compatibilidad (MEF-ADR-0049): la implementacion canonica vive en src/internal/scripts/. No editar.
exec "$(cd "$(dirname "$0")/../.." && pwd)/src/internal/scripts/$(basename "$0")" "$@"
EOF
}

# write_common_shim <ruta> -- variante de una linea (`source`) para el shim
# de _mefisto-common.sh.
write_common_shim() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'EOF'
#!/usr/bin/env bash
# Shim de compatibilidad (MEF-ADR-0049): la implementacion canonica vive en src/internal/scripts/lib/_mefisto-common.sh. No editar.
# `source` (no `exec`): esta lib se sourcea desde otros scripts, nunca se ejecuta sola -- el gate de scope (mefisto-scope-hook.sh) sigue cargandola desde el checkout principal (MEF-ADR-0019 seccion E).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/internal/scripts/lib/_mefisto-common.sh"
EOF
}

git_add_all() {
    git -C "$1" add -A >/dev/null 2>&1
}

run_gate() {
    "$GATE" --root "$1" 2>&1
}

echo "[pre] el gate existe, es ejecutable y tiene sintaxis valida"
if [ -f "$GATE" ]; then
    pass "existe $GATE"
else
    fail "no existe $GATE"
fi
if [ -x "$GATE" ]; then
    pass "es ejecutable"
else
    fail "no tiene el bit ejecutable"
fi
if bash -n "$GATE" 2>/tmp/mefisto-neutrality-gate-syntax.$$; then
    pass "sintaxis bash valida"
else
    fail "error de sintaxis: $(cat /tmp/mefisto-neutrality-gate-syntax.$$)"
fi
rm -f /tmp/mefisto-neutrality-gate-syntax.$$

echo ""
echo "[clean] arbol positivo: shims conformes, salidas con marcador, excepcion de la allowlist filtrada, sin fugas -> exit 0 sin salida"
DIR_CLEAN="$(new_tree clean)"
write_allowlist "$DIR_CLEAN" '{
  "scope_excluded": [],
  "exceptions": [
    { "path": "src/internal/scripts/lib/fx-allowed-model.sh", "rules": ["R1"], "motivo": "Fixture: archivo permitido a nombrar el alias sonnet a proposito." },
    { "path": "src/internal/contract/neutrality-allowlist.json", "rules": ["ALL"], "motivo": "Fixture: este mismo archivo cita 'sonnet' en el motivo de arriba, igual que la allowlist real se autorreferencia." }
  ],
  "not_migrated": [
    { "path": ".claude/scripts/fx-not-migrated.sh", "motivo": "Fixture: script no migrado a proposito.", "issue": null }
  ]
}'
mkdir -p "$DIR_CLEAN/src/internal/scripts/lib"
printf '#!/usr/bin/env bash\n# menciona el modelo sonnet a proposito (cubierto por la excepcion)\necho ok\n' > "$DIR_CLEAN/src/internal/scripts/lib/fx-allowed-model.sh"
printf '#!/usr/bin/env bash\necho ok\n' > "$DIR_CLEAN/src/internal/scripts/lib/fx-clean.sh"
printf 'doctrina neutral de ejemplo, sin fugas.\n' > "$DIR_CLEAN/AGENTS.md"
write_generic_shim "$DIR_CLEAN/.claude/scripts/fx-shim.sh"
write_common_shim "$DIR_CLEAN/.claude/scripts/_mefisto-common.sh"
printf '#!/usr/bin/env bash\necho "no soy un shim, pero estoy en not_migrated"\n' > "$DIR_CLEAN/.claude/scripts/fx-not-migrated.sh"
write_clean_generator "$DIR_CLEAN"
git_add_all "$DIR_CLEAN"

CLEAN_OUT="$(run_gate "$DIR_CLEAN")"
CLEAN_RC=$?
if [ "$CLEAN_RC" -eq 0 ]; then
    pass "exit 0"
else
    fail "exit $CLEAN_RC (esperaba 0). Salida: $CLEAN_OUT"
fi
if [ -z "$CLEAN_OUT" ]; then
    pass "sin salida"
else
    fail "imprimio salida pese a no tener fugas: $CLEAN_OUT"
fi

echo ""
echo "[R1] alias de modelo sin excepcion -> violacion R1"
DIR_R1="$(new_tree r1-neg)"
write_allowlist "$DIR_R1" "$EMPTY_ALLOWLIST"
write_clean_generator "$DIR_R1"
mkdir -p "$DIR_R1/src/internal/scripts/lib"
printf '#!/usr/bin/env bash\n# usa el modelo sonnet para esta tarea\necho ok\n' > "$DIR_R1/src/internal/scripts/lib/fx-model-leak.sh"
git_add_all "$DIR_R1"
R1_OUT="$(run_gate "$DIR_R1")"
R1_RC=$?
if [ "$R1_RC" -ne 0 ] && printf '%s\n' "$R1_OUT" | grep -qE '^src/internal/scripts/lib/fx-model-leak\.sh:[0-9]+: R1$'; then
    pass "reporta 'src/internal/scripts/lib/fx-model-leak.sh:<linea>: R1' con exit != 0"
else
    fail "no reporto la violacion R1 esperada. exit=$R1_RC salida: $R1_OUT"
fi

echo ""
echo "[R2] invocacion directa de CLI sin excepcion -> violacion R2"
DIR_R2="$(new_tree r2-neg)"
write_allowlist "$DIR_R2" "$EMPTY_ALLOWLIST"
write_clean_generator "$DIR_R2"
mkdir -p "$DIR_R2/src/internal/scripts"
printf '#!/usr/bin/env bash\n# invoca claude -p directo, sin pasar por el runner neutral\necho ok\n' > "$DIR_R2/src/internal/scripts/fx-r2-leak.sh"
git_add_all "$DIR_R2"
R2_OUT="$(run_gate "$DIR_R2")"
R2_RC=$?
if [ "$R2_RC" -ne 0 ] && printf '%s\n' "$R2_OUT" | grep -qE '^src/internal/scripts/fx-r2-leak\.sh:[0-9]+: R2$'; then
    pass "reporta 'src/internal/scripts/fx-r2-leak.sh:<linea>: R2' con exit != 0"
else
    fail "no reporto la violacion R2 esperada. exit=$R2_RC salida: $R2_OUT"
fi

echo ""
echo "[R3] variable/ruta de runtime concreto sin excepcion -> violacion R3"
DIR_R3="$(new_tree r3-neg)"
write_allowlist "$DIR_R3" "$EMPTY_ALLOWLIST"
write_clean_generator "$DIR_R3"
mkdir -p "$DIR_R3/src/internal/scripts"
printf '#!/usr/bin/env bash\n# resuelve la ruta via CLAUDE_PROJECT_DIR (prohibido)\necho ok\n' > "$DIR_R3/src/internal/scripts/fx-r3-leak.sh"
git_add_all "$DIR_R3"
R3_OUT="$(run_gate "$DIR_R3")"
R3_RC=$?
if [ "$R3_RC" -ne 0 ] && printf '%s\n' "$R3_OUT" | grep -qE '^src/internal/scripts/fx-r3-leak\.sh:[0-9]+: R3$'; then
    pass "reporta 'src/internal/scripts/fx-r3-leak.sh:<linea>: R3' con exit != 0"
else
    fail "no reporto la violacion R3 esperada. exit=$R3_RC salida: $R3_OUT"
fi

echo ""
echo "[R4] .claude/scripts/*.sh que no es shim ni esta en not_migrated -> violacion R4"
DIR_R4="$(new_tree r4-neg)"
write_allowlist "$DIR_R4" "$EMPTY_ALLOWLIST"
write_clean_generator "$DIR_R4"
mkdir -p "$DIR_R4/.claude/scripts"
printf '#!/usr/bin/env bash\necho "no soy un shim conforme"\n' > "$DIR_R4/.claude/scripts/fx-bad-shim.sh"
git_add_all "$DIR_R4"
R4_OUT="$(run_gate "$DIR_R4")"
R4_RC=$?
if [ "$R4_RC" -ne 0 ] && printf '%s\n' "$R4_OUT" | grep -qF '.claude/scripts/fx-bad-shim.sh:1: R4'; then
    pass "reporta '.claude/scripts/fx-bad-shim.sh:1: R4' con exit != 0"
else
    fail "no reporto la violacion R4 esperada. exit=$R4_RC salida: $R4_OUT"
fi

echo ""
echo "[adapters-check] generate-internal-adapters.sh --check con divergencia -> violacion adapters-check"
DIR_AC="$(new_tree adapters-check-neg)"
write_allowlist "$DIR_AC" "$EMPTY_ALLOWLIST"
write_dirty_generator "$DIR_AC"
git_add_all "$DIR_AC"
AC_OUT="$(run_gate "$DIR_AC")"
AC_RC=$?
if [ "$AC_RC" -ne 0 ] && printf '%s\n' "$AC_OUT" | grep -qF '.claude/agents/fx-agent.md: distinta: adapters-check'; then
    pass "reporta '.claude/agents/fx-agent.md: distinta: adapters-check' con exit != 0"
else
    fail "no reporto la violacion adapters-check esperada. exit=$AC_RC salida: $AC_OUT"
fi

echo ""
echo "[allowlist] entrada sin 'motivo' -> el gate aborta antes de escanear"
DIR_BAD_ALLOW="$(new_tree bad-allowlist)"
write_allowlist "$DIR_BAD_ALLOW" '{
  "scope_excluded": [],
  "exceptions": [
    { "path": "src/internal/scripts/lib/whatever.sh", "rules": ["R1"] }
  ],
  "not_migrated": []
}'
write_clean_generator "$DIR_BAD_ALLOW"
git_add_all "$DIR_BAD_ALLOW"
BAD_ALLOW_OUT="$(run_gate "$DIR_BAD_ALLOW")"
BAD_ALLOW_RC=$?
if [ "$BAD_ALLOW_RC" -ne 0 ] && printf '%s\n' "$BAD_ALLOW_OUT" | grep -qi "motivo"; then
    pass "aborta (exit $BAD_ALLOW_RC) citando 'motivo'"
else
    fail "no aborto citando 'motivo'. exit=$BAD_ALLOW_RC salida: $BAD_ALLOW_OUT"
fi

echo ""
echo "[perf] CA-3 con margen: corrida completa contra el repo real en menos de 20s (limite de CA-3: 10s)"
PERF_START=$(date +%s)
"$GATE" >/dev/null 2>&1
PERF_RC=$?
PERF_END=$(date +%s)
PERF_ELAPSED=$((PERF_END - PERF_START))
if [ "$PERF_ELAPSED" -lt 20 ]; then
    pass "corrida completa en ${PERF_ELAPSED}s (< 20s), exit $PERF_RC (0 o 1 indistinto para este check)"
else
    fail "corrida completa tardo ${PERF_ELAPSED}s (>= 20s, limite CA-3: 10s)"
fi

echo ""
echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
