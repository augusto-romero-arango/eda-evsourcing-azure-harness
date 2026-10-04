#!/usr/bin/env bash
# Wiring de la ejecucion preparada en los cuatro pipelines de agentes (#1860).
# Dobles sin red ni LLM: un launcher falso y un runner falso en un paquete temporal.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (esperado '$2', obtenido '$1')"; fi; }

# --- inventario de emisores (CA-2) ---
total=0
for p in tdd tooling iac scaffold; do
    f="$REPO_ROOT/scripts/$p-pipeline.sh"
    direct="$(grep -c '"\$RUN_AGENT_BIN" "\${args\[@\]}"' "$f" | tr -d ' ')"
    via="$(grep -c 'pipeline_run_runner "\$RUN_AGENT_BIN" "\${args\[@\]}"' "$f" | tr -d ' ')"
    # la unica aparicion directa permitida es dentro de pipeline_run_runner (no en el pipeline)
    eq "$((direct - via))" "0" "$p: ningun emisor directo fuera de pipeline_run_runner"
    total=$((total + via))
    eq "$(grep -c '^pipeline_execution_open '"$p"' ' "$f" | tr -d ' ')" "1" "$p: abre la ejecucion una vez antes del worktree"
    [ "$(grep -c 'pipeline_execution_close' "$f")" -ge 1 ] && pass "$p: cierra en la finalizacion existente" || fail "$p: sin close"
    eq "$(grep -c 'pipeline_runner_started_or_abort' "$f" | tr -d ' ')" "$via" "$p: cada emisor aborta ante not-started"
done
eq "$total" "5" "cinco emisores cableados (tdd x2, tooling, iac, scaffold)"

# --- comportamiento de la libreria con dobles ---
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
PKG="$TMP/pkg"; mkdir -p "$PKG/scripts" "$PKG/src/runtime/lib"
cp "$REPO_ROOT/scripts/_pipeline-common.sh" "$PKG/scripts/"
cat > "$PKG/scripts/run-published-agent.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${FAKE_LAUNCHER_ARGV:?}"
exit "${FAKE_LAUNCHER_RC:-0}"
SH
chmod +x "$PKG/scripts/run-published-agent.sh"
cat > "$TMP/runner.sh" <<'SH'
#!/usr/bin/env bash
printf 'legacy\n%s\n' "$@" > "${FAKE_RUNNER_ARGV:?}"
exit "${FAKE_RUNNER_RC:-0}"
SH
chmod +x "$TMP/runner.sh"
export FAKE_LAUNCHER_ARGV="$TMP/launcher.argv" FAKE_RUNNER_ARGV="$TMP/runner.argv"
LIBS="$REPO_ROOT/scripts/_pipeline-common.sh"

run() { # env-prefix... ; script en stdin
    env -u MEFISTO_EXECUTION_CONTEXT -u MEFISTO_EXECUTION_DIGEST -u MEFISTO_RUNTIME_LIB_DIR -u MEFISTO_RUN_AGENT_BIN "$@" bash -c "source '$LIBS'; abort() { echo \"ABORT:\$1\"; return 1; }; $SCRIPT_BODY" 2>&1
}

# sin contexto ni perfil (Claude): camino legacy, sin launcher
SCRIPT_BODY='MEFISTO_RESOLVED_RUNTIME=claude; pipeline_execution_open tooling "'"$TMP"'" "'"$PKG"'" "'"$PKG"'/src/runtime/lib" "'"$TMP"'/runner.sh"; echo "open=$? en=${MEFISTO_EXECUTION_ENABLED:-0}"; pipeline_run_runner "'"$TMP"'/runner.sh" --agent x; echo "rc=$? ns=$PIPELINE_RUNNER_NOT_STARTED"'
OUT="$(run)"
case "$OUT" in *"open=0 en=0"*"rc=0 ns=0"*) pass "sin contexto: legacy sin servicio ni lease" ;; *) fail "legacy: $OUT" ;; esac
[ -f "$FAKE_RUNNER_ARGV" ] && [ ! -f "$FAKE_LAUNCHER_ARGV" ] && pass "legacy invoca el runner con el argv actual" || fail "legacy no uso el runner"

