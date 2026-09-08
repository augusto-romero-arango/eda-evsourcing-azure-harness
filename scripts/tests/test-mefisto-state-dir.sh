#!/usr/bin/env bash
# test-mefisto-state-dir.sh -- Contrato publicado de estado (issue #1050).
# Compatible con Bash 3.2; usa repositorios temporales y no migra legacy.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMON="$REPO_ROOT/scripts/_pipeline-common.sh"
PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && git init -q)
RUNNER="$TMP/runner.sh"
cat > "$RUNNER" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
[ -z "${STATE_TEST_CD:-}" ] || cd "$STATE_TEST_CD"
source "$STATE_TEST_COMMON"
"$@"
EOF
chmod +x "$RUNNER"
BASH_BIN=/bin/bash
[ -x "$BASH_BIN" ] || BASH_BIN=bash
call() {
    local cwd="$1"
    shift
    env -u MEFISTO_STATE_DIR -u MEFISTO_LEGACY_STATE_DIR STATE_TEST_COMMON="$COMMON" STATE_TEST_CD="$cwd" "$BASH_BIN" "$RUNNER" "$@"
}
call_override() {
    local cwd="$1" state="$2" legacy="$3"
    shift 3
    STATE_TEST_COMMON="$COMMON" STATE_TEST_CD="$cwd" MEFISTO_STATE_DIR="$state" MEFISTO_LEGACY_STATE_DIR="$legacy" "$BASH_BIN" "$RUNNER" "$@"
}

echo "[pre/defaults] helper y bases canonica/legacy"
if bash -n "$COMMON"; then pass "sintaxis valida"; else fail "sintaxis invalida"; fi
if grep -v '^[[:space:]]*#' "$COMMON" | grep -q 'declare -A'; then fail "usa arrays asociativos incompatibles con Bash 3.2"; else pass "sin arrays asociativos"; fi
mkdir -p "$TMP/nested/work"
if [ "$(call "$TMP/nested/work" printenv MEFISTO_STATE_DIR)" = "$TMP/.mefisto/pipeline" ] && [ "$(call "$TMP/nested/work" printenv MEFISTO_LEGACY_STATE_DIR)" = "$TMP/.claude/pipeline" ]; then
    pass "defaults se resuelven contra git toplevel"
else
    fail "defaults no se resuelven contra git toplevel"
fi

echo "[overrides/lectura] canonico primero, legacy despues"
CUSTOM="$TMP/custom"; CUSTOM_LEGACY="$TMP/custom-legacy"
PATH_OUT=$(call_override "$TMP" "$CUSTOM" "$CUSTOM_LEGACY" mefisto_state_path logs/events.log)
if [ "$PATH_OUT" = "$CUSTOM/logs/events.log" ] && [ -d "$CUSTOM/logs" ]; then pass "respeta override y crea padre canonico"; else fail "override o padre incorrecto"; fi
mkdir -p "$CUSTOM_LEGACY/logs"
printf legacy-override > "$CUSTOM_LEGACY/logs/override.log"
if [ "$(call_override "$TMP" "$CUSTOM" "$CUSTOM_LEGACY" mefisto_state_read_first logs/override.log)" = "$CUSTOM_LEGACY/logs/override.log" ]; then pass "respeta override legacy en lectura"; else fail "override legacy ignorado"; fi
ROOT="$TMP/root"
mkdir -p "$ROOT/.mefisto/pipeline/logs"
printf canon > "$ROOT/.mefisto/pipeline/logs/x.log"
if [ "$(call "$TMP" mefisto_state_read_paths logs/x.log "$ROOT")" = "$ROOT/.mefisto/pipeline/logs/x.log" ]; then pass "solo canonico es legible"; else fail "canonico no legible"; fi
mkdir -p "$ROOT/.claude/pipeline/logs"
printf legacy > "$ROOT/.claude/pipeline/logs/x.log"
EXPECTED="$ROOT/.mefisto/pipeline/logs/x.log"$'\n'"$ROOT/.claude/pipeline/logs/x.log"
if [ "$(call "$TMP" mefisto_state_read_paths logs/x.log "$ROOT")" = "$EXPECTED" ] && [ "$(call "$TMP" mefisto_state_read_first logs/x.log "$ROOT")" = "$ROOT/.mefisto/pipeline/logs/x.log" ]; then pass "ambas rutas: canonica primero"; else fail "orden de lectura incorrecto"; fi
rm "$ROOT/.mefisto/pipeline/logs/x.log"
if [ "$(call "$TMP" mefisto_state_read_paths logs/x.log "$ROOT")" = "$ROOT/.claude/pipeline/logs/x.log" ]; then pass "solo legacy sigue siendo legible"; else fail "legacy no legible"; fi
rm "$ROOT/.claude/pipeline/logs/x.log"
if [ -z "$(call "$TMP" mefisto_state_read_paths logs/x.log "$ROOT")" ] && ! call "$TMP" mefisto_state_read_first logs/x.log "$ROOT" >/dev/null; then pass "ninguna ruta retorna vacio y first falla"; else fail "caso sin estado incorrecto"; fi

echo "[root/subdirectorios/fallo] escritura exclusivamente canonica"
SUB=$(call "$TMP" mefisto_state_path summaries/stage-1-writer.md "$ROOT")
if [ "$SUB" = "$ROOT/.mefisto/pipeline/summaries/stage-1-writer.md" ] && [ -d "$ROOT/.mefisto/pipeline/summaries" ]; then pass "root explicito y subdirectorio"; else fail "root explicito incorrecto"; fi
printf legacy > "$ROOT/.claude/pipeline/logs/events.log"
BEFORE=$(shasum "$ROOT/.claude/pipeline/logs/events.log")
CANON=$(call "$TMP" mefisto_state_path logs/events.log "$ROOT")
printf canon > "$CANON"
AFTER=$(shasum "$ROOT/.claude/pipeline/logs/events.log")
if [ "$BEFORE" = "$AFTER" ] && [ "$CANON" = "$ROOT/.mefisto/pipeline/logs/events.log" ]; then pass "legacy queda inalterado"; else fail "legacy fue alterado"; fi
BAD="$TMP/bad"; mkdir -p "$BAD/.mefisto/pipeline"; printf file > "$BAD/.mefisto/pipeline/logs"
BAD_STDOUT="$TMP/bad.stdout"
if ! call "$TMP" mefisto_state_path logs/x.log "$BAD" >"$BAD_STDOUT" 2>/dev/null && [ ! -s "$BAD_STDOUT" ]; then pass "fallo al crear padre no imprime ruta utilizable"; else fail "mkdir imposible devolvio exito o imprimio una ruta"; fi

echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
