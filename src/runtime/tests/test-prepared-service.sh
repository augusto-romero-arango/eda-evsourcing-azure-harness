#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUNNER="$ROOT/src/runtime/mefisto-run-agent.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
mkdir -p "$TMP/bin" "$TMP/wt" "$TMP/work"; printf 'prompt\n' > "$TMP/prompt"

cat > "$TMP/bin/opencode" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = serve ]; then
  printf '%s\n' 'listening http://127.0.0.1:43123'
  sleep 60
fi
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
args_file="${MEFISTO_TEST_CURL_ARGS:?}"
: > "$args_file"
for arg in "$@"; do printf '%s\n' "$arg" >> "$args_file"; done
cat > "${MEFISTO_TEST_CURL_CONFIG:?}"
printf '%s' '{"version":"stub-1"}'
EOF
chmod +x "$TMP/bin/opencode" "$TMP/bin/curl"

PATH="$TMP/bin:$PATH" MEFISTO_TEST_CURL_ARGS="$TMP/curl-args" MEFISTO_TEST_CURL_CONFIG="$TMP/curl-config" bash -c '
  source "$1/src/runtime/lib/mefisto-runtime.sh"
  runtime_service_start opencode "$2/wt" "$2/work" 3 || exit 10
  [ "$MEFISTO_RUNTIME_SERVICE_ENDPOINT" = http://127.0.0.1:43123 ] || exit 11
  [ "$MEFISTO_RUNTIME_SERVICE_VERSION" = stub-1 ] || exit 12
  runtime_service_request opencode GET /agent "$2/work" >/dev/null || exit 13
  runtime_service_stop opencode || exit 14
' _ "$ROOT" "$TMP"
[ $? -eq 0 ] && pass || fail "ciclo start/request/stop"
if grep -q 'opencode:' "$TMP/curl-args" "$TMP/work/runtime-service.log" 2>/dev/null; then fail "credencial no debe estar en argv ni log"; else pass; fi

MEFISTO_FAKE_SCRIPT=success "$RUNNER" --runtime fake --agent logical --execution-agent technical --cwd "$TMP/wt" --prompt-file "$TMP/prompt" --event-log "$TMP/events" >/dev/null 2>&1
[ $? -eq 64 ] && pass || fail "alias sin endpoint debe fallar antes de ejecutar"
MEFISTO_FAKE_SCRIPT=success "$RUNNER" --runtime fake --agent logical --runtime-endpoint http://example.test:9 --cwd "$TMP/wt" --prompt-file "$TMP/prompt" --event-log "$TMP/events2" >/dev/null 2>&1
[ $? -eq 64 ] && pass || fail "endpoint remoto debe fallar antes de ejecutar"

echo "RESULTADO servicio preparado: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]