# contexto transportado invalido: nunca degrada a legacy
rm -f "$FAKE_RUNNER_ARGV" "$FAKE_LAUNCHER_ARGV"
SCRIPT_BODY='pipeline_execution_open tooling "'"$TMP"'" "'"$PKG"'" "'"$PKG"'/src/runtime/lib" "'"$TMP"'/runner.sh"; echo "open=$?"'
OUT="$(run MEFISTO_EXECUTION_CONTEXT=relativo/.mefisto/pipeline/autonomy/runs/r/contexts/c.json MEFISTO_EXECUTION_DIGEST=abc)"
case "$OUT" in *"open=1"*) pass "ruta de contexto ambigua se rechaza" ;; *) fail "ruta ambigua: $OUT" ;; esac
OUT="$(run MEFISTO_EXECUTION_CONTEXT="$TMP/.mefisto/pipeline/autonomy/runs/r/contexts/c.json" MEFISTO_EXECUTION_DIGEST=abc MEFISTO_RUN_AGENT_BIN=/tmp/otro-runner)"
case "$OUT" in *"open=1"*) pass "override del runner se rechaza en modo controlado" ;; *) fail "override: $OUT" ;; esac
OUT="$(run MEFISTO_EXECUTION_CONTEXT="$TMP/.mefisto/pipeline/autonomy/runs/r/contexts/c.json" MEFISTO_EXECUTION_DIGEST=abc MEFISTO_RUNTIME_LIB_DIR="$TMP")"
case "$OUT" in *"open=1"*) pass "libreria de runtime heredada distinta de la release fisica se rechaza" ;; *) fail "lib heredada: $OUT" ;; esac
OUT="$(run MEFISTO_EXECUTION_CONTEXT="$TMP/.mefisto/pipeline/autonomy/runs/r/contexts/c.json" MEFISTO_EXECUTION_DIGEST=abc)"
case "$OUT" in *"open=1"*) pass "contexto inexistente/no validable no degrada a legacy" ;; *) fail "ctx invalido: $OUT" ;; esac
[ ! -f "$FAKE_RUNNER_ARGV" ] && pass "ningun runner se lanzo ante un contexto invalido" || fail "se lanzo el runner"

# rama controlada -> launcher; 75/78 = not-started; otros exits pasan tal cual
for rc in 78 75; do
    SCRIPT_BODY='PIPELINE_EXEC_KIND=tooling; PIPELINE_EXEC_PKG="'"$PKG"'"; MEFISTO_EXECUTION_ENABLED=1; MEFISTO_EXECUTION_CONTEXT=/c.json; MEFISTO_EXECUTION_DIGEST=d; pipeline_run_runner "'"$TMP"'/runner.sh" --agent a --cwd /w; echo "rc=$? ns=$PIPELINE_RUNNER_NOT_STARTED"; pipeline_runner_started_or_abort writer; echo "tras-abort=$?"'
    OUT="$(run FAKE_LAUNCHER_RC=$rc)"
    case "$OUT" in *"rc=$rc ns=1"*"ABORT:writer"*) pass "exit $rc del launcher aborta antes de cualquier recuperacion" ;; *) fail "exit $rc: $OUT" ;; esac
done
OUT="$(run FAKE_LAUNCHER_RC=1)"
case "$OUT" in *"rc=1 ns=0"*) pass "exit del runner tras iniciar conserva sus politicas (no es not-started)" ;; *) fail "rc=1: $OUT" ;; esac
grep -qx -- '--pipeline' "$FAKE_LAUNCHER_ARGV" && grep -qx -- 'tooling' "$FAKE_LAUNCHER_ARGV" && grep -qx -- '--cwd' "$FAKE_LAUNCHER_ARGV" \
    && pass "launcher recibe pipeline, contexto y el argv original" || fail "argv del launcher"

# cierre: sin ejecucion habilitada es no-op y nunca altera el exit
SCRIPT_BODY='MEFISTO_EXECUTION_ENABLED=0; pipeline_execution_close 1; echo "close=$?"'
OUT="$(run)"; case "$OUT" in *"close=0"*) pass "close sin ejecucion habilitada no hace nada" ;; *) fail "close: $OUT" ;; esac
SCRIPT_BODY='MEFISTO_EXECUTION_ENABLED=1; published_execution_close() { echo "outcome=$1"; return 3; }; pipeline_execution_close 143; echo "close=$?"'
OUT="$(run)"; case "$OUT" in *"close=0"*) pass "un fallo de limpieza no altera el exit" ;; *) fail "close fallo: $OUT" ;; esac

printf '\n%s pasaron, %s fallaron\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
